# Audio readiness: MES and the fleet's audio models

| | |
|---|---|
| **Date** | 2026-10-24 |
| **Spec** | Base 0.1, Image 0.1 (media-engine-spec v0.4.0) |
| **Models** | The audio rows of the MLXEngine registry (`MLXEngine/mlx-engine-swift/docs/model-registry.md` § Audio), `mlxengine-audio/PROD`, `mlx-vibevoice-asr-swift` |
| **Engine contract** | MLXToolKit 1.50 (`TTS.swift`, `Streaming.swift`, `LiveSTT.swift`, `SpeechEdit.swift`, `ToolDescriptor.swift`) |
| **Status** | Evaluation. Nothing here changes the spec yet; §8 lists the decisions it needs. RFCs [0001](../rfcs/0001-assets.md), [0002](../rfcs/0002-streamed-output.md) and [0003](../rfcs/0003-offer-supports-and-voices.md) draft A-2, A-1 and A-4. |

## Direction (2026-10-24)

These decisions were made after the first draft of this evaluation. Where they differ from the sections below, they
win, and §4, §5 and §8 have been revised to match.

- **Purpose.** MES exists so an app that conforms to the spec can adopt a new model quickly. For audio, that means
  normalizing the controls: an app asks for "angry" or a laugh once, and every model that can do it understands.
- **Audio 0.1 is generative only.** It starts with three operations (§4):
  - **Voice design:** describe a voice, and create it.
  - **Speech (TTS):** request a built-in voice, or pass what a cloned voice needs.
  - **Speech editing:** basic edits, with AuK as the model of what to cover.
- **Controls are normalized** across models (§4.3, §4.4):
  - emotions such as anger and sadness;
  - nonverbal sounds such as a cough or laughter.
- **Tools come later.** These are utility operations rather than generation: separation, cleanup and loudness, and
  codecs.
- **Speech-to-text stays client-side, out of the spec.** That covers transcription, live or from a file, and other
  interpretive models such as emotion recognition. Apps link them directly through MLXEngine. MES keeps to
  generative models.
- **Voice catalogues stay in the client.** The engine serves a named model's voices by `GET`, and the MCP binding
  gets a helper for the same list ([RFC 0003](../rfcs/0003-offer-supports-and-voices.md) §6.5). Our TTS packages
  get a helper that returns their voices, for the engine to serve (§6).

## Summary

The first draft's findings, from before the direction above.

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
- **Voice catalogues.** The first draft put `voices: [{id, title, languages, gender?, notes?, sample?, license?}]` on
  each offer. As decided, the offer now gives only a count (`supports.voices`), and a client that names the model
  fetches the list with `GET {path}/operations/{op}/models/{model}/voices` (RFC 0003 §6.5). The catalogue UI stays in
  the client. The engine side doesn't have a list yet. The speaker half of E6 is still open (`TTSControls` has no
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
- **Long audio from agents:** a minute of 48 kHz 16-bit mono WAV is ~5.8 MB, ~7.7 MB as a data URL in a tool call. A
  helper tool, `mes_create_upload`, could return a one-time URL the agent PUTs a file to, then names as `upload:<id>`.
  With transcription out of scope, this matters less: speech edits take up to 90 s, and voice references are short.
- **Voices:** `mes_list_voices {operation, model}` (RFC 0003).

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

**Decided (Direction):** speech-to-text, file or live, is out of the spec for now, so this deferral covers voice chat
only.

### 3.7 Kit (code, not spec)

- `MediaEngine.validate` runs only the Image rules (`MediaEngine.swift:33`). Profile rules need a registry.
- `MediaTypes.fileExtension` knows `audio/wav` and `audio/mpeg` only. It needs FLAC, AAC/M4A, Ogg/Opus and L16.
- MESFormsUI needs an audio input widget (pick, record, play), a voice picker driven by `voices`, and a player for
  outputs and chunks.
- The conformance suite's fixtures are PNG and JPEG only.

## 4. An Audio profile (outline)

Revised to the Direction above: generative only, three operations, and controls normalized across models. The label
lists come from the packages as they are on 2026-10-24 (MLXToolKit contract 1.55.0); each list cites its source.

### 4.1 Operations

