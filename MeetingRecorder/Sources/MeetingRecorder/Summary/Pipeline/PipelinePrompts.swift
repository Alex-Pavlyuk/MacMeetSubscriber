import Foundation

// MARK: - JSON models returned by ChunkExtractor

struct ChunkTopic: Codable {
    let name: String            // e.g. "Market scope 37", "Florence", "QA automation"
    let points: [String]        // factual bullets
    let decisions: [String]     // decisions/agreements
}

struct ChunkActionItem: Codable {
    let who: String             // owner name or "unassigned"
    let what: String            // task description
}

struct ChunkExtraction: Codable {
    let topics: [ChunkTopic]
    let actionItems: [ChunkActionItem]
}

// MARK: - Prompts

enum PipelinePrompts {

    /// Stage 2: extract structured info from a single chunk.
    static func extract(timeRange: String, chunkText: String) -> String {
        """
        You analyze a short segment of a meeting transcript.
        Speakers are labeled "Me" (the user) and "Others" (remote participants).
        The segment may contain Russian, Ukrainian, or English.

        RULES:
        - Extract ONLY facts that are explicitly present in the segment below.
        - DO NOT invent dates, numbers, names, or project identifiers.
        - If nothing material is discussed, return {"topics": [], "actionItems": []}.
        - Topic names should be short canonical identifiers (e.g. "Market scope 37", "Florence", "QA automation").
          Use the same name across mentions so the same project clusters correctly.
        - "who" for action items is the owner's name if stated; otherwise "unassigned".

        OUTPUT: a single JSON object, no prose, no code fences. Schema:
        {
          "topics": [
            {
              "name": "<short topic name>",
              "points": ["<fact 1>", "<fact 2>"],
              "decisions": ["<decision 1>"]
            }
          ],
          "actionItems": [
            {"who": "<name or 'unassigned'>", "what": "<task>"}
          ]
        }

        Segment time range: \(timeRange)

        Segment:
        \(chunkText)
        """
    }

    /// Stage 4: write a themed section for one topic cluster.
    static func theme(topicName: String, bulletedFacts: String, language: String) -> String {
        """
        You are writing one section of a meeting summary in \(language).
        The section is about the topic: "\(topicName)".

        Below are the raw facts and decisions extracted from different parts of the meeting,
        each tagged with its time range. Write a coherent summary of this topic:

        - 2–6 sentences or bullets.
        - Merge related facts. Preserve specific names, dates, numbers.
        - Include time ranges in parentheses when referring to specific moments.
        - Do NOT invent facts that are not in the input.
        - Do NOT add action items — those are handled separately.

        Output: just the section body (no heading). Use markdown.

        Facts:
        \(bulletedFacts)
        """
    }

    /// Stage 5: consolidate action items across chunks.
    static func consolidateActions(bulleted: String, language: String) -> String {
        """
        Below is a raw list of action items extracted from a meeting.
        Deduplicate and consolidate them, grouped by owner, in \(language).

        - Merge items that describe the same task.
        - Keep owner names verbatim when identifiable.
        - Put unassigned items under "Unassigned".
        - Format as markdown: one sub-heading per owner (### Name), then bullets.

        Items:
        \(bulleted)
        """
    }

    /// Stage 6: generate a 2-3 sentence overview.
    static func overview(themeNames: [String], language: String) -> String {
        let list = themeNames.map { "- \($0)" }.joined(separator: "\n")
        return """
        Write a 2-3 sentence high-level overview of a meeting in \(language).
        The meeting covered these themes:
        \(list)

        Do NOT expand details. Do NOT add a heading. Just the overview paragraph.
        """
    }
}
