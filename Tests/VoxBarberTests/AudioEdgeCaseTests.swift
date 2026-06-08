import XCTest
import AVFoundation
@testable import VoxBarberAudio

// MARK: – AudioBuffer határeset-tesztek
//
// A meglévő AudioBufferTests-ben nem lefedett szélső eseteket vizsgáljuk:
// negatív indexek, részleges átfedés, mono pufferek, sztereó→mono keverés,
// duration/frameCount inkonzisztens bemenetre, üres pufferek viselkedése.

final class AudioBufferEdgeCaseTests: XCTestCase {

    // MARK: – slice határesetek

    func test_slice_negativeStart_clampsToZero() {
        let buf = AudioBuffer(samples: [0,1, 2,3, 4,5], channelCount: 2, sampleRate: 44100)
        let sliced = buf.slice(from: -10, to: 2)   // -10 → 0
        XCTAssertEqual(sliced.samples, [0,1, 2,3])
        XCTAssertEqual(sliced.frameCount, 2)
    }

    func test_slice_endBeyondBounds_clampsToFrameCount() {
        let buf = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let sliced = buf.slice(from: 0, to: 999)   // 999 → 2
        XCTAssertEqual(sliced.samples, [0,1, 2,3])
    }

    func test_slice_startEqualsEnd_returnsEmpty() {
        let buf = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let sliced = buf.slice(from: 1, to: 1)
        XCTAssertTrue(sliced.samples.isEmpty)
        XCTAssertEqual(sliced.frameCount, 0)
    }

    func test_slice_startGreaterThanEnd_returnsEmpty() {
        let buf = AudioBuffer(samples: [0,1, 2,3, 4,5], channelCount: 2, sampleRate: 44100)
        let sliced = buf.slice(from: 3, to: 1)
        XCTAssertTrue(sliced.samples.isEmpty)
    }

    func test_slice_mono_returnsCorrectSamples() {
        let buf = AudioBuffer(samples: [10, 20, 30, 40], channelCount: 1, sampleRate: 44100)
        let sliced = buf.slice(from: 1, to: 3)   // frame 1..2
        XCTAssertEqual(sliced.samples, [20, 30])
        XCTAssertEqual(sliced.frameCount, 2)
    }

    func test_slice_preservesSampleRateAndChannels() {
        let buf = AudioBuffer(samples: [1, 2, 3, 4], channelCount: 1, sampleRate: 48000)
        let sliced = buf.slice(from: 0, to: 2)
        XCTAssertEqual(sliced.sampleRate, 48000)
        XCTAssertEqual(sliced.channelCount, 1)
    }

    // MARK: – deleting határesetek

    func test_deleting_negativeStart_clampsToZero() {
        let buf = AudioBuffer(samples: [0,1, 2,3, 4,5], channelCount: 2, sampleRate: 44100)
        let result = buf.deleting(from: -5, to: 1)   // frame 0 törlése
        XCTAssertEqual(result.samples, [2,3, 4,5])
    }

    func test_deleting_endBeyondBounds_clampsToFrameCount() {
        let buf = AudioBuffer(samples: [0,1, 2,3, 4,5], channelCount: 2, sampleRate: 44100)
        let result = buf.deleting(from: 1, to: 999)
        XCTAssertEqual(result.samples, [0,1])
    }

    func test_deleting_emptyRange_returnsOriginal() {
        let buf = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let result = buf.deleting(from: 1, to: 1)   // semmit nem töröl
        XCTAssertEqual(result.samples, [0,1, 2,3])
    }

    func test_deleting_invertedRange_returnsOriginal() {
        let buf = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let result = buf.deleting(from: 2, to: 0)   // start > end → nincs törlés
        XCTAssertEqual(result.samples, [0,1, 2,3])
    }

    func test_deleting_mono() {
        let buf = AudioBuffer(samples: [10, 20, 30, 40], channelCount: 1, sampleRate: 44100)
        let result = buf.deleting(from: 1, to: 3)
        XCTAssertEqual(result.samples, [10, 40])
    }

    // MARK: – inserting határesetek

    func test_inserting_emptyOther_returnsOriginal() {
        let base  = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let empty = AudioBuffer.empty(channelCount: 2, sampleRate: 44100)
        let result = base.inserting(empty, at: 1)
        XCTAssertEqual(result.samples, [0,1, 2,3])
    }

    func test_inserting_negativePosition_clampsToStart() {
        let base   = AudioBuffer(samples: [4,5, 6,7], channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [0,1], channelCount: 2, sampleRate: 44100)
        let result = base.inserting(insert, at: -10)   // -10 → 0
        XCTAssertEqual(result.samples, [0,1, 4,5, 6,7])
    }

    func test_inserting_positionBeyondEnd_clampsToEnd() {
        let base   = AudioBuffer(samples: [0,1, 2,3], channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [4,5], channelCount: 2, sampleRate: 44100)
        let result = base.inserting(insert, at: 999)   // 999 → frameCount
        XCTAssertEqual(result.samples, [0,1, 2,3, 4,5])
    }

