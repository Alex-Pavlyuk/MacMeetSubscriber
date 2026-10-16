import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteLastConfirm = false
    @State private var showSidebar = true

    var body: some View {
        HSplitView {
            // Left: main panel (log + controls)
            mainPanel
                .frame(minWidth: 450)

            // Right: recordings catalog
            if showSidebar {
                RecordingsSidebar()
                    .environmentObject(appState)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 350)
            }
        }
        .navigationTitle("MacMeetSubscriber")
        .frame(minWidth: showSidebar ? 750 : 500, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Recordings Panel")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(config: appState.config)
            }
            .frame(minWidth: 520, idealWidth: 520, minHeight: 700, idealHeight: 750)
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                HelpView()
            }
            .frame(minWidth: 550, minHeight: 600)
        }
        .alert("Delete Last Recording?", isPresented: $showDeleteLastConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { appState.deleteLastRecording() }
        } message: {
            if let last = appState.sessionsSorted().first {
                Text("Delete \(last.lastPathComponent)? This cannot be undone.")
            }
        }
        .alert("Delete All Recordings?", isPresented: $showDeleteAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { appState.deleteAllRecordings() }
        } message: {
            Text("This will permanently delete all recording files. This cannot be undone.")
        }
    }

    // MARK: - Main Panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button(action: { appState.isRecording ? appState.stopRecording() : appState.startRecording() }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isRecording ? .red : .gray)
                            .frame(width: 10, height: 10)
                        Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(appState.isRecording ? .red : .accentColor)

                Button("Settings...") { showSettings = true }
                    .controlSize(.large)

                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .controlSize(.large)
                .help("Help & Setup Instructions")

                Toggle("Single language", isOn: englishOnlyBinding)
                    .toggleStyle(.checkbox)
                    .help("Skip ru/uk detection — one transcription cycle instead of three")

                Spacer()

                if appState.isRecording {
                    Text(formatDuration(appState.recordingDuration))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.red)
                        .fontWeight(.bold)
                }

                if !appState.activeJobs.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                    Text("\(appState.activeJobs.count) job(s)")
                        .foregroundStyle(.secondary)
                    Button("Cancel All") { appState.cancelAllJobs() }
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            // Summarization progress bar
            if let status = appState.summaryStatus {
                progressBanner(label: status, progress: nil, color: .blue)
                Divider()
            }

            // Log area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.logEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestampString)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .frame(width: 60, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(entry.color)
                                    .textSelection(.enabled)

                                if let path = entry.filePath {
                                    Button("Open") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)))
                .onChange(of: appState.logEntries.count) {
                    if let last = appState.logEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Button("Delete Last") { showDeleteLastConfirm = true }
                    .disabled(appState.isRecording)

                Button("Delete All") { showDeleteAllConfirm = true }
                    .foregroundStyle(.red)
                    .disabled(appState.isRecording)

                Spacer()

                Button("Clear Log") { appState.logEntries.removeAll() }

                Button("Open Recordings") { appState.openRecordings() }
            }
            .padding()
        }
    }

    private var englishOnlyBinding: Binding<Bool> {
        Binding(
            get: { appState.config.singlePassTranscription },
            set: { appState.config.singlePassTranscription = $0 }
        )
    }

    @ViewBuilder
    private func progressBanner(label: String, progress: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(color)
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        let h = m / 60
        if h > 0 {
            return String(format: "REC %02d:%02d:%02d", h, m % 60, s)
        }
        return String(format: "REC %02d:%02d", m, s)
    }
}
