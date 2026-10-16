import Foundation

/// Multi-stage summarization pipeline:
///   1. Chunk transcript by time windows (no LLM)
///   2. Extract structured JSON from each chunk (LLM)
///   3. Cluster extracted topics by normalized name (no LLM)
///   4. Write themed section per cluster (LLM)
///   5. Consolidate action items across chunks (LLM)
///   6. Write a short overview (LLM)
struct PipelineSummarizer {
    let provider: SummaryProvider
    var onStage: ((String) -> Void)?

    /// Minutes per chunk in stage 1.
    var windowMinutes: Int = 5

    func summarize(transcript: String) async throws -> String {
        // Stage 1: chunk
        onStage?("Chunking transcript…")
        let chunks = Chunker.chunk(transcript: transcript, windowMinutes: windowMinutes)
        if chunks.isEmpty {
            return "Empty transcript."
        }

        // Detect dominant language from the transcript (heuristic).
        let language = detectLanguage(transcript: transcript)

        // Stage 2: extract per chunk
        var extractions: [(chunk: TranscriptChunk, data: ChunkExtraction)] = []
        for chunk in chunks {
            onStage?("Extracting chunk \(chunk.index + 1)/\(chunks.count) (\(chunk.timeRange))…")
            let extraction = try await extractChunk(chunk: chunk)
            extractions.append((chunk, extraction))
        }

        // Stage 3: cluster by topic name (no LLM)
        onStage?("Clustering topics…")
        let clusters = clusterTopics(extractions: extractions)

        // Stage 4: theme writing per cluster
        var themes: [(name: String, body: String)] = []
        for (i, cluster) in clusters.enumerated() {
            onStage?("Writing theme \(i + 1)/\(clusters.count): \(cluster.name)…")
            let body = try await writeTheme(cluster: cluster, language: language)
            themes.append((cluster.name, body))
        }

        // Stage 5: consolidate action items
        onStage?("Consolidating action items…")
        let actions = try await consolidateActions(extractions: extractions, language: language)

        // Stage 6: overview
        onStage?("Writing overview…")
        let overview = try await writeOverview(themes: themes, language: language)

        // Final assembly (no LLM)
        return assemble(overview: overview, themes: themes, actions: actions)
    }

    // MARK: - Stage 2

    private func extractChunk(chunk: TranscriptChunk) async throws -> ChunkExtraction {
        let prompt = PipelinePrompts.extract(timeRange: chunk.timeRange, chunkText: chunk.text)
        // JSON mode + small context + small num_predict. Vastly faster on Ollama.
        let opts = GenerateOptions.forJSONExtraction
        // Retry up to 2 times if JSON is invalid.
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let retryPrompt = attempt == 0
                    ? prompt
                    : prompt + "\n\nIMPORTANT: your previous response was not valid JSON. Return ONLY a single JSON object matching the schema, no prose."
                let response = try await provider.generate(prompt: retryPrompt, options: opts)
                if let parsed = try? parseChunkJSON(response) {
                    return parsed
                }
            } catch {
                lastError = error
            }
        }
        // Soft-fail: return empty extraction so one bad chunk doesn't kill the run.
        _ = lastError
        return ChunkExtraction(topics: [], actionItems: [])
    }

    private func parseChunkJSON(_ raw: String) throws -> ChunkExtraction {
        // Strip common wrappers: ```json ... ``` or ``` ... ```
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // drop first line (```json or ```)
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // If response has prose around JSON, extract the outermost {...}.
        if let startIdx = s.firstIndex(of: "{"),
           let endIdx = s.lastIndex(of: "}"),
           startIdx < endIdx {
            s = String(s[startIdx...endIdx])
        }
        guard let data = s.data(using: .utf8) else {
            throw SummarizerError.httpError(0, "bad encoding")
        }
        return try JSONDecoder().decode(ChunkExtraction.self, from: data)
    }

    // MARK: - Stage 3

    private struct TopicCluster {
        let name: String
        /// (timeRange, points, decisions) collected across chunks
        var occurrences: [(timeRange: String, points: [String], decisions: [String])]
    }

    private func clusterTopics(
        extractions: [(chunk: TranscriptChunk, data: ChunkExtraction)]
    ) -> [TopicCluster] {
        var byKey: [String: TopicCluster] = [:]
        var order: [String] = []
        for (chunk, data) in extractions {
            for topic in data.topics {
                let key = normalizeTopicName(topic.name)
                if byKey[key] == nil {
                    byKey[key] = TopicCluster(name: topic.name, occurrences: [])
                    order.append(key)
                }
                byKey[key]!.occurrences.append((
                    chunk.timeRange,
                    topic.points,
                    topic.decisions
                ))
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private func normalizeTopicName(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "scope ", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    // MARK: - Stage 4

    private func writeTheme(cluster: TopicCluster, language: String) async throws -> String {
        var lines: [String] = []
        for occ in cluster.occurrences {
            for p in occ.points {
                lines.append("- (\(occ.timeRange)) \(p)")
            }
            for d in occ.decisions {
                lines.append("- (\(occ.timeRange)) DECISION: \(d)")
            }
        }
        let facts = lines.joined(separator: "\n")
        let prompt = PipelinePrompts.theme(topicName: cluster.name, bulletedFacts: facts, language: language)
        return try await provider.generate(prompt: prompt, options: .forShortWrite)
    }

    // MARK: - Stage 5

    private func consolidateActions(
        extractions: [(chunk: TranscriptChunk, data: ChunkExtraction)],
        language: String
    ) async throws -> String {
        var lines: [String] = []
        for (chunk, data) in extractions {
            for item in data.actionItems {
                lines.append("- (\(chunk.timeRange)) [\(item.who)] \(item.what)")
            }
        }
        if lines.isEmpty {
            return "_No action items identified._"
        }
        let prompt = PipelinePrompts.consolidateActions(bulleted: lines.joined(separator: "\n"), language: language)
        return try await provider.generate(prompt: prompt, options: .forShortWrite)
    }

    // MARK: - Stage 6

    private func writeOverview(themes: [(name: String, body: String)], language: String) async throws -> String {
        let names = themes.map(\.name)
        if names.isEmpty {
            return "_No substantive topics were identified._"
        }
        let prompt = PipelinePrompts.overview(themeNames: names, language: language)
        return try await provider.generate(prompt: prompt, options: .forShortWrite)
    }

    // MARK: - Assembly

    private func assemble(
        overview: String,
        themes: [(name: String, body: String)],
        actions: String
    ) -> String {
        var out = "## Meeting Overview\n\n\(overview.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        out += "## Topics\n\n"
        for theme in themes {
            out += "### \(theme.name)\n\n\(theme.body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        out += "## Action Items\n\n\(actions.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        return out
    }

    // MARK: - Language detection (very simple)

    private func detectLanguage(transcript: String) -> String {
        // Count Cyrillic vs Latin letters in a sample.
        let sample = transcript.prefix(4000)
        var cyrillic = 0
        var latin = 0
        for ch in sample.unicodeScalars {
            if (0x0400...0x04FF).contains(ch.value) { cyrillic += 1 }
            else if (0x0041...0x007A).contains(ch.value) { latin += 1 }
        }
        if cyrillic > latin * 2 { return "Russian/Ukrainian (match the transcript)" }
        if latin > cyrillic * 2 { return "English" }
        return "the same language(s) as the input"
    }
}
