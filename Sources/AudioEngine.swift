import AVFoundation
import Foundation

/// Manages playback of a single PCM buffer segment via AVAudioEngine.
final class AudioEngine {

    // MARK: Shared instance

    static let shared = AudioEngine()
    private init() { setupEngine() }

    // MARK: Private

    private let engine  = AVAudioEngine()
    private let player  = AVAudioPlayerNode()
    private let mixer   = AVAudioMixerNode()

    // MARK: Playback tracking

    private(set) weak var playingDocument: AudioDocument?
    private var playbackStartSample: Int = 0
    private var playbackSampleRate: Double = 44100
    private var accumulatedSamples: Int = 0   // samples elapsed before latest resume
    private var resumeDate: Date = Date()
    private var _isPaused: Bool = false

    /// True while the player is paused (not stopped).
    var isPaused: Bool { _isPaused }

    /// Current sample position in the original buffer, or nil if fully stopped.
    var currentPlaybackSample: Int? {
        guard player.isPlaying || _isPaused else { return nil }
        if _isPaused {
            return playbackStartSample + accumulatedSamples
        }
        let elapsed = max(0, Date().timeIntervalSince(resumeDate))
        return playbackStartSample + accumulatedSamples + Int(elapsed * playbackSampleRate)
    }

    // MARK: Setup

    private func setupEngine() {
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: nil)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
        } catch {
            print("[AudioEngine] Failed to start engine: \(error)")
        }
    }

    // MARK: Volume  (0.0 … 2.0, where 1.0 = unity gain)

    var volume: Float {
        get { mixer.outputVolume }
        set { mixer.outputVolume = max(0, min(newValue, 2.0)) }
    }

    // MARK: Playback

    /// Play a portion (or all) of a buffer.
    /// - Parameters:
    ///   - buffer:    The full PCM buffer.
    ///   - selection: Optional sample range to play.  Nil plays the whole buffer.
    ///   - document:  The document being played (used for playhead tracking).
    func play(buffer: AVAudioPCMBuffer, selection: ClosedRange<Int>? = nil, document: AudioDocument? = nil) {
        stop()

        let format = buffer.format
        let totalFrames = Int(buffer.frameLength)

        let startFrame = selection?.lowerBound ?? 0
        let endFrame   = selection?.upperBound ?? (totalFrames - 1)
        let frameCount = max(0, endFrame - startFrame + 1)
        guard frameCount > 0 else { return }

        // Reconnect with the correct format if needed
        if player.outputFormat(forBus: 0) != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: mixer, format: format)
        }

        // Restart engine if stopped (e.g. after audio route change)
        if !engine.isRunning {
            try? engine.start()
        }

        // Slice the buffer
        guard let slice = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        slice.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(format.channelCount)
        if let src = buffer.floatChannelData, let dst = slice.floatChannelData {
            for ch in 0 ..< channelCount {
                memcpy(dst[ch], src[ch] + startFrame, frameCount * MemoryLayout<Float>.size)
            }
        }

        // Store tracking info before playback starts
        playingDocument     = document
        playbackStartSample = startFrame
        playbackSampleRate  = format.sampleRate
        accumulatedSamples  = 0
        _isPaused           = false
        resumeDate          = Date()

        player.scheduleBuffer(slice, completionHandler: nil)
        player.play()
    }

    func pause() {
        guard player.isPlaying else { return }
        accumulatedSamples += Int(Date().timeIntervalSince(resumeDate) * playbackSampleRate)
        _isPaused = true
        player.pause()
    }

    func resume() {
        guard _isPaused else { return }
        _isPaused  = false
        resumeDate = Date()
        player.play()
    }

    func stop() {
        player.stop()
        playingDocument    = nil
        _isPaused          = false
        accumulatedSamples = 0
    }

    /// Jump playback to a new sample position, preserving play/pause state.
    func seek(toSample sample: Int, in buffer: AVAudioPCMBuffer, document: AudioDocument) {
        let wasPlaying = player.isPlaying
        let wasPaused  = _isPaused
        guard wasPlaying || wasPaused else { return }

        player.stop()

        let format      = buffer.format
        let totalFrames = Int(buffer.frameLength)
        let startFrame  = max(0, min(sample, totalFrames - 1))
        let frameCount  = totalFrames - startFrame
        guard frameCount > 0 else { return }

        guard let slice = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        slice.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(format.channelCount)
        if let src = buffer.floatChannelData, let dst = slice.floatChannelData {
            for ch in 0 ..< channelCount {
                memcpy(dst[ch], src[ch] + startFrame, frameCount * MemoryLayout<Float>.size)
            }
        }

        playingDocument     = document
        playbackStartSample = startFrame
        playbackSampleRate  = format.sampleRate
        accumulatedSamples  = 0
        _isPaused           = wasPaused
        resumeDate          = Date()

        player.scheduleBuffer(slice, completionHandler: nil)
        if wasPlaying {
            player.play()
        }
        // If was paused: buffer is scheduled, resume() will start it
    }

    var isPlaying: Bool { player.isPlaying }
}
