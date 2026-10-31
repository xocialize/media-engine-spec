# Media Engine Specification — Video profile

| | |
|---|---|
| **Profile** | `video` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1, with what each offer supports (§6.4), adapters (§6.3), output frames, previews and user acceptance ([RFC 0005](../../rfcs/0005-video-in-base.md)) |
| **Schemas** | [`schemas/v0/profiles/video/`](../../schemas/v0/profiles/video/) |
| **Sources** | [`docs/VIDEO-EVALUATION.md`](../../docs/VIDEO-EVALUATION.md) (its Decisions of 2026-10-31); RFC [0005](../../rfcs/0005-video-in-base.md) |

The Video profile defines five operations on moving pictures: generating a clip, extending one, retaking part of one,
upscaling and interpolating. It defines the parameter vocabulary they share, how time, frames and audio inside a
video are handled, and the facts each model offer states about itself. An engine implementing this profile MAY offer
any subset of the operations. For each operation it offers, it MUST honour that operation's required inputs, outputs
and behaviour.

**Why normalized.** A client asks for four seconds at 24 fps with a first frame and a soundtrack, once, and every model
that can do it understands. The engine maps seconds to each model's frame grid, times to frame indices, and the
profile's inputs to the model's own request, and reports exactly what it made.

**Not in Video 0.1.** Instruction edits of a whole clip, slow motion, talking heads, character animation, speech with a
chosen voice, streamed output and HDR come later (§7). Video understanding stays client-side.

## 1. Conventions

1. **Media types.** Engines MUST accept `video/mp4` with H.264 or HEVC video and AAC audio, and SHOULD accept
   `video/quicktime`. Image inputs follow Image §1.1 and audio inputs Audio §1.1. Outputs default to `video/mp4`, in
   the codec the engine writes.
2. **Output format.** Clients MAY ask for another container or codec with `output`: `{media_type, codec}` (`codec`:
   `h264` or `hevc`). One the engine can't give is refused with 422 `unsupported_parameter`, and a descriptor's `output`
   lists only what it can give.
3. **Frames and time.** A clip is frames at a constant rate. Requests speak seconds (`duration_s`, `keyframe_times`,
   `start_s`, `end_s`, `after_s`, `before_s`); results speak frames. Every video output reports `width`, `height`,
   `fps`, `frames` and `duration_s` = `frames` / `fps` (Base §10.1), and `effective` reports the `duration_s`, `fps`,
   `size` and `frames` the job made.
4. **Grids.** A model that makes only certain frame counts or sizes declares them as Facts: `supports.frame_step`
   (`{multiple, offset}`: frames are k × multiple + offset; LTX makes 8k + 1) and `supports.size_step` (sides are
   multiples of it). The engine snaps a request to the nearest admissible value within the offer's limits and warns
   `duration_snapped` or `size_snapped`. It MUST NOT exceed a limit to honour a request: a request whose nearest
   admissible value is outside the limits is 422 `out_of_limits`. Absent values are the model's defaults, reported.
5. **Colour.** The working space is SDR BT.709 at 8 bits per channel. An input in another space is converted, with
   `color_converted`, and outputs are tagged BT.709.
6. **Timing.** Frame-based operations treat a clip as constant frame rate. An input with variable timing is retimed to
   its nominal rate first, with `video_retimed`.
7. **Audio inside a video.** A video output carries at most one audio track: AAC in MP4 and QuickTime.
   - **Facts.** Its `sample_rate` and `channels` are on the output exactly when it has a track (Base §10.1).
   - **`audio`** asks for sound (`true`) or a silent clip (`false`). Absent, the output has sound where the model makes
     it or the source has it. With `false` the engine leaves the track out, remuxing if the model made one.
   - **A `soundtrack`** is the track the picture follows, and it is the output's audio, unchanged except to fit the
     clip (§3.1).
   - **Transformations keep audio.** `upscale` and `interpolate` carry the source's track into the output unchanged
     (copied without re-encoding where the container allows). The engine does this when its model drops audio.
     `extend` and `retake` keep the source's sound where they keep its picture (§3.2, §3.3).
   - **Audio inputs** follow Audio §1.1 (formats), §1.3 (band-limited resampling, with `audio_resampled`) and §1.5 (no
     normalizing).
   - Video outputs don't stream (Base §11 streams `audio` outputs only).
