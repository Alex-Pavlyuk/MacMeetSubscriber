import Foundation

// MARK: - Summary Prompt (used by single-shot path)

private let summaryPrompt = """
You are a meeting summarizer. Analyze the following meeting transcript and produce a structured summary.

The transcript contains two speakers:
- "Me" — the user (recording from their microphone)
- "Others" — other participants (recording from system audio/speakers)

The meeting may contain Russian, Ukrainian, and English speech mixed together.
Produce the summary in the SAME language(s) as the majority of the meeting.

## Important:
- Scan the ENTIRE transcript from beginning to end before writing.
- Each major topic should get its own section regardless of how briefly it was discussed.
- Include specific names, dates, deadlines, and project names mentioned.

## Required sections:

### Meeting Overview
Brief 2-3 sentence overview.

### Key Topics Discussed
Bulleted list of main topics.

### Decisions Made
Bulleted list of decisions or agreements.

### Action Items
Bulleted list of tasks/follow-ups with responsible person if identifiable.

### Notes
Other important observations.

---

## Transcript:

"""

// MARK: - Provider Protocol

/// Options passed to provider.generate. Honored by OllamaProvider; ignored by cloud providers.
struct GenerateOptions {
    /// Override context window size (Ollama only). nil = use provider default.
    var numCtx: Int?
    /// Cap on output tokens.
    var numPredict: Int = 4096
    /// Force JSON output (Ollama "format":"json"). Dramatically speeds up JSON stages.
    var jsonFormat: Bool = false
    /// Keep model loaded in memory between calls (Ollama). "-1" = indefinite for this session.
    var keepAlive: String? = "10m"

    static let `default` = GenerateOptions()
    static let forJSONExtraction = GenerateOptions(numCtx: 4096, numPredict: 1024, jsonFormat: true)
    static let forShortWrite = GenerateOptions(numCtx: 8192, numPredict: 1024)
}

protocol SummaryProvider {
    var displayName: String { get }
    /// Single-shot summarization using the built-in summaryPrompt.
    func summarize(transcript: String) async throws -> String
    /// Arbitrary LLM call with a full prompt (used by pipeline stages).
    func generate(prompt: String, options: GenerateOptions) async throws -> String
}

extension SummaryProvider {
    func summarize(transcript: String) async throws -> String {
        return try await generate(prompt: summaryPrompt + transcript, options: .default)
    }
    func generate(prompt: String) async throws -> String {
        return try await generate(prompt: prompt, options: .default)
    }
}

// MARK: - Claude

struct ClaudeProvider: SummaryProvider {
    let apiKey: String
    let model: String
    var displayName: String { "Claude (\(model))" }

    func generate(prompt: String, options: GenerateOptions) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": options.numPredict,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data, provider: "Claude")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? "Empty response"
    }
}

// MARK: - Gemini

struct GeminiProvider: SummaryProvider {
    let apiKey: String
    let model: String
    var displayName: String { "Gemini (\(model))" }

    func generate(prompt: String, options: GenerateOptions) async throws -> String {
        _ = options
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        let url = URL(string: urlStr)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data, provider: "Gemini")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.first?["text"] as? String ?? "Empty response"
    }
}

// MARK: - OpenAI

struct OpenAIProvider: SummaryProvider {
    let apiKey: String
    let model: String
    var displayName: String { "OpenAI (\(model))" }

    func generate(prompt: String, options: GenerateOptions) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": options.numPredict,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data, provider: "OpenAI")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? "Empty response"
    }
}

// MARK: - Ollama

struct OllamaProvider: SummaryProvider {
    let baseURL: String
    let model: String
    let numCtx: Int
    var displayName: String { "Ollama (\(model))" }
    /// Called periodically with (tokensGenerated, tokensPerSecond).
    var onProgress: ((Int, Double) -> Void)?
    /// Called once per generate() with a diagnostic dict (num_ctx, eval_count,
    /// prompt_eval_count, done_reason, durations in seconds, thinking fallback flag).
    var onStats: (([String: Any]) -> Void)?

    func generate(prompt: String, options: GenerateOptions) async throws -> String {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let effectiveCtx = options.numCtx ?? numCtx
        let opts: [String: Any] = [
            "num_ctx": effectiveCtx,
            "num_predict": options.numPredict,
            "temperature": 0.3,
        ]
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true,
            "options": opts,
        ]
        if options.jsonFormat {
            body["format"] = "json"
        }
        if let keepAlive = options.keepAlive {
            body["keep_alive"] = keepAlive
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 1800

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw SummarizerError.httpError(http.statusCode, errorBody)
        }

