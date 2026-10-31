# Audio readiness: MES and the fleet's audio models

| | |
|---|---|
| **Date** | 2026-10-24 |
| **Spec** | Base 0.1, Image 0.1 (media-engine-spec v0.4.0) |
| **Models** | The audio rows of the MLXEngine registry (`MLXEngine/mlx-engine-swift/docs/model-registry.md` § Audio), `mlxengine-audio/PROD`, `mlx-vibevoice-asr-swift`; for music, `mlxengine-audio/WIP/music-survey/MUSIC-MODEL-SURVEY.md` (AB-R-0604) |
| **Engine contract** | MLXToolKit 1.50 (`TTS.swift`, `Streaming.swift`, `LiveSTT.swift`, `SpeechEdit.swift`, `ToolDescriptor.swift`) |
| **Status** | Evaluation, now taken up: [Audio 0.1](../spec/profiles/audio.md) is drafted from its Direction (v0.7.0, 2026-10-30), and RFCs [0001](../rfcs/0001-assets.md), [0002](../rfcs/0002-streamed-output.md) and [0003](../rfcs/0003-offer-supports-and-voices.md) (A-2, A-1, A-4) are accepted with amendments. A-8 and A-9 apply to Audio (Audio §1.12) and are proposed for Base; A-6 is open. Where this document and the profile differ, the profile wins. |

## Direction (2026-10-24)

These decisions were made after the first draft of this evaluation. Where they differ from the sections below, they
win, and §4, §5 and §8 have been revised to match.

- **Purpose.** MES exists so an app that conforms to the spec can adopt a new model quickly. For audio, that means
  normalizing the controls: an app asks for "angry" or a laugh once, and every model that can do it understands.
- **Audio 0.1 is generative only.** It starts with four operations (§4):
  - **Voice design:** describe a voice, and create it.
  - **Speech (TTS):** request a built-in voice, or pass what a cloned voice needs.
  - **Speech editing:** basic edits, with AuK as the model of what to cover.
  - **Sound generation:** non-verbal audio from a description, such as foley, ambience and effects (MOSS-SoundEffect).
    Sounds, not voices.
- **Music is an operation of its own, `audio.compose`** (§4.7; decided 2026-10-24, A-10), with three offers: ACE-Step
  1.5 (MIT) as the commercial default, YuE2-3B research-only (`named_only`), and MiniMax Music 3 under the community
  licence the operator accepted the same day (AB-D-0157). It joins Audio 0.1 if ACE-Step's package is ready when the
  profile is published, and the first addition after otherwise.
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
| Research and opt-in models | `named_only` and `license.accepted_required` (AuK's `LicenseRef-Qwen-Research`, YuE2's `CC-BY-NC-4.0`) |
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
  axis". It also gains `phase`, a short id for the part of the run in progress (`plan`, `generate`, `denoise`,
  `decode`), with `step` and `steps` counting within the phase: a song runs several stages of different kinds
  (§4.7.3), and `message` is no place for a client to read which.
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

### 3.7 Licence notices on results

A non-commercial model's terms reach the user only if a client shows them, and reach the file only if something
writes them in. YuE2 (§4.7.5) makes both concrete. They apply equally to AuK and to Image's research-licensed
offers, and MiniMax Music 3 (§4.7.5) shows that a commercial licence can carry a display duty too.

1. **Showing the notice is optional.** Base §10.2 calls `notice` text "the client should show", and nothing says
   where. A client can show it in the model picker and never with the result. **Proposal (A-8):** when a result's
   `provenance` names a model, adapter, helper or voice whose `license.commercial_use` isn't `true`, a client that
   presents the result MUST show that licence's `notice` with it, or its `spdx` and `terms_url` when there's no
   notice. MCP's text summary already lists the licence (§15); it gains the notice.
2. **The licence doesn't travel with the file.** Provenance lives in the job, and is left behind once a client saves
   the output. **Proposal (A-9):** when a job's licences include one whose `commercial_use` isn't `true`, the engine
   SHOULD write the `spdx` id and `notice` into the output's own metadata, where the format has a place for it:
   - FLAC and Ogg: the `LICENSE` and `COPYRIGHT` Vorbis comments;
   - MP3: ID3 `TCOP` and `COMM`;
   - WAV: a `LIST/INFO` chunk with `ICOP` and `ICMT`.

   It MAY do the same for every output. The output's `sha256` covers the file as written, tags included. The same
   tags could carry an AI-generated marker, which some jurisdictions now require for synthetic audio.
3. **A display duty on a commercial licence.** MiniMax Music 3's licence permits commercial use and still requires a
   commercial product that uses the model to display `MiniMax-Music3` prominently (§4.7.5). Keyed to
   `commercial_use`, A-8 would let a client skip the one notice that licence insists on. **Revised A-8:** `notice` is
   text the client MUST show: on the offer, with every result whose provenance carries it, and in the MCP text
   summary, whatever `commercial_use` says. A licence has a `notice` only when its terms require something shown (an
   attribution, a display name, a non-commercial restriction); advisory text goes in the offer's `notes`. When
   `commercial_use` isn't `true` and there is no notice, the client shows `spdx` and `terms_url` instead. **Revised
   A-9:** the engine SHOULD write `spdx` and `notice` into the file whenever a job's licences carry a notice or
   aren't all `commercial_use: true`. Base §10.2's "text the client should show" becomes that MUST.