8. **Untouched frames stay untouched.** Frames an operation doesn't make again are the input's frames, re-encoded but
   not regenerated: not a model's reconstruction of them. The one exception is `supports.overlap_s`: seconds next to a
   join that a model may rework so the join is seamless (§3.2, §3.3).
9. **AI-content disclosure.** Base §10.2 rules 1 to 3 apply, and in this profile the marking is a MUST:
   - an output of `video.generate`, `video.extend` or `video.retake` says in the file that it is AI-generated: its
     comment item (`©cmt` in MP4; `com.apple.quicktime.comment` in QuickTime) contains `AI-generated` and the model's
     title, and where the engine writes XMP, `Iptc4xmpExt:DigitalSourceType` is `trainedAlgorithmicMedia`
     (`compositeWithTrainedAlgorithmicMedia` for extend and retake);
   - `video.upscale` and `video.interpolate` keep the marking, watermark and provenance manifest the input carries.
10. **Licences that bind users.** An offer whose licence has `user_accept_required` runs only for requests whose
    `policy.accepted` lists its `spdx` (Base §10.2 rule 4, §10.3). The LTX-2 Community Licence is one:
    the evaluation's §1.1.7 and §5.9.
11. **Prompt enhancement.** An engine that may rewrite `prompt` before the model sees it follows Image §1.9
    (`prompt_enhance`, `prompt_rewritten`, `effective.prompt`, a `prompt_enhance` helper in provenance).
12. **Adapter slots.** An `ic` adapter's slots (Base §6.3) are filled by kind: `video` slots from `control`, `image`
    slots from `references`, and an `audio` slot from `soundtrack`, each starting with that input's first value, in the
    order the request lists its adapters and each adapter's slots in order. A request with fewer values than its
    adapters' required slots is 400 `invalid_request`.
13. **Seeds.** `seed` is 0 – 2⁵³ − 1, as Image's. Results report it in `effective.seed`; a request without one gets one
    the engine picks. A model whose frames aren't bit-identical for the same seed (int8 inference) declares
    `supports.deterministic: false`.
14. **Previews.** An offer that declares `supports.previews` sends stills while it runs: `job.preview` with an image
    (`image/jpeg` or `image/png`, ≤ 256 KiB inline), `output`, and `at_s` and `frame` for the moment shown (Base §11).
    Previews are advisory.
15. **Progress.** Phases are `encode`, `denoise`, `upsample`, `decode`, `upscale`, `interpolate` and `mux`, with `step`
    and `steps` within each. Per-frame operations report `media_s`, the seconds of output made so far.

## 2. Vocabulary

These names MUST be used in descriptors whenever the operation exposes the concept. They are defined in
[`vocabulary.schema.json`](../../schemas/v0/profiles/video/vocabulary.schema.json).

| Name | Type | Meaning |
|---|---|---|
| `negative_prompt` | string, ≤ 4000 characters | What to steer away from. Warn: `supports.negative_prompt` |
| `duration_s` | number, > 0 | `generate`: the clip's length. Snapped to the grid (§1.4). Absent: the model's default, or the soundtrack's length |
| `fps` | number, 1 – 240 | `generate`: the frame rate. `interpolate`: the target rate (§3.5). Gate: `supports.frame_rates` |
| `size` | `{width, height}` in pixels | The output size. Snapped to the grid (§1.4) |
| `aspect` | string `W:H`, e.g. `16:9` | Alternative to `size`, with `resolution` |
| `resolution` | integer, 64 – 4320 | With `aspect`: the short side in pixels (720 for 1280×720 at 16:9). Default: the model's |
| `keyframe_times` | array of numbers | `generate`: one time in seconds per `keyframes` value, in order, strictly inside the clip |
| `audio` | boolean | Whether the output carries an audio track (§1.7) |
| `after_s`, `before_s` | number, ≥ 0 | `extend`: seconds to add after and before the source |
| `start_s`, `end_s` | number, ≥ 0 | `retake`: the span to make again |
| `retake` | `picture` · `sound` · `both` | `retake`: what to make again in the span. Default `both` where the offer retakes sound, else `picture` |
| `scale` | `2` or `4` | `upscale`: the enlargement factor. Absent: the offer's native scale, reported |
| `content` | `live_action` · `drawn` | `upscale`: what the video is, so the engine picks the right model. Required: never guessed |
| `factor` | integer, 2 – 8 | `interpolate`: frames per source frame interval |
| `seed` | integer, 0 – 2⁵³ − 1 | Repeatability (§1.13) |
| `quality` | `draft` · `standard` · `best` | Speed versus fidelity. The engine maps it to models, tiers, stages and steps. Default `standard` |
| `output` | `{media_type, codec}` | Output encoding (§1.2) |
| `prompt_enhance` | `auto` · `on` · `off` | As Image §1.9 |