| Operation | Inputs | Parameters (vocabulary) | Outputs | MLXEngine capability | Models |
|---|---|---|---|---|---|
| `audio.design_voice` | `description` (text, required); `text` (text, optional: what the sample says) | `language`, `seed`, `count` (auditions, 1–4), `quality` | `samples` (audio, `count`) | `tts`, voice from a description | Qwen3-TTS VoiceDesign; VoxCPM2; AuK (`named_only`) |
| `audio.speak` | `text` (required, may carry cues, §4.4); `voice_ref` (audio, 0–1); `voice_ref_text` (text, optional) | `voice`, `language`, `emotion`, `style`, `speed`, `target_duration_s`, `seed`, `quality`, `output` | `audio` | `tts` | Kokoro, MOSS-TTS-Nano, Gepard, Audio8, Qwen3-TTS, MOSS-TTS-Local, IndexTTS-2.5, VoxCPM2; AuK (`named_only`) |
| `audio.edit_speech` | `audio` (required); `transcript` (text, optional) | `edit` (one edit, §4.5), `seed`, `quality`, `output` | `audio`; `transcript` (data, when the edit changes the words or cues) | `speechEdit` | Step-Audio-EditX; AuK (`named_only`) |

**A voice, three ways.** `audio.speak` takes exactly one of these, and a request with more than one is 400:
- `voice`: a built-in voice, by id from the named model's list (RFC 0003 §6.5);
- `voice_ref`, with `voice_ref_text` when the model needs it: a cloned voice;
- neither: the model's default voice, for a model that has one (`supports.default_voice`).

**Designing a voice, then using it.** `design_voice` returns audition clips. The clip is the voice: a client keeps the
one it likes, ideally as an asset (RFC 0001). It then speaks with it through `audio.speak`, passing `voice_ref` = the
clip and `voice_ref_text` = the sample's text (`effective.text`). That is how ML[X] Audio Studio's Voice Library
already works ("the audition take's audio IS the identity", `Character.swift:5-8`). `roxy-voice-gen` does it across
models, designing on Qwen3-TTS and cloning on Gepard. A designed voice therefore works on every cloning model, not
only the one that designed it.
- **Reproducing.** With the same `description`, `seed` and model, an engine SHOULD produce the same voice (E9).
  `effective.seed` reports the seed of each sample. VoxCPM2 takes no seed (`supports.seed: false`).
- **The sample text.** When `text` is absent the engine chooses a short sentence in `language`, and reports it as
  `effective.text`. Qwen3-TTS wants descriptions of 15–40 words, in English or Chinese (`Qwen3TTS.swift:205-210`): a
  `notes` line.
- **Speaking with a description in one pass** (instruct TTS: Qwen3-TTS, VoxCPM2, AuK) is left out of `audio.speak`.
  The result isn't a voice a client can keep, and three models disagree on what a description means.

### 4.2 Conventions

1. **Media types.** Engines MUST accept `audio/wav` (PCM 16/24/32-bit, float) and `audio/flac`, and SHOULD accept
   `audio/mpeg`, `audio/mp4` (AAC) and `audio/ogg` (Opus). Outputs default to `audio/wav` at the model's own rate.
2. **Output format.** `output: {media_type, sample_rate, bit_depth, channels}`, as in Image §1.2. An engine that
   resamples to honour it warns `audio_resampled`. One it can't honour is 422.
3. **Resampling quality.** Inputs are resampled to the model's rate with a band-limited (windowed-sinc) resampler.
   AB-L-0209 measured linear interpolation flipping 5–10 % of Step-Audio's codes, and dragging speaker similarity to
   0.86.
4. **Channels.** Speech models take mono. Engines downmix and warn `audio_downmixed`.
5. **Loudness.** Outputs aren't normalized unless the request asks.
6. **Long text.** Engines split text the model can't take in one pass, at sentence boundaries, and stitch the takes.
   `limits.max_text_chars` bounds the request.
7. **References.** A reference longer than the model takes is trimmed, with `voice_ref_trimmed`. MOSS-TTS trims to
   60 s, and Qwen3-TTS's ICL to 30 s with 10–15 s recommended (`ReferenceEncoder.swift:46-63`).
8. **Seeds.** `seed` is 0 – 2³²−1: Qwen3-TTS, Gepard and IndexTTS-2.5 clamp to 32 bits, because larger seeds break
   the stop token. A model whose result doesn't depend on a seed declares `supports.seed: false`, and warns
   `seed_ignored` when given one (RFC 0003).