### 3.8 Kit (code, not spec)

- `MediaEngine.validate` runs only the Image rules (`MediaEngine.swift:33`). Profile rules need a registry.
- `MediaTypes.fileExtension` knows `audio/wav` and `audio/mpeg` only. It needs FLAC, AAC/M4A, Ogg/Opus and L16.
- MESFormsUI needs an audio input widget (pick, record, play), a voice picker driven by `voices`, and a player for
  outputs and chunks.
- The conformance suite's fixtures are PNG and JPEG only.

## 4. An Audio profile (outline)

Revised to the Direction above: generative only, four operations, and controls normalized across models. The label
lists come from the packages as they are on 2026-10-24 (MLXToolKit contract 1.55.0); each list cites its source.

### 4.1 Operations

| Operation | Inputs | Parameters (vocabulary) | Outputs | MLXEngine capability | Models |
|---|---|---|---|---|---|
| `audio.design_voice` | `description` (text, required); `text` (text, optional: what the sample says) | `language`, `seed`, `count` (auditions, 1–4), `quality` | `samples` (audio, `count`) | `tts`, voice from a description | Qwen3-TTS VoiceDesign; VoxCPM2; AuK (`named_only`) |
| `audio.speak` | `text` (required, may carry cues, §4.4); `voice_ref` (audio, 0–1); `voice_ref_text` (text, optional) | `voice`, `language`, `emotion`, `style`, `speed`, `target_duration_s`, `seed`, `quality`, `output` | `audio` | `tts` | Kokoro, MOSS-TTS-Nano, Gepard, Audio8, Qwen3-TTS, MOSS-TTS-Local, IndexTTS-2.5, VoxCPM2; AuK (`named_only`) |
| `audio.edit_speech` | `audio` (required); `transcript` (text, optional) | `edit` (one edit, §4.5), `seed`, `quality`, `output` | `audio`; `transcript` (data, when the edit changes the words or cues) | `speechEdit` | Step-Audio-EditX; AuK (`named_only`) |
| `audio.generate` | `prompt` (text, required) | `negative_prompt`, `duration_s`, `seed`, `count`, `quality`, `output` | `sounds` (audio, `count`) | `soundEffect` | MOSS-SoundEffect v2.0 |
| `audio.compose` (§4.7; scheduled by A-10) | `caption` (text, required); `lyrics` (text, 0–1); `score` (text, 0–1); `reference` (audio, 0–1); `source` (audio, 0–1) | `duration_s`, `language`, `planning`, `edit`, `anchors`, `timestamps`, `seed`, `quality`, `output` | `song` (audio); `score` (text, 0–1); `timestamps` (data, 0–1) | music (AB-A-0201, AB-A-0202) | ACE-Step 1.5 (default); MiniMax Music 3; YuE2-3B (`named_only`) |

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

### 4.6 Sound generation

`audio.generate` makes non-verbal audio from a description: foley, ambience, creatures, actions and effects. It is
the audio counterpart of `image.generate`, and takes the same shape:
- **Inputs:** `prompt` (text, required).
- **Parameters:** `negative_prompt`, `duration_s`, `seed`, `count`, `quality`, `output`.
- **Outputs:** `sounds` (audio, `count`), each with its reported seed.

MLXEngine already has this as its own capability, `soundEffect`. Its canonical request is `prompt`,
`durationSeconds`, `negativePrompt`, `steps`, `guidanceScale` and `seed` (`SoundEffect.swift`, contract 1.2.0), so
the operation maps onto it field for field:
- **`quality` picks the step count.** The engine maps `draft`, `standard` and `best` to steps and guidance, as Image
  does, so clients never send model-specific diffusion settings (OQ-4). The package defaults are 100 steps at CFG 4.0
  (`MossSoundEffectConfiguration.swift:35-38`). An engine that exposes raw steps does it as an extension
  (`x-moss.steps`).
- **`duration_s` is exact.** The output is that long, up to the offer's `limits.max_duration_s`, which is 30 s for
  MOSS. When it's absent, the engine uses the model's default, 10 s for MOSS, and reports it as
  `effective.duration_s`.
  - MOSS conditions the length through a trained prompt suffix, " duration: X.Xs", and always denoises the full 30 s
    latent, then crops (`Pipeline.swift:164-165`).
  - So a 2 s sound costs as much as a 30 s one. That belongs in the offer's `notes`.
- **`negative_prompt`** steers away from a sound. An empty one is MOSS's trained unconditional path.
- **Seeds.** When the request has no seed, the engine picks one and reports it. The package defaults to seed 0
  (`MossSoundEffectPackage.swift:154`), so without that, every unseeded run of a prompt would give the same sound.
