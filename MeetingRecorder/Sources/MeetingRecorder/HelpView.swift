import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                Text("MacMeetSubscriber")
                    .font(.largeTitle.bold())

                Text("Records meetings, transcribes speech (RU/UK/EN), and generates AI summaries.")
                    .foregroundStyle(.secondary)

                Divider()

                // --- Whisper ---
                sectionHeader("1. Install Whisper Model (Transcription)")

                Text("WhisperKit downloads the model automatically on first use. Choose the model in Settings:")

                bulletList([
                    "tiny — superfast but not accurate",
                    "small — good enough for most cases",
                ])

                Text("The model downloads once and is cached locally. First transcription may take a minute.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Divider()

                // --- Ollama ---
                sectionHeader("2. Install Ollama + Local Model (Local Summarization)")

                Text("For local AI summaries without sending data to the cloud:")

                codeBlock("""
                # Install Ollama
                brew install ollama

                # Start Ollama service
                brew services start ollama

                # Download models
                ollama pull qwen2.5:7b
                ollama pull carstenuhlig/omnicoder-9b
                ollama pull gemma3:12b
                """)

                Text("Then in Settings set:")
                bulletList([
                    "Provider: ollama",
                    "URL: http://localhost:11434",
                    "Model — pick one of:",
                    "    qwen2.5:7b — quick but not accurate",
                    "    carstenuhlig/omnicoder-9b — the optimal quality/speed",
                    "    gemma3:12b — if previous two lose context (as alternative)",
                ])

                Divider()

                // --- Cloud providers ---
                sectionHeader("3. Cloud AI Providers (Alternative)")

                Text("Instead of local Ollama, you can use cloud APIs:")

                bulletList([
                    "Claude — get key at console.anthropic.com",
                    "Gemini — get key at aistudio.google.com",
                    "OpenAI — get key at platform.openai.com",
                ])

                Text("Enter your API key in Settings and select the provider.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Divider()

                // --- Screen Recording ---
                sectionHeader("4. Screen Recording Permission")

                Text("To capture system audio (other participants), macOS requires Screen Recording permission:")

                bulletList([
                    "On first recording, macOS will show a permission dialog",
                    "Click 'Open System Settings'",
                    "Enable the toggle for MacMeetSubscriber.app",
                    "Restart the app",
                ])

                Divider()

                // --- Usage ---
                sectionHeader("5. Usage")

                bulletList([
                    "Click 'Start Recording' to begin",
                    "Speak into your microphone — recorded as 'Me'",
                    "System audio (meeting apps) — recorded as 'Others'",
                    "Click 'Stop Recording' — transcription + summary start automatically",
                    "Use 'Summarize Last' for deferred summarization",
                    "Click 'Open Recordings' to view saved files",
                ])

                Text("Check 'Single language' before the transcribing process to turn on the one-language quick mode. If disabled, Whisper runs three cycles for Ukrainian, English, and Russian. For a single-language meeting one cycle is enough.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Divider()

                // --- Files ---
                sectionHeader("6. Output Files")

                Text("Each recording creates a folder with:")

                bulletList([
                    "mic.wav — your microphone audio",
                    "system.wav — system/meeting audio",
                    "transcript.md — timestamped transcript with speakers",
                    "summary.md — AI-generated meeting summary",
                    "metadata.json — recording metadata",
                ])
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
            }
        }
        .navigationTitle("Help")
    }

    // MARK: - Components

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .font(.body)
                    Text(item)
                        .font(.body)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func codeBlock(_ code: String) -> some View {
        Text(code)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .textSelection(.enabled)
    }
}