9. **Grids.** A value the model takes only on a grid is snapped to the nearest step, with `param_adjusted`. AuK's
   speed, pitch and volume are grids (§4.5).
10. **One label set.** Requests use the profile's labels (§4.3, §4.4). The engine translates them into each model's
    own vocabulary and syntax. A client never writes `[Laughter]` for one model and `(laughs)` for another.

### 4.3 Normalized emotion and style

**Emotion** is `emotion: {label?, description?, intensity?}`:
- **`label`** comes from the table below.
- **`description`** is free text (Qwen3-TTS, VoxCPM2, AuK), for an offer with `supports.emotion_description`.
- **`intensity`** is 0–1. Only IndexTTS-2.5 has one (`emoAlpha`, default 0.6). Elsewhere it's ignored, with
  `emotion_intensity_ignored`.
- **Vectors** (IndexTTS-2.5's 8 weights) are an extension, `x-indextts.emotion_vector`.

Three of our TTS packages already share a vocabulary: E12, `happy, angry, sad, afraid, disgusted, melancholic,
surprised, calm` (`E12Emotion.swift:16`). Each maps a label to its own steering:
- an instruct sentence on Qwen3-TTS (`happy` → "Speak cheerfully and with energy.");
- a `(description)` prefix on VoxCPM2;
- a weight vector on IndexTTS-2.5.

The profile adopts E12 as its core and adds what the editors offer. Labels are adjectives, as every package uses them:
anger is `angry`, sadness is `sad`.

| Label | E12 TTS (IndexTTS-2.5, Qwen3-TTS, VoxCPM2) | AuK edit | Step-Audio-EditX edit |
|---|---|---|---|
| `happy` | `happy` | `happy` | `happy` |
| `sad` | `sad` | `sad` | `sad` |
| `angry` | `angry` | `angry` | `angry` |
| `afraid` | `afraid` | `fearful` | `fear` |
| `disgusted` | `disgusted` | `disgusted` | `disgusted` |
| `surprised` | `surprised` | `surprised` | `surprised` |
| `calm` | `calm` | `calm` | — |
| `melancholic` | `melancholic` | — | — |
| `excited` | — | `excited` | `excited` |
| `neutral` | No emotion (sent as none) | — | `remove` |

- **`neutral`** means no emotion. Every `speak` offer supports it, because the engine simply sends no emotion. In an
  edit, it removes the emotion, which only Step-Audio-EditX does.
- **EditX's other seven** labels are `humour`, `confusion`, `empathy`, `embarrass`, `depressed`, `coldness` and
  `admiration` (`StepAudioEditXPackage.swift:44-47`). The profile registers them as `humorous`, `confused`,
  `empathetic`, `embarrassed`, `depressed`, `cold` and `admiring`. A label is registered when one model supports it;
  `supports.emotions` says which models do.
- **Aliases.** The engine resolves aliases, never the client: `fearful`, `fear` and `scared` → `afraid`, and
  `anger` → `angry`. E12 does this inside three packages (`E12Emotion.swift:18-22`); the profile does it once, for
  every model.

**Style** is `style: <label>`, delivery rather than feeling. Instruct TTS models (Qwen3-TTS, VoxCPM2, AuK) get it as
text, the way they get E12 labels today ("Whisper softly.").

| Label | Step-Audio-EditX edit | AuK edit | Instruct TTS (Qwen3-TTS, VoxCPM2) |
|---|---|---|---|
| `whisper` | `whisper` | `whisper` (`toWhisper`) | "Whisper softly." |
| `shout` | `shout` | — | Instruct text |
| `gentle` | `gentle` | — | Instruct text |
| `serious` | `serious` | — | Instruct text |
| `warm` | `warm` | — | Instruct text |
| `narration` | `story` | — | Instruct text |
| `conversational` | `chat` | — | Instruct text |
| `news` | `news` | — | Instruct text |
| `normal` | `remove` | `normal` (`fromWhisper`) | No style (sent as none) |

EditX's other 24 styles (`arrogant`, `child`, `older`, `ethereal`, `act_coy`, `radio`, `exaggerated`, …,
`StepAudioEditXPackage.swift:48-52`) stay extensions, `x-stepfun.style`. Several describe the speaker rather than the
delivery, and none has a second model.

