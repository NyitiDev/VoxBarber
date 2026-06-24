import XCTest
import AVFoundation
@testable import VoxBarberAudio

final class MP3ExportSmokeTests: XCTestCase {
    @MainActor
    func test_mp3_export_creates_valid_file_with_bitrate() throws {
        // 1 másodperc 440 Hz szinusz, sztereó, 44100 Hz
        let sr = 44100.0
        let frames = Int(sr)
        let ch = 2
        var samples = [Float](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            let v = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sr)) * 0.5
            samples[i * ch + 0] = v
            samples[i * ch + 1] = v
        }
        let buffer = AudioBuffer(samples: samples, channelCount: ch, sampleRate: sr)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbarber_smoke_\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try AudioEngine.shared.save(buffer, to: url, format: .mp3, bitrate: 128)
        } catch {
            XCTFail("save threw: \(error)")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1000, "Az MP3 fájl gyanúsan kicsi")

        // Visszaolvasás: legyen érvényes MP3, közel 1 mp hosszú
        let reloaded = try AudioEngine.shared.load(url: url)
        XCTAssertEqual(reloaded.channelCount, 2)
        let dur = Double(reloaded.frameCount) / reloaded.sampleRate
        XCTAssertEqual(dur, 1.0, accuracy: 0.2)
    }
}
