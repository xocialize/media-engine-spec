# Media Engine Specification — Audio profile

| | |
|---|---|
| **Profile** | `audio` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1, with what each offer supports (§6.4), voices (§6.5), assets (§8.1) and streamed output (§11) |
| **Schemas** | [`schemas/v0/profiles/audio/`](../../schemas/v0/profiles/audio/) |
| **Sources** | [`docs/AUDIO-EVALUATION.md`](../../docs/AUDIO-EVALUATION.md) (its Direction of 2026-10-24); RFCs [0001](../../rfcs/0001-assets.md), [0002](../../rfcs/0002-streamed-output.md), [0003](../../rfcs/0003-offer-supports-and-voices.md) |

The Audio profile defines five generative operations on sound: designing a voice, speaking, editing speech, generating
a sound, and composing a song. It defines the parameter vocabulary they share, one label set for emotions, styles and
nonverbal cues that every model understands through its engine, and the facts each model offer states about itself.
An engine implementing this profile MAY offer any subset of the operations. For each operation it offers, it MUST
honour that operation's required inputs, outputs and behaviour.

**Why normalized.** MES exists so an app that conforms to the spec can adopt a new model quickly. For audio that means
the controls are the profile's: an app asks for `angry`, or a `[laugh]`, once, and every model that can do it
understands. The engine translates the profile's labels into each model's own vocabulary and syntax.

**Not in Audio 0.1.** Speech-to-text and other interpretive models stay client-side, and so do live sessions such as
voice chat. Utility tools (separation, cleanup and loudness, codecs) come later (§7).

## 1. Conventions

1. **Media types.** Engines MUST accept `audio/wav` (PCM at 16, 24 and 32 bits, and 32-bit float) and `audio/flac`,
   and SHOULD accept `audio/mpeg`, `audio/mp4` (AAC) and `audio/ogg` (Opus). Outputs default to `audio/wav` at the
   model's own rate (`supports.sample_rate`, §4).
2. **Output format.** Clients MAY ask for another encoding with `output`: `{media_type, sample_rate, bit_depth,
   channels}`. An engine that resamples or remixes to honour it warns `audio_resampled` or `audio_downmixed`. One it
   can't honour is refused with 422 `unsupported_parameter`, and a descriptor's `output` lists only what it can give.
3. **Resampling quality.** Inputs are resampled to the model's rate with a band-limited (windowed-sinc) resampler.
   Linear interpolation is not enough: it measurably changes discrete speech codes and speaker similarity (AB-L-0209).
   An input resampled warns `audio_resampled` with `param` naming it.
4. **Channels.** Speech models take mono. Engines mix other inputs down and warn `audio_downmixed`.
5. **Loudness.** Outputs aren't normalized unless the request asks.
6. **Long text.** An engine splits text a model can't take in one pass at sentence boundaries, and stitches the takes.
   `limits.max_text_chars` bounds the request (§4.2).
7. **References.** A voice reference longer than the model takes is trimmed, with `voice_ref_trimmed`. A `reference`
   or `source` song longer than the offer allows is refused with 422 `out_of_limits` instead: trimming a song changes
   what it is (§3.5).
8. **Seeds.** `seed` is 0 – 2³²−1, narrower than Image's: several speech models break their stop token with larger
   seeds. A model whose result doesn't depend on a seed declares `supports.seed: false` (Base §6.4) and warns
   `seed_ignored` when given one. Operations whose results are seeded (`operations.json` `seeded`) report the seed
   each used in `effective.seed`, and a request without one gets a seed the engine picks, never a fixed default.
9. **Grids.** A value the model takes only on a grid (an editor's speed or volume steps) is snapped to the nearest
   step, with the warning `param_adjusted`.
10. **One label set.** Requests use the profile's labels (§2.1, §2.2, §3.5.1). The engine translates them into each
    model's own vocabulary and syntax, and resolves aliases (`fearful` → `afraid`) before anything else reads the
    request. A client never writes `[Laughter]` for one model and `(laughs)` for another.
11. **Reused voices are assets.** A client that uses the same reference clip in more than one job SHOULD send it as an
    asset (Base §8.1), so the engine may keep what it derives from the clip (an encoded speaker) for the asset's life.
12. **Licence notices go with the sound.** A result whose provenance names a model, helper or voice whose `license`
    has a `notice` MUST be presented with that notice, whatever `commercial_use` says; when `commercial_use` isn't
    `true` and there is no notice, with its `spdx` and `terms_url`. An engine SHOULD write the `spdx` id and `notice`
    into the output's own metadata where the format has a place (WAV `LIST/INFO` `ICOP` and `ICMT`; FLAC and Ogg
    `LICENSE` and `COPYRIGHT` comments; MP3 ID3 `TCOP` and `COMM`) whenever the job's licences carry a notice or aren't
    all `commercial_use: true`. The output's `sha256` covers the file as written. (Evaluation A-8 and A-9, adopted for
    Audio; Base §10.2 is proposed to take them for every profile.)

