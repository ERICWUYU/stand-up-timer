import Foundation
import StandUpTimerCore
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Permission: Equatable {
        case unavailable
        case unknown
        case authorized
        case denied
    }

    private enum Identifier {
        static let focusEnd = "stand-up-timer.focus-end"
        static let breakEnd = "stand-up-timer.break-end"
    }

    /// 一条待排程提醒的完整描述，让专注和休息走同一条排程路径。
    private struct Descriptor {
        let baseIdentifier: String
        let title: String
        let body: String
        let fireDate: Date
    }

    private let center: UNUserNotificationCenter?

    /// 本管理器已经排程、尚未撤销的 identifier。
    /// 只撤销这些，不触碰本应用的其他通知，也不清空用户可见的送达历史。
    private var scheduledIdentifiers: [String] = []

    override init() {
        center = Self.notificationCenterIfSupported()

        super.init()
        center?.delegate = self
    }

    /// UNUserNotificationCenter.current() 在非 .app 进程中会抛异常。
    private static func notificationCenterIfSupported() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    func currentPermission() async -> Permission {
        guard let center else { return .unavailable }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .unknown
        case .denied:
            return .denied
        case .authorized, .provisional:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorizationIfNeeded() async -> Permission {
        guard let center else { return .unavailable }

        let permission = await currentPermission()
        guard permission == .unknown else { return permission }

        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound]
            )
            return granted ? .authorized : .denied
        } catch {
            // 请求失败是通知服务层的错误，不代表用户拒绝。
            // 回读真实状态；仍然未知时保留“未知”，界面会给出可重试的提示。
            NSLog("通知授权请求失败：\(error)")
            return await currentPermission()
        }
    }

    /// 把核心算出的整条未来提醒序列写入系统。
    ///
    /// 时间线由 `ReminderTimeline` 一次性算好（绝对时间点），这里只负责写入，
    /// 因此通知中心的等待时间不会把后续提醒整体推后，也不会漏掉休眠期间的阶段。
    /// 返回是否所有提醒都写入成功；失败原因会展示在面板上。
    @discardableResult
    func replacePending(
        events: [ReminderEvent],
        sound: ReminderSoundPreference,
        language: AppLanguage
    ) async -> Bool {
        guard let center else { return false }

        // 通知文案跟随界面语言，和面板上的文字保持一致。
        let descriptors = events.map { event -> Descriptor in
            switch event.kind {
            case .focusEnd:
                return Descriptor(
                    baseIdentifier: Identifier.focusEnd,
                    title: L10n.text("notification.focusEnd.title", language: language),
                    body: L10n.text("notification.focusEnd.body", language: language),
                    fireDate: event.fireDate
                )
            case .restEnd:
                return Descriptor(
                    baseIdentifier: Identifier.breakEnd,
                    title: L10n.text("notification.breakEnd.title", language: language),
                    body: L10n.text("notification.breakEnd.body", language: language),
                    fireDate: event.fireDate
                )
            }
        }

        guard !descriptors.isEmpty else {
            // 一个有效时间点都没有时不能报告排程成功。
            await retireScheduled(in: center)
            return false
        }

        // 先写入新提醒，成功后再撤掉上一轮：任何一步失败都还留着旧提醒，
        // 不会出现“旧的已删、新的没排上”的空窗。
        // 每条请求都用唯一 identifier：复用 identifier 会被系统当作
        // “更新已有通知”送达，而更新不会播放声音——这正是切换声音后
        // 第一条提醒静音的原因。
        var added: [String] = []
        for descriptor in descriptors {
            let identifier = "\(descriptor.baseIdentifier).\(UUID().uuidString)"
            let scheduled = await add(
                identifier: identifier,
                title: descriptor.title,
                body: descriptor.body,
                fireDate: descriptor.fireDate,
                sound: sound,
                center: center
            )
            guard scheduled else {
                // 回滚本轮已写入的部分，让上一轮的提醒继续生效。
                center.removePendingNotificationRequests(withIdentifiers: added)
                return false
            }
            added.append(identifier)
        }

        await retireScheduled(in: center)
        scheduledIdentifiers = added
        return true
    }

    func cancelPending() {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        scheduledIdentifiers = []
    }

    /// 清除提醒并等待通知中心确认，避免进程退出后仍触发残留提醒。
    func cancelPendingAndWait() async {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        scheduledIdentifiers = []
        // 查询待发请求会等待通知中心回应，可作为删除已生效的屏障。
        _ = await center.pendingNotificationRequests()
    }

    /// 撤掉上一轮排程的提醒，避免同一阶段重复触发。
    private func retireScheduled(in center: UNUserNotificationCenter) async {
        guard !scheduledIdentifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: scheduledIdentifiers)
        scheduledIdentifiers = []
        // 查询待发请求作为删除生效的屏障，避免新旧请求交错。
        _ = await center.pendingNotificationRequests()
    }

    private func add(
        identifier: String,
        title: String,
        body: String,
        fireDate: Date,
        sound: ReminderSoundPreference,
        center: UNUserNotificationCenter
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let chosen = sound.notificationSound {
            // 使用系统提示音（/System/Library/Sounds）。系统会按文件名解析，
            // 文件缺失时退回默认提示音而不是崩溃。
            content.sound = UNNotificationSound(
                named: UNNotificationSoundName(chosen.fileName)
            )
        } else {
            // 关闭声音：通知照常送达，但不带 sound。
            content.sound = nil
        }

        // 间隔在写入前一刻按绝对触发时间换算，
        // 通知中心的等待时间不会把提醒整体推后。
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, fireDate.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            return true
        } catch {
            // 保留失败原因便于排查；面板同时会显示排程失败提示。
            NSLog("提醒排程失败（\(identifier)）：\(error)")
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
