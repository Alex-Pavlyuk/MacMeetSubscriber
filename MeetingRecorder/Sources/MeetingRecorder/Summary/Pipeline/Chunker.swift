import Foundation

/// A chunk of transcript covering a contiguous time window.
struct TranscriptChunk {
    let index: Int           // 0-based
    let startSeconds: Int    // seconds from meeting start
    let endSeconds: Int
    let text: String         // raw lines in this chunk

    var timeRange: String {
        "\(Chunker.formatTime(startSeconds))-\(Chunker.formatTime(endSeconds))"
    }
}

/// Splits a plain-text transcript (with [HH:MM] or [HH:MM:SS] prefixes per line)
/// into fixed-duration windows. No LLM involved.
enum Chunker {
    /// Split by time windows. Default 5-minute windows.
    /// A line is placed in the window that contains its timestamp. No overlap —
    /// overlap complicates downstream deduplication without much benefit for this use case.
    static func chunk(transcript: String, windowMinutes: Int = 5) -> [TranscriptChunk] {
        let windowSeconds = windowMinutes * 60
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Parse each line's timestamp (seconds). Lines without timestamps inherit previous.
        var parsedLines: [(seconds: Int, text: String)] = []
        var lastSeconds = 0
        for line in lines {
            if let s = parseLeadingTimestamp(line) {
                lastSeconds = s
            }
            parsedLines.append((lastSeconds, line))
        }
        guard let maxSeconds = parsedLines.last?.seconds, maxSeconds > 0 else {
            // Single chunk fallback.
            return [TranscriptChunk(index: 0, startSeconds: 0, endSeconds: 0, text: transcript)]
        }

        var chunks: [TranscriptChunk] = []
        var windowStart = 0
        var idx = 0
        while windowStart <= maxSeconds {
            let windowEnd = windowStart + windowSeconds
            let inWindow = parsedLines.filter { $0.seconds >= windowStart && $0.seconds < windowEnd }
            if !inWindow.isEmpty {
                let text = inWindow.map(\.text).joined(separator: "\n")
                let actualEnd = min(windowEnd, maxSeconds)
                chunks.append(TranscriptChunk(
                    index: idx,
                    startSeconds: windowStart,
                    endSeconds: actualEnd,
                    text: text
                ))
                idx += 1
            }
            windowStart = windowEnd
        }
        return chunks
    }

    /// Parse `[HH:MM]`, `[HH:MM:SS]`, `[MM:SS]` at the start of the line → total seconds.
    static func parseLeadingTimestamp(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        guard let endBracket = trimmed.firstIndex(of: "]") else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<endBracket])
        let parts = inner.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]          // MM:SS or HH:MM (ambiguous — treat as HH:MM if first > 59)
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    static func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
