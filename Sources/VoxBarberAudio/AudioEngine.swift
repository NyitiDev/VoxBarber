import Foundation
import AVFoundation
import SFBAudioEngine
import UniformTypeIdentifiers
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
    /// `nonisolated`: a dekódolás CPU-munka, háttér-threaden kell futnia, soha nem
    /// a fő szálon, különben a `decode(into:)` blokkolja a felhasználói felületet.
    nonisolated public func load(url: URL) throws -> AudioBuffer {
        let log = Logger(subsystem: "VoxBarber", category: "AudioEngine")
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

        // A puffert pontosan a dekóder feldolgozási formátumával hozzuk létre –
        // a `decode(into:)` megköveteli, hogy `buffer.format == processingFormat`,
        // különben `NSInternalInconsistencyException`-t dob (format mismatch).
        let processingFormat = decoder.processingFormat

        let frameCapacity: AVAudioFrameCount = 4096
        guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                                frameCapacity: frameCapacity)
        else { throw AudioEngineError.bufferAllocationFailed }

        // Egyes formátumok (pl. az AVAudioFile által írt 16-bites egész WAV)
        // feldolgozási formátuma nem Float32, így `floatChannelData` nil lenne.
        // Ezekhez egy Float32, nem összefésült cél-formátumra konvertálunk.
        let needsConversion = processingFormat.commonFormat != .pcmFormatFloat32
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channelCount),
                                        interleaved: false)
        let converter: AVAudioConverter? = needsConversion
            ? (floatFormat.flatMap { AVAudioConverter(from: processingFormat, to: $0) })
            : nil
        if needsConversion && (converter == nil || floatFormat == nil) {
            throw AudioEngineError.formatConversionFailed
        }
        let convBuffer: AVAudioPCMBuffer? = (needsConversion && floatFormat != nil)
            ? AVAudioPCMBuffer(pcmFormat: floatFormat!, frameCapacity: frameCapacity)
            : nil

        var allSamples = [Float]()

        // Dekódolás blokkokban – decode(into:length:) tölti fel a puffert.
        // Fontos: a frameLength-et 0-ra kell állítani a hívás előtt, mert a dekóder
        // a frameLength pozíciótól ír; ha az a kapacitással egyenlő, 0 frame-et olvas.
        while true {
            tempBuffer.frameLength = 0
            try decoder.decode(into: tempBuffer, length: frameCapacity)
            let framesRead = Int(tempBuffer.frameLength)
            guard framesRead > 0 else { break }

            // A float-mintákat tartalmazó puffer és sorrendje a (esetleges)
            // konverzió után.
            let sampleBuffer: AVAudioPCMBuffer
            if needsConversion, let converter, let convBuffer {
                convBuffer.frameLength = 0
                var consumed = false
                var convError: NSError?
                converter.convert(to: convBuffer, error: &convError) { _, outStatus in
                    if consumed { outStatus.pointee = .noDataNow; return nil }
                    consumed = true
                    outStatus.pointee = .haveData
                    return tempBuffer
                }
                if let convError { throw convError }
                sampleBuffer = convBuffer
            } else {
                sampleBuffer = tempBuffer
            }

            let producedFrames = Int(sampleBuffer.frameLength)
            guard producedFrames > 0, let channelData = sampleBuffer.floatChannelData else { break }

            if sampleBuffer.format.isInterleaved {
                // Interleaved → már L0,R0,L1,R1,… sorrendben egyetlen pufferben
                let ptr = channelData[0]
                allSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: producedFrames * channelCount))
            } else {
                // Non-interleaved → interleaved (L0,R0,L1,R1,…)
                for frame in 0..<producedFrames {
                    for ch in 0..<channelCount {
                        allSamples.append(channelData[ch][frame])
                    }
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
    /// - Parameters:
    ///   - buffer: A mentendő hangpuffer.
    ///   - url: A célfájl URL-je.
    ///   - format: A kívánt exportformátum.
    ///   - bitrate: MP3 esetén a konstans bitráta kbps-ben (alapértelmezett: 192).
    ///     Más formátumoknál figyelmen kívül marad.
    ///   - sampleRate: A kívánt mintavételi frekvencia Hz-ben. Ha nil vagy a puffer
    ///     frekvenciájával egyezik, nem történik újramintavételezés. (MP3-nál
    ///     jelenleg figyelmen kívül marad.)
    public func save(_ buffer: AudioBuffer, to url: URL, format: ExportFormat, bitrate: Int = 192, sampleRate: Double? = nil) throws {
        // Az MP3-at a SFBAudioEngine (LAME) enkódolja, mert az AVAudioFile nem
        // tud natív MP3-at írni macOS-en.
        if format == .mp3 {
            try saveMP3(buffer, to: url, bitrate: bitrate)
            return
        }

        guard let basePCM = buffer.toAVAudioPCMBuffer() else {
            throw AudioEngineError.bufferConversionFailed
        }

        // A célfrekvencia: a kért érték, vagy a puffer eredeti frekvenciája.
        let targetRate = sampleRate ?? buffer.sampleRate
        let pcm: AVAudioPCMBuffer
        if abs(targetRate - buffer.sampleRate) > 0.5 {
            pcm = try resample(basePCM, to: targetRate)
        } else {
            pcm = basePCM
        }

        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey:          kAudioFormatLinearPCM,
                AVSampleRateKey:        targetRate,
                AVNumberOfChannelsKey:  buffer.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey:  false
            ]
        case .aac:
            settings = [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       targetRate,
                AVNumberOfChannelsKey: buffer.channelCount,
                AVEncoderBitRateKey:   192_000
            ]
        case .flac:
            settings = [
                AVFormatIDKey:          kAudioFormatFLAC,
                AVSampleRateKey:        targetRate,
                AVNumberOfChannelsKey:  buffer.channelCount,
                AVLinearPCMBitDepthKey: 16
            ]
        case .mp3:
            // Az MP3-ot fent külön ág kezeli; ide nem jutunk el.
            return
        }

        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: pcm)
    }

    /// Egy float32, nem összefésült PCM puffert a megadott mintavételi
    /// frekvenciára konvertál `AVAudioConverter` segítségével.
    private func resample(_ pcm: AVAudioPCMBuffer, to targetRate: Double) throws -> AVAudioPCMBuffer {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetRate,
                                            channels: pcm.format.channelCount,
                                            interleaved: false),
              let converter = AVAudioConverter(from: pcm.format, to: outFormat) else {
            throw AudioEngineError.formatConversionFailed
        }

        let ratio = targetRate / pcm.format.sampleRate
        let outCapacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioEngineError.bufferConversionFailed
        }

        var consumed = false
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcm
        }

        converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        if let convError { throw convError }
        return outBuffer
    }

    /// MP3 fájlt ír a SFBAudioEngine (LAME) enkóderrel, állandó bitrátával.
    private func saveMP3(_ buffer: AudioBuffer, to url: URL, bitrate: Int) throws {
        guard let pcm = buffer.toInterleavedAVAudioPCMBuffer() else {
            throw AudioEngineError.bufferConversionFailed
        }

        // Az enkóder nem felülír; a meglévő célfájlt előbb eltávolítjuk.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Az enkódert a fájl kiterjesztése (.mp3) alapján választjuk ki – az
        // `encoderName` alapú kiválasztás pointer-azonosságot vár az exportált
        // konstansra, amit Swiftből nem tudunk megbízhatóan átadni.
        let encoder = try AudioEncoder(url: url)
        encoder.settings = [
            AudioEncodingSettingsKey(rawValue: "Constant Bitrate"): bitrate
        ]
        try encoder.setSourceFormat(pcm.format)
        try encoder.openReturningError()
        try encoder.encode(from: pcm)
        try encoder.finish()
        try encoder.close()
    }
}

// MARK: – Exportformátumok

public enum ExportFormat: String, CaseIterable {
    case wav  = "WAV"
    case mp3  = "MP3"
    case aac  = "AAC"
    case flac = "FLAC"

    public var fileExtension: String {
        switch self {
        case .wav:  return "wav"
        case .mp3:  return "mp3"
        // Az AAC-ot az AVAudioFile MPEG-4 konténerbe (m4a) írja, ezért a helyes,
        // mindenhol felismerhető kiterjesztés az .m4a (nem a nyers .aac/ADTS).
        case .aac:  return "m4a"
        case .flac: return "flac"
        }
    }

    /// A formátumhoz tartozó UTType – a mentő panel ezzel garantálja a helyes
    /// kiterjesztést, a megnyitó panel pedig ez alapján engedi kiválasztani.
    public var utType: UTType {
        switch self {
        case .wav:  return .wav
        case .mp3:  return .mp3
        case .aac:  return .mpeg4Audio
        case .flac: return UTType(filenameExtension: "flac") ?? .audio
        }
    }
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
