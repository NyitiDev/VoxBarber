import Foundation
import AVFoundation

/// Az app belső PCM hangpuffer reprezentációja.
///
/// Minden hangfájl betöltés után ebbe az egységes formátumba kerül
/// (Float32, interleaved), ebből jelenik meg a waveform, és ebből
/// történik a mentés bármely kimeneti formátumba.
public final class AudioBuffer {

    // MARK: – Tulajdonságok

    /// PCM minták: [L0, R0, L1, R1, ...] Float32 (-1.0 … 1.0)
    public var samples: [Float]

    /// Csatornák száma (1 = mono, 2 = sztereó)
    public let channelCount: Int

    /// Mintavételezési frekvencia (Hz), pl. 44100, 48000
    public let sampleRate: Double

    /// A puffer teljes időtartama másodpercben.
    public var duration: Double {
        guard channelCount > 0, sampleRate > 0 else { return 0 }
        return Double(samples.count / channelCount) / sampleRate
    }

    /// A keretek (frame) száma = samples.count / channelCount
    public var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    // MARK: – Inicializálás

    public init(samples: [Float], channelCount: Int, sampleRate: Double) {
        self.samples      = samples
        self.channelCount = channelCount
        self.sampleRate   = sampleRate
    }

    /// Üres (néma) puffer létrehozása – „Új hangfájl" esetén.
    public static func empty(channelCount: Int = 2, sampleRate: Double = 44100) -> AudioBuffer {
        return AudioBuffer(samples: [], channelCount: channelCount, sampleRate: sampleRate)
    }

    // MARK: – Kijelölés-kezelés

