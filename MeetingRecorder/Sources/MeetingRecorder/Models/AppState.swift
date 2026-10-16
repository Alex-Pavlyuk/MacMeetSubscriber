import Foundation
import SwiftUI

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: LogLevel
    let filePath: String?

    enum LogLevel {
        case info, success, error
    }

    init(timestamp: Date, message: String, level: LogLevel, filePath: String? = nil) {
        self.timestamp = timestamp
        self.message = message
        self.level = level
        self.filePath = filePath
    }

    var timestampString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }

    var color: Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - Stats Collector

/// Accumulates per-call stats dicts from OllamaProvider. One pipeline run may
/// produce many calls (extract/theme/actions/overview); single-shot produces one.
final class StatsBox {
    private(set) var calls: [[String: Any]] = []
    var lastCall: [String: Any]? { calls.last }

    func append(_ stats: [String: Any]) {
        calls.append(stats)
    }

    /// Returns nil if no stats were collected (e.g. cloud provider).
    var value: [String: Any]? {
        guard !calls.isEmpty else { return nil }
        if calls.count == 1 { return calls[0] }
        return ["calls": calls, "call_count": calls.count]
    }
}

// MARK: - Job Queue

/// A background job (transcription, summarization, etc.)
struct ProcessingJob: Identifiable {
    let id = UUID()
    let sessionURL: URL
    let kind: Kind
    var task: Task<Void, Never>?

    enum Kind: String {
        case transcribeAndSummarize = "Transcribe + Summarize"
        case transcribe = "Transcribe"
        case summarize = "Summarize"
    }

    var name: String { "\(kind.rawValue): \(sessionURL.lastPathComponent)" }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var logEntries: [LogEntry] = []
    @Published var activeJobs: [ProcessingJob] = []
    @Published var modelStatus: String?          // e.g. "Downloading", "Loading", "Specializing"
    @Published var modelDownloadProgress: Double? // 0.0–1.0 during download, nil otherwise
    @Published var summaryStatus: String?         // e.g. "Summarizing... 42 tokens (3.5 tok/s)"

    var isProcessing: Bool { !activeJobs.isEmpty }

    let config = AppConfig()

    private var micRecorder: MicRecorder?
    private var systemRecorder: SystemRecorder?
    private var transcriber: Transcriber?
    private var startTime: Date?
    private var timer: Timer?
    private var currentSessionURL: URL?

    func log(_ message: String, level: LogEntry.LogLevel = .info, filePath: String? = nil) {
        logEntries.append(LogEntry(timestamp: Date(), message: message, level: level, filePath: filePath))
    }

    // MARK: - Recording (independent of processing)

    func startRecording() {
        guard !isRecording else { return }

        do {
            try config.ensureRecordingsDir()
            let timestamp = DateFormatter.sessionFormatter.string(from: Date())
            let sessionURL = config.recordingsURL.appendingPathComponent(timestamp)
            try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            currentSessionURL = sessionURL

            let micPath = sessionURL.appendingPathComponent("mic.wav").path
            let sysPath = sessionURL.appendingPathComponent("system.wav").path

            log("Starting microphone recorder...")
            micRecorder = MicRecorder(outputPath: micPath)
            try micRecorder?.start()
            log("Mic recording started.", level: .success)

            log("Starting system audio recorder (ScreenCaptureKit)...")
            systemRecorder = SystemRecorder(outputPath: sysPath)
            Task {
                do {
                    try await systemRecorder?.start()
                    await MainActor.run {
                        self.log("System audio recording started.", level: .success)
                    }
                } catch {
                    await MainActor.run {
                        self.log("System audio error: \(error.localizedDescription)", level: .error)
                        self.log("Grant Screen Recording permission in System Settings → Privacy & Security.", level: .error)
                    }
                }
            }

            isRecording = true
            startTime = Date()
            recordingDuration = 0

            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startTime else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
            }

            log("Recording session: \(timestamp)", level: .success)

        } catch {
            log("Error starting recording: \(error.localizedDescription)", level: .error)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        let duration = recordingDuration
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        log("Stopping recording... (\(m)m \(s)s)")

        let micDuration = micRecorder?.stop() ?? 0
        log("Mic recorder stopped (\(String(format: "%.1f", micDuration))s saved).")

        let sessionURL = currentSessionURL

        // Enqueue processing as a background job
        Task {
            await systemRecorder?.stop()
            await MainActor.run { self.log("System recorder stopped.") }

            if let sessionURL {
                await MainActor.run {
                    self.enqueueJob(sessionURL: sessionURL, kind: .transcribeAndSummarize, duration: duration)
                }
            }
        }
    }

