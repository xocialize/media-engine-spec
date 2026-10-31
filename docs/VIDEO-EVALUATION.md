# Video readiness: MES and the fleet's video models

| | |
|---|---|
| **Date** | 2026-10-31 |
| **Spec** | Base 0.1, Image 0.1, Audio 0.1 (media-engine-spec v0.8.0) |
| **Models** | LTX 2.5 (`mlxengine-video-ltx/LTX_DEV/ltx-2-mlx-swift` v0.20.0, `MLXLTX25Package`), SeedVR2 (`mlxengine-video/PROD/mlx-seedvr2-swift` v0.10.1), FlashVSR (`mlxengine-video/WIP/mlx-flashvsr-swift` v0.2.0), RIFE (`mlxengine-video/PROD/mlx-rife-swift` v0.8.0) |
| **Engine contract** | MLXToolKit in mlx-engine-swift 0.73.0 (`TextToVideo.swift`, `VideoEdit.swift`, `VideoUpscale.swift`, `FrameInterpolate.swift`, `Artifacts.swift`, `Adapters.swift`, `RunProgress.swift`) |
| **Requirements** | Gaea PRD §10 (VID-1 to VID-6), Gaea Plan §5 G3 (orders 1 to 4), Engines-PRD §6 (VID-1 to VID-8), MES-PRD §8.4 |
| **Asked by** | gaea, AB-A-0235 (G3 order 1) |
| **Status** | Evaluation, taken up the same day: [Video 0.1](../spec/profiles/video.md) is drafted from its decisions (§9), and [RFC 0005](../rfcs/0005-video-in-base.md) carries the Base changes (B-1 to B-5). Where this document and the profile differ, the profile wins. |

Paths in this document are relative to `/Volumes/Satechi/Development` unless they start with `spec/`, `rfcs/` or
`schemas/`.

## Decisions (2026-10-31)

These are the choices that bind Gaea's plugins and that the ask left open. Each is argued in the section named, and
listed with the others in §9.

- **Five operations** (§5.1): `video.generate` (text, a first and/or last frame, keyframes at times, a soundtrack to
  follow), `video.extend`, `video.retake`, `video.upscale` and `video.interpolate`. Instruction edits, talking heads and
  character animation come later.
- **Requests speak seconds, results speak frames** (§5.3). A request asks for `duration_s`, keyframe times,
  `start_s`/`end_s` and `after_s`; the engine maps them to the model's frame grid (LTX's 8k+1) and reports the frames
  it made. A snap warns.
- **Audio inside a video** (§5.4): an output carries at most one audio track. Its `sample_rate` and `channels` appear on
  the output exactly when it has one. `audio: false` asks for a silent output. A `soundtrack` input is the track the
  picture follows, and it is the output's audio, unchanged. Operations that transform a video keep its audio: the
  engine remuxes the source's track, because none of SeedVR2, FlashVSR or RIFE passes it through. Audio inputs follow
  Audio §1.1 and §1.3. Video output doesn't stream in 0.1.
- **The wire form is a container** (§5.2): `video/mp4` with H.264 or HEVC and AAC, which engines MUST accept, and
  `video/quicktime`, which they SHOULD. No image sequences in 0.1. How Gaea moves frames between its host and a
  plugin is GPP's business; the packages decode containers themselves, so passing the file through is cheapest.
- **Licences** (§4.3, §4.4): Base takes A-8 and A-9 for every profile (a `notice` is shown with every result; `spdx`
  and `notice` go into the file). A new licence flag, `user_accept_required`, says the terms bind each person who uses
  the model through a client. Such an offer runs only for a request whose `policy.accepted` lists its `spdx`, which a
  client sends once its user has seen and accepted the terms. The LTX-2 Community Licence requires exactly this of a
  host (§1.1.7). The operator's own acceptance at first enable stays `accepted_required` (VID-6).
- **AI-content disclosure** (§4.5): Video outputs of generative operations MUST say in the file that they are
  AI-generated, and every operation MUST keep a marking, watermark or provenance record its input carries. Base
  says SHOULD for every profile.
- **LTX's tiers are offers** (§6.1): one model offer per installed tier, each with its own limits and supports, so a
  client sees that compact24 takes no keyframes and max128 goes to 1920×1088. Gaea's lanes stay its own; the profile
  only needs each offer to tell the truth.
- **Previews are frames** (§5.8): `job.preview` gains `at_s` and `frame`, and a `previews` Fact on offers. No package
  emits previews today, so the field is ready for when one does.

## Summary

- **The four models fit MES as batch jobs.** Base already has the `video` kind, `fps` and `duration_s` on outputs,
  `max_duration_s`, `phase`/`step`/`media_s` progress, per-offer `supports` and `limits`, adapters with `ic` slots, and
  the audio facts Audio added. What's missing is a **Video profile** (§5) and five small Base changes (§4).
- **Base gaps** (§4):
  1. **B-1** No frame count on outputs. A video's length is its frames; `duration_s` × `fps` rounds.
  2. **B-2** `job.preview` has no schema and no time: a video preview needs to say which moment it shows.
  3. **B-3** Licence notices with results (A-8) and in files (A-9) are Audio-only. LTX makes them a requirement for
     video too, and Image has needed them since its research offers.
  4. **B-4** Nothing lets an engine know that a client's user accepted terms that bind users, as the LTX licence's
     hosting clause demands.
  5. **B-5** Nothing says an engine keeps AI-content markings an input carries.
- **The packages need engine-side normalization** (§7), as every audio package did:
  - LTX clamps an oversize request instead of refusing it;
  - LTX silently falls back from image-to-video to text-to-video without a VAE encoder;
  - LTX can't turn audio off;
  - LTX takes keyframes as frame indices through `metaData`;
  - LTX ignores `negativePrompt`, `steps` and `guidanceScale`;
  - SeedVR2, FlashVSR and RIFE drop audio and write HEVC with a software encoder that can stall;
  - RIFE discards variable-frame-rate timing, and downloads its own weights outside the engine's weight sourcing.
  None of this blocks the profile: each is a rule the engine applies, a fact an offer declares, or a small ask of
  MLXEngine (§8).
- **The cheapest real job fits `--job-timeout`.** LTX compact24 makes 256×256×9 in 24 s of generation (61.5 s wall
  with load) on a 24 GB M5 Pro; SeedVR2 at a 128² input ×2 runs about 0.3 s a frame; RIFE is sub-second at small sizes.
  The VIDEO tests ask for 256×256, 9 frames, 24 fps, each offer's cheapest tier, and a 128×96, 17-frame fixture
  (§5.11).

## 1. The fleet's video models

### 1.1 LTX 2.5 (`MLXLTX25Package`)