### 4.4 Normalized nonverbal cues

Cues go inline in the text, in one syntax for every model: `[laugh]`, `[cough]`, `[pause 1.5s]`. A literal bracket is
written `\[`. The engine rewrites each cue into the model's syntax, and removes a cue the model can't perform, with
`cue_unsupported` (the first draft spoke it as text, which reads "cough" aloud).

| Cue | Dia2 (later) | VoxCPM2 | Step-Audio-EditX edit | AuK edit (core, not yet on the engine) |
|---|---|---|---|---|
| `laugh` | `(laughs)` | `[laughing]` | `[Laughter]` | `laughs` |
| `cough` | `(coughs)` | — | — | `coughs` |
| `sigh` | `(sighs)` | `[sigh]` | `[Sigh]` | — |
| `breath` | — | — | `[Breathing]` | `breaths` |
| `gasp` | `(gasps)` | — | — | — |
| `clear_throat` | `(clears throat)` | — | — | — |
| `hesitation` | — | — | `[Uhm]` | — |
| `sob` | `(sobs)` | — | — | — |
| `sniff` | `(sniffs)` | — | — | — |
| `pause` (seconds) | — | — | — | — |

- **`pause`** is native only on MOSS-TTS-Local (`[pause 1.0s]`, `MossTTSLocalPackage.swift:10`). Every engine can do
  it anyway: split the text at the pause and insert silence, as long-text stitching already does. So engines MUST
  honour `pause`.
- **Coverage is thin, and that's the finding.**
  - In `speak`, only VoxCPM2 performs cues: `[laughing]` and `[sigh]`, listen-tested (E11), but undeclared.
  - Dia2 accepts 50 cues and "rarely" performs them (`Dia2TTSPackage.swift:79-80`). It is a later operation anyway.
  - Bark has `[laughs]`, `[sighs]`, `[gasps]` and `[clears throat]`, but it's unpublished.
  - A **cough** is in only two places: Dia2, and AuK's core edit, which the engine doesn't expose.
  - The normalized cue costs nothing. Models that perform a cough well are what's missing.
- **EditX's interjections** (`[Surprise-oh]`, `[Confirmation-en]`, `[Question-ei]`, `[Dissatisfaction-hnn]`,
  `[Surprise-ah]`, `[Surprise-wa]`) are Mandarin-specific. They stay extensions, `x-stepfun.<name>`.

### 4.5 Speech editing, modelled on AuK

AuK's instruction set is the broadest we have (`AukInstruction.swift:10-45`), so the profile takes its shape. One job
applies one edit, `edit: {kind, …}`, as both editors do. `supports.edits` lists the kinds an offer takes.

| `kind` | Fields | AuK core | AuK on the engine today | Step-Audio-EditX |
|---|---|---|---|---|
| `emotion` | `emotion` (§4.3 label) | ✓ | ✓ (8 labels) | ✓ (15) |
| `style` | `style` (§4.3 label) | whisper ↔ normal | ✓ | ✓ (33) |
| `add_cue` | `cue`, and `at: start · end`, or `text` with the cue inline | start or end | — | inline, 10 tags |
| `remove_cue` | `cue` (absent: all) | ✓ | — | — |
| `replace_text` | `text`, `with` | ✓ | — | — |
| `insert_text` | `text`, `anchor`, `position: before · after` | ✓ | — | — |
| `remove_text` | `text` | ✓ | — | — |
| `speed` | `factor` | grid 0.5, 0.75, 1.25, 1.5, 2.0 | — | in the core, not exposed |
| `pitch` | `semitones` | grid −3 … +3 | — | — |
| `volume` | `gain_db` | grid −15 … +15 in 5s | — | — |
| `timbre` | `description` | ✓ | — | — |
| `de_accent` | — | ✓ (13 Chinese dialects) | — | — |
| `denoise` | — | ✓ | ✓ | ✓ |
| `trim_silence` | — | — | — | ✓ |

- **What the engine offers today** is the narrow part: emotion, style and denoise on AuK, plus add-cue and
  trim-silence on EditX. The rest of AuK's set, and an optional transcript, are AB-A-0188, which contract 1.55 hasn't
  landed. The profile defines all of them, so engines can add them without changing it.