## 2. Vocabulary

These names MUST be used in descriptors whenever the operation exposes the concept. They are defined in
[`vocabulary.schema.json`](../../schemas/v0/profiles/audio/vocabulary.schema.json).

| Name | Type | Meaning |
|---|---|---|
| `language` | BCP 47 | The language to speak, sing or design in. Absent: the model detects or infers it, and reports `effective.language`. Gate: `supports.languages` (§4) |
| `seed` | integer, 0 – 2³²−1 | Repeatability (§1.8) |
| `quality` | `draft` · `standard` · `best` | Speed versus fidelity. The engine maps it to models, checkpoints, steps and guidance. Default `standard` |
| `count` | integer, 1 – 8 (`design_voice`: 1 – 4) | How many results; each uses `seed + i` |
| `output` | `{media_type, sample_rate, bit_depth, channels}` | Output encoding (§1.2) |
| `voice` | id | `speak`: a preset voice, by id from the named model's list (Base §6.5) |
| `emotion` | `{label?, description?, intensity?}` | `speak`: how the line should feel (§2.1) |
| `style` | label | `speak`: how it's delivered (§2.1) |
| `speed` | number, 0.5 – 2 | `speak`: speaking rate; 1 is the model's natural pace |
| `target_duration_s` | number, ≤ 600 | `speak`: how long the take should be, for dub timing |
| `edit` | object | `edit_speech`: one edit (§3.3). `compose`: a rework of `source` (§3.5) |
| `negative_prompt` | string, ≤ 4000 characters | `generate`: what to steer away from |
| `duration_s` | number, ≤ 600 | `generate`: each sound's exact length. `compose`: the song's target length |
| `planning` | `full` · `melody` · `off` | `compose`: whether the model writes a score before it sings |
| `anchors` | `{bpm?, key?, time_signature?}` | `compose`: musical anchors the plan should keep, e.g. `{bpm: 118, key: "F# minor", time_signature: "6/8"}` |
| `timestamps` | boolean | `compose`: ask for line and word timestamps |
| `prompt_enhance` | `auto` · `on` · `off` | `design_voice`: whether the engine may rewrite the description, as Image §1.9 |