- **`count`** runs the model once per sound, each with its own seed, as Image does.
- **Prompt language.** `supports.languages` says what a prompt may be written in: English and Chinese captions for
  MOSS.
- **Progress** is honest, because the step count is known: `step` and `steps`, then the decode. Cancelling stops at
  the next step, about 0.5 s on M-class chips at bf16.
- **No streaming.** Diffusion makes the whole clip at once, so `supports.stream` is `false`.

MOSS-SoundEffect-v2.0 is Apache-2.0, weights and port both. It is 48 kHz mono, and needs a Pro chip or better
(5.4 GB int4 or 7.4 GB bf16 resident, plus about 18 GB transient). It's the only sound model in the registry today.

**Not in it:**
- **Music.** Songs are `audio.compose` (§4.7): lyrics, a style caption and optionally a score, a reference or a
  recording to rework are inputs a sound doesn't take.
- **Sound under speech.** MOSS-TTS-Local's core prompt has `soundEvent` and `ambientSound` fields that its package
  doesn't expose (`MossTTSLocal.swift:166-173`). Dia2's sound cues (`(applause)`, `(thunder)`) belong with dialog.
  Mixing a generated sound under speech is a client's job for now.

### 4.7 Music

`audio.compose` makes a song: vocals and arrangement from lyrics and a description of the style, or an instrumental
from the description alone. The output is stereo music, minutes long. Three offers serve it, under three licences
(§4.7.5): ACE-Step 1.5 (MIT, the default), YuE2-3B (CC BY-NC 4.0, `named_only`) and MiniMax Music 3 (a community
licence that permits commercial use and requires a displayed name). The survey that chose them is
`mlxengine-audio/WIP/music-survey/MUSIC-MODEL-SURVEY.md` (AB-R-0604); the operator's licence decisions are AB-D-0073
(reversed, YuE2) and AB-D-0157 (MiniMax).

**Its own operation, not a `supports` key on `audio.generate`.** §4.6 left the shape open. It is decided for an
operation of its own (2026-10-24, AB-D-0158), for these reasons:

1. **The inputs differ in kind, not degree.** A sound takes one prompt. A song takes a caption, lyrics with section
   tags, and optionally a score to render, a recording whose timbre to take, and a recording to rework. Base §6 rule 1
   says `params` MUST NOT require model-specific parameters, and rule 4 says what a model can't honour belongs in the
   descriptor. Folding music into `generate` would put a dozen fields no sound model honours on every `generate`
   descriptor, and `prompt` would mean a sound description on one offer and a style caption on another.
2. **A default is per operation.** Base §6 rule 2 picks a default offer when the request names none. One operation
   has one default: for sounds it is MOSS-SoundEffect, for songs ACE-Step 1.5. Routing a `generate` request to a
   music offer because it carries `lyrics` would make the default depend on which inputs are present, and an
   instrumental request has no lyrics to route by.
3. **Three licence postures on one tool.** `audio.generate` is Apache-2.0 throughout. Music carries a non-commercial
   offer and a licence with a display duty. The MCP binding makes one tool per operation (Base §15), so the three
   licence lines sit on `audio_compose`, where an agent composing a song reads them, and never clutter the sound tool.
4. **Different work, different progress.** A sound is one denoise of a known step count. A song runs a planner, then
   an autoregressive or flow stage, then a decode, and the phases have counts of their own (§4.7.3).
5. **Precedent.** Image keeps `image.generate` and `image.edit` apart although both diffuse, because their inputs
   and defaults differ. The same line runs between sounds and songs.

The cost is one more descriptor. The two operations share the conventions of §4.2, `seed`, `quality`, `output`, and
the warning vocabulary. A `supports` key on `generate` would have saved the descriptor and cost every one of the
points above.

#### 4.7.1 Inputs and parameters

Inputs:

| Input | Kind | Count | Meaning |
|---|---|---|---|
| `caption` | text | required | The style: genre, mood, instrumentation, era, tempo in words, a description of the voice. Free text |
| `lyrics` | text | 0–1 | The words, in sections (§4.7.2). Absent: an instrumental, on an offer with `supports.instrumental` |
| `score` | text | 0–1 | An ABC score to render, chord-annotated or melody only (`supports.score`). A client edits the score a previous job returned, and renders it again |
| `reference` | audio | 0–1 | A recording whose timbre or style the song should take (`supports.reference`). It isn't reworked |
| `source` | audio | 0–1 | The recording an `edit` reworks (`supports.edits`) |

Parameters (vocabulary):