`size` and `aspect` are mutually exclusive (400 `invalid_request`), and so are `factor` and `fps` in `interpolate`.
`resolution` without `aspect` is 400. Model-specific knobs (steps, guidance, stage counts, tile sizes, temporal
windows) are never vocabulary; engines expose them, if at all, as extensions (Base §6.2), e.g. `x-ltx.stages`. Adapters
(LoRA, IC-LoRA) are chosen with the request's `adapters` (Base §6.3).

## 3. Operations

The required inputs, outputs and parameters of each operation are listed in
[`operations.json`](../../schemas/v0/profiles/video/operations.json), which the conformance suite reads.
[`job-request.schema.json`](../../schemas/v0/profiles/video/job-request.schema.json) validates a Video job request
against it.

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `video.generate` | `prompt` (text, required); `first_frame` (image, 0–1); `last_frame` (image, 0–1); `keyframes` (image, 0–n); `soundtrack` (audio, 0–1); `references` (image, 0–n); `control` (video, 0–n) | `negative_prompt`, `duration_s`, `fps`, `size` / `aspect` + `resolution`, `keyframe_times`, `audio`, `seed`, `quality`, `output`, `prompt_enhance` | `video` (video, 1) | A clip from text, fixed frames and a soundtrack (§3.1) |
| `video.extend` | `video` (required); `prompt` (text, required) | `after_s`, `before_s`, `negative_prompt`, `audio`, `seed`, `quality`, `output`, `prompt_enhance` | `video` | `before_s` + the source + `after_s` (§3.2) |
| `video.retake` | `video` (required); `prompt` (text, required) | `start_s`, `end_s` (required), `retake`, `negative_prompt`, `seed`, `quality`, `output`, `prompt_enhance` | `video` | The span made again, the rest kept (§3.3) |
| `video.upscale` | `video` (required) | `scale`, `content` (required), `seed`, `quality`, `output` | `video` | Exactly the input's size × `scale`, the same frames (§3.4) |
| `video.interpolate` | `video` (required) | `factor` / `fps`, `seed`, `quality`, `output` | `video` | (N − 1) × factor + 1 frames, every source frame kept (§3.5) |

### 3.1 Generating a clip

`generate` makes a clip from `prompt`, and from whichever of these the offer supports:
- **`first_frame`** and **`last_frame`**: images the clip starts and ends on (`supports.first_frame`, `last_frame`).
  An image of another aspect is aspect-filled and centre-cropped to the output size.
- **`keyframes`**: images the clip passes through, with `keyframe_times`, one time per image (`supports.keyframes`,
  at most `limits.max_keyframes`). The counts must match, and each time must be strictly inside the clip (above 0
  and before its end): otherwise 400 `invalid_request`. The engine puts each at the nearest frame; one moved more than
  half a frame by the grid warns `keyframe_moved`.
- **`soundtrack`**: audio the picture follows, such as speech to lip-sync or music to cut to (`supports.soundtrack`,
  at most `limits.max_soundtrack_s`). The output's audio is the soundtrack, unchanged. Without `duration_s` the clip is
  the soundtrack's length, on the grid and within limits; with it, or when a limit cuts the clip, the soundtrack is
  cut or padded with silence to fit, with `soundtrack_fitted`. `audio: false` with a soundtrack gives the picture only.