    func test_inserting_intoEmptyBuffer() {
        let base   = AudioBuffer.empty(channelCount: 2, sampleRate: 44100)
        let insert = AudioBuffer(samples: [1,2, 3,4], channelCount: 2, sampleRate: 44100)
        let result = base.inserting(insert, at: 0)
        XCTAssertEqual(result.samples, [1,2, 3,4])
    }

    func test_inserting_stereoIntoMono_averagesChannels() {
        let mono   = AudioBuffer(samples: [0, 0], channelCount: 1, sampleRate: 44100)
        // Sztereó: L=1.0, R=0.0 → átlag = 0.5
        let stereo = AudioBuffer(samples: [1.0, 0.0], channelCount: 2, sampleRate: 44100)
        let result = mono.inserting(stereo, at: 0)
        XCTAssertEqual(result.channelCount, 1)
        let first = try? XCTUnwrap(result.samples.first)
        XCTAssertEqual(first ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_inserting_monoIntoStereo_duplicatesBothChannels() {
        let stereo = AudioBuffer(samples: [9,9], channelCount: 2, sampleRate: 44100)
        let mono   = AudioBuffer(samples: [0.3, 0.7], channelCount: 1, sampleRate: 44100)
        let result = stereo.inserting(mono, at: 0)
        // Mono [0.3, 0.7] → sztereó [0.3,0.3, 0.7,0.7] az elejére
        XCTAssertEqual(Array(result.samples.prefix(4)), [0.3, 0.3, 0.7, 0.7])
    }

    // MARK: – duration / frameCount

    func test_duration_zeroSampleRate_returnsZero() {
        let buf = AudioBuffer(samples: [1,2,3,4], channelCount: 2, sampleRate: 0)
        XCTAssertEqual(buf.duration, 0)
    }

    func test_frameCount_monoEqualsSampleCount() {
        let buf = AudioBuffer(samples: [1,2,3,4,5], channelCount: 1, sampleRate: 44100)
        XCTAssertEqual(buf.frameCount, 5)
    }

    func test_emptyBuffer_mono_isConsistent() {
        let buf = AudioBuffer.empty(channelCount: 1, sampleRate: 48000)
        XCTAssertEqual(buf.frameCount, 0)
        XCTAssertEqual(buf.duration, 0)
        XCTAssertEqual(buf.channelCount, 1)
        XCTAssertEqual(buf.sampleRate, 48000)
    }

    // MARK: – AVAudioPCMBuffer határesetek

    func test_toAVAudioPCMBuffer_emptyBuffer_returnsNil() {
        let buf = AudioBuffer.empty(channelCount: 2, sampleRate: 44100)
        XCTAssertNil(buf.toAVAudioPCMBuffer())
    }

    func test_avAudioPCMBuffer_monoRoundtrip_preservesSamples() throws {
        let original: [Float] = [0.2, -0.4, 0.6, -0.8]
        let buf = AudioBuffer(samples: original, channelCount: 1, sampleRate: 48000)

        let pcm = try XCTUnwrap(buf.toAVAudioPCMBuffer())
        let roundtripped = try XCTUnwrap(AudioBuffer(avBuffer: pcm))

        XCTAssertEqual(roundtripped.channelCount, 1)
        XCTAssertEqual(roundtripped.frameCount, 4)
        XCTAssertEqual(roundtripped.sampleRate, 48000)
        for (a, b) in zip(roundtripped.samples, original) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }

    // MARK: – Kombinált műveletek (slice → delete → insert láncolat)

    func test_cutAndPaste_roundtrip_reconstructsOriginal() {
        let original = AudioBuffer(samples: [10,20, 30,40, 50,60, 70,80],
                                   channelCount: 2, sampleRate: 44100)
        // Kivágjuk a frame 1..2 részt: [30,40, 50,60]
        let clip   = original.slice(from: 1, to: 3)
        let cut    = original.deleting(from: 1, to: 3)     // marad [10,20, 70,80]
        // Visszaillesztjük ugyanoda
        let pasted = cut.inserting(clip, at: 1)

        XCTAssertEqual(pasted.samples, original.samples)
    }
}

// MARK: – AudioClipboard forrás-azonosító tesztek

@MainActor
final class AudioClipboardSourceTests: XCTestCase {

    override func setUp() async throws {
        AudioClipboard.shared.clear()
    }

    func test_store_recordsSourcePanelID() {
        let id  = UUID()
        let buf = AudioBuffer(samples: [1,2], channelCount: 1, sampleRate: 44100)
        AudioClipboard.shared.store(buf, sourcePanelID: id)
        XCTAssertEqual(AudioClipboard.shared.sourcePanelID, id)
    }

    func test_clear_resetsSourcePanelID() {
        AudioClipboard.shared.store(AudioBuffer(samples: [1], channelCount: 1, sampleRate: 44100),
                                    sourcePanelID: UUID())
        AudioClipboard.shared.clear()
        XCTAssertNil(AudioClipboard.shared.sourcePanelID)
    }

    func test_store_withoutSourceID_isNil() {
        AudioClipboard.shared.store(AudioBuffer(samples: [1], channelCount: 1, sampleRate: 44100))
        XCTAssertNil(AudioClipboard.shared.sourcePanelID)
    }
}
