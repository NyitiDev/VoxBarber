import XCTest
import AVFoundation
@testable import VoxBarberAudio

// MARK: – AudioBuffer tesztek

final class AudioBufferTests: XCTestCase {

    // MARK: – Alapok

    func test_emptyBuffer_hasDurationZero() {
        let buf = AudioBuffer.empty()
        XCTAssertEqual(buf.duration, 0)
        XCTAssertEqual(buf.frameCount, 0)
        XCTAssertTrue(buf.samples.isEmpty)
    }

    func test_frameCount_calculatesCorrectly() {
        // 4 frame, 2 csatorna = 8 minta
        let buf = AudioBuffer(samples: [Float](repeating: 0.5, count: 8),
                              channelCount: 2, sampleRate: 44100)
        XCTAssertEqual(buf.frameCount, 4)
    }

    func test_duration_calculatesCorrectly() {
        // 44100 frame, 44100 Hz → pontosan 1 másodperc
        let buf = AudioBuffer(samples: [Float](repeating: 0, count: 44100 * 2),
                              channelCount: 2, sampleRate: 44100)
        XCTAssertEqual(buf.duration, 1.0, accuracy: 0.0001)
    }

    // MARK: – slice

    func test_slice_returnsCorrectSamples() {
        // Sztereó puffer: [L0,R0, L1,R1, L2,R2, L3,R3]
        //  values:          0,1   2,3   4,5   6,7
        let samples: [Float] = [0,1, 2,3, 4,5, 6,7]
        let buf = AudioBuffer(samples: samples, channelCount: 2, sampleRate: 44100)

        let sliced = buf.slice(from: 1, to: 3)  // frame 1..2 → [2,3, 4,5]
        XCTAssertEqual(sliced.samples, [2,3, 4,5])
        XCTAssertEqual(sliced.frameCount, 2)
    }

    func test_slice_outOfBounds_returnsEmpty() {
        let buf = AudioBuffer(samples: [1,2,3,4], channelCount: 2, sampleRate: 44100)
        let sliced = buf.slice(from: 5, to: 10)
        XCTAssertTrue(sliced.samples.isEmpty)
    }

    // MARK: – deleting

    func test_deleting_removesCorrectRange() {
        let samples: [Float] = [0,1, 2,3, 4,5, 6,7]
        let buf = AudioBuffer(samples: samples, channelCount: 2, sampleRate: 44100)

        let result = buf.deleting(from: 1, to: 3)  // frame 1..2 törlése
        XCTAssertEqual(result.samples, [0,1, 6,7])
        XCTAssertEqual(result.frameCount, 2)
    }

    func test_deleting_allFrames_returnsEmpty() {
        let buf = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let result = buf.deleting(from: 0, to: 2)
        XCTAssertTrue(result.samples.isEmpty)
    }

    // MARK: – inserting

    func test_inserting_atStart() {
        let base   = AudioBuffer(samples: [4,5, 6,7], channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)

        let result = base.inserting(insert, at: 0)
        XCTAssertEqual(result.samples, [0,1, 2,3, 4,5, 6,7])
    }

    func test_inserting_atEnd() {
        let base   = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [4,5, 6,7], channelCount: 2, sampleRate: 44100)

        let result = base.inserting(insert, at: base.frameCount)
        XCTAssertEqual(result.samples, [0,1, 2,3, 4,5, 6,7])
    }

    func test_inserting_inMiddle() {
        let base   = AudioBuffer(samples: [0,1, 6,7], channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [2,3, 4,5], channelCount: 2, sampleRate: 44100)

        let result = base.inserting(insert, at: 1)  // frame 1 elé
        XCTAssertEqual(result.samples, [0,1, 2,3, 4,5, 6,7])
    }

    func test_inserting_monoIntoStereo_duplicatesChannel() {
        let stereo = AudioBuffer(samples: [0,0, 0,0], channelCount: 2, sampleRate: 44100)
        let mono   = AudioBuffer(samples: [1.0, 1.0], channelCount: 1, sampleRate: 44100)

        let result = stereo.inserting(mono, at: 0)
        // Mono értékek mindkét csatornán megjelennek
        XCTAssertEqual(result.samples[0], 1.0)
        XCTAssertEqual(result.samples[1], 1.0)
    }

    // MARK: – AVAudioPCMBuffer round-trip

    func test_avAudioPCMBuffer_roundtrip_preservesSamples() throws {
        let original: [Float] = [0.1, -0.1, 0.5, -0.5, 0.9, -0.9]
        let buf = AudioBuffer(samples: original, channelCount: 2, sampleRate: 44100)

        let pcm = try XCTUnwrap(buf.toAVAudioPCMBuffer())
        let roundtripped = try XCTUnwrap(AudioBuffer(avBuffer: pcm))

        XCTAssertEqual(roundtripped.channelCount, buf.channelCount)
        XCTAssertEqual(roundtripped.frameCount,   buf.frameCount)
        for (a, b) in zip(roundtripped.samples, original) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }
}

