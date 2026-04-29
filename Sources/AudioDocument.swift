import AppKit
import AVFoundation

/// Pasteboard type used when copying a PCM region between documents.
let VBPasteboardType = NSPasteboard.PasteboardType("com.voxbarber.pcm-region")

/// One loaded audio file.  Wraps the decoded PCM buffer and all metadata.
final class AudioDocument: NSDocument {

    // MARK: - Public state

    /// Full PCM buffer (float32, non-interleaved). Nil until file is read.
    private(set) var buffer: AVAudioPCMBuffer?
    /// Filename without extension, used as window title.
    private(set) var fileName: String = "Untitled"

    // MARK: - NSDocument overrides

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        // Route to the hub window instead of opening a separate window.
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let hub = appDelegate.mainWindowController else { return }
        hub.addTrackPanel(for: self)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        fileName = url.deletingPathExtension().lastPathComponent

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedFileTypeError))
        }

        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileInvalidFileError))
        }
        try audioFile.read(into: pcm)
        pcm.frameLength = frameCount
        self.buffer = pcm
    }

    // NSDocument write stub – real export is handled by ExportManager
    override func data(ofType typeName: String) throws -> Data {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileOperationNotSupportedError))
    }

    // MARK: - Buffer mutation (used by EditOperations)

    func replaceBuffer(with newBuffer: AVAudioPCMBuffer) {
        self.buffer = newBuffer
        updateChangeCount(.changeDone)
        NotificationCenter.default.post(name: .audioDocumentBufferDidChange, object: self)
    }
}

extension Notification.Name {
    static let audioDocumentBufferDidChange = Notification.Name("audioDocumentBufferDidChange")
}