`MLXLTX25Package` holds the 2.5 manifest and hands `load`, `run` and `unload` to the 2.3 class `MLXLTX2Package`
(`ltx-2-mlx-swift/Sources/MLXLTX2/MLXLTX25Package.swift:164-194`). Its behaviour is that class's.

#### 1.1.1 Modes

| Mode | How it's asked today | Notes |
|---|---|---|
| Text to video | `T2VRequest` (`prompt`, `width`, `height`, `numFrames`, `fps`, `seed`) | Two-stage on standard64 and max128, one-stage on compact24 and balanced32 (`MLXLTX2Package.swift:427-430`) |
| First frame | `T2VRequest.initImage` | Always one-stage at the target size, strength 1.0 (`MLXLTX2Package.swift:399-406`). The image is aspect-filled and centre-cropped (`ImageInput.swift:62`). **Without a VAE encoder installed it silently becomes text-to-video** (`Sources/LTX2/LTX2Pipeline.swift:883`) |
| Keyframes, last frame | `metaData["kf.keyframes"]`: `[{path, frame, strength = 1.0}]` | At most 5 (`KeyframeMetaKeys.swift:39`). `frame` is a pixel-frame index above 0; frame 0 is `initImage`. Paths, not bytes. **Two-stage only:** refused with `configurationMismatch` on compact24 and balanced32 (`MLXLTX2Package.swift:417-423`) |
| Audio to video | `T2VRequest.initAudio` (contract 1.40.0; gated by `T2VControls.supportsInitAudio`, which 2.5 declares at `MLXLTX25Package.swift:141`) | Any AVFoundation-readable file. Decoded to 16 kHz stereo for conditioning (`AudioInput.swift:33-48`). The clip is the track's length unless asked, capped by the tier; a longer track is cut, a shorter one zero-padded (`VideoEditRun.swift:209-222`). **The original track goes into the output unchanged, re-read at 48 kHz** (`VideoEditRun.swift:253-264`). Sizes snap down to /64 (`RunStagePlan.swift:334`). Runs two-stage whenever an encoder and upsampler are installed, ignoring a one-stage tier (`AudioToVideo.swift:82-88`) |
| Retake | `VEditRequest`, modes `replace_video`, `replace_audio`, `replace_audio_and_video` (default); `metaData["retake.start"]`, `["retake.duration"]` in seconds | One-stage at the source's size (`VideoEditRun.swift:114-127`). Tokens whose start falls in the span are made again; a modality whose mask is empty stays frozen (`Retake.swift:22-41, 108-117`). `replace_video` keeps the source's audio. **No check that the span lies in the clip** |
| Extend | `VEditRequest` mode `extend`, `metaData["extend.seconds"]` | **Forward only** (`VideoEditRun.swift:104-112`). New frames = round(seconds × fps), the total snapped to 8k+1; the new region is regenerated and **blends 0.5 s back into the source** (`Retake.swift:164-190`). **The extended total isn't re-checked against the tier's frame cap** |
| IC-LoRA | `metaData["ic.adapterId"]`, `ic.referencePath`, `ic.referenceStrength`, `ic.adapterStrength`, `ic.dubAudioPath` | One stage at the target size (`MLXLTX2Package.swift:313-357, 393-398`). A reference is a still or a clip, built at the output size divided by the adapter's `referenceDownscale` |

The `metaData` keys exist "because `VEditRequest` has no canonical time-span field yet" (`VideoEditRun.swift:13-17`).
DFR long clips, outpainting, the duration head, the DiffVAE decoder and prompt enhancement aren't reachable from a
request (enhancement is a separate package, `GemmaTextGenerator+Export.swift:6-11`). `referenceImages` is never read,
though a non-empty one on T2V still switches to the conditioned size limit (`MLXLTX2Package.swift:271`).

#### 1.1.2 Parameters and grids

- **Ignored:** `negativePrompt`, `steps`, `guidanceScale` and `mode` on T2V, and the engine-level `adapters`. The
  model runs distilled with a positive prompt only, so CFG is 1 (`AudioToVideo.swift:100`).
- **Steps** are fixed: 8 in stage one, 3 more in stage two (`Sources/LTX2/Positions.swift:19-23`).
- **Defaults:** 704×512, 9 frames, 24 fps (`RunStagePlan.swift:199, 255`).
- **Sizes:** at least 64; snapped **down** to multiples of 32, or 64 on two-stage tiers (`RunStagePlan.swift:222-243`).
  Over-size requests are **clamped, not refused**.
- **Frames:** generation takes F = ⌈frames / 8⌉ latent frames and delivers 8F − 7, so a request for 24 frames gets
  17 (`RunStagePlan.swift:246-249`); a request already on the 8k + 1 grid (9, 17, 25, …) gets exactly that. Edits
  floor to 8k + 1, at least 9 (`RunStagePlan.swift:350`). Either way a clip is 8k + 1 frames, and an engine that
  passes the snapped count gets what it reports.
- **fps:** any `Double`, no allowed list. The MP4 frame duration is round(600 / fps) on a 600 timescale
  (`FrameCodec.swift:193`), so awkward rates are quantised.
- **Seed:** `UInt64`; nil leaves the generator unseeded (`LTX2Pipeline.swift:764`).
- **Prompt:** tokenised to 1024; on overflow it keeps the **last** 1024 tokens (`GemmaEncoder.swift:88-96`).
- **Output:** MP4, H.264 through VideoToolbox, 32BGRA in, no profile setting (`FrameCodec.swift:144-172`). No HEVC.
  Audio is AAC, 48 kHz, stereo, 192 kbps (`FrameCodec.swift:179-181`), included whenever the audio VAE and vocoder are
  installed (`LTX2Pipeline.swift:247, 427`). **There is no per-request switch to turn audio off.**
- **Edit sources:** any AVFoundation container; fps from the request, else the track's nominal rate, else 24; size
  from the source, never upscaled, snapped down to /32 and capped at the conditioned envelope; length from the
  container duration (`RunStagePlan.swift:282-358`). Missing source audio is tolerated.
- **Geometry preview:** `resolvedGeometry(...)` gives the exact output size before a run, which an engine can use to
  warn `size_snapped` honestly.

#### 1.1.3 Tiers

| Tier | Max size × frames (t2v / conditioned) | Path | Setup | Measured peak |
|---|---|---|---|---|
| compact24 | 704×512×121 / 512×288×121 | one-stage | int8 DiT streamed (pinned), int8 Gemma encoder, lean decoder | 14.5 GB t2v; 16.9–17.2 GB i2v at 704×512 |
| balanced32 | 576×320×161 | one-stage | as compact24, decode window 6 | 15.4 GB t2v / 17.1 GB i2v |
| standard64 | 1280×704×161 | two-stage | int8, streaming optional | 19.4 GB at 704×512×161; 33.6 GB at 1280×704 |
| max128 | 1920×1088×481 | two-stage | bf16 streamed (pinned), decode tiling | 74.4 GB at 1080p×481 |

