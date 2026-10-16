import AVFoundation
import Foundation

/// Writes PCM audio samples to a WAV file.
final class WAVWriter {
    private let fileHandle: FileHandle
    private let sampleRate: Double
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataSize: UInt32 = 0
    private let lock = NSLock()

    init(path: String, sampleRate: Double, channels: UInt16 = 1) throws {
        self.sampleRate = sampleRate
        self.channels = channels

        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))

        // Write placeholder header (44 bytes)
        fileHandle.write(Data(count: 44))
    }

    /// Write float PCM samples (interleaved or per-channel) as 16-bit PCM.
    func writeSamples(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(channels)
        guard frameCount > 0 else { return }

        var samples = [Int16]()
        samples.reserveCapacity(frameCount * channelCount)

        for frame in 0..<frameCount {
            for ch in 0..<min(channelCount, Int(buffer.format.channelCount)) {
                let s = max(-1.0, min(1.0, floatData[ch][frame]))
                samples.append(Int16(s * Float(Int16.max)))
            }
        }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        fileHandle.write(data)
        dataSize += UInt32(data.count)
        lock.unlock()
    }

    /// Write raw float samples from a buffer pointer.
    func writeRawSamples(_ data: UnsafeBufferPointer<Float>, channelCount: Int) {
        let frameCount = data.count / channelCount
        guard frameCount > 0 else { return }

        var samples = [Int16]()
        samples.reserveCapacity(data.count)

        for i in 0..<data.count {
            let s = max(-1.0, min(1.0, data[i]))
            samples.append(Int16(s * Float(Int16.max)))
        }

        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        fileHandle.write(pcmData)
        dataSize += UInt32(pcmData.count)
        lock.unlock()
    }

    /// Finalize the WAV file by writing the correct header.
    func finalize() {
        lock.lock()
        let finalDataSize = dataSize
        lock.unlock()

        fileHandle.seek(toFileOffset: 0)

        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendUInt32(36 + finalDataSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendUInt32(16)
        header.appendUInt16(1) // PCM
        header.appendUInt16(channels)
        header.appendUInt32(UInt32(sampleRate))
        header.appendUInt32(byteRate)
        header.appendUInt16(blockAlign)
        header.appendUInt16(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendUInt32(finalDataSize)

        fileHandle.write(header)
        fileHandle.closeFile()
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