| Parameter | Type | Meaning |
|---|---|---|
| `duration_s` | number | The target length. Absent: the model plans one from the caption and lyrics. Reported as `effective.duration_s` either way. Within the offer's `limits.min_duration_s` and `max_duration_s` |
| `language` | BCP 47 | The language the vocals are sung in. Absent: inferred from the lyrics and reported as `effective.language`. Gate: `supports.languages` |
| `planning` | `full` · `melody` · `off` | Whether the model writes a score before it sings: chord-annotated, melody only, or none. Default: the offer's own. Ignored when `score` is given, since the score is the plan. Gate: `supports.score` |
| `edit` | object | `{kind, strength?, start_s?, end_s?, before_s?, after_s?}`, see below. Needs `source`. Gate: `supports.edits` |
| `anchors` | object | `{bpm?, key?, time_signature?}`: musical anchors the plan should keep. `bpm` is a number; `key` a tonic and mode (`"F# minor"`); `time_signature` a fraction (`"4/4"`). Warn: `anchors_ignored` |
| `timestamps` | boolean | Asks for word and line timestamps (§4.7.3). Warn: `timestamps_unavailable` |
| `seed`, `quality`, `output` | | As §4.2 and §4.7.4 |

**Edits** rework `source` (ACE-Step 1.5 today):
- **`cover`:** a new performance of the source's song in the caption's style. `strength` 0–1 says how far from the
  source it may go (default 0.5).
- **`repaint`:** the span `start_s`–`end_s` of the source is made again, and the rest is kept. The span is at most
  `limits.max_repaint_s`.
- **`extend`:** `before_s` and/or `after_s` seconds of music are added around the source, which plays unchanged in
  the middle.

A request with `edit` and no `source`, or `source` and no `edit`, is 400 `invalid_request`. A `score` without
`lyrics` is 400 too: the words the score was planned from travel with it. How a supplied score and the lyrics
combine is the port's call (AB-T-0350); the engine reports the words it sang in `effective.lyrics` when they differ
from the request.

**No `count`.** A song is minutes of audio, and two of the three offers take longer than real time to make one. A
client that wants variations submits jobs, each with its own seed.

#### 4.7.2 Section tags

Lyrics are plain text, one sung line per line, in sections introduced by a tag on a line of its own:

`[intro]`, `[verse]`, `[pre-chorus]`, `[chorus]`, `[bridge]`, `[solo]`, `[instrumental]`, `[outro]`

A tag may carry a short direction after a dash: `[chorus - anthemic, full band]`. Tags are case-insensitive.
Lyrics with no tag are one `[verse]`. This is the profile's one label set (§4.2 rule 10): the engine writes each
model's own syntax, YuE2's lowercase `[verse]`, ACE-Step's `[Verse]` and `[Chorus - …]`, MiniMax's tags. A tag the
offer's `supports.sections` doesn't list is mapped to the nearest one it does, or dropped, with `section_unsupported`.

#### 4.7.3 Outputs, effective values and progress

Outputs:

| Output | Kind | Count | Meaning |
|---|---|---|---|
| `song` | audio | 1 | Stereo, at the model's rate: `supports.sample_rate` and `channels` say which, and the output reports `sample_rate`, `channels` and `duration_s` (§3.4). ACE-Step and YuE2 are 48 kHz; MiniMax's native rate is 32 or 44.1 kHz (the port resolves it). A client that needs 48 kHz asks through `output.sample_rate` and gets `audio_resampled` where the model can't |
| `score` | text | 0–1 | ABC: the score the model planned, or the one it was given. The editable artifact. Only from an offer with `supports.score` |
| `timestamps` | data | 0–1 | `{lines: [{text, start_s, end_s}], words?: [{text, start_s, end_s}]}`, when `timestamps: true` on an offer with `supports.timestamps`. ACE-Step emits LRC lines; `words` where the model has them |

**Effective values.** `effective.seed` is always reported, and an unseeded request gets a seed the engine picks (as
§4.6: never a fixed default). `effective.duration_s` is always reported. `effective.language` when inferred,
`effective.anchors` when the planner chose or changed them (the bpm, key and time signature the song has), and
`effective.lyrics` when the words sung differ from the request.

