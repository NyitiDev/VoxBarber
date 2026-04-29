import AVFoundation
import AudioToolbox
import AppKit

/// Exports an AVAudioPCMBuffer to a file using ExtAudioFileRef (no external dependencies).
enum ExportManager {

    enum ExportFormat: String, CaseIterable {
        case wav  = "WAV"
        case aiff = "AIFF"
        case m4a  = "M4A (AAC)"

        var fileExtension: String {
            switch self {
            case .wav:  return "wav"
            case .aiff: return "aiff"
            case .m4a:  return "m4a"
            }
        }

        var audioFileTypeID: AudioFileTypeID {
            switch self {
            case .wav:  return kAudioFileWAVEType
            case .aiff: return kAudioFileAIFFType
            case .m4a:  return kAudioFileM4AType
            }
        }

        /// Destination format description.
        var outputASBD: AudioStreamBasicDescription {
            switch self {
            case .wav:
                return AudioStreamBasicDescription(
                    mSampleRate: 0,          // filled in from source
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: 0,    // filled in from source
                    mBitsPerChannel: 16,
                    mReserved: 0
                )
            case .aiff:
                return AudioStreamBasicDescription(
                    mSampleRate: 0,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian,
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: 0,
                    mBitsPerChannel: 16,
                    mReserved: 0
                )
            case .m4a:
                return AudioStreamBasicDescription(
                    mSampleRate: 0,
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: 0,
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1024,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: 0,
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
            }
        }
    }

    // MARK: - Export

    /// Presents a save panel and exports the buffer.
    /// - Parameters:
    ///   - buffer:   The full PCM buffer to export.
    ///   - format:   Target format.
    ///   - window:   Parent window for the save panel.
    ///   - completion: Called on the main thread with a success flag.
    static func export(buffer: AVAudioPCMBuffer,
                       as format: ExportFormat,
                       suggestedName: String,
                       parentWindow window: NSWindow?,
                       completion: @escaping (Bool) -> Void) {

        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.title = "Export as \(format.rawValue)"

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = writeBuffer(buffer, to: url, format: format)
                DispatchQueue.main.async { completion(ok) }
            }
        }

        if let win = window {
            panel.beginSheetModal(for: win, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Core write

    private static func writeBuffer(_ buffer: AVAudioPCMBuffer,
                                    to url: URL,
                                    format: ExportFormat) -> Bool {
        let srcFormat = buffer.format
        let srcASBD   = srcFormat.streamDescription.pointee

        var dstASBD   = format.outputASBD
        dstASBD.mSampleRate        = srcASBD.mSampleRate
        dstASBD.mChannelsPerFrame  = srcASBD.mChannelsPerFrame

        // Fill computed fields for PCM formats
        if dstASBD.mFormatID == kAudioFormatLinearPCM {
            let bytesPerFrame = (dstASBD.mBitsPerChannel / 8) * dstASBD.mChannelsPerFrame
            dstASBD.mBytesPerFrame   = bytesPerFrame
            dstASBD.mBytesPerPacket  = bytesPerFrame
        }

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            format.audioFileTypeID,
            &dstASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extFile
        )
        guard status == noErr, let ef = extFile else {
            print("[ExportManager] ExtAudioFileCreateWithURL failed: \(status)")
            return false
        }
        defer { ExtAudioFileDispose(ef) }

        // Tell ExtAudioFile the client format (float32 non-interleaved = AVAudioPCMBuffer native)
        var clientASBD = srcASBD
        status = ExtAudioFileSetProperty(ef,
                                         kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                         &clientASBD)
        guard status == noErr else {
            print("[ExportManager] SetProperty clientFormat failed: \(status)")
            return false
        }

        // Write in chunks to avoid huge allocations
        let framesPerChunk: AVAudioFrameCount = 4096
        var framesWritten: AVAudioFrameCount = 0
        let totalFrames = buffer.frameLength

        while framesWritten < totalFrames {
            let framesToWrite = min(framesPerChunk, totalFrames - framesWritten)

            // Build AudioBufferList pointing into the source buffer's memory
            let channelCount = Int(srcASBD.mChannelsPerFrame)
            var abl = AudioBufferList()
            abl.mNumberBuffers = UInt32(channelCount)

            withUnsafeMutablePointer(to: &abl.mBuffers) { ablPtr in
                for ch in 0 ..< channelCount {
                    let bufPtr = ablPtr + ch
                    bufPtr.pointee.mNumberChannels = 1
                    bufPtr.pointee.mDataByteSize   = framesToWrite * UInt32(MemoryLayout<Float>.size)
                    bufPtr.pointee.mData            = buffer.floatChannelData.map {
                        UnsafeMutableRawPointer($0[ch] + Int(framesWritten))
                    }
                }
            }

            status = ExtAudioFileWrite(ef, framesToWrite, &abl)
            guard status == noErr else {
                print("[ExportManager] ExtAudioFileWrite failed: \(status)")
                return false
            }
            framesWritten += framesToWrite
        }
        return true
    }
}
