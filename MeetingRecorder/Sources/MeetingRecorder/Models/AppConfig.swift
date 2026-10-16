import Foundation
import SwiftUI

/// Application settings stored in UserDefaults via @AppStorage.
final class AppConfig: ObservableObject {
    // LLM Provider
    @AppStorage("provider") var provider = "claude"

    // Claude
    @AppStorage("claudeAPIKey") var claudeAPIKey = ""
    @AppStorage("claudeModel") var claudeModel = "claude-sonnet-4-20250514"

    // Gemini
    @AppStorage("geminiAPIKey") var geminiAPIKey = ""
    @AppStorage("geminiModel") var geminiModel = "gemini-2.0-flash"

    // OpenAI
    @AppStorage("openaiAPIKey") var openaiAPIKey = ""
    @AppStorage("openaiModel") var openaiModel = "gpt-4o"

    // Ollama
    @AppStorage("ollamaURL") var ollamaURL = "http://localhost:11434"
    @AppStorage("ollamaModel") var ollamaModel = "llama3.1"
    /// 0 means Auto — size picked at summarize time from transcript length.
    @AppStorage("ollamaNumCtx") var ollamaNumCtx = 0

    // Whisper
    @AppStorage("whisperModel") var whisperModel = "small"

    // Transcription
    @AppStorage("singlePassTranscription") var singlePassTranscription = false

    // Summarization pipeline
    @AppStorage("usePipeline") var usePipeline = false

    // Recording
    @AppStorage("autoSummarize") var autoSummarize = true
    @AppStorage("recordingsDir") var recordingsDir = ""

    /// Resolved recordings directory.
    var recordingsURL: URL {
        if !recordingsDir.isEmpty {
            return URL(fileURLWithPath: recordingsDir)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MeetingRecorder")
    }

    func ensureRecordingsDir() throws {
        try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
    }
}