- **Transcripts.** EditX needs one for every edit, though upstream doesn't for denoise and trim. AuK ignores it. The
  offer says which: `supports.transcript: required · optional · unused`. With speech-to-text out of MES, the client
  supplies it.
- **Length.** EditX regenerates the take, so its length changes (up to 90 s in). AuK keeps the source length (up to
  30 s in). The fact key `supports.keeps_length` says which.
- **Licences.** AuK is non-commercial (`LicenseRef-Qwen-Research`, from its Qwen2.5-Omni encoder), so it is
  `named_only` and is never chosen by default. Step-Audio-EditX is Apache-2.0 with the FunASR model licence, both
  permissive, so it is the default editor.
- **Later, as tools:** AuK's dereverberation, enhancement, speaker isolation (`keepSpeaker`, `keepSpeakerSaying`) and
  singing-only.

### 4.6 `supports` keys (RFC 0003)

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `languages` | all | `[BCP 47]` | any | Gate: `language` |
| `default_voice` | `speak` | boolean | `false` | Gate: a request with neither `voice` nor `voice_ref` |
| `voice_ref` | `speak` | boolean | `false` | Gate: the `voice_ref` input |
| `voice_ref_text` | `speak` | `unused` · `optional` · `required` | `unused` | Gate: `required` needs `voice_ref_text` |
| `emotions` | `speak`, `edit_speech` | `[label]` | `speak`: `[neutral]`; `edit_speech`: `[]` | Gate: `emotion.label` |
| `emotion_description` | `speak` | boolean | `false` | Gate: `emotion.description` |
| `emotion_intensity` | `speak` | boolean | `false` | Warn: `emotion_intensity_ignored` |
| `styles` | `speak`, `edit_speech` | `[label]` | `speak`: `[normal]`; `edit_speech`: `[]` | Gate: `style` |
| `cues` | `speak`, `edit_speech` | `[cue]` | `speak`: `[pause]`; `edit_speech`: `[]` | Warn in `speak`: `cue_unsupported`. Gate for `add_cue` and `remove_cue` |
| `speed` | `speak` | boolean | `false` | Gate: `speed` |
| `target_duration` | `speak` | boolean | `false` | Gate: `target_duration_s` |
| `edits` | `edit_speech` | `[kind]` | `[]` | Gate: `edit.kind` |
| `transcript` | `edit_speech` | `required` · `optional` · `unused` | `optional` | Gate: `required` needs `transcript` |
| `keeps_length` | `edit_speech` | boolean | `false` | Fact |
| `sample_rate` | all | integer | — | Fact |

Limit fields: `max_text_chars`, `max_voice_ref_s`, and `max_duration_s` for an edit's input.

The Base keys `stream`, `seed` and `voices` apply too.

### 4.7 Warnings and helper roles

- **Warnings:**
  - `audio_resampled` and `audio_downmixed`;
  - `voice_ref_trimmed`: the reference was clipped to the model's limit;
  - `duration_missed`: `target_duration_s` wasn't met within the offer's tolerance;
  - `cue_unsupported`: a cue was removed;
  - `emotion_intensity_ignored`.
- **Effective values:** a language the model detected, when the request named none, is reported as
  `effective.language`.
- **Helper role:** `prompt_enhance`, as in Image, for a model that rewrites a voice description or an instruction.

### 4.8 Conformance ideas (AUDIO-nnn)

- Outputs report `sample_rate`, `channels` and `duration_s`, and the file agrees.
- Every MUST input type is accepted.
- `voice`, `voice_ref` and neither each route to an offer that supports them; two together are 400.
- A label, cue or edit kind the named model doesn't list is 422 for a gate key. An unsupported cue is removed, with
  `cue_unsupported`.
- `[pause 1s]` adds about a second of silence on every offer.
- `design_voice` returns `count` samples, each with its seed; the same seed reproduces a sample on a seeded model; a
  sample used as `voice_ref` with `effective.text` speaks.
- Streamed chunks concatenate to the final output, sample-exact (RFC 0002).
- An asset survives two jobs and is gone after `DELETE` (RFC 0001).

### 4.9 Later, and outside

