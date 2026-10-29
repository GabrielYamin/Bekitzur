import AVFoundation
import BekitzurCapture
import Observation

/// Plays a Conversation's Recording, with both tracks of a call together, and reports where it is so the Transcript
/// can follow along.
@Observable
@MainActor
final class PlaybackModel {
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    /// The part playing on its own, like a line a Speaker said, which stops at its end.
    private(set) var clip: ClosedRange<Double>?
    var rate: Float = 1 {
        didSet {
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
        }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var clipEndObserver: Any?

    isolated deinit {
        stop()
    }

    /// - Parameter microphoneDelay: Seconds the microphone track starts later than the others, to line up a call.
    func load(_ tracks: [URL], microphoneDelay: Double = 0) async {
        stop()
        let composition = AVMutableComposition()
        do {
            for url in tracks {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let length = try await asset.load(.duration)
                let lane = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let isMicrophone = url.deletingPathExtension().lastPathComponent == ConversationRecorder.Track.microphone.name
                let start = isMicrophone ? CMTime(seconds: microphoneDelay, preferredTimescale: 48_000) : .zero
                try lane?.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: start)
            }
        } catch {
            AppLog.write("Playback couldn't load \(tracks.map(\.lastPathComponent)): \(error)")
            return
        }
        guard !composition.tracks.isEmpty else { return }

        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.endClip()
            }
        }
        self.player = player
        duration = composition.duration.seconds
        isLoaded = true
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        endClip()
        if time >= duration - 0.1 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    /// Plays just `clip`, and stops at its end. A boundary observer rather than the time updates, since an update
    /// queued before the seek would report the old time and stop the clip as it starts.
    func play(_ clip: ClosedRange<Double>) {
        seek(to: clip.lowerBound)
        play()
        guard let player else { return }
        self.clip = clip
        let end = NSValue(time: CMTime(seconds: clip.upperBound, preferredTimescale: 600))
        clipEndObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        endClip()
    }

    func seek(to seconds: Double) {
        endClip()
        time = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        endClip()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        isLoaded = false
        time = 0
        duration = 0
    }

    private func endClip() {
        if let clipEndObserver { player?.removeTimeObserver(clipEndObserver) }
        clipEndObserver = nil
        clip = nil
    }
}
