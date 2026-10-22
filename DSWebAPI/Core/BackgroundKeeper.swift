import Foundation
import AVFoundation

/// 切到后台时用一段静音音频保活，让本地 API 服务继续在线。
/// （iOS 会挂起普通 App；靠 audio 后台模式 + 静音循环可以继续跑网络监听）
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard let url = Bundle.main.url(forResource: "silent", withExtension: "wav") else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        self.player = player
        isRunning = true
    }

    func stop() {
        player?.stop()
        player = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    var running: Bool { isRunning }
}
