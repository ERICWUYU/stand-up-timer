import Foundation
import StandUpTimerCore

/// 历史持久化的非致命问题，供未来的统计界面提示；不影响计时运行。
enum HistoryNotice: Equatable {
    /// 历史文件无法解析或版本未知，原始字节已备份到关联 URL，本次以空历史开始。
    case corruptFileQuarantined(backup: URL)
    /// 存储目录或文件根本不可用（创建/备份失败），本进程退化为不落盘的内存历史。
    case storageUnavailable
    /// 一次追加写入失败，计时与内存状态不受影响。
    case writeFailed
}

/// 基于 Application Support 的本地 JSON 文件历史存储。
///
/// 职责仅限文件 I/O：编解码、版本判定、合并去重全部复用 Core 的
/// `ActivityHistoryCodec`，使策略逻辑可以在测试 target 中单测。
/// 纯离线，没有任何网络或分析行为。
final class FileHistoryStore: ActivityHistoryStoring {
    /// 原子写入操作：把 data 落到 target，失败时自行清理临时文件并抛错。
    /// 默认实现基于同目录临时文件 + FileManager 替换；测试可注入失败替身。
    typealias AtomicWrite = (_ data: Data, _ target: URL) throws -> Void

    private enum Constants {
        static let directoryName = "StandUpTimer"
        static let fileName = "activity-history.json"
        static let corruptPrefix = "activity-history.corrupt-"
        static let corruptSuffix = ".json"
        static let temporaryPrefix = ".activity-history."
        static let temporarySuffix = ".tmp"
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let atomicWrite: AtomicWrite
    private let lock = NSLock()
    private var cachedRecords: [ActivityRecord]

    /// 初始化时完成一次加载与（可能的）损坏隔离；非 nil 表示需要向用户提示。
    private(set) var loadNotice: HistoryNotice?

    /// 生产入口：固定使用当前用户的 Application Support 目录。
    convenience init(fileManager: FileManager = .default) throws {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(Constants.directoryName, isDirectory: true)
        try self.init(directoryURL: directory, fileManager: fileManager, atomicWrite: nil)
    }

    /// 可注入目录的初始化器，仅供测试与组合根使用；测试借此完全避开
    /// 用户真实的 Application Support。
    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        atomicWrite: AtomicWrite? = nil
    ) throws {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(Constants.fileName)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // 默认原子写入器需要目录与 FileManager，在这里闭包捕获。
        let resolvedWriter: AtomicWrite = atomicWrite ?? { [directoryURL, fileManager] data, target in
            try FileHistoryStore.defaultAtomicWrite(
                data,
                to: target,
                in: directoryURL,
                fileManager: fileManager
            )
        }
        self.atomicWrite = resolvedWriter

        let presentData = fileManager.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL)
            : nil

        switch ActivityHistoryCodec.inspect(presentData: presentData) {
        case .noFile:
            cachedRecords = []
        case let .restored(records):
            // 防御性保证内存中始终是规范的时间升序、去重状态。
            cachedRecords = ActivityHistoryCodec.merge(existing: records, appending: [])
        case let .corrupt(bytes):
            // 关键约束：先把损坏字节原样备份，再把主文件原子替换为合法的
            // 空信封。任一步失败都直接抛出，原文件保持不动、可恢复，
            // 由 TimerModel 退化为内存存储；绝不静默覆盖不可读数据。
            let backupURL = try Self.quarantine(
                bytes: bytes,
                in: directoryURL,
                fileManager: fileManager
            )
            do {
                let emptyEnvelope = try ActivityHistoryCodec.encode([])
                try resolvedWriter(emptyEnvelope, fileURL)
            } catch {
                // 替换失败：备份已落盘，原始损坏文件仍在原处，初始化宣告失败。
                throw error
            }
            cachedRecords = []
            loadNotice = .corruptFileQuarantined(backup: backupURL)
        }
    }

    func loadRecords() -> [ActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return cachedRecords
    }

    func append(_ records: [ActivityRecord]) throws {
        guard !records.isEmpty else { return }

        // 一把锁覆盖合并、编码、原子替换与缓存更新：defer 保证任何路径
        // （包括编码抛错）都释放锁，后续调用不会死锁。
        lock.lock()
        defer { lock.unlock() }

        let merged = ActivityHistoryCodec.merge(
            existing: cachedRecords,
            appending: records
        )
        // 编码在锁内、替换之前：失败时磁盘与缓存都不变，锁由 defer 释放。
        let data = try ActivityHistoryCodec.encode(merged)
        try atomicWrite(data, fileURL)
        // 只有持久化替换成功后才更新内存缓存。
        cachedRecords = merged
    }

    /// 默认原子写入：同目录唯一临时文件 → 已存在则 replaceItemAt，否则 moveItem。
    /// 失败时清理临时文件并原样抛错，不吞掉原始错误。
    static func defaultAtomicWrite(
        _ data: Data,
        to target: URL,
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let temporaryURL = directory.appendingPathComponent(
            "\(Constants.temporaryPrefix)\(UUID().uuidString)\(Constants.temporarySuffix)"
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// 把损坏字节写到明确命名的备份文件，文件名含 UTC 时间戳，必要时追加序号。
    private static func quarantine(
        bytes: Data,
        in directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())

        var candidate = directory
            .appendingPathComponent("\(Constants.corruptPrefix)\(stamp)\(Constants.corruptSuffix)")
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                "\(Constants.corruptPrefix)\(stamp)-\(counter)\(Constants.corruptSuffix)"
            )
            counter += 1
        }
        try bytes.write(to: candidate, options: .atomic)
        return candidate
    }
}
