# RFC 0006: Separation, and what AuK's editor needs

| | |
|---|---|
| **Status** | Accepted (2026-11-05) |
| **Affects** | Audio 0.1 (§1.8, §2, §2.2, §3, §3.3, new §3.6, §4.1, §4.2, §6, §7); `schemas/v0/profiles/audio/` (`operations.json`, `operations.schema.json`, `vocabulary.schema.json`, `supports.schema.json`, `job-request.schema.json`) |
| **Author** | xocialize |
| **Context** | Gaea's G5 plan (`gaea-mes-media-server/Docs/Gaea - G5 audio plan.md`, gaps S-1 to S-5; decisions G-27 to G-31 = AB-D-0209 to AB-D-0213); AB-A-0250. AuK's engine surfaces in `mlx-auk-swift` v0.3.0 (`AuKSurfaces.separationPlan`, `speechEditControls`), on MLXEngine contract 1.59.0 |
| **Decision** | mlx-apps, as the spec's owner, on AB-A-0250. Landed in MESKit v0.10.0 (see [Decision](#decision)) |

## Problem

AuK (Tencent Hunyuan) speaks, edits speech and separates sources. Audio 0.1's `edit_speech` was modelled on its
instruction set, so most of it fits, but five things don't:

1. **Separation** (S-1). AuK's third surface keeps one speaker of a conversation (the n-th to start talking, or the one
   who says given words), the singing, or every voice. The profile lists `audio.separate` under "Later" (§7). G-29
   asks that it be designed for music stems too, so the fleet's HTDemucs and Mel-Band-RoFormer ports can follow as
   plugins, though G5 ships only AuK.
2. **Dereverberation** (S-2). AuK removes reverb; the profile has only `denoise`.
3. **Humming** (S-3). AuK's nonverbal sounds are breath, laugh, cough and humming; the profile has no `hum` cue.
4. **Where a cue goes** (S-4). AuK adds a cue at the start or the end of a take, never inside it. The profile's
   `add_cue` also places one inline in the transcript (`text`), and nothing tells a client which an offer takes.
5. **Length after an edit** (S-5). Content and speed edits change a take's length. AuK fits an edit to a length, but
   `target_duration_s` is `speak`'s only.

Reading AuK's surfaces turned up two more, which this RFC takes too:

6. **Removing every cue** (S-6). `remove_cue` without a `cue` removes every cue (§3.3). AuK removes one kind of sound
   at a time and refuses the rest ("removeNonverbal needs a sound"), so an offer needs to say so.
7. **The instrumental stem** (S-1). The ask lists `vocals`, `drums`, `bass` and `other` for music. Both fleet music
   separators produce `vocals` and `instrumental` (HTDemucs v4's `htdemucs_ft` vocal branch and Mel-Band-RoFormer, in
   `mlx-demucs-swift` and `mlx-mel-roformer-swift`), the instrumental as the mixture minus the vocals.

## Proposal

### §3.6 Separating sources: `audio.separate`

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `audio.separate` | `audio` (required: the mixture) | `stems`, `speaker`, `seed`, `quality`, `output` | One audio output per stem, named by the stem | The mixture's sources, each the mixture's length (§3.6) |

**Stems** are a registered label set, like cues. A stem is registered when one model produces it.

| Stem | What it holds | Produced by |
|---|---|---|
| `speaker` | One speaker of a conversation, picked by `speaker` | AuK |
| `singing` | The singing alone, every other sound removed | AuK |
| `voices` | Every human voice, speech and singing, everything else removed | AuK (Base, not Flash) |
| `vocals` | A song's lead and backing vocals | HTDemucs, Mel-Band-RoFormer |
| `instrumental` | A song without its vocals | HTDemucs, Mel-Band-RoFormer |
| `drums`, `bass`, `other` | The four-stem split's other three | HTDemucs (four-stem) |

**Request.**
- `stems` lists what to make, unique, at least one. Absent: every stem the chosen offer produces, except `speaker`,
  which needs a pick; with a `speaker` pick and no `stems`, just `[speaker]`.
- `speaker` picks one speaker: `{ordinal: n}`, the n-th to start talking (from 1), or `{saying: text}`, the one who
  says these words. Exactly one of the two.
- The `speaker` stem without a pick is 400 `invalid_request`, and so are a pick with a `stems` list that doesn't name
  `speaker` and a stem listed twice.
- A stem the named offer doesn't list, or that no offer the engine may choose lists, is 422 `unsupported_parameter`
  (`param: "stems"`), and so is a pick kind the offer doesn't list (`param: "speaker"`).

**Outputs.** One audio output per stem made, named by the stem (`speaker`, `vocals`, …), in the order asked. Each
reports its facts (`sample_rate`, `channels`, `duration_s`) and is the mixture's length: to within a frame at the
output's rate. `effective.stems` lists the stems made, and `effective.seed` the seed, as in every seeded operation.
`effective.speaker` echoes the pick.

**How stems are made** is a Fact every offer states, `supports.stem_method`:
- **`masked`:** each stem is the mixture filtered, sample-aligned with it. Stems may be mixed with the mixture or
  subtracted from it; an offer may make one stem as the mixture minus another (an instrumental).
- **`regenerated`:** a generative model makes each stem again at the mixture's length. It is not phase-aligned with
  the mixture, so a client MUST NOT derive anything by subtraction, and an engine MUST NOT offer a stem it could only
  make that way. AuK is `regenerated`.

