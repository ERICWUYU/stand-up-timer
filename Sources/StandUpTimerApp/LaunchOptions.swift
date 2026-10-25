import Foundation

enum LaunchOptions {
    /// 人工验证通知时可传入 `--test-durations 10`，
    /// 把专注和休息都设为 10 秒。
    ///
    /// 这个覆盖只作用于本次进程：既不恢复旧状态，也不写回设置和计时状态。
    static var overrideDuration: TimeInterval? {
        let arguments = CommandLine.arguments
        guard
            let index = arguments.firstIndex(of: "--test-durations"),
            arguments.indices.contains(index + 1),
            let seconds = TimeInterval(arguments[index + 1]),
            // inf / 1e309 会溢出成正无穷，StandUpTimer 的前置条件会直接崩溃。
            seconds.isFinite,
            seconds > 0
        else {
            return nil
        }
        return seconds
    }
}
