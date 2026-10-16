import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records system audio using ScreenCaptureKit.
final class SystemRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var wavWriter: WAVWriter?
    private(set) var isRecording = false
    let outputPath: String
    let sampleRate: Double
    let channels: Int

    init(outputPath: String, sampleRate: Double = 48000, channels: Int = 1) {
        self.outputPath = outputPath
        self.sampleRate = sampleRate
        self.channels = channels
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = channels
        config.excludesCurrentProcessAudio = true

        wavWriter = try WAVWriter(path: outputPath, sampleRate: sampleRate, channels: UInt16(channels))

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(self, type: .audio,
                                     sampleHandlerQueue: DispatchQueue(label: "system.audio.capture"))
        try await stream!.startCapture()
        isRecording = true
    }

    func stop() async {
        guard isRecording else { return }
        do {
            try await stream?.stopCapture()
        } catch {
            print("[SystemRecorder] Stop error: \(error)")
        }
        wavWriter?.finalize()
        stream = nil
        isRecording = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        ) else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        guard let srcData = dataPointer else { return }

        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let bytesPerFrame = Int(asbd.mBytesPerFrame)
            for ch in 0..<Int(asbd.mChannelsPerFrame) {
                if let channelData = pcmBuffer.floatChannelData?[ch] {
                    memcpy(channelData, srcData.advanced(by: ch * frameCount * bytesPerFrame),
                           frameCount * bytesPerFrame)
                }
            }
        } else {
            if let channelData = pcmBuffer.floatChannelData?[0] {
                memcpy(channelData, srcData, dataLength)
            }
        }

        wavWriter?.writeSamples(pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemRecorder] Stream stopped: \(error.localizedDescription)")
    }
}
