import AVFoundation
import StandUpTimerCore

/// 试听通知声音。声音来自系统提示音目录，与通知实际播放的是同一个文件。
@MainActor
final class SoundPreviewPlayer {
    private var player: AVAudioPlayer?

    /// 返回是否成功开始播放，便于界面提示。
    @discardableResult
    func play(_ sound: NotificationSound) -> Bool {
        player?.stop()
        player = nil

        let url = URL(fileURLWithPath: sound.systemPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            return player.play()
        } catch {
            return false
        }
    }
}
