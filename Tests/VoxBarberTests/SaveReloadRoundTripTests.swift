import XCTest
import AVFoundation
@testable import VoxBarberAudio

final class SaveReloadRoundTripTests: XCTestCase {

    private func makeBuffer(sr: Double = 44100.0, ch: Int = 2, seconds: Double = 1.0) -> VoxBarberAudio.AudioBuffer {
        let frames = Int(sr * seconds)
        var samples = [Float](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            let v = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sr)) * 0.5
            for c in 0..<ch { samples[i * ch + c] = v }
        }
        return VoxBarberAudio.AudioBuffer(samples: samples, channelCount: ch, sampleRate: sr)
    }

    @MainActor
    func test_wav_roundtrip_same_rate() throws {
        let buffer = makeBuffer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb_wav_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEngine.shared.save(buffer, to: url, format: .wav)
        let reloaded = try AudioEngine.shared.load(url: url)
        XCTAssertEqual(reloaded.channelCount, 2)
        XCTAssertEqual(reloaded.sampleRate, 44100, accuracy: 1)
        XCTAssertGreaterThan(reloaded.frameCount, 40000, "A betöltött WAV nem tartalmaz mintákat")
    }

    @MainActor
    func test_wav_roundtrip_resampled() throws {
        let buffer = makeBuffer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb_wav_rs_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEngine.shared.save(buffer, to: url, format: .wav, sampleRate: 22050)
        let reloaded = try AudioEngine.shared.load(url: url)
        XCTAssertEqual(reloaded.sampleRate, 22050, accuracy: 1)
    }

    @MainActor
    func test_aac_roundtrip() throws {
        let buffer = makeBuffer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb_aac_\(UUID().uuidString)." + ExportFormat.aac.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEngine.shared.save(buffer, to: url, format: .aac)
        _ = try AudioEngine.shared.load(url: url)
    }

    @MainActor
    func test_flac_roundtrip() throws {
        let buffer = makeBuffer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb_flac_\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioEngine.shared.save(buffer, to: url, format: .flac)
        _ = try AudioEngine.shared.load(url: url)
    }
}