- **Later (generative):**
  - `audio.speak_dialog`: two-speaker scenes, Dia2, with a structured `script` so clients never write `[S1]`;
  - `audio.generate`: sound effects, MOSS-SoundEffect.
- **Later (tools):**
  - `audio.separate`: HTDemucs, Mel-Band-RoFormer;
  - `audio.enhance`: AudioPolishKit loudness, and AuK's enhancement family;
  - codecs: Mimi.
- **Outside MES:** speech-to-text (Nemotron, R2T2, VibeVoice-ASR, Whisper), emotion recognition (emotion2vec+), and
  voice chat. Apps link these directly through MLXEngine.

## 5. Our models: where each belongs

**Embedded** means an app links the package and drives it through MLXEngine in its own process. **Engine** means
an MES engine serves it as jobs. Most models can do both; the shape column says which gets the most out of the
model. Resident sizes are the packages' declared `residentBytes`, with the declared peak transient after the "+".

### 5.1 In Audio 0.1

| Model | Resident | Operations | Shape | Notes for the profile |
|---|---|---|---|---|
| MOSS-TTS-Nano-100M | 0.4–0.7 + 1.4 GB | `speak` (clone) | Embedded first; engine draft tier, streamed | Streams: 62–380 ms to first audio, RTF 0.10. 20 languages, Apache-2.0. The best in-app TTS we have |
| Kokoro-82M | 0.5 GB | `speak` (built-in voices) | Embedded first; engine draft tier | 10 voices, English, one pass of up to 512 tokens. Needs the voice-list helper (§6) |
| Gepard-1.0 | 1.2 + 4.0 GB | `speak` (clone) | Embedded first; engine, streamed | VoiceChatKit's voice. ~790 ms to first audio since v0.4.0 |
| VoxCPM2 | 9.3 + 4.0 GB, Pro chips and up | `speak` (clone), `design_voice` | Engine | Best tier, 48 kHz. Clip alone, or clip and transcript (continuation). Designs from a `(description)` prefix, with no seed; its README still says design isn't exposed. Performs `[laughing]` and `[sigh]` |
| IndexTTS-2.5 | 3.9–4.6 + 5.1 GB | `speak` (clone) | Engine | 8 emotions or a vector; native target duration (dub timing); zh/en/ja/es/ar. Commercial use needs a separate licence above 100M MAU or RMB 1B revenue |
| Qwen3-TTS 1.7B | ~3.0 + 4.8 GB (8-bit) | `speak` (built-in voices, clone), `design_voice` | Engine | Three checkpoints: CustomVoice (presets), Base (clone: clip alone ~0.75 similarity, with transcript ~0.89), VoiceDesign (description + seed). E12 emotions. The core can stream, but the package doesn't expose it |
| MOSS-TTS-Local v1.5 (4B) | 6.5–12.2 + 2.4 GB | `speak` (clone) | Engine, streamed | 149 ms to first audio at int8: the case for streaming from an engine |
| Audio8 0.6b / Mini 0.1b | 2.6 / 1.81 + 4.2–4.4 GB | `speak` (clone) | Engine | 44.1 kHz. Streams, but 2.41 s to first audio. Mini: commercial use only below US$2M revenue |
| Step-Audio-EditX | 7.0–10.3 + 2.0 GB | `edit_speech` | Engine, the default editor | 15 emotions, 33 styles, 10 inline cues, denoise, trim; 0.5–90 s. The length changes, and the result carries a transcript. Apache-2.0 + FunASR model licence: commercial use |
| AuK / AuK-Flash | 7.8–12.9 + 1.5 GB | `edit_speech`, `speak` (clone), `design_voice` | Engine, `named_only` | The model for what `edit_speech` covers (§4.5). 0.5–30 s; en/zh; keeps the source length. Non-commercial (Qwen Research) |

### 5.2 Later

| Model | Resident | Operation | Why later |
|---|---|---|---|
| Dia2-2B | 4.5 + 3.0 GB | `speak_dialog`: two speakers, English, up to 120 s | Generative, but scenes aren't in the first set. `(laughs)` is accepted and rarely performed |
| MOSS-SoundEffect | 5.4–7.4 + 18 GB, Pro and up | `generate` (sound effects): up to 30 s, 48 kHz | Generative, but not speech. Next after the first set |
| HTDemucs v4 / Mel-Band-RoFormer | 0.9 + 6.7 GB / 0.3–0.7 GB | `separate`: vocals and instrumental, 44.1 kHz stereo | Tools |
| AudioPolishKit | no weights (DSP) | `enhance`: loudness, with input and output LUFS | Tools |
| Mimi codec | 0.8 GB | Encode and decode codes | Tools, if ever: codes mean nothing across engines |