**Warnings:**
- `song_truncated`: the model hit its length or token cap before the lyrics ended (YuE2's 9000 semantic tokens,
  ACE-Step's 600 s). `effective.duration_s` says where it stopped, and the message names the last section sung;
- `duration_missed`: `duration_s` wasn't met within the offer's tolerance (reused from `speak`);
- `section_unsupported`, `anchors_ignored` and `timestamps_unavailable`, above;
- `audio_resampled` and `audio_downmixed` for `reference` and `source`, as §4.2.

An `edit` span outside the source, or longer than `max_repaint_s`, is 422 `out_of_limits`. A `reference` or
`source` longer than the offer's `max_reference_s` or `max_source_s` is 422 too, not trimmed: trimming a song
changes what it is.

**Progress.** The three models run phases of different kinds, so an honest progress report names the phase and
counts within it:

| Offer | Phases |
|---|---|
| YuE2-3B | `plan` (score tokens) → `generate` (semantic tokens, up to 9000) → `synthesize` (ODE steps × chunks) → `decode` (VAE tiles) |
| ACE-Step 1.5 | `plan` (planner tokens; skipped at `draft`) → `denoise` (8 steps turbo, 50 base) → `decode` (VAE) |
| MiniMax Music 3 | `plan` (global LM tokens) → `detail` (local LM, per frame) → `denoise` (flow steps) → `decode` (VAE) |

Within Base's `running` stage the engine reports `step` and `steps` for the current phase, names the phase in
`message`, and sets `fraction` only once the whole is estimable, which is after the plan fixes the duration. §3.4's
`media_s` applies to the decode. A `phase` field on progress, a short id from this list, would serve clients
better than parsing `message`; §3.4 now proposes it. Cancelling stops at the next token or step. None of the three
streams (`supports.stream: false`): a song's first seconds exist only after its plan.

**MCP.** The tool is `audio_compose`. `lyrics`, `caption` and `score` are plain strings; `reference` and `source`
are data URLs or `upload:<id>`. A song is never under 1 MB, so the result carries a `resource_link` and the text
summary, never an inline `audio` block (§3.5). The three licence lines, with the notices and notes of §4.7.5, are on
the tool's description (Base §15).

**MLXEngine capability.** AB-A-0201 and AB-A-0202 ask mlx-engine for one music `Capability` covering the three
models. The operation maps onto the request surface those asks propose field for field, so the adapter has nothing
to invent:

| Operation | Capability (AB-A-0201, AB-A-0202) |
|---|---|
| `caption` | `style` / `caption` |
| `lyrics`, section tags (§4.7.2) | `lyrics`, with the engine writing each model's tag syntax |
| `score`, `planning` | `score`, `planning` (`.full` / `.melody` / `.off`) |
| `reference` | `referenceAudio` |
| `source` + `edit` | `sourceAudio` + `editMode` (`cover` / `repaint` / `extend`) with its strength or span |
| `anchors` | `anchors` (`bpm`, `key`, `timeSignature`) |
| `duration_s` | `durationSeconds` / `maxSeconds` |
| `language` | `vocalLanguage` |
| `timestamps` | timestamps out |
| `quality` | steps, `guidanceScale` and the checkpoint, by the mapping in §4.7.4; raw values only as extensions (`x-acestep.steps`) |
| `song`, `score`, `timestamps` out; `song_truncated` | `audio`, `score`, timestamps, `truncated` |
| `supports` keys (§4.8) | the per-package feature flags the asks call for (`score`, `referenceAudio`, `sourceAudio`, `anchors`, timestamps) |
| Progress phases | the named phases with counts the asks propose |

#### 4.7.4 Quality

`quality` picks the step count, the guidance and, where the operator installed more than one checkpoint, the
checkpoint, as Image does (OQ-4). Clients never send diffusion settings. The mapping below is the recommendation for
the MLXEngine adapter; the ports settle the numbers at their gates (E25, AB-T-0350, AB-T-0351), and an offer lists
only the tiers it serves.

| Offer | `draft` | `standard` | `best` |
|---|---|---|---|
| ACE-Step 1.5 | Turbo, 8 Euler steps, no CFG, planner off: the caption, lyrics and anchors drive the DiT directly. The fastest song in the fleet, 2–3× real time on an M3 Max | Turbo, 8 steps, the 1.7B planner on | The base or sft checkpoint, 50 steps, CFG 7: offered only when the operator installed it |
| YuE2-3B | — | The package's default ODE steps; CFG 1.0 with a score (`full`, `melody`), 1.01 without (`off`) | More ODE steps and CFG 1.2, the card's knob. Best-of-n is a client's job: n jobs, n seeds |
| MiniMax Music 3 | — | The port's default flow steps on the mxfp8 weights, which the port recommends for lyric fidelity | The same steps on the bf16 weights |

**A fixed-step turbo.** ACE-Step's turbo checkpoint is distilled for 8 steps, so `quality` can't buy it more steps;
the tiers change what else runs (the planner) or which checkpoint. An engine that wants to expose the step count
anyway does it as an extension. MXFP4 weights are never a tier for MiniMax: mlx-audio warns they drop or alter
requested words.

#### 4.7.5 The three offers and their licences

The offers, with their licence fields, `supports` and `limits` (other fields left out; the language lists are cut
short, the packages declare the full ones):

```json
{
  "id": "ace-step-1.5",
  "title": "ACE-Step 1.5",
  "default": true,
  "quality_tiers": ["draft", "standard"],
  "memory_class": "large",
  "speed_class": "fast",
  "license": {
    "spdx": "MIT",
    "commercial_use": true,
    "terms_url": "https://github.com/ace-step/ACE-Step-1.5/blob/main/LICENSE"
  },
  "notes": "Write the caption yourself and set language: the planner's own captions can drift off-topic or into the wrong language, and the base checkpoint sometimes skips verse lines. Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them.",
  "supports": {
    "languages": ["en", "zh", "ja", "ko", "es", "fr", "de", "it", "pt", "ru"],
    "instrumental": true,
    "reference": true,
    "edits": ["cover", "repaint", "extend"],
    "anchors": ["bpm", "key", "time_signature"],
    "timestamps": true,
    "sample_rate": 48000,
    "channels": 2
  },
  "limits": {"min_duration_s": 10, "max_duration_s": 600, "max_repaint_s": 90}
}
```

```json
{
  "id": "yue2-3b",
  "title": "YuE2 3B",
  "named_only": true,
  "quality_tiers": ["standard", "best"],
  "memory_class": "large",
  "speed_class": "slow",
  "license": {
    "spdx": "CC-BY-NC-4.0",
    "commercial_use": false,
    "terms_url": "https://huggingface.co/m-a-p/YuE2-3B/blob/main/LICENSE",
    "accepted_required": true,
    "notice": "YuE2-3B by M-A-P (huggingface.co/m-a-p/YuE2-3B), CC BY-NC 4.0. Non-commercial use only: don't sell, license or monetize songs made with it, or use them in paid or client work."
  },
  "notes": "Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them.",
  "supports": {
    "languages": ["en", "zh"],
    "score": "optional",
    "sample_rate": 48000,
    "channels": 2
  },
  "limits": {"max_duration_s": 360}
}
```

```json
{
  "id": "minimax-music3",
  "title": "MiniMax Music 3",
  "quality_tiers": ["standard", "best"],
  "memory_class": "xlarge",
  "speed_class": "standard",
  "license": {
    "spdx": "LicenseRef-MiniMax-Music3-Community",
    "commercial_use": true,
    "terms_url": "https://huggingface.co/MiniMaxAI/MiniMax-Music3/blob/main/LICENSE",
    "accepted_required": true,
    "notice": "Made with MiniMax-Music3 (huggingface.co/MiniMaxAI/MiniMax-Music3), under the MiniMax-Music3 Community License."
  },
  "notes": "Commercial use needs MiniMax's written authorization only above USD 20M aggregate yearly revenue from products that use it (licence §3.2). Anyone offering this engine as a hosted generation service must keep technical and organizational safeguards against infringing outputs (§4), and the acceptable-use policy asks that machine-generated content be disclosed in public settings. The best lyric adherence of the three; no reference audio, score or edits. Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them.",
  "supports": {
    "languages": ["en", "zh"],
    "instrumental": true,
    "sample_rate": 44100,
    "channels": 2
  },
  "limits": {"max_duration_s": 300}
}
```

The operation's own `limits.max_duration_s` is 600, the most any offer allows; each offer narrows it (RFC 0003 §6.4).

**ACE-Step 1.5: the commercial default.** The offer a client that names no model gets, at `draft` and `standard`.
- **`spdx: MIT`, `commercial_use: true`.** The weights' grant is the GitHub LICENSE, the HF card's licence tag and
  the card's own sentence on commercial use; the HF repos carry no LICENSE file, and the Oobleck VAE's initialisation
  isn't stated (survey §3.1). Both go in the package manifest, not the offer: MIT asks for nothing to be shown with a
  song, so the offer has no `notice`.
- **`notes`** carry the two things a client should know before it trusts the planner (survey §3.1): its own captions
  drift, so a client writes the caption and sets `language`; and the base checkpoint can skip lines. The covers line is
  the same as YuE2's, because the problem is the same for every music model.
- **`quality_tiers`** list `best` only when the operator installed the base or sft checkpoint.

**YuE2-3B: research only.** Unchanged from the decision of 2026-10-24 (AB-D-0073 reversed, AB-A-0200):
- **`named_only`.** Never chosen by default (Base §6 rule 2), so a client that names no model never gets a
  non-commercial song.
- **`accepted_required`.** The operator accepts the terms before first use. The text they accept should say the
  outputs are non-commercial, not only name the licence.
- **`commercial_use: false`.** A request with `policy.license: commercial-use` is refused with 422 `policy_unmet`
  (Base §10.3). A commercial client sends that policy by default, and drops it only in a mode the user chooses for
  personal, non-commercial work.
- **`notice`.** Running the model copies the weights, and CC BY-NC 4.0 §2(a)(1) licenses that only for
  non-commercial purposes. So the songs are non-commercial whoever runs the engine. MES keeps the weights out of the
  client, so a commercial client doesn't distribute them, but that doesn't make the songs commercially usable. A
  hosted engine making songs for paying users is commercial use. The notice also carries the attribution the
  weights' LICENSE asks for: YuE2, the model and its repo.
- **`notes`.** YuE2's model card promotes covers of existing songs, and a cover needs the original song's rights,
  which no model licence grants. That's usage guidance rather than the model's terms, so it goes in `notes` (Base §6
  rule 5).

**MiniMax Music 3: commercial, with a name to display.** The operator accepted the MiniMax-Music3 Community License
on 2026-10-24 (AB-D-0157): the USD 20 M revenue threshold, the UI display requirement and the hosted-service
safeguards duty.
- **`spdx: LicenseRef-MiniMax-Music3-Community`**, `terms_url` the HF LICENSE. The licence is MIT-shaped with
  conditions, and its lineage is permissive throughout (Qwen3-8B Apache-2.0, a stable-audio-tools DiT and a DAC VAE,
  both MIT).
- **`commercial_use: true`.** The licence grants commercial use. Its §3.2 threshold binds the operator's revenue,
  not each song, and the operator has accepted it; so a `policy.license: commercial-use` request may run here.
  `accepted_required: true` records that acceptance, as A-6 asks for every licence with a threshold.
- **`notice`** carries `MiniMax-Music3`, because §3.1 of the licence requires a commercial product that uses the
  model to display that name prominently. The notice is the text a client shows, so it is the display: a model
  picker line, a line with the result, a credit in an export. It names the model as the licence spells it.
- **`notes`** carry what binds an operator rather than a user: the §3.2 threshold, the §4 safeguards duty on anyone
  who hosts the engine as a service, and the acceptable-use policy's disclosure item. None of it changes a request,
  so none of it is `notice` (Base §6 rule 5).

**A-8 and A-9 when `commercial_use` is `true`.** §3.7's proposals keyed the duty to show a notice to
`commercial_use` not being `true`. MiniMax breaks that key: commercial use is allowed, and the one thing its licence
insists on is a displayed name. So A-8 and A-9 are revised (§3.7, §8):
- a client MUST show `license.notice` with a result whose provenance carries it, whatever `commercial_use` says, and
  the MCP text summary carries it; `notice` is reserved for text the terms require to be shown (an attribution, a
  display name, a non-commercial restriction), and advisory text goes in `notes`;
- the engine SHOULD write `spdx` and `notice` into the output file whenever a job's licences carry a notice or
  aren't all `commercial_use: true`.

For MiniMax, that puts `MiniMax-Music3` on the offer, on the MCP tool's model line (Base §15), on every result, and
in the file's tags. The engine operator's own UI shows it on the model's card (MESEngineUI), so the operator's
product meets §3.1 too.

**What the three have in common.** The covers sentence is in every `notes`, since no music licence grants rights
to a song someone else wrote. Every offer declares `sample_rate` and `channels`, so a client knows before it asks
what it will get. And every offer's weights stay in the engine: a client distributes none of them, whichever licence
applies.

### 4.8 `supports` keys (RFC 0003)

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `languages` | all | `[BCP 47]` | any | Gate: `language`. In `generate`, a Fact: the languages a prompt may be written in |
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
| `instrumental` | `compose` | boolean | `false` | Gate: a request without `lyrics` |
| `score` | `compose` | `unused` · `optional` | `unused` | Gate: the `score` input and `planning`. Fact: the `score` output |
| `reference` | `compose` | boolean | `false` | Gate: the `reference` input |
| `edits` | `compose` | `[kind]` | `[]` | Gate: `edit.kind`, and the `source` input |
| `sections` | `compose` | `[tag]` | the eight of §4.7.2 | Warn: `section_unsupported` |
| `anchors` | `compose` | `[field]` | `[]` | Warn: `anchors_ignored` |
| `timestamps` | `compose` | boolean | `false` | Warn: `timestamps_unavailable` |
| `sample_rate` | all | integer | — | Fact |
| `channels` | `generate`, `compose` | integer | — | Fact |

Limit fields: `max_text_chars`, `max_voice_ref_s`, and `max_duration_s`: an edit's input, a generated sound's
length, or a song's. For `compose` also `min_duration_s`, `max_lyrics_chars`, `max_reference_s`, `max_source_s` and
`max_repaint_s` (§4.7.3).

The Base keys `stream`, `seed` and `voices` apply too.

### 4.9 Warnings and helper roles

- **Warnings:**
  - `audio_resampled` and `audio_downmixed`;
  - `voice_ref_trimmed`: the reference was clipped to the model's limit;
  - `duration_missed`: `target_duration_s` wasn't met within the offer's tolerance;
  - `cue_unsupported`: a cue was removed;
  - `emotion_intensity_ignored`;
  - `song_truncated`, `section_unsupported`, `anchors_ignored` and `timestamps_unavailable` (§4.7.3).
- **Effective values:** a language the model detected, when the request named none, is reported as
  `effective.language`. A song reports `effective.duration_s` always, and `effective.anchors` and `effective.lyrics`
  when the plan changed them (§4.7.3).
- **Helper role:** `prompt_enhance`, as in Image, for a model that rewrites a voice description or an instruction.

### 4.10 Conformance ideas (AUDIO-nnn)

- Outputs report `sample_rate`, `channels` and `duration_s`, and the file agrees.
- Every MUST input type is accepted.
- `voice`, `voice_ref` and neither each route to an offer that supports them; two together are 400.
- A label, cue or edit kind the named model doesn't list is 422 for a gate key. An unsupported cue is removed, with
  `cue_unsupported`.
- `[pause 1s]` adds about a second of silence on every offer.
- `design_voice` returns `count` samples, each with its seed; the same seed reproduces a sample on a seeded model; a
  sample used as `voice_ref` with `effective.text` speaks.
- `generate` returns `count` sounds, each `duration_s` long to the frame, each with its seed; the same seed
  reproduces a sound; an unseeded request reports the seed it used.
- `compose` returns one song with `sample_rate`, `channels`, `duration_s` and its seed, and `effective.duration_s`;
  the same seed reproduces it; an unseeded request reports the seed it used; `edit` without `source` and `score`
  without `lyrics` are 400; a `score`, `reference` or `edit` sent to an offer without the key is 422
  `unsupported_parameter`; a request that names no model never gets YuE2-3B; a result from an offer whose licence has
  a `notice` carries that notice in the MCP text summary (A-8); an `extend` result is `before_s` + source + `after_s`
  long, to the frame.
- Streamed chunks concatenate to the final output, sample-exact (RFC 0002).
- An asset survives two jobs and is gone after `DELETE` (RFC 0001).

### 4.11 Later, and outside

- **Later (generative):**
  - `audio.speak_dialog`: two-speaker scenes, Dia2, with a structured `script` so clients never write `[S1]`.
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
| MOSS-SoundEffect v2.0 | 5.4 (int4) – 7.4 (bf16) + 18 GB, Pro chips and up | `generate` | Engine | Foley, ambience, creatures and actions from EN/ZH captions; up to 30 s; 48 kHz mono. Apache-2.0 |
| AuK / AuK-Flash | 7.8–12.9 + 1.5 GB | `edit_speech`, `speak` (clone), `design_voice` | Engine, `named_only` | The model for what `edit_speech` covers (§4.5). 0.5–30 s; en/zh; keeps the source length. Non-commercial (Qwen Research) |

### 5.2 Later

| Model | Resident | Operation | Why later |
|---|---|---|---|
| Dia2-2B | 4.5 + 3.0 GB | `speak_dialog`: two speakers, English, up to 120 s | Generative, but scenes aren't in the first set. `(laughs)` is accepted and rarely performed |
| ACE-Step 1.5 (turbo + 1.7B planner) | ≈18.7 GB bf16 peak (full tier), ≈12.5 GB (lite tier): estimated, from the arraypress MLX-Swift measurements on an M3 Max; no package yet (E25, V0 running) | `compose`, the default: caption and lyrics, reference audio, cover/repaint/extend, bpm/key/time-signature anchors, word timestamps; 10–600 s, 48 kHz stereo | Joins with its package (A-10). MIT, `commercial_use: true` (§4.7.5) |
| YuE2-3B | ≈8.5 GB bf16: estimated, no package yet (AB-T-0350) | `compose`, `named_only`: lyrics and a style caption to a song with vocals through an editable ABC score; up to 360 s, 48 kHz stereo | Non-commercial (CC BY-NC 4.0), `accepted_required` (§4.7.5) |
| MiniMax Music 3 | ≈28.5 GB bf16, ≈15 GB mxfp8: estimated, from the mlx-community shards; no package yet (AB-T-0351, queued behind E25) | `compose`: caption and lyrics; up to 300 s; stereo at 32 or 44.1 kHz (the port resolves which) | Community licence accepted (AB-D-0157): `commercial_use: true`, a `MiniMax-Music3` notice to display (§4.7.5). 32 GB Macs are the floor at 8-bit |
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
| MOSS-SoundEffect | With no seed, uses seed 0 (`MossSoundEffectPackage.swift:154`): every unseeded run of a prompt is the same sound | Image §2's convention: each result reports the seed it used | The adapter picks a seed and reports it |
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
| A-7 | What does Audio 0.1 cover? | **Decided:** generative only. Voice design, speech with a built-in or cloned voice, speech editing modelled on AuK, sound generation (non-verbal, MOSS-SoundEffect), and normalized emotions and nonverbal cues (§4). Tools later; STT and other interpretive models out |
| A-5 | Order: Audio before Video, or shared time conventions first? | Shared conventions in Base first (§7), then whichever profile has a client waiting |
| A-6 | Licences that allow commercial use only below a revenue or user threshold? | Add `commercial_use: "conditional"`, with the threshold in `notice`. `license: commercial-use` admits it only once the operator has accepted the terms (`accepted_required`). MiniMax Music 3 shows the accepted case: the operator accepted its threshold (AB-D-0157), so the offer declares `true` with `accepted_required` and the threshold in `notes` (§4.7.5). `conditional` is for a threshold nobody has accepted |
| A-8 | Must a client show a licence's notice with the result? | Yes, and not only for non-commercial licences: a MUST in Base §10.2 whenever a licence in `provenance` has a `notice`, and the MCP text summary carries it. A `notice` exists only when the terms require something shown; a non-commercial licence without one is shown as `spdx` and `terms_url` (§3.7, revised for MiniMax's display duty) |
| A-9 | Should the licence travel in the output file? | Yes: the engine SHOULD write the `spdx` id and `notice` into the file's metadata when a job's licences carry a notice or aren't all commercial, and MAY for every output (§3.7) |
| A-10 | Music: a `supports` key on `audio.generate`, or an operation of its own? And when? | **Decided (2026-10-24, AB-D-0158):** its own operation, `audio.compose` (§4.7), with ACE-Step 1.5 as the commercial default, YuE2-3B `named_only` and MiniMax Music 3 under its accepted community licence (§4.7.5). Schedule, recommended: it ships in Audio 0.1 if ACE-Step's engine package exists when the profile is published (E25), else as the first addition after. The operation is defined now so the MLXEngine music capability (AB-A-0201, AB-A-0202) maps onto it |
