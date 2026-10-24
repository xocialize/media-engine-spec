# Audio readiness: MES and the fleet's audio models

| | |
|---|---|
| **Date** | 2026-10-24 |
| **Spec** | Base 0.1, Image 0.1 (media-engine-spec v0.4.0) |
| **Models** | The audio rows of the MLXEngine registry (`MLXEngine/mlx-engine-swift/docs/model-registry.md` § Audio), `mlxengine-audio/PROD`, `mlx-vibevoice-asr-swift` |
| **Engine contract** | MLXToolKit 1.50 (`TTS.swift`, `Streaming.swift`, `LiveSTT.swift`, `SpeechEdit.swift`, `ToolDescriptor.swift`) |
| **Status** | Evaluation. Nothing here changes the spec yet; §8 lists the decisions it needs. RFCs [0001](../rfcs/0001-assets.md), [0002](../rfcs/0002-streamed-output.md) and [0003](../rfcs/0003-offer-supports-and-voices.md) draft A-2, A-1 and A-4. |

## Summary

- **Most of our audio models fit MES as it stands, as batch jobs.** Base already has the `audio` input and output
  kind, `duration_s` on outputs and `max_duration_s` in limits. What's missing is an **Audio profile**: operations,
  vocabulary and conventions (§4). Cloning, two-speaker scenes, speech editing, sound effects, separation, polish,
  file transcription and emotion all map to job-shaped operations.
- **Four Base gaps stop a conformant audio engine** (§3):
  1. **Retention forbids voice reuse.** Base §13 rule 4 says an engine keeps nothing derived from inputs past the
     job, and uploads are single-use. Our TTS packages cache the encoded reference voice across runs (E1), which is
     what makes a 500-line dub or a 6-segment take affordable. An audio engine built on them doesn't conform today.
  2. **No streamed output.** OQ-6 (D-32) settled on "previews only in v1". TTS needs ordered audio chunks, so first
     audio arrives in well under a second (MOSS-TTS-Nano 62 ms, MOSS-TTS-Local 149 ms, Gepard ~790 ms) rather than
     after the whole take.
  3. **Offers can't say what each model supports.** Languages, voice catalogues, cloning, emotion modes, speaker
     count, native duration control and sample rate differ per model, and the descriptor has nowhere per-offer to
     say so. Base §6 rule 4 ("no surprises") can't be met.
  4. **Audio facts are missing from results**: no `sample_rate` or `channels` on outputs, and no progress axis for
     a job whose length isn't known in advance.
- **Live, two-way audio should stay direct for now** (§1, §5). Live transcription, voice chat and barge-in feed audio
  that doesn't exist yet into a session that holds a model resident. That is a different protocol from a job, and
  MLXEngine already does it in-process (`LiveTranscribing`, `StreamEmitting`, VoiceChatKit). MES shouldn't take on
  sessions in Audio 0.1.
- **Model split** (§5):
  - **Embedded first:** MOSS-TTS-Nano, Kokoro, Gepard, Nemotron, R2T2, and the full-duplex VoiceChat model.
  - **Engine first:** VoxCPM2, IndexTTS-2.5, Qwen3-TTS, Dia2, MOSS-TTS-Local, Audio8, Step-Audio-EditX, AuK,
    MOSS-SoundEffect, VibeVoice-ASR and Whisper.
  - **Either:** separation, emotion and polish are small and batch-shaped.
  - Most embedded-first models also earn an engine offer: a draft tier, or file transcription.
- **Served as they are today, every TTS package breaks at least one MES rule** (§5.4). All of them keep the voice
  cache. On top of that: Kokoro silently falls back to its default voice, Gepard and Kokoro ignore seeds,
  Qwen3-TTS, Gepard and IndexTTS-2.5 clamp them, and MOSS-TTS-Nano trims the reference. Separately, three licences allow commercial use only
  below a revenue or user threshold, which `commercial_use: true | false | unknown` can't express.

## 1. Two ways an app uses an audio model

