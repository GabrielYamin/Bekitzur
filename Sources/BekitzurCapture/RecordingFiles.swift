import AudioToolbox
import Foundation

/// Tracks are recorded as ADTS AAC, where every frame carries its own header, so whatever reached the disk can be read
/// even if the app dies mid-recording; an .m4a can't be opened until it's finished. When the Conversation is processed,
/// each ADTS track becomes an .m4a holding the same frames, without re-encoding.
public enum RecordingFiles {
    public static let recordingExtension = "aac"

    /// ADTS tracks in a Conversation's folder that haven't become .m4a files yet.
    public static func unfinished(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == recordingExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies the ADTS file's frames into an .m4a beside it, then removes the ADTS file. A last frame cut off by a crash
    /// is left out. Throws, keeping the ADTS file, if it holds no readable frame.
    @discardableResult
    public static func finish(_ source: URL) throws -> URL {
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        var openedInput: AudioFileID?
        try check(AudioFileOpenURL(source as CFURL, .readPermission, kAudioFileAAC_ADTSType, &openedInput), "open \(source.lastPathComponent)")
        guard let input = openedInput else { throw CaptureError(step: "open \(source.lastPathComponent)", status: kAudioFileUnspecifiedError) }
        defer { AudioFileClose(input) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format), "read the format of \(source.lastPathComponent)")
        var createdOutput: AudioFileID?
        try check(AudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType, &format, .eraseFile, &createdOutput), "create \(destination.lastPathComponent)")
        guard let output = createdOutput else { throw CaptureError(step: "create \(destination.lastPathComponent)", status: kAudioFileUnspecifiedError) }

        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(input, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileGetProperty(input, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie) == noErr {
                AudioFileSetProperty(output, kAudioFilePropertyMagicCookieData, cookieSize, cookie)
            }
        }

        // An AAC frame holds at most 768 bytes per channel.
        let batch: UInt32 = 1_024
        var data = [UInt8](repeating: 0, count: Int(batch) * 768 * Int(max(format.mChannelsPerFrame, 1)))
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: Int(batch))
        var packets: Int64 = 0
        var copied = noErr
        while copied == noErr {
            var bytes = UInt32(data.count)
            var count = batch
            let status = AudioFileReadPacketData(input, false, &bytes, &descriptions, packets, &count, &data)
            guard count > 0, status == noErr || status == kAudioFileEndOfFileError else { break }
            copied = AudioFileWritePackets(output, false, bytes, descriptions, packets, &count, data)
            packets += Int64(count)
        }

        // Apple's AAC encoder starts with 2,112 frames of priming, which an .m4a records so readers skip them.
        if packets > 0, format.mFramesPerPacket > 0 {
            let frames = packets * Int64(format.mFramesPerPacket)
            var table = AudioFilePacketTableInfo(mNumberValidFrames: max(0, frames - 2_112), mPrimingFrames: Int32(min(frames, 2_112)), mRemainderFrames: 0)
            AudioFileSetProperty(output, kAudioFilePropertyPacketTableInfo, UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &table)
        }
        let closed = AudioFileClose(output)
        guard packets > 0, copied == noErr, closed == noErr else {
            try? FileManager.default.removeItem(at: destination)
            throw CaptureError(step: "copy \(source.lastPathComponent) into an .m4a", status: closed != noErr ? closed : copied != noErr ? copied : kAudioFileInvalidFileError)
        }
        try FileManager.default.removeItem(at: source)
        return destination
    }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw CaptureError(step: step, status: status) }
}