    /// Visszaadja a megadott [startFrame, endFrame) tartomány mintáit új pufferként.
    public func slice(from startFrame: Int, to endFrame: Int) -> AudioBuffer {
        let clampedStart = max(0, startFrame)
        let clampedEnd   = min(frameCount, endFrame)
        guard clampedStart < clampedEnd else {
            return AudioBuffer(samples: [], channelCount: channelCount, sampleRate: sampleRate)
        }
        let sampleStart = clampedStart * channelCount
        let sampleEnd   = clampedEnd   * channelCount
        let sliced = Array(samples[sampleStart..<sampleEnd])
        return AudioBuffer(samples: sliced, channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Törli a megadott [startFrame, endFrame) tartomány mintáit (kivágás).
    public func deleting(from startFrame: Int, to endFrame: Int) -> AudioBuffer {
        let clampedStart = max(0, startFrame)
        let clampedEnd   = min(frameCount, endFrame)
        var newSamples = samples
        if clampedStart < clampedEnd {
            let sampleStart = clampedStart * channelCount
            let sampleEnd   = clampedEnd   * channelCount
            newSamples.removeSubrange(sampleStart..<sampleEnd)
        }
        return AudioBuffer(samples: newSamples, channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Beilleszti az `other` puffer tartalmát a `atFrame` pozícióba.
    /// Ha a sampleRate vagy csatornaszám eltér, a `other` puffert átkonvertálja.
    public func inserting(_ other: AudioBuffer, at atFrame: Int) -> AudioBuffer {
        let insertAt = max(0, min(frameCount, atFrame)) * channelCount
        // Egyszerű eset: azonos formátum
        let sourceSamples: [Float]
        if other.channelCount == channelCount {
            sourceSamples = other.samples
        } else if other.channelCount == 1 && channelCount == 2 {
            // Mono → sztereó duplikálás
            sourceSamples = other.samples.flatMap { [$0, $0] }
        } else if other.channelCount == 2 && channelCount == 1 {
            // Sztereó → mono átlagolás
            var mono: [Float] = []
            mono.reserveCapacity(other.samples.count / 2)
            for i in stride(from: 0, to: other.samples.count - 1, by: 2) {
                mono.append((other.samples[i] + other.samples[i + 1]) * 0.5)
            }
            sourceSamples = mono
        } else {
            sourceSamples = other.samples
        }
        var newSamples = samples
        newSamples.insert(contentsOf: sourceSamples, at: insertAt)
        return AudioBuffer(samples: newSamples, channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Az `other` puffer tartalmát a `atFrame` pozíciótól összemossa (mixeli) a
    /// jelenlegi hanganyaggal, mintavételek összeadásával (nem közbékelődés).
    /// Ha a beékelt anyag túlnyúlna a jelenlegi puffer végén, a cél puffer
    /// megnövekszik: a túllógó részben már csak az `other` anyaga szól (az addigi
    /// hanganyagot csenddel egészítjük ki). A csúcsok túlcsordulása ellen az
    /// eredmény -1.0 … 1.0 tartományra van vágva (clamp).
    public func mixing(_ other: AudioBuffer, at atFrame: Int) -> AudioBuffer {
        // Az `other` puffert a jelenlegi csatornaszámra igazítjuk.
        let sourceSamples: [Float]
        if other.channelCount == channelCount {
            sourceSamples = other.samples
        } else if other.channelCount == 1 && channelCount == 2 {
            sourceSamples = other.samples.flatMap { [$0, $0] }
        } else if other.channelCount == 2 && channelCount == 1 {
            var mono: [Float] = []
            mono.reserveCapacity(other.samples.count / 2)
            for i in stride(from: 0, to: other.samples.count - 1, by: 2) {
                mono.append((other.samples[i] + other.samples[i + 1]) * 0.5)
            }
            sourceSamples = mono
        } else {
            sourceSamples = other.samples
        }

        let mixStart = max(0, min(frameCount, atFrame)) * channelCount
        var newSamples = samples
        // Ha a beékelt anyag túlnyúlik a jelenlegi puffer végén, megnöveljük a
        // puffert csenddel (0.0), hogy a túllógó rész is elférjen.
        let requiredCount = mixStart + sourceSamples.count
        if requiredCount > newSamples.count {
            newSamples.append(contentsOf: repeatElement(0.0, count: requiredCount - newSamples.count))
        }
        for i in 0..<sourceSamples.count {
            let dst = mixStart + i
            let summed = newSamples[dst] + sourceSamples[i]
            newSamples[dst] = min(1.0, max(-1.0, summed))
        }
        return AudioBuffer(samples: newSamples, channelCount: channelCount, sampleRate: sampleRate)
    }

    // MARK: – AVAudioPCMBuffer konverzió

    /// `AVAudioPCMBuffer`-ből hozza létre a belső puffert (Float32 formátumra konvertálva).
    public convenience init?(avBuffer: AVAudioPCMBuffer) {
        guard let channelData = avBuffer.floatChannelData else { return nil }
        let frameLength  = Int(avBuffer.frameLength)
        let channelCount = Int(avBuffer.format.channelCount)
        let sampleRate   = avBuffer.format.sampleRate

        // De-interleave: AVAudioPCMBuffer channel-szeparált, nekünk interleaved kell
        var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
        for ch in 0..<channelCount {
            let src = channelData[ch]
            for frame in 0..<frameLength {
                interleaved[frame * channelCount + ch] = src[frame]
            }
        }
        self.init(samples: interleaved, channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Létrehoz egy `AVAudioPCMBuffer`-t a belső pufferből (lejátszáshoz / mentéshez).
    public func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard channelCount > 0, frameCount > 0 else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { return nil }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = pcm.floatChannelData else { return nil }
        for ch in 0..<channelCount {
            let dst = channelData[ch]
            for frame in 0..<frameCount {
                dst[frame] = samples[frame * channelCount + ch]
            }
        }
        return pcm
    }

    /// Interleaved Float32 `AVAudioPCMBuffer`-t készít.
    /// Egyes enkóderek (pl. az MP3) interleaved bemenetet várnak.
    public func toInterleavedAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard channelCount > 0, frameCount > 0 else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { return nil }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        // Interleaved pufferben a 0. csatorna mutatója az összes mintát
        // L0,R0,L1,R1,… sorrendben tartalmazza – épp ahogy a `samples` tömbben.
        guard let channelData = pcm.floatChannelData else { return nil }
        let dst = channelData[0]
        for i in 0..<(frameCount * channelCount) {
            dst[i] = samples[i]
        }
        return pcm
    }
}