- **`references`**: images of a subject the clip should keep, such as a character or product (`supports.references`),
  and the `image` slots of `ic` adapters (§1.12). **`control`**: the `video` slots of `ic` adapters, such as a pose or
  depth clip.
- **Sound.** An offer with `supports.audio` makes sound with the picture, at its `sample_rate` and `channels`.
  `audio: true` without a soundtrack needs one.

The clip is `duration_s` long at `fps`, of `size` (or `aspect` at `resolution`), each snapped to the grid (§1.4).
`effective` reports all four with `frames` and `seed`.

### 3.2 Extending a clip

`extend` adds `after_s` seconds after the source and `before_s` before it, from `prompt`, continuing what's there.
- **Length.** The output is `before_s` + the source + `after_s`. Each added part is a whole number of the grid's steps
  (`frame_step.multiple` frames), so a source on the grid gives an output on it; a part that moves by more than half a
  frame warns `duration_snapped`. At most `limits.max_extend_s` is added in all, and the total is within
  `max_duration_s` and `max_frames`. Given values that add nothing (both 0) are 400; absent both, `after_s` is the
  offer's default. `effective.after_s` and `before_s` report what was added.
- **`before_s`** needs `supports.extend_before`.
- **The source is kept** (§1.8): its frames appear in the output, except within `supports.overlap_s` of a join.
- **Sound.** The source's track plays under the source. The new parts get the model's sound (`supports.audio`), or
  silence, so the track spans the clip.

### 3.3 Retaking part of a clip

`retake` makes the span from `start_s` to `end_s` again from `prompt`, and keeps the rest.
- **The span** has `start_s` < `end_s` (400 otherwise), lies inside the source (422 `out_of_limits` otherwise), and is
  at most `limits.max_retake_s`. The engine widens it to the model's grid, with `span_snapped` when it moves by more
  than half a frame, and reports `effective.start_s` and `end_s`.
- **`retake`** says what is made again: `picture`, `sound` or `both`, from `supports.retake`. Whatever isn't, is kept.
  `sound` or `both` on a source without audio is 422 `input_invalid`.
- **The output** has the source's frames, fps and size. Outside the span (and `supports.overlap_s` around it) the
  frames are the source's (§1.8).

### 3.4 Upscaling

`upscale` enlarges every frame by `scale`.
- **Exact size.** The output is exactly the input's width and height × `scale`, with the same frames, fps and duration.
  `supports.scales` lists the factors an offer takes.
- **`content`** is REQUIRED: `live_action` or `drawn`, never guessed. `supports.content` lists what an offer is fit
  for, and with no model named the engine chooses among the offers that list it. A generative upscaler that invents
  texture on drawings lists only `live_action`.
- **Tiers.** A request that names a `quality` runs at that tier or is refused; only a request with none may run at
  another tier (Base §6 rule 2). A tier refused for memory is never swapped for another.
- **Limits.** `max_width` and `max_height` bound the output. The engine checks the input's size once it has read it,
  and refuses a job whose output would exceed them with `out_of_limits`.
- **Sound** is kept (§1.7).

### 3.5 Interpolating

`interpolate` adds frames between the source's.
- **`factor`** or **`fps`**, not both (400). With `factor` the output has (N − 1) × `factor` + 1 frames at the source's
  fps × `factor`: source frame i is output frame i × `factor`, kept (§1.8), and the frames between are new. With
  `fps`, the engine uses the nearest factor the offer admits (`limits.max_factor`) and warns `fps_adjusted` when the
  result's rate differs from the request. Absent both: factor 2.
- **Duration** changes by less than one source frame. **Sound** is kept (§1.7).

**Variants and versions.** `upscale` and `interpolate` keep a clip's content, and `extend` and `retake` keep most of
it, so clients may store their results as versions of the source. `generate` makes new clips. The profile describes
this distinction; it doesn't impose it.

## 4. What each offer supports

### 4.1 `supports` keys