### 5.3 Outside MES (client-side)

| Model | Resident | What | Why outside |
|---|---|---|---|
| Nemotron 3.5 ASR 0.6B | 0.64 (int8) – 1.24 + 0.82 GB | Live STT, `cumulative`; 80 ms–1.12 s chunks; 40 locales | Interpretive (STT) |
| Confucius4-R2T2 | 2.8 (int8) + 3.6 GB | Live STT, `incremental`, 160 ms chunks, hotwords | Interpretive (STT) |
| VibeVoice-ASR 7B | 6.2 + 4.6 GB, growing 0.18 GB a minute | STT with speakers | Interpretive (STT) |
| Whisper large-v3-turbo | not declared | STT | Interpretive (STT), and not an engine package yet |
| emotion2vec+ | 1.0 + 0.4 GB | Emotion recognition, 9 classes | Interpretive |
| NemotronLabs-VoiceChat-11B (DEV) | — | Full duplex on an 80 ms frame clock | A session, not a job (§3.6) |

### 5.4 What would break as it is

Served through the adapter unchanged, these break a MES rule:

| Package | Behaviour | MES rule | Fix |
|---|---|---|---|
| Kokoro | A `referenceAudio` request gets the default voice (`KokoroTTSPackage.swift:132-139`), and a `.named` id goes to the core unchecked | §6 rule 4, no surprises; §10.1, every deviation warns | `supports.voice_ref: false`, so a clone request is 422 before it runs; voice ids checked against the list (RFC 0003) |
| VoxCPM2 | A `.named` voice silently falls back to zero-shot (`VoxCPM2TTSPackage.swift:180-181`), and a seed is never read | §6 rule 4; §10.1 | `supports.voices: 0`, so a voice id is 422; `supports.seed: false` |
| Gepard, Kokoro | Accept a seed and ignore it: Gepard's decoding is greedy (`GepardPackage.swift:29`), and Kokoro's package reads none | §10.1: `seed_ignored` | The offer declares `supports.seed: false`, and the kit warns (RFC 0003) |
| Qwen3-TTS, Gepard, IndexTTS-2.5 | Seeds are clamped to 32 bits, because large seeds break EOS | Image's seed range is 0 – 2⁵³−1 | The Audio vocabulary caps `seed` at 2³²−1 |
| MOSS-TTS-Nano, MOSS-TTS-Local | References are trimmed to 60 s | §10.1 | `voice_ref_trimmed` |
| Step-Audio-EditX | Needs a transcript for every edit, including denoise and trim, which upstream doesn't (`StepAudioEditXPackage.swift:197-198`) | — | `supports.transcript: required`, so a request without one goes to another editor or is 422 |
| All TTS | The encoded reference is cached across runs | §13 rule 4 | Assets (§3.1) |

**Licences.** IndexTTS-2.5 allows commercial use below 100M MAU or RMB 1B revenue, and Audio8-Mini below US$2M
revenue (R2T2 has the same terms as IndexTTS-2.5, but it is STT, now outside MES). MLXEngine records an advisory. Base §10.2 has only `commercial_use: true | false | unknown`, so a
`license: commercial-use` request either admits these with a `notice`, or refuses them. That needs a decision (A-6).

## 6. Engine-side work the adapter depends on

The MLXEngine adapter (DLV-9) maps capabilities onto operations, so the profile can only expose what the contract
declares:
- **A voice-list helper (decided).** E6's speaker half is open, so `TTSControls` lists no voices. Kokoro's and
  Qwen3-TTS CustomVoice's presets are hardcoded in their packages and in clients today. Each TTS package with presets
  gains a helper that returns its voices (id, title, languages, tags, an optional sample). The adapter calls it when
  a client names the model and asks for the list, and serves it as RFC 0003's `GET …/voices` and `mes_list_voices`.
- **Normalized controls.** The packages each speak their own emotion and cue dialect (§4.3, §4.4). Either the adapter
  carries the mapping table, or `TTSControls` declares labels in the profile's vocabulary.