Model-specific knobs (steps, guidance, CFG, emotion weight vectors, an editor's 24 further styles) are never
vocabulary. Engines expose them, if at all, as extensions (Base §6.2): `x-moss.steps`, `x-indextts.emotion_vector`,
`x-stepfun.style`.

### 2.1 Emotion and style

**Emotion** is `emotion: {label?, description?, intensity?}`, with at least one field:
- **`label`**, from the table below. Labels are adjectives, as every package uses them: anger is `angry`.
- **`description`**, free text ("tired but trying to sound cheerful"), for an offer with
  `supports.emotion_description`.
- **`intensity`**, 0 – 1. An offer without `supports.emotion_intensity` runs the label at its own strength and warns
  `emotion_intensity_ignored`.

| Label | Meaning | Aliases the engine resolves |
|---|---|---|
| `neutral` | No emotion. Every `speak` offer supports it: the engine sends none. As an edit, it removes the emotion | — |
| `happy` | | `happiness`, `joy` |
| `sad` | | `sadness` |
| `angry` | | `anger` |
| `afraid` | | `fearful`, `fear`, `scared` |
| `disgusted` | | `disgust` |
| `surprised` | | `surprise` |
| `calm` | | |
| `melancholic` | | |
| `excited` | | |
| `humorous`, `confused`, `empathetic`, `embarrassed`, `depressed`, `cold`, `admiring` | Registered from the speech editors (Step-Audio-EditX) | |

The core is the label set three TTS packages already share (`happy`, `angry`, `sad`, `afraid`, `disgusted`,
`melancholic`, `surprised`, `calm`); the rest are what the editors add. A label is registered when one model supports
it. `supports.emotions` says which models do.

**Style** is `style: <label>`: delivery, not feeling. Instruct-TTS models receive it as text ("Whisper softly.").

| Label | Meaning |
|---|---|
| `normal` | No style; as an edit, it removes one (e.g. back from a whisper) |
| `whisper`, `shout`, `gentle`, `serious`, `warm` | Delivery |
| `narration`, `conversational`, `news` | Register |

### 2.2 Nonverbal cues

Cues go inline in `speak` text and in transcripts, in one syntax for every model: `[laugh]`, `[cough]`,
`[pause 1.5s]`. A literal bracket is written `\[`. Bracketed text that isn't cue-shaped (`[S1]`, `[a long aside]`)
is text.

| Cue | | Cue | |
|---|---|---|---|
| `laugh` | | `gasp` | |
| `cough` | | `clear_throat` | |
| `sigh` | | `hesitation` | an "uhm" |
| `breath` | | `sob` | |
| `pause` | `[pause <seconds>s]`; `[pause]` is half a second | `sniff` | |

- **The engine rewrites** each cue into the model's syntax, and **removes** a cue the model can't perform, with the
  warning `cue_unsupported`. It never speaks a cue as words.
- **`pause` is always honoured.** An engine whose model has no pause splits the text there and inserts silence, as it
  does when it stitches long text (§1.6).

## 3. Operations

The required inputs, outputs and parameters of each operation are listed in
[`operations.json`](../../schemas/v0/profiles/audio/operations.json), which the conformance suite reads.
[`job-request.schema.json`](../../schemas/v0/profiles/audio/job-request.schema.json) validates an Audio job request
against it.

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `audio.design_voice` | `description` (text, required); `text` (text, optional: what the samples say) | `language`, `seed`, `count`, `quality`, `output`, `prompt_enhance` | `samples` (audio, `count`) | Auditions of a voice from its description, each with its seed, and `effective.text` (§3.1) |
| `audio.speak` | `text` (text, required, may carry cues); `voice_ref` (audio, 0–1); `voice_ref_text` (text, optional) | `voice`, `language`, `emotion`, `style`, `speed`, `target_duration_s`, `seed`, `quality`, `output` | `audio` (audio, 1; may stream) | The text spoken in one voice, three ways (§3.2) |
| `audio.edit_speech` | `audio` (required); `transcript` (text, optional) | `edit` (required), `seed`, `quality`, `output` | `audio`; `transcript` (data `{text}`, 0–1) | One edit of a spoken take (§3.3) |
| `audio.generate` | `prompt` (text, required) | `negative_prompt`, `duration_s`, `seed`, `count`, `quality`, `output` | `sounds` (audio, `count`) | Non-verbal sounds, each exactly `duration_s` long (§3.4) |
| `audio.compose` | `caption` (text, required); `lyrics` (text, 0–1); `score` (text, 0–1); `reference` (audio, 0–1); `source` (audio, 0–1) | `duration_s`, `language`, `planning`, `edit`, `anchors`, `timestamps`, `seed`, `quality`, `output` | `song` (audio, 1); `score` (text `text/vnd.abc`, 0–1); `timestamps` (data, 0–1) | A song, an instrumental, or a rework of a recording (§3.5) |

### 3.1 Designing a voice

`design_voice` returns audition clips of a voice described in words ("a warm, low voice of a woman in her forties,
unhurried, with a slight rasp").
- **The clip is the voice.** A client keeps the sample it likes, ideally as an asset (§1.11), and speaks with it
  through `audio.speak`: `voice_ref` the clip, `voice_ref_text` the sample's text (`effective.text`). A designed voice
  therefore works on every cloning model, not only the one that designed it.
- **Reproducing.** With the same `description`, `seed` and model, an engine SHOULD design the same voice.
  `effective.seed` reports the base seed; sample `i` used `seed + i`. A model that takes no seed says
  `supports.seed: false`.
- **The sample text.** Without `text`, the engine chooses a short sentence in `language`, and reports it as
  `effective.text` either way.
- **Prompt enhancement.** An engine may rewrite a short description into the detailed one a model was trained on,
  under `prompt_enhance`, exactly as Image §1.9 (`prompt_rewritten`, `effective.description`, a `prompt_enhance`
  helper in provenance).
- **Speaking with a description in one pass** (instruct TTS) is not part of `speak` in 0.1: the result isn't a voice a
  client can keep, and models disagree on what a description means.

### 3.2 Speaking

`speak` takes exactly one of three ways to choose a voice. A request with both `voice` and `voice_ref` is 400
`invalid_request`, and so is `voice_ref_text` without `voice_ref`.
- **`voice`:** a preset voice, by id from the model's list (Base §6.5). The voice implies its model: with no model
  named, the engine chooses among the offers that list it. Provenance names it (`provenance.voice`).
- **`voice_ref`:** a cloned voice, with `voice_ref_text`, its transcript, where the model uses one
  (`supports.voice_ref_text`). The offer must have `supports.voice_ref`. An offer that ignores the transcript warns
  `voice_ref_text_ignored`.
- **Neither:** the model's own default voice, for an offer with `supports.default_voice`.

Then:
- **Emotion and style** use §2.1, gated by `supports.emotions`, `emotion_description` and `styles`.
- **Cues** use §2.2: unsupported ones are removed with `cue_unsupported`; pauses are always honoured.
- **`target_duration_s`** asks for a take of that length (dub timing), on an offer with `supports.target_duration`.
  One that misses it beyond the offer's tolerance warns `duration_missed`.
- **Streaming.** The `audio` output may stream (Base §11, `job.output_chunk`) from an offer with `supports.stream`.
  The plan states the stream's format, from the request's `output` or the offer's `sample_rate` and `channels`, so an
  offer that streams MUST declare `supports.sample_rate`. Releasing the job mid-stream stops speech within a chunk:
  that is barge-in.
- **Progress.** An autoregressive model doesn't know its length until it stops, so `fraction` is absent and progress
  reports `media_s`, the seconds of audio made so far.

### 3.3 Editing speech

One job applies one edit, `edit: {kind, …}`. AuK's instruction set is the model of what to cover; `supports.edits`
lists the kinds an offer takes.

| `kind` | Fields | Meaning |
|---|---|---|
| `emotion` | `emotion` (§2.1 label) | Re-deliver with that feeling; `neutral` removes one |
| `style` | `style` (§2.1 label) | Re-deliver in that style; `normal` removes one |
| `add_cue` | `cue`, and `at`: `start` · `end`, or `text`: the transcript with the cue inline | Add a nonverbal sound |
| `remove_cue` | `cue` (absent: every cue) | Remove nonverbal sounds |
| `replace_text` | `text`, `with` | Say `with` instead of `text`, in the same voice |
| `insert_text` | `text`, `anchor`, `position`: `before` · `after` | Add words next to `anchor` |
| `remove_text` | `text` | Remove words |
| `speed` | `factor` | Faster or slower (an editor's grid: §1.9) |
| `pitch` | `semitones` | Higher or lower |
| `volume` | `gain_db` | Louder or quieter |
| `timbre` | `description` | Change the voice's colour, in words |
| `de_accent` | — | Toward a standard accent |
| `denoise` | — | Remove background noise |
| `trim_silence` | — | Remove leading and trailing silence |

- **Fields.** A kind's fields are required, and other fields are 400 `invalid_request`. A kind, emotion, style or cue
  the named offer doesn't list is 422 `unsupported_parameter`.
- **Transcripts.** `supports.transcript` says whether the model `required`, `optional` or `unused` it. With
  speech-to-text outside MES, the client supplies it. A transcript uses the cue syntax of §2.2.
- **Length.** `supports.keeps_length` says whether the take keeps its length (an editor that edits in place) or is made
  again (an editor whose length changes).
- **The edited transcript.** When the edit changes the words or the cues, the engine returns the take's new
  transcript as the `transcript` output, `{text}`.

### 3.4 Generating sounds

`generate` makes non-verbal audio from a description: foley, ambience, creatures, actions and effects. Sounds, not
voices, and not songs (§3.5).
- **`duration_s` is exact**: each sound is that long, to the frame (`round(duration_s × sample_rate)` frames), within
  `limits.max_duration_s` (and an offer's `min_duration_s`). Absent: the model's default, reported as
  `effective.duration_s`.
- **`count`** runs the model once per sound, each with its own seed (`seed + i`), as Image does.
- **`quality`** picks steps and guidance, so clients never send diffusion settings.
- **`supports.languages`** says what a prompt may be written in. Here it is a Fact, not a gate.
- **Progress** is honest, because the step count is known: `step` and `steps` in a `denoise` phase, then `decode`.

### 3.5 Composing a song

`compose` makes a song: vocals and arrangement from lyrics and a description of the style, an instrumental from the
description alone, or a rework of a recording.

**Inputs.** `caption` is the style: genre, mood, instrumentation, era, tempo in words, the voice. `lyrics` are the
words, in sections (§3.5.1); without them the song is an instrumental, on an offer with `supports.instrumental`.
`score` is an ABC score to render (`supports.score`), usually one a previous job returned and the client edited; it
travels with the lyrics it was planned from, so a `score` without `lyrics` is 400. `reference` is a recording whose
timbre or style the song should take (`supports.reference`); it isn't reworked. `source` is the recording an `edit`
reworks.

**Edits** rework `source` (`supports.edits`):
- **`cover`:** a new performance of the source's song in the caption's style; `strength` 0 – 1 says how far it may go
  (default 0.5).
- **`repaint`:** the span `start_s`–`end_s` is made again, and the rest kept. The span is at most
  `limits.max_repaint_s`, and inside the source.
- **`extend`:** `before_s` and/or `after_s` seconds of music around the source, which plays unchanged in the middle.
  The song is `before_s` + the source + `after_s` long, to the frame.

An `edit` without `source`, or `source` without `edit`, is 400. A span outside the source, or longer than
`max_repaint_s`, and a `reference` or `source` longer than `max_reference_s` or `max_source_s`, are 422
`out_of_limits`.

**No `count`.** A song is minutes of audio. A client that wants variations submits jobs, each with its own seed.

#### 3.5.1 Section tags

Lyrics are plain text, one sung line per line, in sections introduced by a tag on a line of its own:

`[intro]`, `[verse]`, `[pre-chorus]`, `[chorus]`, `[bridge]`, `[solo]`, `[instrumental]`, `[outro]`

A tag may carry a short direction after a dash: `[chorus - anthemic, full band]`. Tags are case-insensitive. Lyrics
with no tag are one `[verse]`. The engine writes each model's own syntax. A tag the offer's `supports.sections`
doesn't list is mapped to the nearest one it does, or dropped, with `section_unsupported`.

#### 3.5.2 Outputs and effective values

- **`song`**: one audio output at the model's rate and channels (`supports.sample_rate`, `channels`), reporting
  `sample_rate`, `channels` and `duration_s`.
- **`score`**: ABC (`text/vnd.abc`), the score the model planned or was given, from an offer with `supports.score`.
  It is the editable artifact.
- **`timestamps`**: `{lines: [{text, start_s, end_s}], words?: […]}`, when `timestamps: true` on an offer with
  `supports.timestamps`; elsewhere `timestamps_unavailable`.
- **Effective values.** `effective.seed` and `effective.duration_s` always. `effective.language` when it was
  inferred, `effective.anchors` when the plan chose or changed them, `effective.lyrics` when the words sung differ from
  the request.
- **`song_truncated`**: the model hit its length or token cap before the lyrics ended. `effective.duration_s` says
  where it stopped, and the message names the last section sung.
- **Anchors** an offer can't keep warn `anchors_ignored`.

**Progress.** Song models run phases of different kinds, so progress names the `phase` (Base §7.2) and counts within
it: `plan` (planner tokens) → `generate` or `denoise` → `decode`, with `fraction` only once the whole is estimable.

**Quality** picks steps, guidance and, where the operator installed more than one, the checkpoint. A model distilled
for a fixed step count changes what else runs at each tier (its planner) instead. The fleet's three offers and their
licences, with how each tier maps, are in the evaluation's §4.7.4 and §4.7.5, and in
[`examples/v0/operations-audio-compose.json`](../../examples/v0/operations-audio-compose.json).

**Variants and versions.** `edit_speech`, and `compose` with a `repaint` or `extend`, keep a recording's identity, so
clients may store their results as versions of it. `design_voice`, `speak`, `generate`, and `compose` otherwise make
new sounds. The profile describes this distinction; it doesn't impose it.

## 4. What each offer supports

### 4.1 `supports` keys

Model offers state what they support with `supports` (Base §6.4). Base defines `stream`, `seed` and `voices`; the
Audio profile defines these. [`supports.schema.json`](../../schemas/v0/profiles/audio/supports.schema.json) types
them per operation.

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `languages` | all | `[BCP 47]` | any | Gate: `language` (a tag matches its primary language: `en` admits `en-GB`). In `generate`, a Fact: what a prompt may be written in |
| `sample_rate` | all | integer | — | Fact. REQUIRED on an offer with `stream` |
| `channels` | all | integer | 1 | Fact |
| `default_voice` | `speak` | boolean | `false` | Gate: a request with neither `voice` nor `voice_ref` |
| `voice_ref` | `speak` | boolean | `false` | Gate: the `voice_ref` input |
| `voice_ref_text` | `speak` | `unused` · `optional` · `required` | `unused` | Gate: `required` needs `voice_ref_text`. Warn: `unused` with one, `voice_ref_text_ignored` |
| `emotions` | `speak`, `edit_speech` | `[label]` | `speak`: `[neutral]`; `edit_speech`: `[]` | Gate: `emotion.label`, an `emotion` edit's label |
| `emotion_description` | `speak` | boolean | `false` | Gate: `emotion.description` |
| `emotion_intensity` | `speak` | boolean | `false` | Warn: `emotion_intensity_ignored` |
| `styles` | `speak`, `edit_speech` | `[label]` | `speak`: `[normal]`; `edit_speech`: `[]` | Gate: `style`, a `style` edit's label |
| `cues` | `speak`, `edit_speech` | `[cue]` | `speak`: `[pause]`; `edit_speech`: `[]` | Warn in `speak`: `cue_unsupported`. Gate for `add_cue` and `remove_cue` |
| `speed` | `speak` | boolean | `false` | Gate: `speed` other than 1 |
| `target_duration` | `speak` | boolean | `false` | Gate: `target_duration_s` |
| `edits` | `edit_speech`, `compose` | `[kind]` | `[]` | Gate: `edit.kind` |
| `transcript` | `edit_speech` | `required` · `optional` · `unused` | `optional` | Gate: `required` needs `transcript` |
| `keeps_length` | `edit_speech` | boolean | `false` | Fact |
| `instrumental` | `compose` | boolean | `false` | Gate: a request without `lyrics` |
| `score` | `compose` | `unused` · `optional` | `unused` | Gate: the `score` input and `planning`. Fact: the `score` output |
| `reference` | `compose` | boolean | `false` | Gate: the `reference` input |
| `sections` | `compose` | `[tag]` | the eight of §3.5.1 | Warn: `section_unsupported` |
| `anchors` | `compose` | `[bpm · key · time_signature]` | `[]` | Warn: `anchors_ignored` |
| `timestamps` | `compose` | boolean | `false` | Warn: `timestamps_unavailable` |

A request implies the offers whose gates admit it (Base §6.4 rule 2); a named offer that doesn't is 422
`unsupported_parameter`, never a substitute (rule 3). Warn keys never narrow the choice. MESEngineKit applies every
key in this table for the engine, and every limit it can read from the request itself (text lengths, the durations asked
for, a repaint span), and produces the Warn keys' warnings. Limits on the length of input media are the engine's to check.

### 4.2 Limit fields

A descriptor's `limits`, and an offer's narrower ones, take these fields beside Base's `max_duration_s` and
`max_count`:

| Field | Operations | Bounds |
|---|---|---|
| `max_text_chars` | `design_voice` (the description), `speak`, `edit_speech` | Characters of text |
| `max_voice_ref_s` | `speak` | A reference longer is trimmed (§1.7) |
| `max_duration_s` (Base) | `speak` (the take), `edit_speech` (the input), `generate`, `compose` | Seconds |
| `min_duration_s` | `generate`, `compose` | Seconds |
| `max_lyrics_chars` | `compose` | Characters of lyrics |
| `max_reference_s`, `max_source_s` | `compose` | Longer is 422, not trimmed |
| `max_repaint_s` | `compose` | A `repaint` span |

A value outside an offer's limit implies another offer, or is 422 `out_of_limits` (Base §6.4).

### 4.3 Voices

A preset voice is listed by its model (Base §6.5): `GET {path}/operations/audio.speak/models/{model}/voices`, or
`mes_list_voices` over MCP. The offer says only how many (`supports.voices`). The profile suggests, without requiring,
these voice `tags`: `female`, `male`, `child`, `young`, `older`; an accent (`american`, `british`, `australian`,
`indian`, …); and delivery words from §2.1 (`calm`, `warm`, `narration`, `news`).

## 5. Warnings

The profile adds these warning codes to Base's:

| Code | When |
|---|---|
| `audio_resampled` | An input, or the output, was resampled (§1.2, §1.3) |
| `audio_downmixed` | An input, or the output, was mixed down (§1.4) |
| `voice_ref_trimmed` | The reference was clipped to the model's limit |
| `voice_ref_text_ignored` | The model clones from the clip alone; the transcript wasn't used |
| `duration_missed` | `target_duration_s` or `duration_s` wasn't met within the offer's tolerance |
| `cue_unsupported` | A cue was removed (§2.2) |
| `emotion_intensity_ignored` | The model has no intensity (§2.1) |
| `song_truncated` | The song stopped before the lyrics did (§3.5.2) |
| `section_unsupported` | A section tag was mapped or dropped (§3.5.1) |
| `anchors_ignored` | An anchor couldn't be kept |
| `timestamps_unavailable` | The model doesn't time its lyrics |
| `prompt_rewritten`, `prompt_enhance_ignored`, `prompt_enhance_failed` | As Image §1.9, for `design_voice`'s description |

**Helper roles** (Base §10.1): `prompt_enhance`, a model that rewrote a description.

## 6. Conformance (AUDIO-nnn)

An engine conforms to Audio 0.1 for the operations it offers when:
- every offered operation's descriptor lists its required inputs and outputs (`operations.json`);
- the parameters it exposes use the vocabulary names, and its offers' `supports` the keys of §4;
- these tests pass. Each asks for an offer's cheapest tier, so slow models fit `--job-timeout`.

| Test | Checks |
|---|---|
| AUDIO-001 | Descriptors match the operations table: required inputs and outputs of the right kinds, only vocabulary parameters, the required `edit` |
| AUDIO-002 | Offers' `supports` keys have the profile's types and their limits are the profile's fields; a streaming offer states its `sample_rate` |
| AUDIO-003 | Audio outputs report `sample_rate`, `channels` and `duration_s`, and a WAV file agrees to within a frame |
| AUDIO-004 | Every MUST input format is accepted: WAV at 16 and 24 bits and in float, and FLAC |
| AUDIO-005 | `speak`: `voice`, `voice_ref` and neither each route to an offer that supports them; provenance names a preset voice; `voice` with `voice_ref` is 400 |
| AUDIO-006 | An emotion the named model doesn't list is 422; an alias is resolved by the engine (`fearful` runs as `afraid`) |
| AUDIO-007 | A cue the model can't perform is removed with `cue_unsupported`; `[pause 1s]` gives at least 0.8 s of silence |
| AUDIO-008 | `design_voice` returns `count` samples with `effective.text` and seed; the same seed reproduces a sample; a sample clones through `speak` |
| AUDIO-009 | `edit_speech`: a listed edit runs; an unlisted kind is 422; one missing its fields is 400; `keeps_length` keeps it |
| AUDIO-010 | `generate`: `count` sounds, each `duration_s` long to the frame, each seeded; the same seed reproduces; an unseeded request reports its seed |
| AUDIO-011 | `compose`: one song with its facts, `effective.duration_s` and seed; the same seed reproduces; an edit without source and a score without lyrics are 400; no `named_only` offer runs by default |
| AUDIO-012 | `compose` `extend`: `before_s` + source + `after_s`, to the frame |
| AUDIO-013 | `compose`: a `score`, `reference` or `edit` to an offer without the key is 422 `unsupported_parameter` |
| AUDIO-014 | `output.sample_rate` is honoured; an un-offered media type is 422 `unsupported_parameter`; a seed of 2³² is 422 `out_of_limits` |

Base's tests of what each offer supports (BASE-014 to BASE-018), assets (BASE-032 to BASE-035) and streamed output
(BASE-053 to BASE-057) run on the Audio operations an engine offers.

## 7. Later, and outside

- **Later (generative):** `audio.speak_dialog`, two-speaker scenes (Dia2), with a structured script so clients never
  write `[S1]`; and speaking from a description in one pass (§3.1).
- **Later (tools):** `audio.separate` (stems), `audio.enhance` (loudness and cleanup), codecs.
- **Outside MES:** speech-to-text, emotion recognition and voice chat. Apps link these directly through MLXEngine.
