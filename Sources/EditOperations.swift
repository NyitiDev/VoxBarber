import AppKit
import AVFoundation

/// Stateless helpers that operate on AVAudioPCMBuffer values.
/// All functions return new buffers; the originals are never mutated directly
/// (the document's replaceBuffer(with:) is the mutation entry-point).
enum EditOperations {

    // MARK: - Cut

    /// Returns the modified buffer (with the range removed) and the excised segment.
    static func cut(from buffer: AVAudioPCMBuffer,
                    range: ClosedRange<Int>) -> (modified: AVAudioPCMBuffer, excised: AVAudioPCMBuffer)? {
        guard let excised = copy(from: buffer, range: range) else { return nil }
        let lo = range.lowerBound
        let hi = range.upperBound + 1
        let totalFrames = Int(buffer.frameLength)
        let newLength = totalFrames - (hi - lo)
        guard newLength >= 0,
              let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                           frameCapacity: AVAudioFrameCount(max(0, newLength))) else { return nil }
        result.frameLength = AVAudioFrameCount(newLength)
        let chCount = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = result.floatChannelData {
            for ch in 0 ..< chCount {
                if lo > 0 {
                    memcpy(dst[ch], src[ch], lo * MemoryLayout<Float>.size)
                }
                let tail = totalFrames - hi
                if tail > 0 {
                    memcpy(dst[ch] + lo, src[ch] + hi, tail * MemoryLayout<Float>.size)
                }
            }
        }
        return (result, excised)
    }

    // MARK: - Copy

    /// Returns a new buffer containing only the selected sample range.
    static func copy(from buffer: AVAudioPCMBuffer,
                     range: ClosedRange<Int>) -> AVAudioPCMBuffer? {
        let lo = range.lowerBound
        let len = range.upperBound - lo + 1
        guard len > 0,
              lo >= 0,
              range.upperBound < Int(buffer.frameLength),
              let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                           frameCapacity: AVAudioFrameCount(len)) else { return nil }
        result.frameLength = AVAudioFrameCount(len)
        let chCount = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = result.floatChannelData {
            for ch in 0 ..< chCount {
                memcpy(dst[ch], src[ch] + lo, len * MemoryLayout<Float>.size)
            }
        }
        return result
    }

    // MARK: - Paste

    /// Inserts `segment` into `target` at `atFrame`.
    static func paste(segment: AVAudioPCMBuffer,
                      into target: AVAudioPCMBuffer,
                      at atFrame: Int) -> AVAudioPCMBuffer? {
        let segLen    = Int(segment.frameLength)
        let tgtLen    = Int(target.frameLength)
        let insertAt  = min(max(0, atFrame), tgtLen)
        let newLength = tgtLen + segLen
        guard let result = AVAudioPCMBuffer(pcmFormat: target.format,
                                            frameCapacity: AVAudioFrameCount(newLength)) else { return nil }
        result.frameLength = AVAudioFrameCount(newLength)
        let chCount = Int(target.format.channelCount)

        // If the segment format differs, do a simple zero-pad paste (format mismatch
        // should be handled upstream by converting the segment first).
        guard segment.format.sampleRate == target.format.sampleRate,
              segment.format.channelCount == target.format.channelCount,
              let src  = target.floatChannelData,
              let seg  = segment.floatChannelData,
              let dst  = result.floatChannelData else { return nil }

        for ch in 0 ..< chCount {
            // Before insert point
            if insertAt > 0 {
                memcpy(dst[ch], src[ch], insertAt * MemoryLayout<Float>.size)
            }
            // Segment
            memcpy(dst[ch] + insertAt, seg[ch], segLen * MemoryLayout<Float>.size)
            // After insert point
            let tail = tgtLen - insertAt
            if tail > 0 {
                memcpy(dst[ch] + insertAt + segLen, src[ch] + insertAt, tail * MemoryLayout<Float>.size)
            }
        }
        return result
    }

    // MARK: - Pasteboard helpers

    static func writeToPasteboard(_ buffer: AVAudioPCMBuffer) {
        guard let data = encodePCM(buffer) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: VBPasteboardType)
    }

    static func readFromPasteboard(expectedFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let data = NSPasteboard.general.data(forType: VBPasteboardType) else { return nil }
        return decodePCM(data, format: expectedFormat)
    }

    // MARK: - PCM serialisation (simple raw float32 + header)

    private struct PCMHeader {
        var sampleRate: Float64
        var channels: UInt32
        var frameLength: UInt32
    }

    private static func encodePCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        let format = buffer.format
        var header = PCMHeader(
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            frameLength: buffer.frameLength
        )
        var data = Data(bytes: &header, count: MemoryLayout<PCMHeader>.size)
        let frames = Int(buffer.frameLength)
        if let chData = buffer.floatChannelData {
            for ch in 0 ..< Int(format.channelCount) {
                data.append(Data(bytes: chData[ch], count: frames * MemoryLayout<Float>.size))
            }
        }
        return data
    }

    private static func decodePCM(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let hSize = MemoryLayout<PCMHeader>.size
        guard data.count >= hSize else { return nil }
        var header = PCMHeader(sampleRate: 0, channels: 0, frameLength: 0)
        _ = withUnsafeMutableBytes(of: &header) { data.copyBytes(to: $0, from: 0..<hSize) }

        let frames = Int(header.frameLength)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        if let dst = buf.floatChannelData {
            for ch in 0 ..< Int(header.channels) {
                let offset = hSize + ch * frames * MemoryLayout<Float>.size
                let end    = offset + frames * MemoryLayout<Float>.size
                guard end <= data.count else { return nil }
                _ = data.withUnsafeBytes { ptr in
                    memcpy(dst[ch], ptr.baseAddress! + offset, frames * MemoryLayout<Float>.size)
                }
            }
        }
        return buf
    }
}
