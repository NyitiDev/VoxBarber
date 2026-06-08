import Foundation
import AVFoundation
import SFBAudioEngine
import os

/// Hangfájlok betöltése, lejátszása és mentése.
///
/// - Betöltés: SFBAudioEngine → Float32 PCM → `AudioBuffer`
///   Támogatott: WAV, MP3, AAC, FLAC, OGG, Opus, WavPack, stb.
/// - Lejátszás: `AVAudioEngine` + `AVAudioPlayerNode`
/// - Mentés: AVAudioFile (WAV, AAC, FLAC) + SFBAudioEngine (MP3 – következő iteráció)
@MainActor
public final class AudioEngine {

    // MARK: – Diagnosztika

    private let log = Logger(subsystem: "VoxBarber", category: "AudioEngine")

    // MARK: – Singleton

    public static let shared = AudioEngine()
    private init() { setupAVEngine() }

    // MARK: – AVAudioEngine (lejátszáshoz)

    private let avEngine   = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private func setupAVEngine() {
        avEngine.attach(playerNode)
        avEngine.connect(playerNode, to: avEngine.mainMixerNode, format: nil)
        do {
            try avEngine.start()
        } catch {
            log.error("AVAudioEngine indítása sikertelen (setup): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: – Betöltés

    /// Betölti a fájlt és visszaadja az `AudioBuffer`-t.
    /// SFBAudioEngine végzi a dekódolást – WAV, MP3, AAC, FLAC, OGG, Opus, stb.
    public func load(url: URL) throws -> AudioBuffer {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer {
            do {
                try decoder.close()
            } catch {
                log.error("Dekóder lezárása sikertelen: \(error.localizedDescription, privacy: .public)")
            }
        }

        let channelCount = Int(decoder.processingFormat.channelCount)
        let sampleRate   = decoder.processingFormat.sampleRate

        // Float32, non-interleaved formátum az AVAudioPCMBuffer-hez
        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { throw AudioEngineError.formatConversionFailed }

        let frameCapacity: AVAudioFrameCount = 4096
        guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: readFormat,
                                                frameCapacity: frameCapacity)
        else { throw AudioEngineError.bufferAllocationFailed }

        var allSamples = [Float]()

        // Dekódolás blokkokban – decode(into:) tölti fel a puffert
        while true {
            tempBuffer.frameLength = frameCapacity          // maximális kapacitás jelzése
            try decoder.decode(into: tempBuffer)            // tényleges dekódolás
            let framesRead = Int(tempBuffer.frameLength)
            guard framesRead > 0 else { break }

            guard let channelData = tempBuffer.floatChannelData else { break }
            // Non-interleaved → interleaved (L0,R0,L1,R1,…)
            for frame in 0..<framesRead {
                for ch in 0..<channelCount {
                    allSamples.append(channelData[ch][frame])
                }
            }
        }

        return AudioBuffer(samples: allSamples, channelCount: channelCount, sampleRate: sampleRate)
    }

    // MARK: – Lejátszás

    /// Az éppen lejátszó panel UUID-ja. `nil`, ha nincs aktív lejátszás.
    public private(set) var currentPlayingPanelID: UUID?

    /// Elindítja az `AudioBuffer` lejátszását az `atFrame` pozíciótól.
    /// - Parameters:
    ///   - buffer: A lejátszandó hangpuffer.
    ///   - atFrame: Kezdő frame-pozíció (alapértelmezett: 0).
    ///   - panelID: A forrás panel UUID-ja (bezárás-ellenőrzéshez).
    /// Az aktuális lejátszás kezdő frame-pozíciója (a teljes pufferen belül).
    private var playbackStartFrame: Int = 0

    /// Visszaadja az aktuális lejátszási pozíciót frame-ben (a teljes pufferben).
    /// Szüneteltetés előtt hívva ad pontos pozíciót.
    public func currentPlaybackFrame() -> Int {
        guard let lastRenderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime) else {
            return playbackStartFrame
        }
        return playbackStartFrame + Int(max(0, playerTime.sampleTime))
    }

    public func play(_ buffer: AudioBuffer, fromFrame atFrame: Int = 0, panelID: UUID? = nil) {
        // Mindig leállítjuk – szüneteltetett állapotban is – hogy töröljük a sorban
        // álló régi puffereket. Így sosem játszódik le előző panel hangja.
        playerNode.stop()
        if !avEngine.isRunning {
            do {
                try avEngine.start()
            } catch {
                log.error("AVAudioEngine indítása sikertelen (play): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        currentPlayingPanelID = panelID
        playbackStartFrame = max(0, atFrame)

        // Ha van indulási pozíció, a puffert levágjuk
        let playBuffer: AudioBuffer = atFrame > 0
            ? buffer.slice(from: atFrame, to: buffer.frameCount)
            : buffer

        guard let pcm = playBuffer.toAVAudioPCMBuffer() else { return }
        playerNode.scheduleBuffer(pcm, at: nil)
        playerNode.play()
    }

    /// Megállítja a lejátszást.
    public func stop() {
        playerNode.stop()
        currentPlayingPanelID = nil
        playbackStartFrame = 0
    }

    /// Szünetelteti a lejátszást.
    public func pause() { playerNode.pause() }

    /// Beállítja a lejátszó hangerejét (0.0 – 1.0).
    public func setVolume(_ volume: Float) {
        playerNode.volume = max(0.0, min(1.0, volume))
    }

    // MARK: – Mentés

    /// Az `AudioBuffer` tartalmát fájlba menti a megadott formátumban.
    public func save(_ buffer: AudioBuffer, to url: URL, format: ExportFormat) throws {
        guard let pcm = buffer.toAVAudioPCMBuffer() else {
            throw AudioEngineError.bufferConversionFailed
        }

        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey:          kAudioFormatLinearPCM,
                AVSampleRateKey:        buffer.sampleRate,
                AVNumberOfChannelsKey:  buffer.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey:  false
            ]
        case .aac:
            settings = [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       buffer.sampleRate,
                AVNumberOfChannelsKey: buffer.channelCount,
                AVEncoderBitRateKey:   192_000
            ]
        case .flac:
            settings = [
                AVFormatIDKey:          kAudioFormatFLAC,
                AVSampleRateKey:        buffer.sampleRate,
                AVNumberOfChannelsKey:  buffer.channelCount,
                AVLinearPCMBitDepthKey: 16
            ]
        case .mp3:
            // AVAudioFile nem ír natív MP3-at macOS-en; ideiglenesen PCM WAV-ként ment.
            settings = [
                AVFormatIDKey:          kAudioFormatLinearPCM,
                AVSampleRateKey:        buffer.sampleRate,
                AVNumberOfChannelsKey:  buffer.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey:  false
            ]
        }

        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: pcm)
    }
}

// MARK: – Exportformátumok

public enum ExportFormat: String, CaseIterable {
    case wav  = "WAV"
    case mp3  = "MP3"
    case aac  = "AAC"
    case flac = "FLAC"

    public var fileExtension: String { rawValue.lowercased() }
}

// MARK: – Hibák

public enum AudioEngineError: LocalizedError {
    case formatConversionFailed
    case bufferAllocationFailed
    case bufferConversionFailed

    public var errorDescription: String? {
        switch self {
        case .formatConversionFailed: return "A hangformátum konvertálása sikertelen."
        case .bufferAllocationFailed: return "A hangpuffer lefoglalása sikertelen."
        case .bufferConversionFailed: return "A hangpuffer AVAudioPCMBuffer-re való konvertálása sikertelen."
        }
    }
}