        var result = ""
        var thinking = ""
        var tokenCount = 0
        let startTime = Date()
        var stats: [String: Any] = [
            "model": model,
            "num_ctx": effectiveCtx,
            "num_predict": options.numPredict,
        ]

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let token = json["response"] as? String, !token.isEmpty {
                result += token
                tokenCount += 1
                if tokenCount % 5 == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tps = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                    onProgress?(tokenCount, tps)
                }
            }
            if let thought = json["thinking"] as? String, !thought.isEmpty {
                thinking += thought
            }

            if json["done"] as? Bool == true {
                if let reason = json["done_reason"] as? String { stats["done_reason"] = reason }
                if let v = json["eval_count"] as? Int { stats["eval_count"] = v }
                if let v = json["prompt_eval_count"] as? Int { stats["prompt_eval_count"] = v }
                if let v = json["total_duration"] as? Int {
                    stats["total_duration_s"] = round(Double(v) / 1e8) / 10
                }
                if let v = json["load_duration"] as? Int {
                    stats["load_duration_s"] = round(Double(v) / 1e8) / 10
                }
                if let v = json["prompt_eval_duration"] as? Int {
                    stats["prompt_eval_duration_s"] = round(Double(v) / 1e8) / 10
                }
                if let v = json["eval_duration"] as? Int {
                    stats["eval_duration_s"] = round(Double(v) / 1e8) / 10
                }
                break
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let tps = elapsed > 0 ? Double(tokenCount) / elapsed : 0
        onProgress?(tokenCount, tps)

        let responseEmpty = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        stats["response_chars"] = result.count
        stats["thinking_chars"] = thinking.count
        if responseEmpty && !thinking.isEmpty {
            stats["used_thinking_fallback"] = true
            onStats?(stats)
            return thinking
        }
        onStats?(stats)
        return result
    }

    /// Fetch available model names from an Ollama instance.
    static func fetchModels(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]] ?? []
            return models.compactMap { $0["name"] as? String }.sorted()
        } catch {
            return []
        }
    }
}

// MARK: - Summarizer

struct Summarizer {
    let config: AppConfig

    func getProvider(override: String? = nil, transcript: String? = nil) throws -> SummaryProvider {
        let name = override ?? config.provider
        switch name {
        case "claude":
            guard !config.claudeAPIKey.isEmpty else { throw SummarizerError.missingKey("Claude") }
            return ClaudeProvider(apiKey: config.claudeAPIKey, model: config.claudeModel)
        case "gemini":
            guard !config.geminiAPIKey.isEmpty else { throw SummarizerError.missingKey("Gemini") }
            return GeminiProvider(apiKey: config.geminiAPIKey, model: config.geminiModel)
        case "openai":
            guard !config.openaiAPIKey.isEmpty else { throw SummarizerError.missingKey("OpenAI") }
            return OpenAIProvider(apiKey: config.openaiAPIKey, model: config.openaiModel)
        case "ollama":
            let ctx = config.ollamaNumCtx == 0
                ? Self.autoNumCtx(for: transcript ?? "")
                : config.ollamaNumCtx
            return OllamaProvider(baseURL: config.ollamaURL, model: config.ollamaModel, numCtx: ctx)
        default:
            throw SummarizerError.unknownProvider(name)
        }
    }

    /// Auto-picks num_ctx from transcript length. Rough: 1 token ≈ 3 chars for mixed Cyrillic/Latin.
    /// Budget covers prompt overhead (~2k) plus output reserve (~1k).
    static func autoNumCtx(for transcript: String) -> Int {
        let estInput = transcript.count / 3
        let needed = estInput + 3072
        switch needed {
        case ..<3584: return 4096
        case ..<7168: return 8192
        case ..<14336: return 16384
        default: return 32768
        }
    }

    /// Summarize with optional streaming progress for Ollama.
    /// If `usePipeline` is enabled in config, runs multi-stage pipeline instead of single-shot.
    func summarize(
        transcript: String,
        onProgress: ((Int, Double) -> Void)? = nil,
        onStage: ((String) -> Void)? = nil,
        onStats: (([String: Any]) -> Void)? = nil
    ) async throws -> (summary: String, providerName: String) {
        var provider = try getProvider(transcript: transcript)
        if var ollama = provider as? OllamaProvider {
            if let onProgress { ollama.onProgress = onProgress }
            if let onStats { ollama.onStats = onStats }
            provider = ollama
        }

        let displayName = config.usePipeline
            ? provider.displayName + " [pipeline]"
            : provider.displayName

        var summary = ""
        for attempt in 1...2 {
            if config.usePipeline {
                let pipeline = PipelineSummarizer(provider: provider, onStage: onStage)
                summary = try await pipeline.summarize(transcript: transcript)
            } else {
                summary = try await provider.summarize(transcript: transcript)
            }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 16 { return (summary, displayName) }
            if attempt == 1 {
                onStage?("Empty summary, retrying...")
                try Task.checkCancellation()
            } else {
                throw SummarizerError.emptyOutput(provider: displayName, got: trimmed)
            }
        }
        return (summary, displayName)
    }
}

enum SummarizerError: LocalizedError {
    case missingKey(String)
    case unknownProvider(String)
    case httpError(Int, String)
    case emptyOutput(provider: String, got: String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "\(p) API key not configured. Open Settings to add it."
        case .unknownProvider(let p): return "Unknown provider: \(p)"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .emptyOutput(let p, let got):
            let preview = got.isEmpty ? "<empty>" : String(got.prefix(80))
            return "\(p) returned empty/too-short summary (\(got.count) chars): \(preview)"
        }
    }
}

private func checkHTTPResponse(_ response: URLResponse, data: Data, provider: String) throws {
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
        let body = String(data: data, encoding: .utf8) ?? "no body"
        throw SummarizerError.httpError(http.statusCode, body)
    }
}
