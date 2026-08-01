import AVFoundation
import Foundation

@MainActor
final class AudioPlayerModel: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isAvailable = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        stop()

        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            isAvailable = false
            duration = 0
            return
        }

        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
        isAvailable = true
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
    }
}

extension AudioPlayerModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.currentTime = 0
        }
    }
}