| | **Engine** (MES over HTTP, MCP or in-process) | **Embedded** (MLXEngine in the app's process) |
|---|---|---|
| **Shape** | A request in, a finished file out | Audio streams out while it's made; live audio streams in |
| **Latency that matters** | Seconds: the whole take | First audio under a second; a transcript word 80 ms–1.1 s behind speech |
| **State** | None between jobs (Base §13) | Resident model, cached voice, an open mic session, conversation history |
| **Callers** | Any client on the LAN, agents over MCP, Pixel Agency apps | One app: VoiceChatKit, ML[X] Audio Studio, the Gepard Demo |
| **Good for** | Narration, dubbing, cloning, scenes, edits, effects, separation, file transcription | Voice chat, dictation, live captions, read-aloud as you type |

Everything an app needs for the embedded shape exists in MLXEngine:
- **Streamed TTS:** `StreamEmitting.runStream` → `MLXServeEngine.stream()` → `TTSStreamHandle` (chunks, the
  aggregated `.wav`, cancel). Five packages conform: Gepard, Audio8, Audio8-Mini, MOSS-TTS-Nano and
  MOSS-TTS-Local. Gepard's gate measured 102 ms to first audio, at 51 dB SNR against batch (E2). Since v0.4.0 it
  holds the first chunk until it can rule out a silent decode, about 790 ms.
- **Text arriving while speaking:** `IncrementalTTS` in tts-orchestrator-kit releases a segment at each sentence
  boundary. 483 ms to first audio from a simulated 25 words/s LLM feed (E13).
- **Live transcription:** `LiveTranscribing` / `STTSession` (`LiveSTT.swift`). It has:
  - a copy-only `push`, safe on the mic's real-time thread, that reports overruns;
  - a declared `cumulative` or `incremental` discipline;
  - a `committedThrough` watermark;
  - admission sized to a planned duration.
- **The whole loop:** VoiceChatKit pipelines mic → live STT → LFM2.5 → Gepard streaming → gapless playback,
  half-duplex by design.

MES reaches the embedded shape in one way today: `MESInProcess` (DLV-3) puts an engine behind the client API with no
sockets. That keeps descriptors, validation and provenance the same, but it still writes each output to the spool
and hands it over after the job finishes. So it carries the batch half of an embedded app (render this narration),
and nothing live.

## 2. What the spec already handles

| Need | Where |
|---|---|
| Audio inputs and outputs | Kind `audio` (Base §18); `media_types` on inputs and outputs |
| Length limits | `limits.max_duration_s` (descriptor) |
| Output length | `duration_s` on outputs (§10.1) |
| Several named outputs | Output count ranges, e.g. one output per stem |
| Text in, structured data out | Kinds `text` and `data`; a `data` output over 64 KiB is fetched by `href` (the kit already drops `value` past 65 536 bytes) |
| Model choice by tier | `quality_tiers` and §6 rule 2: draft → Kokoro or MOSS-TTS-Nano, best → VoxCPM2 or IndexTTS-2.5 |
| Research and opt-in models | `named_only` and `license.accepted_required` (AuK's `LicenseRef-Qwen-Research`) |
| Usage guidance per model | `notes` (§6 rule 5): "write turns as [S1]/[S2]", "give the reference transcript" |
| Seeds | `seed`, and `effective.seed` (Qwen3-TTS VoiceDesign + seed is the E9 Voice Library) |
| Helper models | `provenance.helpers` with a role, e.g. AuK's prompt enhancer turning a free-form request into a canonical instruction |
| Cancelling | `DELETE` or WebSocket `cancel` |

## 3. Gaps in Base

### 3.1 Retention and voice reuse (blocking)

**Problem.** A cloned voice is used for many requests. Base allows neither half of that:
- **Uploads are single-use** (§8). A 500-line dub with a two-voice scene re-uploads the same two clips 500 times.
- **Nothing derived may outlive the job** (§13 rule 4, "anything derived from them"). Every cloning TTS package
  memoizes the encoded reference until unload, keyed by the clip's bytes: the speaker embedding, VAE features or
  speaker prefix (E1 for Qwen3-TTS, VoxCPM2 and Gepard; IndexTTS-2.5, Audio8, MOSS-TTS and Dia2 do the same). Gepard's first audio is ~1000 ms cold and 143 ms warm. Behind MES, that cache breaks
  rule 4 as soon as a second job runs. Clearing it per job throws away the measured win, and the adapter (DLV-9)
  can't clear it anyway without unloading the package.

**Proposal: client-owned assets.** A new Base feature, `assets`:
- `POST {path}/assets` takes the bytes, like an upload, and answers `{asset_id, media_type, bytes, sha256,
  expires_at}`. The client sets `ttl_s`, capped by `limits.max_asset_ttl_s` (say ≤ 7 days).
- `{"asset": "<id>"}` is an InputValue any number of jobs may use. `DELETE {path}/assets/{id}` removes it, and
  `GET {path}/assets` lists the caller's own.
- **Retention:** §13 gains one rule. An asset, and anything the engine derives from it (a cached speaker
  embedding), is kept until the asset is deleted or expires, and deleted within 60 s of that. The client chose to
  keep it, so custody stays honest and the cache becomes legal. Rules 1–5 still cover everything else.
- **Not audio-only.** The same thing serves Image: an IC-LoRA's reference images, or a product shot reused across a
  campaign.

**Alternatives.** Clarifying that an in-memory cache "isn't a copy" weakens the guarantee clients pay for (R5,
custody). Multi-use uploads with a short TTL fix only the re-upload half.

### 3.2 Streamed output (blocking for interactive TTS; reopens OQ-6)

**Problem.** An output exists only once the job reaches `holding`. A 30 s narration starts playing after about 30 s
of synthesis at RTF ≈ 1. `job.preview` doesn't help: previews replace each other, while audio chunks add up in order.

**Proposal.** A `streaming` feature, with the semantics MLXEngine's `StreamEmitting` already uses:
- A descriptor output may declare `stream: {media_type}`, e.g. `audio/L16;rate=24000;channels=1` (RFC 2586 PCM, so
  no fake per-chunk WAV headers).
- A request opts in with `stream: ["audio"]`. The engine then sends `job.output_chunk` events:
  `{output, index, offset_s, final, data}`, where `data` is base64 of at most 256 KiB, as for previews. Over
  WebSocket an engine MAY send the same chunks as binary frames.
- **Parity:** the final output, which still lands in `holding`, is exactly the chunks concatenated. An engine
  builds it from what it sent. A client that ignores chunks loses nothing, and retention is unchanged.
- **Cancel is barge-in:** release stops synthesis; no more chunks arrive.
- **MCP:** no change. An MCP tool returns once, so agents get the finished file.

**Scope.** Output streaming only. Streaming input (text arriving while speaking, mic audio) is a session (§3.6).

### 3.3 Per-offer capabilities (blocking, and Image needs it too)

**Problem.** One `audio.speak` descriptor gathers models that differ in what they accept:

| Fact | Varies by model |
|---|---|
| Languages | English-only to multilingual |
| Voices | A preset catalogue (Kokoro's 10, Qwen3-TTS CustomVoice's 9); cloning only (IndexTTS-2.5, Gepard); a voice from a description (Qwen3-TTS VoiceDesign, AuK) |
| Cloning input | A clip alone (Gepard, MOSS-TTS), or a clip plus its transcript (Qwen3-TTS ICL, VoxCPM2 continuation, Audio8) |
| Emotion | None, categorical, from a clip, from a description (`TTSControls.emotionModes`) |
| Speakers per take | 1, or 2 with turn tags (Dia2: `speakerTags`) |
| Native duration control | Yes or no (`supportsTargetDuration`) |
| Output sample rate | 22.05 kHz (Gepard, IndexTTS-2.5), 24 kHz (Kokoro, Qwen3-TTS, Dia2), 44.1 kHz (Audio8), 48 kHz (VoxCPM2, MOSS-TTS) |
| Streaming | Per model (`StreamGranularity.audioChunk`) |
| Max text, max reference length | Per model |

`limits` are per operation, `params` must not be model-specific (§6 rule 1), and rule 4 says what a model can't
honour belongs in the descriptor. There's nowhere per offer to put any of this.

**Proposal.**
- Model offers gain a profile-defined `supports` object. The Audio profile defines its keys, and Image can define
  its own: `negative_prompt` and max size per model have the same problem.
- §6.3 rule 2 generalizes. A request that uses a supported-only feature (emotion, a second speaker, a voice id)
  implies an offer that supports it. With no model named, the engine chooses among those. A named model that doesn't
  support it is 422 `unsupported_parameter`. This is MLXEngine's declared-control rule (`checkDeclaredControls`),
  where an undeclared emotion is refused before admission, carried over the wire.
- **Voice catalogues** follow the adapter pattern: `voices: [{id, title, languages, gender?, notes?, sample?, license?}]`
  on an offer. The engine side doesn't have this yet. The speaker half of E6 is still open (`TTSControls` has no
  voice list), so the MLXEngine adapter has nothing to read today (§6).

### 3.4 Audio facts in results and progress

- **Outputs** gain `sample_rate`, `channels` and `bit_depth`, next to `width`, `height`, `duration_s` and `fps`
  (§10.1, `job.schema.json`).
- **Progress** gains `media_s`: seconds of audio produced or consumed. An autoregressive TTS doesn't know its length
  until the stop token, so `fraction` is absent. `LiveSTT.swift` calls `processedSeconds` "the only honest progress
  axis".
- **Decoded limits** (§17): engines enforce `max_duration_s` and sample counts on decoded audio. A small FLAC can
  decode to hours.

### 3.5 MCP binding

- **Results:** an `audio` content block for audio outputs of at most 1 MB, as for image previews. swift-sdk 0.12.1
  has `.audio(data:mimeType:)`; `MCPBinding.swift:423` passes only PNG and JPEG today.
- **Inputs:** the input hint text says `data:image/png;base64,…` for every kind (`MCPBinding.swift:201`).
- **Long audio from agents:** ten minutes of 16 kHz mono WAV is ~19 MB, ~25 MB as a data URL in a tool call. A helper
  tool, `mes_create_upload`, could return a one-time URL the agent PUTs a file to, then names as `upload:<id>`. Without
  it, transcription over MCP is practical only for short clips.

### 3.6 Sessions (deferred, and recorded here so the decision is visible)

Live transcription and full voice chat need:
- audio pushed from a real-time thread with explicit back-pressure (`PushOutcome.overrun`);
- an assembly discipline (`cumulative` or `incremental`) and a `committedThrough` watermark;
- a model held resident for the session, admitted against a planned duration;
- for voice chat, echo cancellation and barge-in.

Over a network that's a WebSocket or WebRTC protocol with jitter buffers, the class of OpenAI's Realtime API. It has
no outputs to hold, so §13 would need its own rules for it. **Recommendation:** keep it out of Base 0.x and the Audio
0.1 draft. Revisit when a remote client needs it, e.g. Lite on an iPad dictating through a Mac Studio's Nemotron.
`LiveSTT.swift` is the design to start from.

### 3.7 Kit (code, not spec)

- `MediaEngine.validate` runs only the Image rules (`MediaEngine.swift:33`). Profile rules need a registry.
- `MediaTypes.fileExtension` knows `audio/wav` and `audio/mpeg` only. It needs FLAC, AAC/M4A, Ogg/Opus and L16.
- MESFormsUI needs an audio input widget (pick, record, play), a voice picker driven by `voices`, and a player for
  outputs and chunks.
- The conformance suite's fixtures are PNG and JPEG only.

## 4. An Audio profile (outline)

### 4.1 Operations

| Operation | Inputs | Parameters (vocabulary) | Outputs | MLXEngine capability | Models |
|---|---|---|---|---|---|
| `audio.speak` | `text`; `voice_ref` (audio, 0–1); `voice_ref_text` (text, optional); `emotion_ref` (audio, 0–1) | `voice`, `voice_description`, `language`, `emotion`, `target_duration_s`, `speed`, `seed`, `quality`, `output` | `audio` | `tts` | Kokoro, MOSS-TTS-Nano, Gepard, Audio8, Qwen3-TTS, MOSS-TTS-Local, IndexTTS-2.5, VoxCPM2; AuK (`named_only`) |
| `audio.speak_dialog` | `script` (data: `[{speaker, text}]`); `voice_refs` (audio, 1–n); `voice_ref_texts` (text, 0–n) | `language`, `seed`, `quality`, `output` | `audio` | `tts` with `speakerTags` | Dia2-2B |
| `audio.edit_speech` | `audio`; `transcript` (text); `instruction` (text, optional) | `edit`: `{kind: emotion · style · paralinguistic · denoise · trim_silence, label?, target_text?}` (the engine's `SpeechEditOperation`), `seed`, `quality` | `audio`; `transcript` (data) | `speechEdit` | Step-Audio-EditX; AuK (`named_only`) |
| `audio.transcribe` | `audio` | `language`, `context` (terms to bias toward), `speakers` (`auto` · `off`), `timestamps` (`segment` · `word`), `formats` (`json`, `vtt`, `srt`) | `transcript` (data: `{text, segments[{text, start_s, duration_s, speaker?}], language?}`); `subtitles` (text, 0–n) | `stt` | Nemotron, R2T2, VibeVoice-ASR (speakers); Whisper once wrapped |
| `audio.generate` | `prompt` (text) | `negative_prompt`, `duration_s`, `seed`, `quality`, `output` | `audio` | `soundEffect` | MOSS-SoundEffect |
| `audio.separate` | `audio` | `stems`: any of `vocals`, `drums`, `bass`, `other`, `instrumental`, as the offer supports (ours give `vocals` and `instrumental`) | `stems` (audio, 1–n, named) | `audioSeparation` | HTDemucs, Mel-Band-RoFormer |
| `audio.enhance` | `audio` | `kind`: `loudness` · `denoise` · `dereverb` · `bandwidth`; `target_lufs` | `audio` | `audioPolish`, plus `speechEdit` denoise | AudioPolishKit (loudness); Step-Audio-EditX, AuK (denoise) |
| `audio.describe` | `audio` | — | `description` (data: `{emotion: {label, confidence, scores}}`) | `speechEmotion` | emotion2vec+ |

Left out: **Mimi encode** (`audioCodec`). Codec codes mean nothing across engines, so it's a building block, not a
client operation. Music (E17) waits for a permissively licensed model.

**Why a separate `speak_dialog`.** MES's premise is that clients ask for operations and engines normalize how each
model is used. Dia2 wants `[S1]` / `[S2]` in its text, the next scene model will want something else, and
`TTSControls.speakerTags` exists because "scene models do not share a syntax". A structured `script` lets the
engine write the tags, so clients never learn a model's markup.

### 4.2 Conventions

1. **Media types.** Engines MUST accept `audio/wav` (PCM 16/24/32-bit, float) and `audio/flac`, and SHOULD accept
   `audio/mpeg`, `audio/mp4` (AAC) and `audio/ogg` (Opus). Outputs default to `audio/wav` at the model's own rate.
2. **Output format.** `output: {media_type, sample_rate, bit_depth, channels}`, as in Image §1.2. An engine that
   resamples to honour it warns `audio_resampled`. One it can't honour is 422.
3. **Resampling quality.** Inputs are resampled to the model's rate with a band-limited (windowed-sinc) resampler.
   AB-L-0209 measured linear interpolation flipping 5–10 % of Step-Audio's codes, and dragging speaker similarity to
   0.86.
4. **Channels.** Speech models take mono. Engines downmix and warn `audio_downmixed`. Separation keeps the input's
   channels.
5. **Loudness.** Outputs aren't normalized unless the request asks (`audio.enhance`, or a `loudness` target).
6. **Voices.** `voice` names an id from the offer's `voices` (§3.3). `voice_ref` clones, and offers that condition on
   a transcript say so in `supports`. `voice_description` designs a voice; with a `seed` it reproduces (E9). A
   request with more than one of the three is 400.
7. **Long text.** Engines split text the model can't take in one pass, and stitch the takes. `limits.max_text_chars`
   bounds the request.
8. **Inline cues.** Nonverbal tags (laughs, sighs) are an offer's declared list (`supports.cues`). A tag the offer
   doesn't list is spoken as text, with the warning `cue_unsupported`.
9. **Emotion.** `emotion: {label?, description?}`. Labels come from the offer's list. Model-defined vectors
   (IndexTTS-2.5's head) are an extension.
10. **Seeds.** `seed` is 0 – 2³²−1: Qwen3-TTS, Gepard and IndexTTS-2.5 clamp to 32 bits, because larger seeds break the stop
    token. An offer whose decoding is deterministic warns `seed_ignored` when given one.

### 4.3 Warnings and helper roles

`audio_resampled`, `audio_downmixed`, `voice_ref_trimmed` (reference clipped to the model's limit),
`duration_missed` (`target_duration_s` not met within the offer's tolerance) and `cue_unsupported`. A language the
model detected, when the request named none, is reported as `effective.language`. Helper role: `prompt_enhance`, as
in Image, for AuK's instruction canonicalizer.

### 4.4 Conformance ideas (AUDIO-nnn)

- Outputs report `sample_rate`, `channels` and `duration_s`, and the file agrees.
- Every MUST input type is accepted.
- Streamed chunks concatenate to the final output, sample-exact.
- A feature an offer doesn't support, used with that model named, is 422.
- `transcribe` segments are ordered and lie within the input's duration.
- `separate` returns each requested stem at the input's duration.
- An asset survives two jobs and is gone after `DELETE`.

## 5. Our models: where each belongs

**Embedded** means an app links the package and drives it through MLXEngine in its own process. **Engine** means
an MES engine serves it as jobs. Most models can do both; the group says which shape gets the most out of the
model. Resident sizes are the packages' declared `residentBytes`, with the declared peak transient after the "+".

### 5.1 Embedded first

| Model | Resident | Why embedded | Engine offer too? |
|---|---|---|---|
| MOSS-TTS-Nano-100M | 0.4–0.7 + 1.4 GB | Streams: 62–380 ms to first audio, RTF 0.10. 20 languages, clones from a clip, Apache-2.0. The best in-app TTS we have | Yes: the draft tier of `audio.speak`, streamed |
| Kokoro-82M | 0.5 GB | 10 preset voices, English, one pass of up to 512 tokens: instant UI speech | Yes: draft tier. Needs `voices` (§3.3) |
| Gepard-1.0 | 1.2 + 4.0 GB | VoiceChatKit's voice. Streams, ~790 ms to first audio since v0.4.0. Clone-only | Yes, streamed |
| Nemotron 3.5 ASR 0.6B | 0.64 (int8) – 1.24 + 0.82 GB | Live, `cumulative`; 80 ms–1.12 s chunks; 40 locales. Dictation and voice chat | Yes: `audio.transcribe` for files |
| Confucius4-R2T2 | 2.8 (int8) + 3.6 GB | Live, `incremental`, 160 ms chunks, hotwords. Memory stays flat however long the session runs | Yes: `transcribe` with `context` |
| NemotronLabs-VoiceChat-11B (DEV) | — | Full duplex on an 80 ms frame clock, with KV and recurrent state carried across frames. It can't be a job | No |
| Mimi codec | 0.8 GB | A building block other packages use (codes) | No (§4.1) |

### 5.2 Engine first

| Model | Resident | Operation | Notes for the profile |
|---|---|---|---|
| VoxCPM2 | 9.3 + 4.0 GB, Pro chips and up | `audio.speak`, best tier, 48 kHz | Continuation cloning needs the reference transcript |
| IndexTTS-2.5 | 3.9–4.6 + 5.1 GB | `audio.speak`: clone-only; 8 emotions or a vector; native target duration (dub timing); zh/en/ja/es/ar | Commercial use needs a separate licence above 100M MAU or RMB 1B revenue |
| Qwen3-TTS 1.7B | ~3.0 + 4.8 GB (8-bit) | `audio.speak`: CustomVoice presets, ICL cloning, VoiceDesign + seed, `instruct` | The core can stream (`synthesizeStream`), but the package doesn't expose it |
| Dia2-2B | 4.5 + 3.0 GB | `audio.speak_dialog`: two speakers, English, up to 120 s | `(laughs)` is accepted and rarely performed: a `cues` note |
| MOSS-TTS-Local v1.5 (4B) | 6.5–12.2 + 2.4 GB | `audio.speak`. Streams, 149 ms to first audio at int8: the case for streaming from an engine | `[pause 1.5s]` cues |
| Audio8 0.6b / Mini 0.1b | 2.6 / 1.81 + 4.2–4.4 GB | `audio.speak`, 44.1 kHz. Streams, but 2.41 s to first audio | Mini: commercial use only below US$2M revenue |
| Step-Audio-EditX | 7.0–10.3 + 2.0 GB | `audio.edit_speech`: 15 emotions, 33 styles, 10 paralinguistic tags, denoise, trim; up to 90 s | The length changes, and the result carries a transcript |
| AuK / AuK-Flash | 7.8–12.9 + 1.5 GB | `audio.speak` (instruct TTS) and `audio.edit_speech`; up to 30 s; en/zh | Non-commercial (Qwen Research): `named_only` |
| MOSS-SoundEffect | 5.4–7.4 + 18 GB, Pro and up | `audio.generate`; up to 30 s; 48 kHz | — |
| VibeVoice-ASR 7B | 6.2 + 4.6 GB, growing 0.18 GB a minute | `audio.transcribe` with speakers | Its live path (~3 s floor) stays embedded in the Studio |
| Whisper large-v3-turbo | not declared | `audio.transcribe` | A library, not an engine package yet: wrap it first |

### 5.3 Either

| Model | Resident | Operation |
|---|---|---|
| HTDemucs v4 / Mel-Band-RoFormer | 0.9 + 6.7 GB / 0.3–0.7 GB | `audio.separate`: vocals and instrumental, 44.1 kHz stereo |
| emotion2vec+ | 1.0 + 0.4 GB | `audio.describe`: 9 classes |
| AudioPolishKit | no weights (DSP) | `audio.enhance`, loudness. Reports input and output LUFS |

### 5.4 What would break as it is

Served through the adapter unchanged, these break a MES rule:

| Package | Behaviour | MES rule | Fix |
|---|---|---|---|
| Kokoro | A `referenceAudio` request gets the default voice (`KokoroTTSPackage.swift:132-139`) | §6 rule 4, no surprises; §10.1, every deviation warns | Declared as `supports.voice_ref: none`, so a clone request is 422 before it runs (RFC 0003) |
| Gepard, Kokoro | Accept a seed and ignore it: Gepard's decoding is greedy (`GepardPackage.swift:29`), and Kokoro's package reads none | §10.1: `seed_ignored` | The offer declares `supports.seed: false`, and the kit warns (RFC 0003) |
| Qwen3-TTS, Gepard, IndexTTS-2.5 | Seeds are clamped to 32 bits, because large seeds break EOS | Image's seed range is 0 – 2⁵³−1 | The Audio vocabulary caps `seed` at 2³²−1 |
| MOSS-TTS-Nano | References are trimmed to 60 s | §10.1 | `voice_ref_trimmed` |
| All TTS | The encoded reference is cached across runs | §13 rule 4 | Assets (§3.1) |

**Licences.** IndexTTS-2.5 and R2T2 allow commercial use below 100M MAU or RMB 1B revenue, and Audio8-Mini below
US$2M revenue. MLXEngine records an advisory. Base §10.2 has only `commercial_use: true | false | unknown`, so a
`license: commercial-use` request either admits these with a `notice`, or refuses them. That needs a decision (A-6).

## 6. Engine-side work the adapter depends on

The MLXEngine adapter (DLV-9) maps capabilities onto operations, so the profile can only expose what the contract
declares:
- **Voice catalogue.** E6's speaker half is open, so `TTSControls` lists no voices. Kokoro's and Qwen3-TTS
  CustomVoice's presets are hardcoded in clients today.
- **Languages per surface.** Not declared anywhere in `TTSControls` or `STTControls`.
- **Output sample rate per surface.** Known only from the returned `.wav` (E7).
- **Seed in `TTSRequest`.** Not a canonical field: Qwen3-TTS and Gepard read `metaData["seed"]`, so the adapter
  needs a per-package mapping, which the contract set out to retire.
- **Streaming in the best-tier models.** Five packages stream, none of them best-tier. Qwen3-TTS's core already has
  a streaming generator (`Qwen3TTS+Protocols.swift:13`) that E2 says "maps 1:1 onto `StreamEmitting`", but the
  package doesn't expose it. VoxCPM2 needs upstream PR #212 and `f7f1b78` ported (E2).
- **Voice handles.** E1 left a contract-level `prepareVoice(reference:transcript:) -> VoiceHandle` as a possible
  follow-up. An MES asset (§3.1) is the wire twin of that handle, and would make the cache explicit instead of keyed
  by bytes.

## 7. Video and Audio share time

The build plan drafts the Video profile next, and LTX 2.5 emits 48 kHz audio and takes audio in (VID-2). Put the
time-based conventions in Base, or in a section both profiles cite, so they agree once: audio media types, output
sample rate, `duration_s`, `media_s` progress and streamed chunks. Otherwise Video defines them first and Audio
inherits whatever it chose.

## 8. Decisions this needs

| # | Question | Recommendation |
|---|---|---|
| A-1 | Reopen OQ-6 for audio: streamed output in Base? | Yes, as the `streaming` feature (§3.2), output only |
| A-2 | Assets, so a voice can be reused and its encoding cached? | Yes, as a Base feature, also usable by Image (§3.1) |
| A-3 | Live sessions in MES? | Not in 0.x. Live STT and voice chat stay embedded (§3.6) |
| A-4 | Per-offer `supports` and `voices`? | Yes, in Base, with keys defined per profile (§3.3) |
| A-5 | Order: Audio before Video, or shared time conventions first? | Shared conventions in Base first (§7), then whichever profile has a client waiting |
| A-6 | Licences that allow commercial use only below a revenue or user threshold? | Add `commercial_use: "conditional"`, with the threshold in `notice`. `license: commercial-use` admits it only once the operator has accepted the terms (`accepted_required`) |
