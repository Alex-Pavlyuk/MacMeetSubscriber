import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testIsLoading = false

    // Local copies — only written to config on Save
    @State private var provider: String = ""
    @State private var claudeAPIKey: String = ""
    @State private var claudeModel: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var geminiModel: String = ""
    @State private var openaiAPIKey: String = ""
    @State private var openaiModel: String = ""
    @State private var ollamaURL: String = ""
    @State private var ollamaModel: String = ""
    @State private var ollamaNumCtx: Int = 16384
    @State private var whisperModel: String = ""
    @State private var singlePassTranscription: Bool = false
    @State private var autoSummarize: Bool = true
    @State private var recordingsDir: String = ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaModelsLoading = false

    @State private var claudeExpanded: Bool = false
    @State private var geminiExpanded: Bool = false
    @State private var openaiExpanded: Bool = false
    @State private var ollamaExpanded: Bool = false

    var body: some View {
        Form {
            Section("Audio") {
                Text("Microphone: Default system input")
                    .foregroundStyle(.secondary)
                Text("System audio: ScreenCaptureKit (automatic)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("LLM Provider") {
                Picker("Provider", selection: $provider) {
                    Text("Claude").tag("claude")
                    Text("Gemini").tag("gemini")
                    Text("OpenAI").tag("openai")
                    Text("Ollama (Local)").tag("ollama")
                }
            }

            Section("External Connectors") {
                DisclosureGroup("Claude", isExpanded: $claudeExpanded) {
                    SecureField("API Key", text: $claudeAPIKey)
                    TextField("Model", text: $claudeModel)
                    testButton(for: "claude")
                }

                DisclosureGroup("Gemini", isExpanded: $geminiExpanded) {
                    SecureField("API Key", text: $geminiAPIKey)
                    TextField("Model", text: $geminiModel)
                    testButton(for: "gemini")
                }

                DisclosureGroup("OpenAI", isExpanded: $openaiExpanded) {
                    SecureField("API Key", text: $openaiAPIKey)
                    TextField("Model", text: $openaiModel)
                    testButton(for: "openai")
                }

                DisclosureGroup("Ollama (Local)", isExpanded: $ollamaExpanded) {
                    TextField("URL", text: $ollamaURL)
                        .onChange(of: ollamaURL) { fetchOllamaModels() }

                    if ollamaModelsLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading models...")
                                .foregroundStyle(.secondary)
                        }
                    } else if ollamaModels.isEmpty {
                        HStack {
                            TextField("Model", text: $ollamaModel)
                            Button("Refresh") { fetchOllamaModels() }
                        }
                        Text("Could not fetch models. Check that Ollama is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        HStack {
                            Text("\(ollamaModels.count) model(s) available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { fetchOllamaModels() }
                                .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• qwen2.5:7b — quick but not-accurate")
                            Text("• carstenuhlig/omnicoder-9b — the optimal quality/speed")
                            Text("• gemma3:12b — if previous two lose context (as alternative)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Picker("Context window (num_ctx)", selection: $ollamaNumCtx) {
                        Text("Auto (by meeting length)").tag(0)
                        Text("4096 (fastest)").tag(4096)
                        Text("8192").tag(8192)
                        Text("16384").tag(16384)
                        Text("32768 (slow, more VRAM)").tag(32768)
                        Text("65536 (very slow)").tag(65536)
                    }
                    Text("Auto picks 4096–32768 based on transcript size. Larger values let the model see longer transcripts but increase prefill time and VRAM usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    testButton(for: "ollama")
                }
            }

            Section("Whisper (Transcription)") {
                Picker("Model", selection: $whisperModel) {
                    Text("tiny (fastest, lower quality)").tag("tiny")
                    Text("small (best for multilingual)").tag("small")
                }
                Text("'Single language' toggle is on the main screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle("Auto-summarize after recording", isOn: $autoSummarize)
                HStack {
                    TextField("Recordings directory", text: $recordingsDir)
                    Button("Default") { recordingsDir = "" }
                }
                Text("Default: ~/Documents/MeetingRecorder/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 650)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(); dismiss() }
            }
        }
        .navigationTitle("MacMeetSubscriber — Settings")
        .onAppear { loadFromConfig(); fetchOllamaModels() }
    }

    // MARK: - Ollama Models

    private func fetchOllamaModels() {
        let url = ollamaURL.isEmpty ? "http://localhost:11434" : ollamaURL
        ollamaModelsLoading = true
        Task {
            let models = await OllamaProvider.fetchModels(baseURL: url)
            await MainActor.run {
                ollamaModels = models
                ollamaModelsLoading = false
                // If current selection is not in the list, keep it (manual entry)
                // If list is non-empty and current model is empty, select first
                if !models.isEmpty && ollamaModel.isEmpty {
                    ollamaModel = models.first ?? ""
                }
            }
        }
    }

    // MARK: - Load / Save

    private func loadFromConfig() {
        provider = config.provider
        claudeAPIKey = config.claudeAPIKey
        claudeModel = config.claudeModel
        geminiAPIKey = config.geminiAPIKey
        geminiModel = config.geminiModel
        openaiAPIKey = config.openaiAPIKey
        openaiModel = config.openaiModel
        ollamaURL = config.ollamaURL
        ollamaModel = config.ollamaModel
        ollamaNumCtx = config.ollamaNumCtx
        whisperModel = config.whisperModel
        singlePassTranscription = config.singlePassTranscription
        autoSummarize = config.autoSummarize
        recordingsDir = config.recordingsDir

        switch provider {
        case "gemini": geminiExpanded = true
        case "openai": openaiExpanded = true
        case "ollama": ollamaExpanded = true
        default: claudeExpanded = true
        }
    }

    private func save() {
        config.provider = provider
        config.claudeAPIKey = claudeAPIKey
        config.claudeModel = claudeModel
        config.geminiAPIKey = geminiAPIKey
        config.geminiModel = geminiModel
        config.openaiAPIKey = openaiAPIKey
        config.openaiModel = openaiModel
        config.ollamaURL = ollamaURL
        config.ollamaModel = ollamaModel
        config.ollamaNumCtx = ollamaNumCtx
        config.whisperModel = whisperModel
        config.singlePassTranscription = singlePassTranscription
        config.autoSummarize = autoSummarize
        config.recordingsDir = recordingsDir
    }

    // MARK: - Test Connection

    @ViewBuilder
    private func testButton(for providerName: String) -> some View {
        HStack {
            Button {
                testConnection(provider: providerName)
            } label: {
                HStack(spacing: 4) {
                    if testIsLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(testIsLoading)

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("OK") ? .green : .red)
                    .lineLimit(2)
            }
        }
    }

    private func testConnection(provider providerName: String) {
        testResult = nil
        testIsLoading = true

        // Build a temporary config from current (unsaved) values
        let tempConfig = AppConfig()
        save() // write current values so test uses them

        Task {
            let result = await runTest(config: tempConfig, provider: providerName)
            await MainActor.run {
                testResult = result
                testIsLoading = false
            }
        }
    }

    private func runTest(config: AppConfig, provider: String) async -> String {
        let summarizer = Summarizer(config: config)
        do {
            let p = try summarizer.getProvider(override: provider)
            let reply = try await p.summarize(transcript: "Test. Reply with only: OK")
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return "OK — \(p.displayName) responded (\(trimmed.prefix(40)))"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