Envelopes: `LTX2Configuration.swift:42-73, 142-176, 786-813`; peaks: `probes/tier25-matrix/README.md` (AB-R-0106).
The manifest declares bf16 40 GB resident + 6 GB activation and int8 23 + 5 GB, no int4, macOS 26, chip floor `.max`
(`MLXLTX25Package.swift:83-121`). bf16 streaming needs storage of about 1 GB/s (`minSustainedReadBytesPerSecond`) or
the GPU watchdog fires. Gaea's VID-3 runs the tiers as lanes chosen by memory.

#### 1.1.4 Timings

| Tier | Geometry | Machine | Generation | Source |
|---|---|---|---|---|
| compact24 | **256×256×9** | M5 Pro 24 GB | **24.0 s** (61.5 s wall with load and warm-up); i2v 29.3 s | `probes/pruna-m5pro-24gb/logs/smoke-pruna-256x256x9.full.log:12` |
| compact24 | 512×288×121 | Mac Studio M5 Max | 65–67 s | `probes/tier25-matrix/compact24-t2v-rep*.log` |
| compact24 | 704×512×121 | M5 Pro 24 GB | 149.9 s (i2v 174.9 s) | `probes/pruna-m5pro-24gb/envelope-704x512/README.md:39` |
| balanced32 | 576×320×161 | M5 Max | 108–119 s | tier25-matrix |
| standard64 | 704×512×161 | M5 Max | 143–147 s | tier25-matrix |

The 256×256×9 figure is one smoke run. The peak stays near 14.5 GB at any size because the text encoder sets the
floor: a small clip saves time, not memory.

#### 1.1.5 Adapters

- **Plain LoRA:** `metaData["loraId"]`, optional `["loraStrength"]`, **one at a time**, swapped on the loaded DiT
  (`MLXLTX2Package.swift:226-253`). Files come from Hugging Face on first use (gated repos need `HF_TOKEN`).
- **The i2v adapter** (4.93 GB) is not applied automatically; the host passes it as `loraId`, and its download inside
  `run()` reports no progress (`RunStagePlan.swift:79-85`).
- **IC-LoRA** registry (`Sources/MLXLTX2/Resources/ltx-lora-registry.json`): `union-control` (pose, depth and canny in
  one adapter, chosen by which control video you feed it, at half resolution), `ingredients` (a reference sheet,
  strength 1.4), `lipdub` (a reference video plus dub audio) and `cameraman-v2` (research-only, non-commercial).
  Selecting an IC adapter as a plain `loraId` throws (`MLXLTX2Package.swift:233-237`).
- Typed adapters through MLXToolKit (contract 1.53.0, AB-A-0197) are still open; the package ignores
  `T2VRequest.adapters`.

#### 1.1.6 Progress, cancellation, determinism

- **Phases:** `encode` (48 encoder layers), `denoise` (per step, stage 1/2 on two-stage), `upsample` (a marker),
  `decode` (per window, the total known at run time) and `postprocess` (the mux) (`RunStagePlan.swift:66-148`).
- **No preview frames, no latent previews.**
- **Cancellation** is checked per denoise step, decode chunk and encoder layer: about 1.1 s steady state, 17–21 s at
  worst inside one long step (`MVP-READINESS.md:95-97`).
- **Determinism:** bf16 with a seed is bit-identical; int8, the default on three tiers, spreads by about 3.5e-3
  (`BENCH.md:50`).

#### 1.1.7 Licence

Code Apache-2.0. Weights under the **LTX-2 Community License** (`mlxengine-video-ltx/LTX_DEV/ltx-2-upstream/LICENSE`):
- **Acceptance by use** (line 5). The engine itself has no acknowledgement gate.
- **Revenue threshold:** an entity with $10M or more in annual revenue needs a paid commercial licence (line 87).
- **Hosting and redistribution (§3, line 114 on):** the use restrictions of Attachment A and §4 must be passed on as
  enforceable terms, a full copy of the licence supplied, modified files marked, attribution kept. **Users must comply
  too** (line 156).
- **Outputs:** Lightricks claims no rights in them (line 159).
- **AI-content disclosure:** content must not be presented without expressly saying it is machine-generated
  (Attachment A item 5, line 313).
- **Non-compete:** no use in products that compete directly with Lightricks' own (item 20, line 377).
- Community LoRAs carry their own terms ("unspecified-community"; research-only for `cameraman-v2`).

A server that hosts LTX for other people's clients is a host in §3's sense. That is what B-4 (§4.4) answers.

### 1.2 SeedVR2 (`SeedVR2UpscalePackage`)

- **Surfaces:** `imageUpscale` and `videoUpscale` (`SeedVR2UpscalePackage.swift:72-79`).
- **Scale 2 or 4 only**, default 2; anything else throws `unsupportedScale` (`:169-170`). The model is 1:1: a CoreImage
  Lanczos pre-upscale, then a one-step diffusion refines it tile by tile (README:5-9).
- **Parameters:** seed (default 0, deterministic per seed), `colorCorrect` (LAB wavelet, on), tiles 256 with 32
  overlap, `temporalWindow` 9 (1 or 4k + 1, rounded down). **No frame-count rule on the input:** a ragged tail is
  padded and trimmed. A scene cut ends a window early. Any input size works; **output is exactly input × scale**.
- **Timing:** source PTS kept (`:206, :228`); the response echoes the source's duration and fps.
- **Variants:** int8 (default, 4.72 GB) and fp16 (8.44 GB); int4 excluded. Declared 4.8 GB resident + 4.5 GB
  activation, chip floor `.pro`. The temporal path measures more: 7.8 to 13.5 GiB for T = 1 to 13 on one 256² tile,
  plus about 0.8 GiB per extra tile (`:252-277`).
- **Speed:** about 0.31 s a frame for a 128² input ×2 at T = 9 (`mlxengine-todo/probes/v12s_streaming_memory.out:333`);
  8.3–8.7 s a frame for 320×192 → 1280×768 (`mlxengine-forge/Docs/FLASHVSR-SPIKE.md:143`).
- **Progress: none** (profiler regions only). Cancellation per frame and tile.
- **Licence:** code MIT, weights Apache-2.0 (ByteDance-Seed). Commercial use allowed; nothing to show.

### 1.3 FlashVSR (`FlashVSRUpscalePackage`, WIP)

- **`videoUpscale` only.** Scale 4 (native, default) or 2 (the same model on a ×2 bicubic input).
- **Live action only:** it invents texture on anime, graphics and bokeh (README:9-15).
- **Parameters:** seed, `topkRatio`, `localRange` 11, `colorFix` on, bf16 or fp32. Any input size (padded to /128 and
  cropped back). Every input frame gets one output frame; clips under 25 frames still pay for a first chunk of 21.
  Source PTS kept.