    // MARK: - Job Queue

    private func enqueueJob(sessionURL: URL, kind: ProcessingJob.Kind, duration: Double? = nil) {
        var job = ProcessingJob(sessionURL: sessionURL, kind: kind)
        log("Queued: \(job.name)")

        let jobId = job.id
        let task = Task {
            switch kind {
            case .transcribeAndSummarize:
                await self.processRecording(jobId: jobId, sessionURL: sessionURL, duration: duration ?? 0)
            case .transcribe:
                await self.runTranscribe(jobId: jobId, sessionURL: sessionURL)
            case .summarize:
                await self.runSummarize(jobId: jobId, sessionURL: sessionURL)
            }
            await MainActor.run {
                self.activeJobs.removeAll { $0.id == jobId }
            }
        }
        job.task = task
        activeJobs.append(job)
    }

    func cancelJob(_ job: ProcessingJob) {
        job.task?.cancel()
        activeJobs.removeAll { $0.id == job.id }
        log("Cancelled: \(job.name)", level: .error)
    }

    func cancelAllJobs() {
        for job in activeJobs {
            job.task?.cancel()
        }
        activeJobs.removeAll()
        log("All jobs cancelled.", level: .error)
    }

    // MARK: - Process Recording (transcribe + summarize)

    private func processRecording(jobId: UUID, sessionURL: URL, duration: Double) async {
        do {
            let micPath = sessionURL.appendingPathComponent("mic.wav").path
            let sysPath = sessionURL.appendingPathComponent("system.wav").path

            let transcriber = getTranscriber()

            try Task.checkCancellation()
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcribing mic.wav...") }
            let micSegments = try await transcriber.transcribe(audioPath: micPath, speakerLabel: "Me")
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Mic: \(micSegments.count) segments.", level: .success) }

            try Task.checkCancellation()
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcribing system.wav...") }
            let sysSegments = try await transcriber.transcribe(audioPath: sysPath, speakerLabel: "Others")
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] System: \(sysSegments.count) segments.", level: .success) }

            let allSegments = (micSegments + sysSegments).sorted { $0.start < $1.start }

            let transcriptMD = Transcriber.toMarkdown(allSegments)
            let transcriptURL = sessionURL.appendingPathComponent("transcript.md")
            try transcriptMD.write(to: transcriptURL, atomically: true, encoding: .utf8)
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcript saved.", level: .success, filePath: transcriptURL.path) }

            let plainText = Transcriber.toPlainText(allSegments)

            var metadata: [String: Any] = [
                "timestamp": sessionURL.lastPathComponent,
                "duration_seconds": round(duration * 10) / 10,
                "segments_count": allSegments.count,
                "languages": Array(Set(allSegments.compactMap(\.language))),
                "status": "pending_summary",
            ]

            // Auto-summarize
            if config.autoSummarize && !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Task.checkCancellation()
                let statsBox = StatsBox()
                do {
                    await MainActor.run {
                        log("[\(sessionURL.lastPathComponent)] Summarizing with \(self.config.provider)...")
                        summaryStatus = "Summarizing..."
                    }
                    let summarizer = Summarizer(config: config)
                    let (summary, providerName) = try await summarizer.summarize(
                        transcript: plainText,
                        onProgress: { tokens, tps in
                            Task { @MainActor in
                                self.summaryStatus = "Summarizing... \(tokens) tokens (\(String(format: "%.1f", tps)) tok/s)"
                            }
                        },
                        onStage: { stage in
                            Task { @MainActor in
                                self.summaryStatus = stage
                            }
                        },
                        onStats: { stats in statsBox.append(stats) }
                    )

                    let summaryURL = sessionURL.appendingPathComponent("summary.md")
                    try "# Meeting Summary\n\n\(summary)".write(to: summaryURL, atomically: true, encoding: .utf8)

                    metadata["status"] = "complete"
                    metadata["provider"] = providerName
                    if let stats = statsBox.value { metadata["ollama_stats"] = stats }
                    await MainActor.run {
                        summaryStatus = nil
                        log("[\(sessionURL.lastPathComponent)] Summary saved (\(providerName)).", level: .success, filePath: summaryURL.path)
                        if let fallback = statsBox.lastCall?["used_thinking_fallback"] as? Bool, fallback {
                            log("[\(sessionURL.lastPathComponent)] Note: response was empty, used thinking field as fallback.", level: .error)
                        }
                    }
                } catch {
                    metadata["summary_error"] = error.localizedDescription
                    if let stats = statsBox.value { metadata["ollama_stats"] = stats }
                    await MainActor.run { log("[\(sessionURL.lastPathComponent)] Summary error: \(error.localizedDescription)", level: .error) }
                }
            } else if !config.autoSummarize {
                await MainActor.run { log("[\(sessionURL.lastPathComponent)] Auto-summarize disabled.") }
            }