Model offers state what they support with `supports` (Base §6.4). Base defines `stream`, `seed` and `voices`; the Video
profile defines these. [`supports.schema.json`](../../schemas/v0/profiles/video/supports.schema.json) types them per
operation.

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `first_frame` | `generate` | boolean | `false` | Gate: the `first_frame` input |
| `last_frame` | `generate` | boolean | `false` | Gate: the `last_frame` input |
| `keyframes` | `generate` | boolean | `false` | Gate: the `keyframes` input |
| `soundtrack` | `generate` | boolean | `false` | Gate: the `soundtrack` input |
| `references` | `generate` | boolean | `false` | Gate: `references` beyond the image slots of the request's adapters |
| `audio` | `generate`, `extend`, `retake` | boolean | `false` | Gate: `audio: true` on `generate` without a soundtrack. Fact: the model makes sound |
| `sample_rate`, `channels` | `generate`, `extend`, `retake` | integer | — | Fact: the sound the model makes. REQUIRED with `audio` |
| `negative_prompt` | `generate`, `extend`, `retake` | boolean | `true` | Warn: `negative_prompt_ignored` |
| `frame_rates` | `generate` | `[number]` | any rate | Gate: `fps` |
| `frame_step` | all | `{multiple, offset}` | `{multiple: 1, offset: 0}` | Fact (§1.4) |
| `size_step` | `generate` | integer | 1 | Fact (§1.4) |
| `extend_before` | `extend` | boolean | `false` | Gate: `before_s` above 0 |
| `retake` | `retake` | `[picture · sound · both]` | `[picture]` | Gate: `retake` |
| `overlap_s` | `extend`, `retake` | number | 0 | Fact (§1.8) |
| `scales` | `upscale` | `[2 · 4]` | `[2, 4]` | Gate: `scale` |
| `content` | `upscale` | `[live_action · drawn]` | both | Gate: `content` |
| `deterministic` | all | boolean | `true` | Fact: the same seed gives identical frames |
| `previews` | all | boolean | `false` | Fact: the offer sends previews (§1.14) |

A request implies the offers whose gates admit it (Base §6.4 rule 2); a named offer that doesn't is 422
`unsupported_parameter`, never a substitute (rule 3). MESEngineKit applies every key in this table for the engine,
and every limit it can read from the request itself (the size and duration asked for, keyframe counts, extend and
retake spans, the factor), and produces the Warn keys' warnings. Limits on the input media (a source's length or
size, a soundtrack's length) are the engine's to check once it has read them.

### 4.2 Limit fields

A descriptor's `limits`, and an offer's narrower ones, take these fields beside Base's `max_width`, `max_height`,
`max_megapixels` and `max_duration_s`:

| Field | Operations | Bounds |
|---|---|---|
| `min_width`, `min_height` | `generate` | Pixels |
| `min_duration_s` | `generate` | Seconds |
| `max_frames` | all | The output's frames |
| `max_fps` | `generate`, `interpolate` | The output's rate |
| `max_keyframes` | `generate` | `keyframes` values |
| `max_soundtrack_s` | `generate` | A longer soundtrack is cut to the clip, with `soundtrack_fitted` |
| `max_source_s` | `extend`, `retake`, `upscale`, `interpolate` | The input video; longer is 422, not trimmed |
| `max_extend_s` | `extend` | `after_s` + `before_s` |
| `max_retake_s` | `retake` | The span |
| `max_factor` | `interpolate` | `factor` |

For `upscale`, `max_width` and `max_height` bound the output (§3.4). A value outside an offer's limit implies another
offer, or is 422 `out_of_limits` (Base §6.4).

## 5. Warnings

The profile adds these warning codes to Base's:

| Code | When |
|---|---|
| `size_snapped` | The output size was moved to the model's grid (§1.4) |
| `duration_snapped` | The length was moved to the model's frame grid (§1.4) |
| `fps_adjusted` | The output's rate differs from the request (§3.5) |
| `span_snapped` | A retake span was widened to the grid (§3.3) |
| `keyframe_moved` | A keyframe landed more than half a frame from its time (§3.1) |
| `soundtrack_fitted` | The soundtrack was cut or padded to the clip (§3.1) |
| `video_retimed` | A variable-rate input was retimed to constant (§1.6) |
| `color_converted` | An input was converted to BT.709 (§1.5) |
| `audio_resampled` | An audio input was resampled (§1.7, Audio §1.3) |
| `audio_unavailable` | `audio: true`, but the source has no track to keep |
| `negative_prompt_ignored` | The model can't use a negative prompt |
| `prompt_rewritten`, `prompt_enhance_ignored`, `prompt_enhance_failed` | As Image §1.9 |