- **Refuses outputs above 1920×1152 (bf16) or 1280×768 (fp32) before loading**, reading the size from the `tkhd` box
  (`FlashVSRConfiguration.swift:113-151`).
- **Memory:** bf16 3.5 GB weights; peaks 9.2 GB at 640×384 out, 19.1 GB at 1280×768, 33.7 GB at 1920×1152.
- **Speed:** 0.72 s a frame end to end at 1280×768; 2.05–2.14 s at 1920×1152 (`PORTING-SPEC.md:142-149`).
- **Progress:** `upsample` steps in bursts of 21 then 8. One chunk is uninterruptible.
- **Determinism:** reproducible per seed on one machine, but hard top-k makes it unstable to tiny input changes
  (`PORTING-SPEC.md:216-222`).
- **Licence:** code and weights Apache-2.0; `NOTICE` credits FlashVSR, DiffSynth-Studio, Wan2.1 and TAEHV.

### 1.4 RIFE (`RIFEInterpolatePackage`)

- **`frameInterpolate`**, a video in; integer `factor` 2–8, default 2 (`:99-100`). The model takes any timestep, but the
  request has none, and no target fps.
- **Output:** N source frames become (N − 1) × factor + 1, each source frame followed by its in-betweens, the last
  frame at the end (`:146, :172`). Timing is uniform at source fps × factor: **source PTS and VFR are discarded**.
- **No seed** (deterministic). Tiling above 1920×1080; frames padded to /64 internally.
- **Memory:** about 21 MB of weights; 0.8 / 2.4 / 3.9 GB at 360p / 720p / 1080p.
- **Speed:** 0.32 s an output frame at 1080p ×2 (`MLXEngine/mlx-engine-swift/docs/model-registry.md:184`).
- **Weights come through its own `HubApi` download, not the engine's weight sourcing** (`:73-77`).
- **Progress:** download only, no run progress. Cancellation per frame.
- **Licence:** MIT.

### 1.5 What the three non-generative packages share

From `frame-stream-native` (`NativeFrameStream.swift`), which all three use:
- **Containers mp4/mov/m4v/qt only**; anything else is `unsupportedContainer`.
- **"Video-only by design": audio is never passed through.**
- **Output is HEVC in MP4, tagged BT.709**, from 32BGRA, on the software encoder by default because the hardware one
  stalls after MLX work; a stall surfaces as `encoderStalled` after 90 s.
- A cancelled or failed run leaves no partial output; one response at the end.

## 2. MLXToolKit's request types

| Type | Fields | Missing for a profile |
|---|---|---|
| `T2VRequest` (`TextToVideo.swift:11-83`) | `prompt`, `negativePrompt?`, `initImage?`, `referenceImages?`, `initAudio?` (declaration-gated), `numFrames?`, `fps?`, `width?`, `height?`, `steps?`, `guidanceScale?`, `seed: UInt64?`, `adapters`, `mode?`, `metaData` | Keyframes and a last frame (in `metaData`, as frame indices and paths); a switch for audio |
| `VEditRequest` (`VideoEdit.swift:9-64`) | `video`, `prompt`, `referenceImages?`, `negativePrompt?`, `width?`, `height?`, `numFrames?`, `fps?`, `steps?`, `guidanceScale?`, `seed?`, `adapters`, `mode?`, `metaData` | A time span (retake, extend), which modality to retake; all in `metaData` |
| `VideoUpscaleRequest` (`VideoUpscale.swift:7-23`) | `video`, `scale: Int?`, `mode?`, `metaData`; response `appliedScale` | `content` (live action or drawn), which VID-4 requires |
| `FrameInterpolateRequest` (`FrameInterpolate.swift:8-24`) | `video`, `factor: Int?`, `mode?`, `metaData`; response `appliedFactor` | A target fps or timestep |
| `Video` (`Artifacts.swift:124-138`) | `format: mp4 \| mov`, `data`, `durationSeconds?`, `frameRate?` | Width, height, frame count, audio facts |

- **Progress** (`RunProgress.swift:14-83`): an open phase vocabulary (`encode`, `denoise`, `upsample`, `decode`,
  `generate`, `postprocess`), with `step`/`totalSteps` and LTX's `stage`/`totalStages`.
- **Streaming** (`Streaming.swift:34-39`) carries `TTSStreamChunk` only. **No frame streaming or previews for video.**
- **Capabilities** `talkingHead` and `characterAnimation` exist (`Capability.swift:38, 65`) with no fleet model in
  this evaluation; they are later operations (§5.12).

## 3. Requirements

- **Gaea PRD §10:** VID-1 every Video operation; VID-2 LTX text-, image- and audio-to-video with 48 kHz audio, first and
  last frame plus keyframes, retake and extend, LoRA and IC-LoRA as adapters; VID-3 LTX tiers as lanes, compact24 to
  max128, within budget on 32, 64 and 128 GB Macs; VID-4 SeedVR2 and FlashVSR, **`content` required and a refused tier
  never swapped**; VID-5 RIFE; VID-6 **the LTX licence ships with the plugin, is shown when LTX is first enabled, and
  outputs keep their AI-content disclosure**.
- **Gaea Plan G3:** order 1 is this profile; order 2 says GPP's canonical input is MP4 with H.264 or HEVC and AAC,
  **"outputs report frames, frame rate, size and audio facts"**, frame previews go through the existing preview path;
  order 3 checks input lengths and sizes against offer limits. Plan §6.1 leaves the spool's frame transport to the
  profile.
- **Engines-PRD §6:** VID-2 "up to 5 keyframes"; VID-5 SeedVR2 2×/4× for drawn or unspecified content, FlashVSR live
  action only, ≤ 1920×1152; VID-6 RIFE any factor, tiled to 4K; VID-7 HEVC or H.264 at a quality floor; VID-8 the
  full licence shown on first enable, AI-content disclosure on outputs, "watermarks and provenance are never removed".
- **MES-PRD §8.4:** generate (prompt, duration_s, fps, size/aspect, keyframes, audio), extend (video, prompt,
  duration_s), retake (video, span, prompt), upscale (video, scale, content "never guessed"), interpolate (video,
  "factor or target fps").

## 4. What Base already handles, and its gaps

Base has, since v0.7.0: the `video` kind; `width`, `height`, `duration_s`, `fps`, `sample_rate`, `channels` on
outputs; `max_width`, `max_height`, `max_megapixels`, `max_duration_s` in limits; `phase`, `step`, `steps`, `media_s`
in progress; per-offer `supports` and `limits` with Gate, Warn and Fact classes; adapters with `ic` slots of any
kind; the `previews` feature; assets. AUDIO-EVALUATION §7 asked for time to live in Base first; it does.

### 4.1 B-1: frames on outputs

