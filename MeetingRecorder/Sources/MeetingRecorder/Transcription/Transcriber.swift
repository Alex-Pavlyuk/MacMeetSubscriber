import AVFoundation
import Foundation
import WhisperKit

/// A single transcription segment with speaker label.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
    let speaker: String // "Me" or "Others"
    let language: String?
}

/// Transcribes audio files using WhisperKit with text-based language correction.
final class Transcriber: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    /// The original (short) model name from settings — used for identity checks.
    private(set) var modelName: String
    /// The resolved name passed to WhisperKit.
    private var resolvedModel: String

    /// When true, skip ru/uk passes — just auto-detect (faster, less accurate for ru/uk).
    var singlePass: Bool = false

    init(modelName: String = "small") {
        self.modelName = modelName
        self.resolvedModel = modelName
    }

    /// Called on main thread to report status changes (state description).
    var onStatus: ((String) -> Void)?
    /// Called on main thread to report download progress (0.0–1.0, nil when not downloading).
    var onDownloadProgress: ((Double?) -> Void)?

    @MainActor
    private func reportProgress(_ message: String) {
        onStatus?(message)
    }

    private func ensureModel() async throws -> WhisperKit {
        if let wk = whisperKit { return wk }

        // Create without downloading/loading so we can attach callbacks first
        let config = WhisperKitConfig(
            model: resolvedModel,
            verbose: true,
            download: false
        )
        let wk = try await WhisperKit(config)

        // Attach state callback BEFORE triggering download/load
        wk.modelStateCallback = { [weak self] _, newState in
            guard let self else { return }
            Task { @MainActor in
                self.onStatus?(newState.description)
            }
        }

        // Observe download progress via KVO
        let observer = wk.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            let pct = progress.fractionCompleted
            Task { @MainActor in
                self.onDownloadProgress?(pct)
            }
        }
        _progressObserver = observer

        // Now trigger download + load + prewarm with callbacks active
        try await wk.setupModels(
            model: resolvedModel,
            modelRepo: nil,
            modelFolder: nil,
            download: true
        )
        try await wk.prewarmModels()
        try await wk.loadModels()

        whisperKit = wk

        await MainActor.run {
            onStatus?("Model ready")
            onDownloadProgress?(nil)
        }
        return wk
    }

    private var _progressObserver: NSKeyValueObservation?

    /// Raw segment from a single Whisper pass — keeps avgLogprob for comparison.
    private struct RawSegment {
        let start: Double
        let end: Double
        let text: String
        let language: String?
        let avgLogprob: Float
    }

    /// Transcribe with multi-pass language detection for ru/uk/en.
    ///
    /// Pass 1: auto-detect — reliably catches English, gives baseline for Cyrillic.
    /// Pass 2+3: forced ru + forced uk — only if Cyrillic detected, to distinguish ru/uk.
    func transcribe(audioPath: String, speakerLabel: String) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: audioPath) else { return [] }

        let attrs = try FileManager.default.attributesOfItem(atPath: audioPath)
        if let size = attrs[.size] as? UInt64, size < 1024 { return [] }

        if Self.isSilent(audioPath: audioPath) { return [] }

        let wk = try await ensureModel()

        let baseOptions = DecodingOptions(
            task: .transcribe,
            skipSpecialTokens: true,
            wordTimestamps: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: ChunkingStrategy.none
        )

        // Pass 1: auto-detect — reliable for English
        let totalPasses = singlePass ? 1 : 3
        await reportProgress("Pass 1/\(totalPasses): auto-detecting language...")
        var autoOptions = baseOptions
        autoOptions.language = nil
        autoOptions.detectLanguage = true
        let autoResults = try await wk.transcribe(audioPath: audioPath, decodeOptions: autoOptions)
        let autoSegments = Self.extractSegments(from: autoResults)

        // Check if any Cyrillic was detected — if not, all English, done (1 pass)
        let hasCyrillic = autoSegments.contains { seg in
            seg.text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }

        guard hasCyrillic else {
            await reportProgress("English detected — done (1 pass)")
            return autoSegments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text,
                                  speaker: speakerLabel, language: "en")
            }
        }

        // Single pass mode — use auto-detect as-is
        if singlePass {
            await reportProgress("Single pass done")
            return autoSegments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text,
                                  speaker: speakerLabel, language: $0.language ?? "ru")
            }
        }

        // Has Cyrillic — need ru/uk passes to distinguish
        await reportProgress("Pass 2/3: forced Russian...")
        var ruOptions = baseOptions
        ruOptions.language = "ru"
        let ruResults = try await wk.transcribe(audioPath: audioPath, decodeOptions: ruOptions)
        let ruSegments = Self.extractSegments(from: ruResults, langOverride: "ru")

        await reportProgress("Pass 3/3: forced Ukrainian...")
        var ukOptions = baseOptions
        ukOptions.language = "uk"
        let ukResults = try await wk.transcribe(audioPath: audioPath, decodeOptions: ukOptions)
        let ukSegments = Self.extractSegments(from: ukResults, langOverride: "uk")

        await reportProgress("Merging language results...")
        // Merge: English from auto-detect, ru/uk from forced passes
        return Self.mergeAll(auto: autoSegments, ru: ruSegments, uk: ukSegments, speaker: speakerLabel)
    }

    /// Extract raw segments from WhisperKit results, filtering hallucinations.
    private static func extractSegments(from results: [TranscriptionResult], langOverride: String? = nil) -> [RawSegment] {
        var segments: [RawSegment] = []
        for result in results {
            let lang = langOverride ?? result.language
            for seg in result.segments {
                var text = seg.text.trimmingCharacters(in: CharacterSet.whitespaces)
                text = text.replacingOccurrences(
                    of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                ).trimmingCharacters(in: CharacterSet.whitespaces)

                guard !text.isEmpty, text != "[BLANK_AUDIO]" else { continue }
                if seg.avgLogprob < -1.0 || seg.compressionRatio > 2.4 { continue }
                if seg.noSpeechProb > 0.6 { continue }

                let lower = text.lowercased()
                let hallucinations = [
                    "редактор субтитров", "корректор", "субтитры",
                    "subtitles", "translated by", "подписывайтесь",
                    "amara.org", "www.", "http"
                ]
                if hallucinations.contains(where: { lower.contains($0) }) { continue }

                segments.append(RawSegment(
                    start: Double(seg.start), end: Double(seg.end),
                    text: text, language: lang, avgLogprob: seg.avgLogprob
                ))
            }
        }
        return segments
    }

    /// Merge auto-detect (for English) with forced ru/uk passes (for Cyrillic).
    ///
    /// For each auto-detect segment:
    /// - Latin text → English, use auto-detect result
    /// - Cyrillic text → find matching ru/uk segments, compare text divergence
    private static func mergeAll(auto: [RawSegment], ru: [RawSegment], uk: [RawSegment], speaker: String) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []

        for autoSeg in auto {
            // Auto-detect produced Latin text → English
            if isLatin(autoSeg.text) {
                result.append(TranscriptSegment(
                    start: autoSeg.start, end: autoSeg.end, text: autoSeg.text,
                    speaker: speaker, language: "en"
                ))
                continue
            }

            // Cyrillic — use forced ru/uk passes
            let ruMatch = ru.first { overlap($0, autoSeg) > 0.5 }
            let ukMatch = uk.first { overlap($0, autoSeg) > 0.5 }

            guard let ruSeg = ruMatch, let ukSeg = ukMatch else {
                // Fallback to auto-detect
                result.append(TranscriptSegment(
                    start: autoSeg.start, end: autoSeg.end, text: autoSeg.text,
                    speaker: speaker, language: autoSeg.language ?? "ru"
                ))
                continue
            }

            // Compare Cyrillic parts of ru vs uk texts
            let ruCyrillic = ruSeg.text.filter { $0.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } }
            let ukCyrillic = ukSeg.text.filter { $0.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } }

            // If one pass lost all Cyrillic (digits/numbers) — keep ru version
            if ruCyrillic.isEmpty || ukCyrillic.isEmpty {
                result.append(TranscriptSegment(
                    start: ruSeg.start, end: ruSeg.end, text: ruSeg.text,
                    speaker: speaker, language: "ru"
                ))
                continue
            }

            let similarity: Double
            if ruCyrillic.count > 3 && ukCyrillic.count > 3 {
                similarity = Self.textSimilarity(ruCyrillic, ukCyrillic)
            } else {
                similarity = Self.textSimilarity(ruSeg.text, ukSeg.text)
            }

            // High similarity → Russian, low → Ukrainian
            if similarity > 0.85 {
                result.append(TranscriptSegment(
                    start: ruSeg.start, end: ruSeg.end, text: ruSeg.text,
                    speaker: speaker, language: "ru"
                ))
            } else {
                result.append(TranscriptSegment(
                    start: ukSeg.start, end: ukSeg.end, text: ukSeg.text,
                    speaker: speaker, language: "uk"
                ))
            }
        }
        return result
    }

    /// Character-level similarity ratio (0.0 = completely different, 1.0 = identical).
    /// Uses longest common subsequence for accurate comparison.
    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0 && n > 0 else { return 0 }

        // LCS length using two-row DP
        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
            curr = [Int](repeating: 0, count: n + 1)
        }
        let lcsLen = prev[n]
        return Double(2 * lcsLen) / Double(m + n)
    }

    /// Check if text is predominantly Latin (English).
    private static func isLatin(_ text: String) -> Bool {
        var latin = 0, cyrillic = 0
        for ch in text.unicodeScalars {
            if (0x0041...0x007A).contains(ch.value) { latin += 1 }
            else if (0x0400...0x04FF).contains(ch.value) { cyrillic += 1 }
        }
        return latin > 0 && Double(latin) / Double(max(latin + cyrillic, 1)) > 0.7
    }

    /// Calculate time overlap ratio between two segments.
    private static func overlap(_ a: RawSegment, _ b: RawSegment) -> Double {
        let overlapStart = max(a.start, b.start)
        let overlapEnd = min(a.end, b.end)
        let overlapDur = max(0, overlapEnd - overlapStart)
        let minDur = min(a.end - a.start, b.end - b.start)
        return minDur > 0 ? overlapDur / minDur : 0
    }

    // MARK: - Text-based Language Detection

    /// Detect ru/uk/en from text content using unique characters and marker words.
    static func detectLanguageFromText(_ text: String) -> String {
        let lower = text.lowercased()

        // Ukrainian-only letters: і, ї, є, ґ
        let ukLetters: [Character] = ["і", "ї", "є", "ґ"]
        let ukLetterCount = lower.filter { ukLetters.contains($0) }.count

        // Russian-only letters: ы, э, ё
        let ruLetters: [Character] = ["ы", "э", "ё"]
        let ruLetterCount = lower.filter { ruLetters.contains($0) }.count

        let ukWords: Set<String> = ["це", "але", "або", "також", "що", "від", "після",
                                     "якщо", "навіщо", "інший", "треба", "будь", "ще"]
        let ruWords: Set<String> = ["это", "или", "тоже", "после", "если", "зачем",
                                     "очень", "только", "вообще", "конечно", "нужно"]

        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let ukWordHits = words.intersection(ukWords).count
        let ruWordHits = words.intersection(ruWords).count

        let ukScore = ukLetterCount * 3 + ukWordHits
        let ruScore = ruLetterCount * 3 + ruWordHits

        if ukScore > ruScore { return "uk" }
        if ruScore > ukScore { return "ru" }
        return "ru" // default for ambiguous Cyrillic
    }

    /// Transcribe both mic and system audio, merge and sort.
    func transcribeMeeting(micPath: String, systemPath: String) async throws -> [TranscriptSegment] {
        let micSegments = try await transcribe(audioPath: micPath, speakerLabel: "Me")
        let sysSegments = try await transcribe(audioPath: systemPath, speakerLabel: "Others")
        return (micSegments + sysSegments).sorted { $0.start < $1.start }
    }

    // MARK: - Audio Analysis

    /// Check if an audio file is mostly silence by sampling multiple points.
    static func isSilent(audioPath: String, threshold: Float = 0.005) -> Bool {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)) else { return true }
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0 else { return true }

        let sampleRate = format.sampleRate
        let chunkFrames = AVAudioFrameCount(min(Double(totalFrames), sampleRate * 5))

        let positions: [AVAudioFramePosition] = [0, totalFrames / 4, totalFrames / 2, totalFrames * 3 / 4]

        for pos in positions {
            let safePos = min(pos, totalFrames - AVAudioFramePosition(chunkFrames))
            guard safePos >= 0 else { continue }

            file.framePosition = safePos
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { continue }
            do { try file.read(into: buffer) } catch { continue }
            guard let channelData = buffer.floatChannelData?[0] else { continue }
            let count = Int(buffer.frameLength)
            guard count > 0 else { continue }

            var sumSquares: Float = 0
            for i in 0..<count { sumSquares += channelData[i] * channelData[i] }
            let rms = sqrt(sumSquares / Float(count))
            if rms >= threshold { return false }
        }
        return true
    }

    // MARK: - Formatting

    static func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s)
                      : String(format: "%02d:%02d", m, s)
    }

    static func toMarkdown(_ segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "# Transcript\n\n*No speech detected.*\n" }

        var lines = ["# Transcript\n"]

        let languages = Set(segments.compactMap(\.language))
        let langNames = ["en": "English", "ru": "Russian", "uk": "Ukrainian",
                         "de": "German", "fr": "French", "es": "Spanish"]
        if !languages.isEmpty {
            let display = languages.map { langNames[$0] ?? $0 }.joined(separator: ", ")
            lines.append("**Languages detected:** \(display)\n")
        }
        lines.append("---\n")

        var currentSpeaker: String?
        for seg in segments {
            let ts = formatTimestamp(seg.start)
            if seg.speaker != currentSpeaker {
                currentSpeaker = seg.speaker
                lines.append("\n### [\(ts)] **\(seg.speaker)**\n")
            }
            lines.append("[\(ts)] \(seg.text)\n")
        }

        return lines.joined(separator: "\n")
    }

    static func toPlainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { seg in
            "[\(formatTimestamp(seg.start))] \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }
}