- **Languages per surface.** Not declared anywhere in `TTSControls`.
- **Output sample rate per surface.** Known only from the returned `.wav` (E7).
- **Seed in `TTSRequest`.** Not a canonical field: Qwen3-TTS and Gepard read `metaData["seed"]`, so the adapter
  needs a per-package mapping, which the contract set out to retire.
- **Streaming in the best-tier models.** Five packages stream, none of them best-tier. Qwen3-TTS's core already has
  a streaming generator (`Qwen3TTS+Protocols.swift:13`) that E2 says "maps 1:1 onto `StreamEmitting`", but the
  package doesn't expose it. VoxCPM2 needs upstream PR #212 and `f7f1b78` ported (E2).
- **Voice handles.** E1 left a contract-level `prepareVoice(reference:transcript:) -> VoiceHandle` as a possible
  follow-up. An MES asset (§3.1) is the wire twin of that handle, and would make the cache explicit instead of keyed
  by bytes.
- **Voice design isn't a contract concept.** `VoiceSelector` has `named`, `referenceAudio` and `auto`, and nothing for
  design (`TTS.swift:9-13`). Each package takes the description its own way: `.auto` plus `emotion.textDescription`,
  or `metaData.instruct`, which is the slot emotion also uses. A `.design(description)` case would let `design_voice`
  and emotion coexist on Qwen3-TTS.
- **Cues aren't declared.** `TTSControls` has no cue list. VoxCPM2 performs `[laughing]` and `[sigh]` but declares
  neither, and Dia2's 50 live only in its tokenizer. Packages should declare cues, ideally under the profile's names.
- **Speech edits (AB-A-0188).** AuK's content edits (replace, insert, remove words), speed, pitch, volume, timbre,
  de-accent and nonverbal add or remove are in its core, not in `SpeechEditOperation`. AB-A-0188 also asks for an
  optional transcript and `targetDuration` on `SpeechEditRequest`. Contract 1.55 has none of it.
- **Qwen3-TTS's preset list.** The sources disagree on CustomVoice's speakers:
  - the API reference lists 10;
  - E6 says 9;
  - vendored mlx-audio docs list 7.

  At run time the ids come from `config.json` `spk_id`, so the voice-list helper should read them there.
- **A licence note to check.** `EmotionPresets.swift:10-14` in IndexTTS-2.5 still calls the baked matrices
  "NonCommercial", while the package declares `LicenseRef-Bilibili-Model-Use`.

## 7. Video and Audio share time

The build plan drafts the Video profile next, and LTX 2.5 emits 48 kHz audio and takes audio in (VID-2). Put the
time-based conventions in Base, or in a section both profiles cite, so they agree once: audio media types, output
sample rate, `duration_s`, `media_s` progress and streamed chunks. Otherwise Video defines them first and Audio
inherits whatever it chose.

## 8. Decisions this needs

| # | Question | Recommendation |
|---|---|---|
| A-1 | Reopen OQ-6 for audio: streamed output in Base? | Yes, as the `streaming` feature (§3.2), output only. RFC 0002 |
| A-2 | Assets, so a voice can be reused and its encoding cached? | Yes, as a Base feature, also usable by Image (§3.1). RFC 0001 |
| A-3 | Live sessions in MES? | **Decided:** not in 0.x. Voice chat stays embedded, and speech-to-text is out of the spec (§3.6) |
| A-4 | Per-offer `supports` and `voices`? | Yes, in Base, with keys defined per profile (§3.3). **Decided:** a named model's voices are listed by `GET` and `mes_list_voices`, not inline. RFC 0003 |
| A-7 | What does Audio 0.1 cover? | **Decided:** generative only. Voice design, speech with a built-in or cloned voice, speech editing modelled on AuK, and normalized emotions and nonverbal cues (§4). Tools later; STT and other interpretive models out |
| A-5 | Order: Audio before Video, or shared time conventions first? | Shared conventions in Base first (§7), then whichever profile has a client waiting |
| A-6 | Licences that allow commercial use only below a revenue or user threshold? | Add `commercial_use: "conditional"`, with the threshold in `notice`. `license: commercial-use` admits it only once the operator has accepted the terms (`accepted_required`) |