// MARK: – AudioClipboard tesztek

@MainActor
final class AudioClipboardTests: XCTestCase {

    override func setUp() async throws {
        AudioClipboard.shared.clear()
    }

    func test_initiallyEmpty() {
        XCTAssertFalse(AudioClipboard.shared.hasContent)
        XCTAssertNil(AudioClipboard.shared.peek())
    }

    func test_store_makesContentAvailable() {
        let buf = AudioBuffer(samples: [1,2,3,4], channelCount: 2, sampleRate: 44100)
        AudioClipboard.shared.store(buf)

        XCTAssertTrue(AudioClipboard.shared.hasContent)
        XCTAssertNotNil(AudioClipboard.shared.peek())
    }

    func test_peek_doesNotClearContent() {
        let buf = AudioBuffer(samples: [1,2], channelCount: 1, sampleRate: 44100)
        AudioClipboard.shared.store(buf)

        _ = AudioClipboard.shared.peek()
        XCTAssertTrue(AudioClipboard.shared.hasContent)
    }

    func test_clear_removesContent() {
        AudioClipboard.shared.store(AudioBuffer(samples: [1], channelCount: 1, sampleRate: 44100))
        AudioClipboard.shared.clear()

        XCTAssertFalse(AudioClipboard.shared.hasContent)
        XCTAssertNil(AudioClipboard.shared.peek())
    }

    func test_store_overwritesPrevious() {
        let first  = AudioBuffer(samples: [1,2], channelCount: 1, sampleRate: 44100)
        let second = AudioBuffer(samples: [9,8], channelCount: 1, sampleRate: 44100)
        AudioClipboard.shared.store(first)
        AudioClipboard.shared.store(second)

        XCTAssertEqual(AudioClipboard.shared.peek()?.samples, [9,8])
    }
}

// MARK: – Copy-Cut-Paste integrációs teszt

@MainActor
final class CopyCutPasteIntegrationTests: XCTestCase {

    override func setUp() async throws {
        AudioClipboard.shared.clear()
    }

    /// Forrás puffer: [A,B,C,D], kijelöljük a B,C részét (frame 1–2),
    /// Copy → Paste üres pufferbe → üres puffer tartalma [B,C].
    func test_copy_then_paste_into_empty() {
        let source = AudioBuffer(samples: [10,20,30,40], channelCount: 1, sampleRate: 44100)
        let clip = source.slice(from: 1, to: 3)
        AudioClipboard.shared.store(clip)

        var dest = AudioBuffer.empty(channelCount: 1, sampleRate: 44100)
        let clipboard = AudioClipboard.shared.peek()!
        dest = dest.inserting(clipboard, at: 0)

        XCTAssertEqual(dest.samples, [20,30])
    }

    /// Forrás puffer: [A,B,C,D], Cut a B,C részére →
    /// forrás marad [A,D], vágólap tartalmaz [B,C].
    func test_cut_removesFromSource_andStoresInClipboard() {
        var source = AudioBuffer(samples: [10,20,30,40], channelCount: 1, sampleRate: 44100)
        let clip = source.slice(from: 1, to: 3)
        AudioClipboard.shared.store(clip)
        source = source.deleting(from: 1, to: 3)

        XCTAssertEqual(source.samples, [10,40])
        XCTAssertEqual(AudioClipboard.shared.peek()?.samples, [20,30])
    }

    /// Több Paste egymás után: minden paste a kurzor után illeszti be a tartalmat.
    func test_multiple_pastes_append_sequentially() {
        let clip = AudioBuffer(samples: [1,2], channelCount: 1, sampleRate: 44100)
        AudioClipboard.shared.store(clip)

        var dest = AudioBuffer.empty(channelCount: 1, sampleRate: 44100)
        var cursor = 0

        for _ in 0..<3 {
            let c = AudioClipboard.shared.peek()!
            dest = dest.inserting(c, at: cursor)
            cursor += c.frameCount
        }

        XCTAssertEqual(dest.samples, [1,2, 1,2, 1,2])
        XCTAssertEqual(dest.frameCount, 6)
    }
}