            let metaURL = sessionURL.appendingPathComponent("metadata.json")
            let metaData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            try metaData.write(to: metaURL)

            let status = metadata["status"] as? String ?? "unknown"
            await MainActor.run {
                log("[\(sessionURL.lastPathComponent)] Done. Status: \(status), segments: \(allSegments.count).", level: .success)
            }
        } catch is CancellationError {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Cancelled.", level: .error) }
        } catch {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Error: \(error.localizedDescription)", level: .error) }
        }
    }

    // MARK: - Standalone Transcribe

    private func runTranscribe(jobId: UUID, sessionURL: URL) async {
        do {
            let micPath = sessionURL.appendingPathComponent("mic.wav").path
            let sysPath = sessionURL.appendingPathComponent("system.wav").path
            let transcriber = getTranscriber()

            try Task.checkCancellation()
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcribing mic.wav...") }
            let micSegs = try await transcriber.transcribe(audioPath: micPath, speakerLabel: "Me")
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Mic: \(micSegs.count) segments.", level: .success) }

            try Task.checkCancellation()
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcribing system.wav...") }
            let sysSegs = try await transcriber.transcribe(audioPath: sysPath, speakerLabel: "Others")
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] System: \(sysSegs.count) segments.", level: .success) }

            let all = (micSegs + sysSegs).sorted { $0.start < $1.start }
            let md = Transcriber.toMarkdown(all)
            let url = sessionURL.appendingPathComponent("transcript.md")
            try md.write(to: url, atomically: true, encoding: .utf8)

            let metaURL = sessionURL.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metaURL),
               var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                meta["segments_count"] = all.count
                meta["languages"] = Array(Set(all.compactMap(\.language)))
                try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(to: metaURL)
            }

            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcript saved.", level: .success, filePath: url.path) }
        } catch is CancellationError {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcription cancelled.", level: .error) }
        } catch {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Transcribe error: \(error.localizedDescription)", level: .error) }
        }
    }

    // MARK: - Standalone Summarize

    private func runSummarize(jobId: UUID, sessionURL: URL) async {
        do {
            let micPath = sessionURL.appendingPathComponent("mic.wav").path
            let sysPath = sessionURL.appendingPathComponent("system.wav").path

            let plainText: String
            let transcriptURL = sessionURL.appendingPathComponent("transcript.md")
            if FileManager.default.fileExists(atPath: transcriptURL.path) {
                // Use existing transcript
                plainText = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            } else if FileManager.default.fileExists(atPath: micPath) || FileManager.default.fileExists(atPath: sysPath) {
                let transcriber = getTranscriber()
                let segments = try await transcriber.transcribeMeeting(micPath: micPath, systemPath: sysPath)
                plainText = Transcriber.toPlainText(segments)
            } else {
                await MainActor.run { log("[\(sessionURL.lastPathComponent)] No audio or transcript found.", level: .error) }
                return
            }

            guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run { log("[\(sessionURL.lastPathComponent)] Empty transcript.", level: .error) }
                return
            }

            try Task.checkCancellation()
            await MainActor.run {
                log("[\(sessionURL.lastPathComponent)] Summarizing with \(self.config.provider)...")
                summaryStatus = "Summarizing..."
            }
            let summarizer = Summarizer(config: config)
            let statsBox = StatsBox()
            let (summary, providerName) = try await summarizer.summarize(
                transcript: plainText,
                onProgress: { tokens, tps in
                    Task { @MainActor in
                        self.summaryStatus = "Summarizing... \(tokens) tokens (\(String(format: "%.1f", tps)) tok/s)"
                    }
                },
                onStage: { stage in
                    Task { @MainActor in
                        self.summaryStatus = stage
                    }
                },
                onStats: { stats in statsBox.append(stats) }
            )
            await MainActor.run { summaryStatus = nil }

            let summaryURL = sessionURL.appendingPathComponent("summary.md")
            try "# Meeting Summary\n\n\(summary)".write(to: summaryURL, atomically: true, encoding: .utf8)

            let metaURL = sessionURL.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metaURL),
               var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                meta["status"] = "complete"
                meta["provider"] = providerName
                meta.removeValue(forKey: "summary_error")
                if let stats = statsBox.value { meta["ollama_stats"] = stats }
                try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(to: metaURL)
            }

            await MainActor.run {
                log("[\(sessionURL.lastPathComponent)] Summary saved (\(providerName)).", level: .success, filePath: summaryURL.path)
                if let fallback = statsBox.lastCall?["used_thinking_fallback"] as? Bool, fallback {
                    log("[\(sessionURL.lastPathComponent)] Note: response was empty, used thinking field as fallback.", level: .error)
                }
            }
        } catch is CancellationError {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Summarization cancelled.", level: .error) }
        } catch {
            await MainActor.run { log("[\(sessionURL.lastPathComponent)] Summarize error: \(error.localizedDescription)", level: .error) }
        }
    }

    private func getTranscriber() -> Transcriber {
        let model = config.whisperModel
        if transcriber == nil || transcriber?.modelName != model {
            log("Loading Whisper model '\(model)'...")
            let t = Transcriber(modelName: model)
            t.onStatus = { [weak self] status in
                self?.modelStatus = status
                self?.log("Whisper: \(status)")
            }
            t.onDownloadProgress = { [weak self] progress in
                self?.modelDownloadProgress = progress
            }
            transcriber = t
        }
        // Always sync singlePass from config (can be toggled mid-session)
        transcriber?.singlePass = config.singlePassTranscription
        return transcriber!
    }

    // MARK: - Public Actions (enqueue jobs)

    func summarizeLast() {
        guard let session = findLastPending() else {
            log("No pending recordings to summarize.")
            return
        }
        enqueueJob(sessionURL: session, kind: .summarize)
    }

    func summarizeAllPending() {
        let pending = findAllPending()
        guard !pending.isEmpty else {
            log("No pending recordings to summarize.")
            return
        }
        for session in pending {
            enqueueJob(sessionURL: session, kind: .summarize)
        }
    }

    func retranscribe(_ sessionURL: URL) {
        enqueueJob(sessionURL: sessionURL, kind: .transcribe)
    }

    func resummarize(_ sessionURL: URL) {
        enqueueJob(sessionURL: sessionURL, kind: .summarize)
    }

    // MARK: - Queries

    private func findLastPending() -> URL? {
        sessionsSorted().first { readStatus($0) == "pending_summary" }
    }

    private func findAllPending() -> [URL] {
        sessionsSorted().filter { readStatus($0) == "pending_summary" }
    }

    func sessionsSorted() -> [URL] {
        let dir = config.recordingsURL
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.hasDirectoryPath }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("metadata.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func readStatus(_ sessionURL: URL) -> String? {
        let metaURL = sessionURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return meta["status"] as? String
    }

    // MARK: - Delete Recordings

    func deleteLastRecording() {
        guard let session = sessionsSorted().first else {
            log("No recordings to delete.")
            return
        }
        deleteRecording(session)
    }

    func deleteAllRecordings() {
        let sessions = sessionsSorted()
        guard !sessions.isEmpty else {
            log("No recordings to delete.")
            return
        }
        var deleted = 0
        for session in sessions {
            do {
                try FileManager.default.removeItem(at: session)
                deleted += 1
            } catch {
                log("Failed to delete \(session.lastPathComponent): \(error.localizedDescription)", level: .error)
            }
        }
        log("Deleted \(deleted) recording(s).", level: .success)
    }

    func deleteRecording(_ sessionURL: URL) {
        let name = sessionURL.lastPathComponent
        do {
            try FileManager.default.removeItem(at: sessionURL)
            log("Deleted: \(name)", level: .success)
        } catch {
            log("Delete failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Shutdown

    /// Cancel all in-flight work so the process can exit cleanly.
    func shutdown() {
        if isRecording {
            isRecording = false
            timer?.invalidate()
            timer = nil
            _ = micRecorder?.stop()
            // systemRecorder?.stop() is async — but we're terminating, so just cancel tasks
        }
        cancelAllJobs()
        transcriber = nil
        modelStatus = nil
        modelDownloadProgress = nil
        summaryStatus = nil
    }

    // MARK: - Utilities

    func openRecordings() {
        try? config.ensureRecordingsDir()
        NSWorkspace.shared.open(config.recordingsURL)
    }
}

extension DateFormatter {
    static let sessionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
