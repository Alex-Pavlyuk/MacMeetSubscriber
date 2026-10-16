import SwiftUI

/// Right sidebar showing a catalog of all recordings with actions.
struct RecordingsSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var sessions: [RecordingSession] = []
    @State private var deleteTarget: RecordingSession?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recordings")
                    .font(.headline)
                Spacer()
                Button { refreshSessions() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(10)

            Divider()

            if sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No recordings yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(sessions) { session in
                        RecordingRow(session: session, onDelete: {
                            deleteTarget = session
                            showDeleteConfirm = true
                        }, onRetranscribe: {
                            appState.retranscribe(session.url)
                            // Refresh after a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshSessions() }
                        }, onResummarize: {
                            appState.resummarize(session.url)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshSessions() }
                        }, onOpen: {
                            NSWorkspace.shared.open(session.url)
                        })
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refreshSessions() }
        .alert("Delete Recording?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    appState.deleteRecording(target.url)
                    deleteTarget = nil
                    refreshSessions()
                }
            }
        } message: {
            if let target = deleteTarget {
                Text("Delete \(target.name)? This cannot be undone.")
            }
        }
        // Auto-refresh when processing finishes
        .onChange(of: appState.isProcessing) {
            if !appState.isProcessing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshSessions() }
            }
        }
        .onChange(of: appState.isRecording) {
            if !appState.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshSessions() }
            }
        }
    }

    private func refreshSessions() {
        sessions = appState.sessionsSorted().map { url in
            let meta = readMeta(url)
            return RecordingSession(
                url: url,
                name: url.lastPathComponent,
                status: meta?["status"] as? String ?? "unknown",
                segments: meta?["segments_count"] as? Int ?? 0,
                duration: meta?["duration_seconds"] as? Double ?? 0,
                languages: meta?["languages"] as? [String] ?? [],
                hasTranscript: FileManager.default.fileExists(atPath: url.appendingPathComponent("transcript.md").path),
                hasSummary: FileManager.default.fileExists(atPath: url.appendingPathComponent("summary.md").path)
            )
        }
    }

    private func readMeta(_ url: URL) -> [String: Any]? {
        let metaURL = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return meta
    }
}

// MARK: - Data Model

struct RecordingSession: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let status: String
    let segments: Int
    let duration: Double
    let languages: [String]
    let hasTranscript: Bool
    let hasSummary: Bool

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return "\(m)m \(s)s"
    }

    var statusIcon: String {
        switch status {
        case "complete": return "checkmark.circle.fill"
        case "pending_summary": return "clock.fill"
        default: return "questionmark.circle"
        }
    }

    var statusColor: Color {
        switch status {
        case "complete": return .green
        case "pending_summary": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Row View

struct RecordingRow: View {
    let session: RecordingSession
    let onDelete: () -> Void
    let onRetranscribe: () -> Void
    let onResummarize: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Image(systemName: session.statusIcon)
                    .foregroundStyle(session.statusColor)
                    .font(.caption)
                Text(session.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            // Info
            HStack(spacing: 8) {
                Text(session.durationString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if session.segments > 0 {
                    Text("\(session.segments) seg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !session.languages.isEmpty {
                    Text(session.languages.joined(separator: ","))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Actions
            HStack(spacing: 4) {
                Button("Open") { onOpen() }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)

                Button(session.hasTranscript ? "Re-transcribe" : "Transcribe") { onRetranscribe() }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)

                Button(session.hasSummary ? "Re-summarize" : "Summarize") { onResummarize() }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)

                Spacer()

                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