A clip's length is a frame count. `duration_s` × `fps` is a float product that rounds differently in different
clients (9 frames at 24 fps is 0.375 s; at 23.976 fps it isn't a round number at all), and LTX's grid is in frames.
**Proposal:** outputs gain `frames`, the number of video frames, for `video` outputs. And for a `video` output,
`sample_rate` and `channels` describe its audio track and are present exactly when it has one, so a client can tell a
silent clip from one with sound without opening it (Plan G3 order 2).

### 4.2 B-2: previews with a time

`job.preview` is `{media_type, href | data}`, without a schema. A video preview is a still of one moment, or a
proxy of the clip. **Proposal:** a schema for `job.preview`'s data, with optional `output` (which output it previews),
`at_s` (the moment in that output a still shows) and `frame` (its index). A preview is advisory: no client may rely
on its bytes being in the result.

### 4.3 B-3: licence notices for every profile (A-8, A-9)

Audio §1.12 adopted A-8 (a `notice` is shown with every result whose provenance carries it, whatever
`commercial_use` says) and A-9 (the engine writes `spdx` and `notice` into the file), and proposed them for Base. LTX's
licence makes them a requirement for video (§1.1.7), and Image's research offers have needed them all along.
**Proposal:** Base §10.2 takes both, with a table of where each format MES lists keeps them: WAV, FLAC and Ogg, MP3,
**MP4 and QuickTime** (the copyright item, `cprt` or `com.apple.quicktime.copyright`, and the comment item, `©cmt` or
`com.apple.quicktime.comment`), PNG (`iTXt` `Copyright` and `Comment`) and JPEG (EXIF `Copyright` and
`UserComment`). Audio §1.12 then points to Base.

### 4.4 B-4: terms a client's user must accept

The LTX licence binds everyone who uses the model, and requires a host to pass its use restrictions on as enforceable
terms with a full copy of the licence (§1.1.7). Gaea is that host for every client on the LAN. Base §10.2 has two
licence flags, and neither reaches the person at the client:
- `notice` is text a client shows. Showing isn't accepting, and an engine can't tell whether it was shown.
- `accepted_required` is the **operator's** acceptance before first use. That is VID-6's "shown when LTX is first
  enabled", and it stays. It says nothing about the people using the operator's engine.

Options:
1. **Clients SHOULD ask their users to accept.** Unenforceable; a client written from the spec alone wouldn't know
   it had to.
2. **A licence flag, and the request says it was accepted.** `license.user_accept_required: true` means the terms bind
   each user. A client shows the `notice` and `terms_url` to its user, records the acceptance, and sends
   `policy.accepted: ["<spdx>"]` with that user's requests. The engine runs such a model, adapter, helper or voice only
   for a request whose `policy.accepted` lists its `spdx`, and treats one that doesn't like any other policy miss:
   with no model named it chooses an offer the policy allows, and a named one is 422 `policy_unmet`, with `reason:
   "terms_not_accepted"` and the `param` `policy`.
3. **Per-client acceptance at pairing.** Couples licences to pairing; `open` mode has no pairing, and acceptance is a
   person's, not a device's.

**Recommendation: option 2.** It reuses the policy machinery every engine already has (§10.3), makes the obligation
discoverable from the descriptor, and an engine that serves LTX can show the licence's own §3 compliance: no
request runs on it unless the client said its user accepted. An agent over MCP passes the same `policy.accepted`; the
person who configured the agent is the user who accepted. A client that never shows terms simply can't use those
offers, and learns why from the refusal.

### 4.5 B-5: AI-content markings travel

LTX requires disclosure that content is machine-generated (§1.1.7); Engines-PRD VID-8 says watermarks and provenance
are never removed; Gaea VID-6 says outputs keep their AI-content disclosure. An upscale or interpolation re-encodes
every frame and, done naively, drops every metadata item and any provenance manifest. **Proposal:** Base §10.2 says an
engine SHOULD mark what a generative operation makes as AI-generated, in the file, and MUST NOT remove an AI-content
marking, a watermark or a provenance manifest (such as C2PA) that an input carries: when it transforms that input, it
carries them into the output where the format allows. The Video profile makes the marking a MUST for its generative
operations (§5.9).

### 4.6 What Base doesn't need

- **Streamed video.** Base streams `audio` outputs only. Video previews (B-2) cover "show me something while it
  runs"; fragmented-MP4 streaming waits for a model that makes frames in order fast enough to watch, and none does.
- **Image sequences on the wire.** The packages take containers; no client asked for frame folders (§5.2).
- **`commercial_use: conditional` (A-6).** LTX's $10M threshold is the same case as MiniMax Music 3's: the operator
  accepts the terms at first enable (`accepted_required`), and on that basis the offer declares `commercial_use: true`
  with the threshold in its `notice` (AUDIO-EVALUATION §4.7.5, AB-D-0157). A-6 stays open for a threshold nobody has
  accepted.

## 5. The Video profile

### 5.1 Operations

| Operation | Inputs | Parameters | Output | Required behaviour |
|---|---|---|---|---|
| `video.generate` | `prompt` (text, required); `first_frame` (image, 0–1); `last_frame` (image, 0–1); `keyframes` (image, 0–n); `soundtrack` (audio, 0–1); `references` (image, 0–n); `control` (video, 0–n) | `negative_prompt`, `duration_s`, `fps`, `size` / `aspect` + `resolution`, `keyframe_times`, `audio`, `seed`, `quality`, `output`, `prompt_enhance` | `video` | A clip from text, fixed frames and a soundtrack |
| `video.extend` | `video` (required); `prompt` (text, required) | `after_s`, `before_s`, `negative_prompt`, `audio`, `seed`, `quality`, `output`, `prompt_enhance` | `video` | `before_s` + the source + `after_s` |
| `video.retake` | `video` (required); `prompt` (text, required) | `start_s`, `end_s` (both required), `retake`, `negative_prompt`, `seed`, `quality`, `output`, `prompt_enhance` | `video` | The span made again, the rest kept |
| `video.upscale` | `video` (required) | `scale`, `content` (required), `seed`, `quality`, `output` | `video` | Exactly the input's size × `scale`, same frames |
| `video.interpolate` | `video` (required) | `factor` / `fps`, `seed`, `quality`, `output` | `video` | (N − 1) × factor + 1 frames, every source frame kept |

Why these inputs:
- **`first_frame` and `last_frame` are inputs of their own**, not keyframes at 0 and the end: image-to-video is the
  common case, it is LTX's `initImage` (frame 0 is refused as a keyframe), and a form gets one well per role.
- **`keyframes` with `keyframe_times`**, one time per image, in seconds: what VID-2 and §8.4 ask for ("keyframes at
  times"); the engine maps each to a frame.
- **`soundtrack`** rather than `audio`, because the MCP binding puts inputs and params in one schema and `audio` is the
  parameter (§5.4).
- **`references`** are subject references (`T2VRequest.referenceImages`, gated by `supports.references`), and image
  slots of `ic` adapters. **`control`** fills `video` slots of `ic` adapters (a pose, depth or edge clip for
  `union-control`). An adapter's `audio` slot (`lipdub`'s dub audio) takes the `soundtrack`.
- **`prompt` is required for extend and retake**: a text-conditioned model has nothing else to go on, and `VEditRequest`
  requires one.

### 5.2 Containers and codecs (V-4)

- Inputs: engines MUST accept `video/mp4` with H.264 or HEVC video and, where there's sound, AAC; they SHOULD accept
  `video/quicktime`. Image inputs follow Image §1.1, audio inputs Audio §1.1.
- Outputs default to `video/mp4`, in the codec the engine writes (LTX: H.264; the frame-stream packages: HEVC).
  `output: {media_type, codec}` asks for another (`codec`: `h264` or `hevc`); one an engine can't give is 422
  `unsupported_parameter`, and the descriptor's `output` lists only what it can.
- **Gaea's spool** (Plan §6.1): the packages decode containers with AVAssetReader and write them with AVAssetWriter, so
  the cheapest path between host and plugin is the file itself. Raw frames are for a plugin whose package takes frames;
  none does yet. This is GPP's choice, not the profile's.
- **Colour:** SDR, BT.709, 8-bit, which is what every package writes. Other inputs are converted with
  `color_converted`. HDR waits for a model that keeps it.
- **Timing:** frame-based operations treat a clip as constant frame rate. An input with variable timing is retimed to
  its nominal rate with `video_retimed` (RIFE discards PTS anyway).

### 5.3 Time, frames and grids (V-3)

- **Requests speak seconds; results speak frames.** `duration_s`, `keyframe_times`, `start_s`/`end_s`,
  `after_s`/`before_s` are seconds; `effective` reports `duration_s`, `fps`, `size` and `frames`, and the output
  reports `frames`, `fps` and `duration_s` = `frames` / `fps`.
- **Grids** are Facts: `supports.frame_step` (`{multiple, offset}`: frames = k · multiple + offset; LTX `{8, 1}`) and
  `supports.size_step` (LTX 32; 64 on two-stage tiers). An engine snaps to the nearest admissible value within the
  offer's limits and warns `duration_snapped` or `size_snapped`; it never exceeds a limit to honour a request, and
  refuses a request no admissible value is near (LTX clamps today; the engine refuses instead, §7).
- **Keyframes** go to the frame nearest their time; one moved more than half a frame by the grid warns
  `keyframe_moved`. Times outside (0, duration) are 400: the first and last frames have inputs of their own.
- **Defaults** are the model's, reported: LTX's 704×512, 9 frames, 24 fps.

### 5.4 Audio inside a video (V-2)

This is the choice that binds plugins most, so it is spelled out:

1. **One track.** A video output carries at most one audio track, AAC in MP4 and QuickTime. Its facts are the output's
   `sample_rate` and `channels`, present exactly when it has a track (B-1). A model that makes sound declares
   `supports.audio` with `sample_rate` and `channels` Facts (LTX: 48 000, 2).
2. **`audio`** (boolean) asks for sound or silence. Absent: the offer's default, which is sound where the model makes
   it or the source has it. `false`: the engine leaves the track out (remuxing, since LTX can't switch it off).
   `true` on `generate` needs `supports.audio` or a `soundtrack`.
3. **`soundtrack`** is the track the picture follows (LTX audio-to-video), gated by `supports.soundtrack`. **It is
   the output's audio, unchanged** apart from fitting the clip: without `duration_s` the clip is the track's length
   (on the grid, within limits); with it, the track is cut or padded with silence, with `soundtrack_fitted`. This is
   what LTX does (§1.1.1) and what a music video or a dub needs.
4. **Transformations keep audio.** `upscale` and `interpolate` carry the source's track unchanged (copied, not
   re-encoded, where the container allows). **The engine does this**, since none of SeedVR2, FlashVSR or RIFE passes
   audio through. `extend` keeps the source's track under the source and puts the model's sound, or silence, under the
   new part. `retake`'s `retake` says what is made again: `picture` (the default for an offer without sound),
   `sound`, or `both`; whatever isn't is kept.
5. **Audio's conventions apply to audio inputs:** Audio §1.1 formats, §1.3's band-limited resampling with
   `audio_resampled`, §1.5's no normalizing. Video output audio isn't streamed (Base streams `audio` outputs only).
6. **Voices and speech** inside video (a speaking character with a chosen voice) are later: no fleet model takes a
   voice. When one does, it uses Base §6.5's voice shape, as RFC 0003 anticipated.

### 5.5 Extend and retake

- **Extend:** the output is `before_s` + the source + `after_s`, each added part a whole number of grid steps (8
  frames on LTX, which is what keeps an 8k + 1 source on the grid). `before_s` is gated by
  `supports.extend_before` (LTX extends forward only). Total length counts against `max_duration_s` and `max_frames`,
  which LTX doesn't re-check (§7).
- **Retake:** `start_s` < `end_s`, inside the source (422 `out_of_limits` otherwise, which LTX doesn't check);
  the span at most `limits.max_retake_s`; the output has the source's frame count. The span snaps outward to the
  model's grid with `span_snapped`.
- **The source is kept.** Frames outside the made-again parts are the source's frames, re-encoded but not
  regenerated, except within `supports.overlap_s` of a join, which the model may rework so the join is seamless (LTX
  extend: 0.5 s). Audio follows §5.4.

### 5.6 Upscale

- `scale` 2 or 4 (both packages), output exactly input × scale, same frames, fps and duration. Absent: the offer's
  native scale (FlashVSR 4, SeedVR2 2), reported as `effective.scale`. `supports.scales` gates.
- **`content` is required** (`live_action` or `drawn`), never guessed (VID-4, §8.4). `supports.content` gates:
  FlashVSR lists only `live_action`; SeedVR2 both. With no model named, an engine may prefer one by content (Base
  `defaultModel`: FlashVSR for live action, SeedVR2 for drawn).
- **A refused tier is never swapped** (VID-4): a request that names a `quality` stays at it (Base §6 rule 2); only a
  request with none may move tiers.
- `max_width` and `max_height` bound the **output** (FlashVSR 1920×1152). Input sizes are the engine's to check once
  it has read the clip.

### 5.7 Interpolate

- `factor` (2–8, `limits.max_factor`) or `fps` (the target rate), not both (400). With `fps`, the engine uses the
  nearest admissible factor and warns `fps_adjusted` when the result's rate differs.
- The output has (N − 1) × factor + 1 frames at the source's fps × factor; source frame i is output frame
  i × factor, re-encoded but not regenerated. Duration changes by less than one source frame; the audio track is kept.
- Slow motion (factor × frames at the source's rate) is later (§5.12).

### 5.8 Previews and progress

- **Previews** (B-2): still frames (`image/jpeg` or `image/png`, ≤ 256 KiB inline) with `at_s`, sent by offers that
  declare `supports.previews`. No package makes them today (§1, §2); an engine can preview frames a per-frame
  package has finished once packages expose them (§8).
- **Progress** names phases from the packages' own vocabulary: `encode`, `denoise` (LTX's stages in sequence),
  `upsample`, `decode`, `upscale`, `interpolate`, `mux`. Per-frame operations report `media_s`, the seconds of output
  made so far. SeedVR2 and RIFE report nothing today; an engine reports at least `stage` (§8).

### 5.9 Licence and disclosure in video (V-5, V-6)

- Base §10.2 (B-3, B-4, B-5) applies.
- **Disclosure, MUST in Video:** a `video.generate`, `extend` or `retake` output says in the file that it is
  AI-generated: the comment item contains `AI-generated` and the model's title, and where the engine writes XMP,
  `Iptc4xmpExt:DigitalSourceType` is `trainedAlgorithmicMedia` (or `compositeWithTrainedAlgorithmicMedia` for extend
  and retake). `upscale` and `interpolate` keep the input's marking.
- **LTX offers** declare `spdx: "LicenseRef-LTX-2-Community"`, `commercial_use: true` (the operator accepted at first
  enable, MiniMax's precedent, §4.6), `accepted_required: true`, `user_accept_required: true`, `terms_url` at the
  licence, and a `notice` that says what the user takes on: the use restrictions, the $10M threshold, and that outputs
  must be disclosed as machine-generated.

### 5.10 `supports` keys and limits

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `first_frame`, `last_frame`, `keyframes`, `soundtrack`, `references` | generate | boolean | `false` | Gate: the input |
| `audio` | generate, extend, retake | boolean | `false` | Gate: `audio: true` without a soundtrack. Fact: the model makes sound |
| `sample_rate`, `channels` | where `audio` | integer | — | Fact: the sound it makes |
| `negative_prompt` | generate, extend, retake | boolean | `true` | Warn: `negative_prompt_ignored` |
| `frame_rates` | generate | `[number]` | any | Gate: `fps` |
| `frame_step` | all | `{multiple, offset}` | `{1, 0}` | Fact |
| `size_step` | generate | integer | 1 | Fact |
| `extend_before` | extend | boolean | `false` | Gate: `before_s` |
| `retake` | retake | `[picture · sound · both]` | `[picture]` | Gate: `retake` |
| `overlap_s` | extend, retake | number | 0 | Fact |
| `scales` | upscale | `[2 · 4]` | `[2, 4]` | Gate: `scale` |
| `content` | upscale | `[live_action · drawn]` | both | Gate: `content` |
| `deterministic` | all | boolean | `true` | Fact: the same seed gives identical frames |
| `previews` | all | boolean | `false` | Fact |

Limits: Base's `max_width`, `max_height`, `max_megapixels`, `max_duration_s`; and `min_duration_s`, `min_width`,
`min_height`, `max_frames`, `max_fps`, `max_keyframes`, `max_extend_s`, `max_retake_s`, `max_factor`,
`max_source_s` (the input clip) and `max_soundtrack_s`. The kit checks those a request states; input media lengths
are the engine's.

### 5.11 Conformance sizing (V-11)

Every VIDEO test asks for an offer's cheapest tier and the smallest useful clip:
- `video.generate`: 256×256 (inside every LTX tier and on both grids), 9 frames at 24 fps (`duration_s` 0.375), or the
  offer's `min_duration_s` and `min_width` where larger. compact24: about 25 s of generation, about a minute with a
  cold load, inside the default 180 s `--job-timeout`.
- Video inputs: a 128×96, 17-frame (8 · 2 + 1), 24 fps H.264 fixture with a 48 kHz stereo AAC track, 0.71 s long. On
  the /32 grid, LTX's minimum of 9 frames and 64 px, SeedVR2's 128² sweet spot, and RIFE's pairs. SeedVR2 ×2 is about
  5 s; RIFE under a second; LTX extend and retake about a minute.
- About ten LTX jobs in the whole suite. Reproduction checks use the offer's `deterministic` Fact: bit-identical
  frames where it's `true`, a reported difference where it's `false` (int8 LTX).

### 5.12 Later, and outside

- **Later:** `video.edit` (an instruction edit of a whole clip, `VEditRequest`'s v2v and rv2v, when a fleet model does
  it); slow motion; talking heads and character animation (`talkingHead`, `characterAnimation`); speech with a voice
  inside video; streamed segments (fragmented MP4); HDR.
- **Outside:** video understanding (`videoAnalysis`) is interpretive, and stays client-side as speech-to-text does.

## 6. Our models in Video 0.1

### 6.1 LTX 2.5: one offer per tier (V-7)

| Offer (suggested id) | Operations | Quality | Limits | Supports |
|---|---|---|---|---|
| `ltx-2.5-compact24` | generate, extend, retake | `draft` | 704×512 (t2v), 512×288 (conditioned: first frame, soundtrack), `max_frames` 121, `min_width`/`min_height` 64 | `first_frame`, `soundtrack`, `audio` (48 000, 2), `size_step` 32, `frame_step` {8, 1}, `negative_prompt: false`, `deterministic: false`, `retake` [picture, sound, both], `overlap_s` 0.5 on extend (retake: none; its span widens to whole latent frames) |
| `ltx-2.5-balanced32` | generate, extend, retake | `draft`, `standard` | 576×320, 161 frames | as compact24 |
| `ltx-2.5-standard64` | generate, extend, retake | `standard`, `best` | 1280×704, 161 frames | as above plus `last_frame`, `keyframes` (`max_keyframes` 5), `size_step` 64 |
| `ltx-2.5-max128` | generate, extend, retake | `best` | 1920×1088, 481 frames | as standard64, `deterministic: true` (bf16) |

- The conditioned envelope is smaller than t2v on compact24 (512×288). One offer can carry only one `max_width`, so the
  engine declares the t2v envelope and refuses a conditioned request above 512×288 with 422 `out_of_limits` naming
  the input, or Gaea splits the tier into two offers. The first is simpler and still honest, since the refusal is
  at submit.
- `max_fps` isn't a package limit; Gaea may declare one (LTX was trained at 24 and 25 fps).
- Adapters (§1.1.5): plain LoRAs as `plain`, `union-control` as `ic` with one `video` slot, `ingredients` with one
  `image` slot, `lipdub` with a `video` and an `audio` slot; `max_adapters` 1 (one at a time), each with its own
  licence (`cameraman-v2` non-commercial). Wired once AB-A-0197 types them.

### 6.2 SeedVR2, FlashVSR, RIFE

| Offer | Operation | Quality | Limits | Supports | Licence |
|---|---|---|---|---|---|
| `seedvr2-int8` (default for `drawn`) | upscale | `draft`, `standard` | Gaea's budget | `scales` [2, 4], `content` [live_action, drawn] | Apache-2.0 (weights), commercial |
| `seedvr2-fp16` | upscale | `best` | as above | as above | Apache-2.0 |
| `flashvsr` (default for `live_action`, once out of WIP) | upscale | `standard` | `max_width` 1920, `max_height` 1152 | `scales` [2, 4], `content` [live_action] | Apache-2.0; credit in `notes` |
| `rife-4.25` | interpolate | `standard` | `max_factor` 8 | `seed: false` | MIT |

## 7. What would break as it is

Served as it is today, each package breaks at least one rule; each fix is the engine's (Gaea's plugin), unless §8
says otherwise:

| Package | Behaviour | Rule | Fix |
|---|---|---|---|
| LTX | Clamps over-size sizes and frame counts | Base §6 rule 4 (limits stated, not discovered) | Check against the offer's limits at submit; refuse |
| LTX | A frame count off the 8k + 1 grid comes back shorter (24 gives 17) | §5.3 (snap to the nearest, warn) | Pass the snapped count, which comes back exact |
| LTX | Image-to-video silently becomes text-to-video without a VAE encoder | No surprises | Don't declare `first_frame` without the encoder |
| LTX | Audio can't be switched off | §5.4 | Remux without the track for `audio: false` |
| LTX | Keyframes by frame index and path in `metaData`; refused on one-stage tiers | §5.3 | Map times to frames; declare `keyframes` only on two-stage tiers |
| LTX | Ignores `negativePrompt`, `steps`, `guidanceScale` | Base §6.4 Warn | Declare `negative_prompt: false`; no step or guidance knobs |
| LTX | Extend total not re-checked against the tier cap; retake span not checked | Limits | Check both at submit |
| LTX | int8 isn't bit-deterministic | IMAGE-007-style checks | Declare `deterministic: false` |
| LTX | Audio-to-video runs two-stage on compact24 | Tier budgets (VID-3) | Gaea's governor; or don't declare `soundtrack` on compact24 until the package honours the tier |
| LTX | i2v adapter not applied automatically; downloads inside `run()` | Progress, no surprises | Pass it; materialize it beforehand (GPP `materialize`) |
| SeedVR2, FlashVSR, RIFE | Drop audio | §5.4 rule 4 | Remux the source's track |
| SeedVR2, FlashVSR, RIFE | HEVC on a software encoder; `encoderStalled` after 90 s | Output format | Declare `codec: hevc`; transcode for `h264` |
| RIFE | Discards VFR timing | §5.2 | Retime with `video_retimed` |
| RIFE | Downloads weights itself through `HubApi` | Base §17 (no undeclared traffic) | Route through the engine's weight sourcing |
| SeedVR2 | Declared footprint understates the temporal path | Tier budgets | Gaea's governor uses the measured figures |
| SeedVR2, RIFE | No run progress | §5.8 | Report `stage`; ask MLXEngine (§8) |
| FlashVSR | WIP; not bit-stable across machines | — | Offer after it leaves WIP; `deterministic` true per machine only |

## 8. Engine-side work the plugins depend on

These are asks for MLXEngine and the packages, not spec work. They are named here so Gaea's GPP work and the
package owners can pick them up:

1. **Typed time and keyframes in MLXToolKit:** a time span and a retake modality on `VEditRequest`, an extend length,
   and keyframes (`[{image, frame, strength}]`) on `T2VRequest`, so `metaData` keys and file paths go away.
2. **`content` on `VideoUpscaleRequest`**, and a target `fps` or timestep on `FrameInterpolateRequest` (RIFE takes any
   timestep internally).
3. **Audio passthrough** in `frame-stream-native` (copy the source's audio track), and an `audio: false` switch in LTX.
4. **A frame hook for previews:** a callback with finished frames (per-frame packages) or a decoded stage-one frame
   (LTX), so an engine can send `job.preview`.
5. **Run progress** in SeedVR2 and RIFE (`upscale` / `interpolate` steps per frame).
6. **Weight sourcing** for RIFE through the engine, not `HubApi`.
7. **Typed adapters for LTX** (AB-A-0197): LoRA and IC-LoRA through `T2VRequest.adapters`, with `ic` slots.

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| V-1 | Which operations in Video 0.1? | **Decided:** `generate`, `extend`, `retake`, `upscale`, `interpolate` (§5.1). `edit`, slow motion, talking heads and character animation later (§5.12) |
| V-2 | How is audio inside a video described? | **Decided:** one AAC track; `sample_rate`/`channels` on the output exactly when it has one; `audio` boolean; `soundtrack` is the output's audio, unchanged; transformations keep the source's audio, remuxed by the engine; Audio's input conventions; no streaming (§5.4) |
| V-3 | Seconds or frames? | **Decided:** seconds in requests, frames in results; grids are Facts; snaps warn; limits never exceeded (§5.3) |
| V-4 | What crosses the wire? | **Decided:** `video/mp4` (H.264 or HEVC, AAC) MUST, `video/quicktime` SHOULD; no image sequences. GPP's frame transport is Gaea's; the packages decode containers, so pass the file (§5.2) |
| V-5 | Do `license.notice` and `accepted_required` fit LTX? | **Partly.** `accepted_required` is VID-6's first-enable acceptance; `notice` is shown with results (B-3, A-8 and A-9 for every profile). The licence's hosting clause also binds users, so Base gains `user_accept_required` and `policy.accepted` (B-4, RFC 0005). `commercial_use: true` per MiniMax's precedent; A-6 stays open (§4.3–4.6) |
| V-6 | AI-content disclosure? | **Decided:** MUST in Video's generative outputs (comment item, XMP where written); markings, watermarks and manifests an input carries are kept by every operation (B-5) |
| V-7 | LTX tiers in the descriptor? | **Recommended:** one offer per installed tier with per-offer limits and supports (§6.1). Gaea's lanes are its own |
| V-8 | Previews? | **Decided:** frames through `job.preview` with `at_s` (B-2), `supports.previews`. Packages need a frame hook (§8) |
| V-9 | Upscale `content`? | **Decided:** required, `live_action` or `drawn`; gated per offer; a named tier is never swapped (§5.6) |
| V-10 | Interpolation by factor or fps? | **Decided:** either, not both; (N − 1) × factor + 1 frames (§5.7) |
| V-11 | Conformance sizing? | **Decided:** 256×256 × 9 frames at 24 fps on the cheapest tier; a 128×96 × 17-frame fixture with AAC (§5.11) |
| V-12 | Seeds? | **Decided:** as Image, 0 – 2⁵³ − 1; `deterministic` Fact for reproduction (§5.10) |