**Helper roles** (Base §10.1): `prompt_enhance`, a model that rewrote the prompt.

## 6. Conformance (VIDEO-nnn)

An engine conforms to Video 0.1 for the operations it offers when:
- every offered operation's descriptor lists its required inputs and outputs (`operations.json`);
- the parameters it exposes use the vocabulary names, and its offers' `supports` the keys of §4;
- these tests pass. Each asks for an offer's cheapest tier and a small clip (256×256, 9 frames at 24 fps, or the
  offer's minimum), and video inputs are a 128×96, 17-frame, 24 fps H.264 clip with a 48 kHz stereo AAC track, so the
  slowest models fit `--job-timeout`.

| Test | Checks |
|---|---|
| VIDEO-001 | Descriptors match the operations table: required inputs and outputs of the right kinds, only vocabulary parameters, the required ones present |
| VIDEO-002 | Offers' `supports` keys have the profile's types, their limits are the profile's fields, and an offer with `audio` states `sample_rate` and `channels` |
| VIDEO-003 | Video outputs report `width`, `height`, `fps`, `frames` and `duration_s`, and the file agrees; `sample_rate` and `channels` are present exactly when the file has an audio track, and agree |
| VIDEO-004 | Every MUST input format is accepted: MP4 with H.264 and with HEVC, each with AAC |
| VIDEO-005 | `generate`: the frames are on the offer's grid and `effective` reports `duration_s`, `fps`, `size` and `frames` as made; `size` with `aspect` is 400; a size off the grid snaps with `size_snapped` |
| VIDEO-006 | `generate`: `first_frame`, `last_frame` and `keyframes` route to offers that support them; a named offer that doesn't is 422; keyframes without a time each, or a time outside the clip, is 400 |
| VIDEO-007 | `audio: false` gives a silent clip; an offer with `supports.audio` gives a track at its declared rate and channels; `audio: true` to an offer without is 422 |
| VIDEO-008 | `soundtrack`: the output's track lasts as long as the clip; a named offer without `soundtrack` is 422 |
| VIDEO-009 | `extend`: the output is the source plus the added frames on the grid, the source's frames kept (the error is reported); `before_s` to an offer without `extend_before` is 422 |
| VIDEO-010 | `retake`: the source's frame count, the frames outside the span kept; `end_s` before `start_s` is 400; a `retake` value the offer doesn't list is 422 |
| VIDEO-011 | `upscale`: exactly the input's size × `scale`, the same frames and fps, the source's audio kept; no `content` is 400; a `content` the named offer doesn't list is 422 |
| VIDEO-012 | `interpolate`: (N − 1) × `factor` + 1 frames at the source's fps × `factor`, source frames kept, audio kept; `factor` with `fps` is 400 |
| VIDEO-013 | Disclosure: a generated clip's comment item says `AI-generated`; `upscale` and `interpolate` keep an input's marking |
| VIDEO-014 | Previews from an offer with `supports.previews` are images with `at_s` inside the clip |
| VIDEO-015 | `seed` is reported; the same seed reproduces identical frames where the offer is `deterministic` (the difference is reported where it isn't); an `output` media type the descriptor doesn't offer is 422 |

Base's tests of what each offer supports (BASE-014 to BASE-018) and of users' acceptance (BASE-019) run on the Video
operations an engine offers.

## 7. Later, and outside

- **Later:** `video.edit` (an instruction edit of a whole clip, with reference images), slow motion, talking heads
  and character animation, speech with a chosen voice inside a video (Base §6.5), streamed segments, HDR.
- **Outside MES:** video understanding (captioning, analysis), which is interpretive and stays client-side.
