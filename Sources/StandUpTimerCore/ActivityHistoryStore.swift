import Foundation

/// 活动历史的窄存储协议。
///
/// 核心只依赖协议与纯编解码/合并规则，文件系统实现由 App 层提供，
/// 测试使用 `InMemoryActivityHistory`。协议方法同步且不隔离到特定 actor，
/// 具体实现自行保证内部线程安全。
public protocol ActivityHistoryStoring: AnyObject {
    /// 读取当前全部记录，按时间升序排列。
    func loadRecords() -> [ActivityRecord]
    /// 追加记录：按稳定 id 去重、保持时间顺序后落盘。
    /// 磁盘失败时抛错，调用方必须把它当作非致命错误处理，不能影响计时。
    func append(_ records: [ActivityRecord]) throws
}

/// 历史读写可能出现的非致命错误。
public enum ActivityHistoryError: Error, Equatable {
    /// 数据存在但无法解析为受支持的历史信封；关联值为原始字节，
    /// App 层应先把这些字节备份到明确命名的文件，再以空历史重新开始。
    case corruptEnvelope(Data)
    /// 信封版本不受当前实现支持。
    case unsupportedVersion(Int)
    /// 单条记录未通过解码校验（schema、语义字段、时长或幂等 id）。
    /// 整个文件按损坏处理并保留原始字节，不做就地修复。
    case invalidRecord(reason: String)
}

/// 磁盘加载的三种判定结果，把“损坏保留”策略做成可单测的纯逻辑，
/// 不依赖 FileManager。
public enum ActivityHistoryLoadOutcome: Equatable, Sendable {
    /// 历史文件不存在，从空历史开始。
    case noFile
    /// 成功解析。
    case restored([ActivityRecord])
    /// 文件损坏，关联值为需要原样备份的字节。
    case corrupt(Data)
}

/// 版本化 JSON 信封与纯持久化规则。
public enum ActivityHistoryCodec {
    /// 信封结构版本（与单条记录的 schemaVersion 独立）。
    public static let envelopeVersion = 1

    public static func encode(_ records: [ActivityRecord]) throws -> Data {
        // 写入侧复用与解码完全相同的校验（含规范 id）：非法记录在生成任何
        // JSON 之前就被拒绝，不能落盘后等到下次启动把整份历史判为损坏。
        // 不静默修正、丢弃或部分写入，统一抛 invalidRecord。
        for record in records {
            try ActivityRecord.validate(record)
        }
        let envelope = Envelope(
            envelopeVersion: Self.envelopeVersion,
            records: records
        )
        return try JSONEncoder().encode(envelope)
    }

    /// 解析信封并校验版本与每条记录；损坏或版本未知时抛 `ActivityHistoryError`。
    ///
    /// 记录级校验错误（`.invalidRecord`）原样向上抛出，保留具体原因；
    /// 语法级损坏统一包装为 `.corruptEnvelope` 并携带原始字节。
    public static func decode(_ data: Data) throws -> [ActivityRecord] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as ActivityHistoryError {
            throw error
        } catch {
            throw ActivityHistoryError.corruptEnvelope(data)
        }
        guard envelope.envelopeVersion == Self.envelopeVersion else {
            throw ActivityHistoryError.unsupportedVersion(envelope.envelopeVersion)
        }
        return envelope.records
    }

    /// 把一次原始读取映射为加载结果：nil 表示无文件，损坏或版本未知时
    /// 原始字节原样返回，由 App 层负责备份后以空历史替换，绝不静默覆盖。
    public static func inspect(presentData data: Data?) -> ActivityHistoryLoadOutcome {
        guard let data else { return .noFile }
        do {
            return .restored(try decode(data))
        } catch {
            // ActivityHistoryError 的两种情况（损坏、版本未知）都保留原字节；
            // 未来版本不可读时同样不能无声抹掉用户数据。
            return .corrupt(data)
        }
    }

    /// 合并已有记录与新记录：
    /// - 按稳定 id 去重，已存在的 id 保留先到记录（重放转换不会产生重复）；
    /// - 按日期升序稳定排序，同日期保持原有相对顺序，离线追赶插入的旧时刻
    ///   记录也能落到正确位置。
    public static func merge(
        existing: [ActivityRecord],
        appending additions: [ActivityRecord]
    ) -> [ActivityRecord] {
        var seen = Set<String>()
        var ordered: [(index: Int, record: ActivityRecord)] = []
        ordered.reserveCapacity(existing.count + additions.count)

        func ingest(_ record: ActivityRecord, index: Int) {
            guard !seen.contains(record.id) else { return }
            seen.insert(record.id)
            ordered.append((index, record))
        }

        for (index, record) in existing.enumerated() {
            ingest(record, index: index)
        }
        for (offset, record) in additions.enumerated() {
            ingest(record, index: existing.count + offset)
        }

        return ordered
            .sorted { lhs, rhs in
                if lhs.record.date != rhs.record.date {
                    return lhs.record.date < rhs.record.date
                }
                return lhs.index < rhs.index
            }
            .map(\.record)
    }
}

/// 历史信封的磁盘表示，版本字段在前，便于未来迁移。
private struct Envelope: Codable {
    let envelopeVersion: Int
    let records: [ActivityRecord]

    enum CodingKeys: String, CodingKey {
        case envelopeVersion
        case records
    }
}

/// 测试与无磁盘环境使用的内存历史存储，可按需注入读取/写入错误。
public final class InMemoryActivityHistory: ActivityHistoryStoring {
    private var records: [ActivityRecord] = []
    private let appendError: Error?
    /// 每次 append 调用的入参，便于断言写入时机与测试时长模式不写历史。
    public private(set) var appendCalls: [[ActivityRecord]] = []

    public init(appendError: Error? = nil) {
        self.appendError = appendError
    }

    public func loadRecords() -> [ActivityRecord] {
        records
    }

    public func append(_ newRecords: [ActivityRecord]) throws {
        appendCalls.append(newRecords)
        if let appendError { throw appendError }
        records = ActivityHistoryCodec.merge(existing: records, appending: newRecords)
    }
}
