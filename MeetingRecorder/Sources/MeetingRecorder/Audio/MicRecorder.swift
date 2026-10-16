import AVFoundation
import Foundation

/// Records audio from the default microphone using AVAudioEngine.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var wavWriter: WAVWriter?
    private(set) var isRecording = false
    let outputPath: String

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    func start(sampleRate: Double = 48000) throws {
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Target format: mono float32
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create recording format"])
        }

        wavWriter = try WAVWriter(path: outputPath, sampleRate: hwFormat.sampleRate, channels: 1)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.wavWriter?.writeSamples(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> Double {
        guard isRecording else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        wavWriter?.finalize()
        isRecording = false

        // Return file duration
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let size = attrs[.size] as? UInt64 {
            let dataSize = size > 44 ? size - 44 : 0
            let sampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
            return Double(dataSize) / (sampleRate * 2) // 16-bit mono
        }
        return 0
    }
}
