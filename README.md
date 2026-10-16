# MacMeetSubscriber (Meeting Recorder)

macOS app that records meetings (microphone + system audio via ScreenCaptureKit), transcribes them with WhisperKit, and summarizes with a configurable LLM provider (Claude / Gemini / OpenAI / local Ollama).

**Author:** Alex Pavlyuk ([@Alex-Pavlyuk](https://github.com/Alex-Pavlyuk))

## Build

```bash
cd MeetingRecorder
./build_app.sh
open dist/MacMeetSubscriber.app
```

The first build signs the app to establish TCC identity. Subsequent builds only replace the binary (preserving mic / screen capture permissions).

## Settings overview

Open the app → **Settings**.

- **LLM Provider** — pick Claude / Gemini / OpenAI / Ollama
- **API keys** — per-provider, stored in macOS UserDefaults
- **Ollama URL** — default `http://localhost:11434`
- **Ollama model** — auto-discovered from the running Ollama instance
- **Context window (num_ctx)** — see the memory section below
- **Whisper model** — `small` (multilingual, recommended) or `tiny` (fast)
- **Use multi-stage pipeline** — see pipeline section
- **Auto-summarize after recording** — run transcription + summarization automatically after Stop

## Workflow

1. Start Recording → mic and system audio are captured to `mic.wav` / `system.wav`
2. Stop Recording → app transcribes with WhisperKit (multi-pass language detection) and produces `transcript.md`
3. If auto-summarize is on, the summarizer runs and writes `summary.md`
4. Each recording lives under `~/Documents/MeetingRecorder/YYYY-MM-DD_HH-MM-SS/`

You can also re-summarize existing recordings: right-click the row or use **Summarize Last** / **Summarize All Pending**.

## Ollama context window and memory

The KV cache grows linearly with `num_ctx`. Pick the smallest value that still fits your meetings — larger contexts need more RAM and slow down prefill.

### Rules of thumb

**40-minute meeting ≈ 18-22K tokens** of transcript. It will only fit completely when `num_ctx ≥ 32768`.

| Meeting length | Recommended `num_ctx` |
|----------------|-----------------------|
| ≤ 15 min | 8192 |
| 15 – 25 min | 16384 |
| 25 – 55 min | **32768** ← most common |
| 55 min – 1.5 h | 65536 |

### RAM footprint (8-9B models, Q4)

| `num_ctx` | KV cache | Model | Total in RAM |
|-----------|----------|-------|--------------|
| 4096 | ~0.5 GB | ~5 GB | **~5.5 GB** |
| 8192 | ~1 GB | ~5 GB | **~6 GB** |
| 16384 | ~2 GB | ~5 GB | **~7-8 GB** |
| 32768 | ~4 GB | ~5 GB | **~9-10 GB** |
| 65536 | ~8 GB | ~5 GB | **~13-14 GB** |

For 12B models (gemma3) add ~2-3 GB.

### Troubleshooting slow generation

Symptom: tok/s is 10× lower than expected (e.g. 2-3 tok/s on an 8B model that should run at 20-30 tok/s on Apple Silicon).

Almost always the cause is **memory pressure**: several Ollama models loaded at once, causing swap. Check:

```bash
# Show currently loaded models and their size:
curl -s http://localhost:11434/api/ps | python3 -m json.tool

# Show swap activity; if Swapouts is growing, you're thrashing:
vm_stat | grep -E "free|Swapouts"
```

Fix:

```bash
# Unload every model except the one you want:
for m in qwen3:8b qwen2.5:7b llama3.1:8b gemma3:12b deepseek-r1:8b mistral-nemo; do
  curl -s http://localhost:11434/api/generate -d "{\"model\":\"$m\",\"keep_alive\":0}" > /dev/null
done

# Prevent this from happening again — put this in ~/.zshrc or your LaunchAgent:
export OLLAMA_MAX_LOADED_MODELS=1

# If Ollama has been running for days, restart it:
brew services restart ollama

# Keep Ollama up to date — older 0.20.x releases have Metal regressions:
brew upgrade ollama
```

Other causes of slow generation:
- Thermal throttling (common on MacBook Air / base M2 under sustained load — let it cool down)
- Other apps holding wired memory — close Chrome / Docker / Xcode if tight on RAM
- Model running on CPU (unusual). Check `size_vram` in `/api/ps` — should equal model size

## Multi-stage pipeline

`Settings → Summarization → Use multi-stage pipeline` switches from a single LLM call to a 6-stage process:

1. **Chunk** the transcript into 5-minute windows (no LLM)
2. **Extract** structured JSON (topics, points, decisions, action items) per chunk — N LLM calls with JSON format
3. **Cluster** chunks by normalized topic name (no LLM)
4. **Write** a themed section per cluster — K LLM calls
5. **Consolidate** action items across chunks — 1 LLM call
6. **Overview** — 1 LLM call

### When to use it

**Good fit:**
- Cloud providers (Claude / OpenAI / Gemini) — extra calls are cheap, quality jumps noticeably
- Local Ollama **only if** generation speed ≥ 15 tok/s (see troubleshooting above)
- Long meetings (1+ hour) where single-shot can't hold the full transcript in context

**Bad fit:**
- Slow local inference (<10 tok/s) — each chunk takes many minutes, overall time balloons to 40+ min
- Short meetings (<15 min) — single-shot already fits everything

### Expected timings (40-min meeting, 9 chunks)

| Setup | Single-shot | Pipeline |
|-------|-------------|----------|
| Claude Sonnet | ~20 s | ~40-60 s |
| Ollama @ 25 tok/s | ~8 min | ~10-12 min |
| Ollama @ 15 tok/s | ~15 min | ~18-22 min |
| Ollama @ 3 tok/s (thrashing) | ~40 min | **don't** |

Pipeline eliminates most date/fact hallucinations because each chunk sees only a small slice of transcript, so the model can't invent things that weren't said.

## Files written per recording

```
~/Documents/MeetingRecorder/2026-04-16_15-33-19/
  mic.wav               # microphone capture
  system.wav            # system audio capture
  transcript.md         # speaker-labeled, timestamped transcript
  summary.md            # LLM summary
  metadata.json         # duration, segment count, languages, provider, status
```

`metadata.json.status` is one of `pending_summary` (transcribed but not summarized) or `complete`.

## License

Copyright © 2026 Alex Pavlyuk.

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).