**Limits.** `max_duration_s` bounds the mixture (AuK: 30 s). A longer mixture is refused with `out_of_limits`, never
trimmed (Audio §1.7, as for `source`: cutting a recording changes what it is): 422 at submission, or as the job's error
when the engine reads the mixture's length as the job starts. Input lengths are the engine's to check (§4.1).

**Variants.** A stem keeps the recording's identity: clients may store stems as versions of it (§3.5, last paragraph).

**`supports` for `audio.separate`:**

| Key | Type | Absent | Class |
|---|---|---|---|
| `stems` | `[stem]` | — (REQUIRED) | Gate: each stem asked. Absent `stems` in the request takes the offer's list less `speaker` |
| `speaker_selection` | `[ordinal · saying]` | `[]` | Gate: the `speaker` pick's kind |
| `stem_method` | `masked` · `regenerated` | — (REQUIRED) | Fact |

### §3.3 Editing speech

- **`dereverb`** (S-2), no fields: remove reverberation.
- **`add_cue` placement** (S-4). `supports.cue_placement`: `[edge · inline]`, absent `[edge, inline]`. Gate: an
  `add_cue` with `at` needs `edge`; one with `text` needs `inline`. The other form to an offer that lacks it is 422
  `unsupported_parameter` (`param: "edit"`).
- **Removing every cue** (S-6). `supports.remove_all_cues`: boolean, absent `true`. Gate: a `remove_cue` without a
  `cue` needs it. AuK declares `false`.
- **`target_duration_s`** (S-5) joins `edit_speech`'s parameters, gated by `supports.target_duration` as in `speak`:
  the edited take should be that long, and one that misses it beyond the offer's tolerance warns `duration_missed`. It
  is bounded by `limits.max_duration_s`. With it, `keeps_length` no longer applies: the take is the length asked for.

### §2.2 Cues

**`hum`** (S-3): humming. AuK's `humming`.

### §2 Vocabulary

`target_duration_s` covers `speak` and `edit_speech`. `stems` and `speaker` are new, for `separate`.

### Conformance

| Test | Checks |
|---|---|
| AUDIO-015 | `separate`: each stem an offer lists runs, and returns one output named by the stem, with its facts, the mixture's length to within a frame; `effective.stems` lists them |
| AUDIO-016 | `separate`: a stem the named offer doesn't list is 422 `unsupported_parameter`; the `speaker` stem without a pick is 400; a pick kind the offer doesn't list is 422 |
| AUDIO-017 | `separate`: a mixture longer than the offer's `max_duration_s` is refused `out_of_limits`, at submission (422) or as the job's error |
| AUDIO-018 | `edit_speech`: `add_cue` in a placement the offer doesn't list is 422; `remove_cue` without a cue to an offer with `remove_all_cues: false` is 422; `target_duration_s` to an offer without `target_duration` is 422, and with it the take is that long (or warns `duration_missed`) |

AUDIO-001 learns stem-named outputs: a descriptor lists the stems its offers produce as outputs (at least one), and
no output that isn't a registered stem. AUDIO-002 requires every `separate` offer to state `stems` and `stem_method`.
AUDIO-009's missing-kind refusal covers `dereverb`.

## Compatibility

Additive while Audio is 0.1:
- `audio.separate` is a new operation. A 0.9 client never asks for it, and a 0.9 engine never offers it. A 0.9
  conformance tool reports a 0.10 engine's `audio.separate` as an operation it doesn't know: run the 0.10 tool.
- `dereverb`, `hum`, `stems`, `speaker` and `target_duration_s` on `edit_speech` are new values and parameters. A 0.9
  client never sends them.
- `cue_placement` and `remove_all_cues` default to today's behaviour (Base §6.4 rule 1), so offers that don't state
  them keep their meaning. A 0.9 client that places a cue inline on AuK gets 422 with the key named, rather than a
  wrong result.
- `operations.json` gains an output field, `stem`; older readers ignore it.

## Alternatives considered

- **One output, `stems`, holding several values.** Base names outputs from the descriptor, and an output has no field
  to say which stem a value is. Naming outputs by stem needs no Base change, and a client reads `outputs` by name as
  it does for every other operation.
- **AuK's three stems only** (G-29's alternative). Leaves Demucs and Mel-Band-RoFormer for another RFC with the same
  shape.
- **An open stem set** (MLXToolKit's `Stem` is open). Clients couldn't label or pick stems they don't know, and two
  engines could name the same source differently. A label is registered when a model produces it, as cues are.
- **`supports.stem_method` absent meaning `masked`.** A regenerating offer that forgot the key would invite
  subtraction. Every `separate` offer states it.
- **A pick without the `speaker` stem adds it** (AuK's own behaviour). A request should say what it gets; the 400
  costs a client one word.
- **Refusing `remove_cue` without a cue for everyone.** Today's offers may remove every cue; S-6 lets an offer say it
  can't, as `cue_placement` does for placement.

## Decision

Accepted on 2026-11-05, as proposed, with the operator's approval of G5 (G-27 to G-31). Landed in MESKit v0.10.0:
- `AudioProfile.stems`, `cues` with `hum`, `editKinds` with `dereverb`, the new supports keys and parameters (MESCore).
- `AudioProfileRules` (MESEngineCore): the 400s for `separate`, the `stems`, `speaker_selection`, `cue_placement`,
  `remove_all_cues` and `edit_speech` `target_duration` gates, and the limit on `target_duration_s`.
- `mes-mock-engine` offers `audio.separate` (a masked and a regenerated offer); MESFormsUI edits `stems`, `speaker`
  and the new edit kinds.
- AUDIO-015 to AUDIO-018, and AUDIO-001 and AUDIO-002 for stem outputs and the required keys.
