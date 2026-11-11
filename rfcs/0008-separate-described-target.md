# RFC 0008: Separating a described sound, and saying an offer watermarks

| | |
|---|---|
| **Status** | Draft (2026-11-11), awaiting the operator's acceptance |
| **Affects** | Audio 0.1 (§2, §3, §3.6, §4.1, §6); Base 0.1 (§6.4, §10.2 rule 3, §18); `schemas/v0/profiles/audio/` (`operations.json`, `vocabulary.schema.json`, `supports.schema.json`, `job-request.schema.json`); `schemas/v0/base/descriptor.schema.json` |
| **Author** | xocialize |
| **Context** | AB-A-0269 (mlx-audio). SAM-Audio base in Swift-MLX: `xocialize/mlx-sam-audio-swift` v0.1.0, weights `mlx-community/sam-audio-base-swift-fp16` (AB-R-0827); operator approval AB-D-0221, licence AB-D-0220, watermark AB-D-0222. The engine contract's side is AB-A-0268 (mlx-engine), open |
| **Decision** | mlx-apps, as the spec's owner, on AB-A-0269. Not landed: MESKit v0.13.0 follows acceptance |

## Problem

`audio.separate` (Audio §3.6, [RFC 0006](0006-audio-separate-and-auk-edits.md)) makes stems from a registered label
set: `speaker`, `singing`, `voices`, `vocals`, `instrumental`, `drums`, `bass`, `other`. A client picks from the list.
It cannot say what to separate.

SAM-Audio (Meta) separates the sound a client describes in words: "speech", "dog barking", "drums". It returns two
recordings, the described sound and everything else. A client may also mark stretches of the mixture where the sound
is heard, or is not, and the model uses them as anchors. None of this fits §3.6:

1. **No description.** There is no parameter for the words, and no stem to name the result: "dog barking" is not a
   label anyone can register.
2. **No spans.** Nothing carries the marked stretches.
3. **No word for a watermark.** Every SAM-Audio output carries an AudioSeal watermark (AB-D-0222). Base §10.2 rule 3
   says a watermark an input carries is kept, but an offer has nowhere to say it adds one.

What was measured for the first offer (AB-R-0827): 48 kHz mono out; the two outputs are generated, so the target plus
the residual is not the mixture, sample for sample; about 3.8 s for a 10 s clip, 7.5 GB at peak; clips of about 10 s.
It works on general sounds, speech against music, drums and bass, and not on guitar-like instruments. A description
must be a few lowercase words ("speech", "dog barking"); a sentence ("a person speaking") fails.

## Proposal

### Audio §3.6: a described target

**Two more stems.**

| Stem | What it holds | Produced by |
|---|---|---|
| `target` | The sound `describe` names | SAM-Audio |
| `residual` | The mixture without that sound | SAM-Audio |

They are stems like the others: one output each, named `target` and `residual`, the mixture's length, listed in
`supports.stems` and in the descriptor's outputs. What `target` holds is the request's to say, with `describe`.

**`describe`** (new parameter): the sound to separate, in a few words. A string of 1 to 200 characters with at least
one that isn't a space.
- It names a sound: a noun or verb phrase such as `speech`, `dog barking`, `rain on a window`. It is not an
  instruction and not a sentence. An offer's `notes` (Base §6 rule 5) say how its model wants it written.
- Case and the spaces around it don't count: `Dog Barking` and `dog barking` are one request. An engine folds them
  for a model that needs lowercase, without a warning, and `effective.describe` is the text the model was given.
- It is written in a language the offer lists in `supports.languages`, where the offer lists any (a Fact here, as in
  `generate`).
- Gate: `supports.described_target`. Sent to a named offer without it, or when no offer the engine may choose has it,
  it is 422 `unsupported_parameter` with `param: "describe"`.

**`describe` and `stems`.**
- With `describe` and no `stems`: those of `target` and `residual` the chosen offer lists, in that order.
- With `describe`, `stems` may name `target`, `residual` or both, and nothing else. Another stem beside `describe` is
  400 `invalid_request` (`param: "stems"`): one request separates by description or by label, not both.
- `target` or `residual` in `stems` without `describe` is 400 `invalid_request` (`param: "describe"`).
- `describe` with a `speaker` pick is 400 `invalid_request` (`param: "speaker"`).
- Without `describe` and without `stems`, the stems made are the offer's less `speaker` (as today), `target` and
  `residual`. A named offer that leaves none, one that only separates by description, is 422
  `unsupported_parameter` with `param: "stems"`, and its message says to give `describe`. This is the answer a named
  `speaker`-only offer already gives a request without a pick. With no model named, the engine chooses an offer that
  has a stem to make.

**`spans`** (new parameter): where in the mixture the described sound is heard, or is not. A list of 1 to 32 spans,
each `{start_s, end_s, present}`:
- `start_s` and `end_s` are seconds from the mixture's start, `start_s` ≥ 0 and `end_s` > `start_s`;
- `present: true` says the described sound is heard throughout the span, `false` that it isn't heard in it. `present`
  is required. Time no span covers says nothing.
- Spans don't overlap; one may start where another ends. The order doesn't matter.
- Gate: `supports.spans`. Sent to an offer without it: 422 `unsupported_parameter`, `param: "spans"`.
- `spans` without `describe`, a span with `end_s` ≤ `start_s`, and two spans that overlap are each 400
  `invalid_request` (`param: "spans"`).
- A span that ends more than a frame after the mixture does is refused with `out_of_limits` (`param: "spans"`): 422
  at submission, or as the job's error when the engine reads the mixture's length only as the job starts. This is the
  rule for a mixture longer than `max_duration_s`, for the same reason: the request alone doesn't show the mixture's
  length. A span is never clipped to fit.

Spans guide the model; they don't cut the outputs. `target` and `residual` are still the mixture's length.

**Outputs and effective values.** As §3.6 today: one output per stem made, named by the stem, in the order asked
(else `target`, then `residual`). `effective.stems` lists them, `effective.describe` is the description as the model
was given it, and `effective.spans` the spans that ran, in time order. `effective.seed` as before.

**How the stems are made** stays the offer's fact, `supports.stem_method`. SAM-Audio is `regenerated`: its target
plus its residual is not the mixture, and a client MUST NOT make either from the other by subtraction. An offer that
masks may make `residual` as the mixture minus `target`. A `regenerated` offer lists `residual` only when its model
makes one.

**`supports` for `audio.separate`** gains:

| Key | Type | Absent | Class |
|---|---|---|---|
| `described_target` | boolean | `false` | Gate: `describe` |
| `spans` | boolean | `false` | Gate: `spans` |

An offer states `described_target: true` exactly when its `stems` list `target`. It lists `residual` only with
`target`, and states `spans: true` only with `described_target: true`. An offer may list labelled stems too: it then
separates either way, one way per request.

`supports.languages` on a `separate` offer with `described_target` is the languages `describe` may be written in.

**The first offer**, as its plugin would state it (the plugin's to settle, shown here to test the shape):

```json
{
  "id": "sam-audio-base",
  "title": "SAM-Audio Base",
  "license": { "spdx": "LicenseRef-SAM", "commercial_use": true, "terms_url": "…", "user_accept_required": true },
  "notes": "Name the sound in a few lowercase words: 'speech', 'dog barking'. Sentences don't work. It separates general sounds, speech from music, drums and bass; not guitar-like instruments.",
  "supports": {
    "stems": ["target", "residual"],
    "described_target": true,
    "spans": true,
    "stem_method": "regenerated",
    "languages": ["en"],
    "sample_rate": 48000,
    "channels": 1,
    "watermark": "audioseal"
  },
  "limits": { "max_duration_s": 10 }
}
```

A request, and what it reports:

```json
{
  "operation": "audio.separate",
  "inputs": { "audio": { "upload": "upl_d4" } },
  "params": {
    "describe": "dog barking",
    "spans": [
      { "start_s": 1.2, "end_s": 2.0, "present": true },
      { "start_s": 6.0, "end_s": 9.5, "present": false }
    ]
  }
}
```

Outputs `target` and `residual`; `effective.stems: ["target", "residual"]`, `effective.describe: "dog barking"`,
`effective.spans` as sent, `effective.seed` the seed the engine picked.

### Base §6.4: an offer says its outputs are watermarked

A new Base `supports` key:

| Key | Type | Absent | Class | Meaning |
|---|---|---|---|---|
| `watermark` | string | none stated | Fact | Every output this model makes carries an imperceptible watermark, made by the named scheme: a lowercase id such as `audioseal` or `synthid` |

- It is a Fact: no request turns it on or off. An engine that lets an operator turn the mark off states the key only
  while it is on.
- Absent means the offer states none, not that there is none.
- A client SHOULD show it with the offer, next to the licence. It is not a licence `notice` and needs no acceptance.
- Base §10.2 rule 3 already keeps a watermark through later operations. It gains one sentence: an offer that adds a
  watermark of its own says so with `supports.watermark`.
- §18 registers the key. Scheme ids aren't a registry: an id is the scheme's own name, lowercased, and a client shows
  one it doesn't know as written.

It goes in Base because image and video models mark their outputs too, and one key serves them all.

### Schemas

| File | Change |
|---|---|
| `audio/vocabulary.schema.json` | `stem` gains `target`, `residual`; `stems` `maxItems` 10; new `describe`, `spans` |
| `audio/operations.json` | `audio.separate`: outputs `target`, `residual` (`stem: true`); vocabulary `describe`, `spans` |
| `audio/job-request.schema.json` | `audio.separate` params: `describe`, `spans`; `spans` requires `describe` |
| `audio/supports.schema.json` | `separate_supports`: `described_target`, `spans`; `described_target: true` requires `target` in `stems` and the reverse; `spans: true` requires `described_target: true` |
| `base/descriptor.schema.json` | `supports.watermark`: a string, `^[a-z0-9][a-z0-9._-]*$`, at most 64 characters |

### MESKit

- **MESCore:** `AudioProfile.stems` with the two stems, `Param.describe` and `.spans`, `SupportsKey.describedTarget`
  and `.spans`, a `SeparationSpan` value; `ModelOffer.watermark`, beside `voiceCount`.
- **MESEngineKit:** `AudioProfileRules` applies every 400 and both gates above, and the default stems. `RunContext`
  gives the engine `describe` and `spans`, and a check of the spans against the mixture's length for the engine to
  call when it has read the mixture (input lengths are the engine's to check, §4.1). The plan carries
  `effective.stems`; the engine reports `effective.describe` and `effective.spans`.
- **MESClientKit:** `JobResult.stems` and `downloadStems` already read stems by name, and take the new two.
- **MESFormsUI:** a "Sound to separate" field, shown only when an offer the request may run on has
  `described_target`, with the hint "Name the sound in a few words: speech, dog barking. Sentences don't work."; a
  spans editor (start, end, heard or not heard) shown only where an offer has `spans` and a description is given; the
  stems picker offers `target` and `residual` only beside a description. The form says before sending what an engine
  would refuse. An offer's `watermark` shows on its model row.
- **mes-mock-engine:** a `mock-separator-described` offer shaped like the one above.

## Compatibility

Additive while Audio and Base are 0.1.
- `describe`, `spans`, `target` and `residual` are new. A 0.12 client never sends them, and a 0.12 engine never offers
  them. A 0.12 client's stems picker may show `target` and `residual` for a described offer, since it lists every
  stem an offer makes; choosing one gets a 400 that says to give `describe`.
- `described_target` and `spans` are absent `false`, today's behaviour (Base §6.4 rule 1).
- A request with neither `stems` nor a pick, and no model named, never lands on a described-only offer: it has no
  stem to make without a description.
- `watermark` is a Fact; clients ignore keys they don't know (Base §6.4 rule 5).
- A 0.12 conformance tool reports `target` and `residual` outputs as stems it doesn't know (AUDIO-001): run the 0.13
  tool.

## Conformance

| Test | Checks |
|---|---|
| AUDIO-019 | `separate` by description: an offer with `described_target` runs with `describe` and returns the outputs `target` and `residual` (those it lists), each with its facts and the mixture's length to within a frame; `effective.stems` and `effective.describe` report them; `stems: [target]` returns the one |
| AUDIO-020 | `separate`: `describe` to a named offer without `described_target` is 422 `unsupported_parameter` (`param: "describe"`); `target` without `describe`, and `describe` beside a labelled stem, are 400; a described-only offer named without `describe` is refused |
| AUDIO-021 | `separate` spans: an offer with `spans` runs with them and `effective.spans` echoes them; `spans` to an offer without the key is 422; `spans` without `describe`, a span with `end_s` ≤ `start_s`, and overlapping spans are 400; a span past the mixture's end is refused `out_of_limits`, at submission (422) or as the job's error |

AUDIO-002 also checks that `described_target` and `target` go together, that `residual` comes only with `target`, and
that `spans` comes only with `described_target`. AUDIO-015 runs an offer's labelled stems only: `target` and
`residual` are AUDIO-019's. Base's descriptor schema types `watermark` (BASE-010's schema check covers it).

## How this lines up with the engine contract (AB-A-0268)

The MES shape doesn't wait on the contract: a plugin maps one to the other.

| MES | Proposed on `AudioSeparationRequest` / `AudioSeparationControls` |
|---|---|
| `describe` | `description: String?` |
| `spans[].{start_s, end_s, present}` | `spans: [SeparationSpan]?`, `{startSeconds, endSeconds, present}` |
| stems `target`, `residual` | `Stem.target`, `Stem.residual` |
| `supports.described_target`, `supports.spans` | `describedTarget`, `spans` |
| `spans` without `describe`: 400 | refused |
| a span with end ≤ start, or past the mixture: 400, `out_of_limits` | refused |
| a described-only offer without `describe`: refused | "a surface declaring describedTarget and no fixed stems refuses a request without a description" |
| overlapping spans: 400 | not stated; a plugin never forwards them |

If mlx-engine reshapes its side (a rename, or `present` as two lists), the plugin's mapping changes and this RFC
doesn't. If the contract ships without spans, the offer leaves `supports.spans` out until it has them.

## Alternatives considered

- **Name the output by the description** (`dog barking`). Base names outputs from the descriptor, which can't list
  what a client will type. Two fixed names keep outputs readable by name, and `effective.describe` says what
  `target` holds.
- **An open stem set**, the description as a stem. RFC 0006 turned this down for labels; a description is not a
  label, and a client could not tell `vocals` the registered stem from `vocals` the description.
- **`describe` as a text input**, like `design_voice`'s `description`. Inputs are the material an operation works on
  (the text to speak, the mixture). `describe` chooses which stem to make, as `speaker.saying` does, so it is a
  parameter, and its hint travels in the descriptor's `x-mes-ui`.
- **`description` as the name.** The profile already uses it for an input (`design_voice`), in `emotion`, and in a
  `timbre` edit. `describe` is free, and reads as what the request does.
- **A span past the mixture as 400**, as the ask proposed. An engine learns the mixture's length when it reads the
  file, often after the job is accepted; 400 is for what the request alone shows. `out_of_limits`, at submission or
  as the job's error, is what a too-long mixture already gets.
- **Clipping a span to the mixture.** A silent change to what the client marked. Base asks for a warning on every
  change; a refusal is plainer, and the tolerance of a frame covers rounding.
- **`present` optional, absent `true`.** One word saved; a span whose meaning depends on a default is easier to get
  wrong in a list that mixes both kinds.
- **A limit on how a description is written** (`max_describe_words`, a pattern). What works is the model's, not a
  number: "dog barking" and "rain on a window" pass, "a person speaking" fails. The profile says what a description
  is, the offer's `notes` say what its model likes, and the form's hint says the same.
- **A candidates count** (best of several draws). The measurements that suggested it were superseded: one draw passes
  (AB-A-0269, first reply). Nothing to add.
- **The watermark as a licence `notice`.** A notice is text the terms require shown, and clients must show it with
  every result. A watermark is a property of the output, the operator's choice here, not a term.
- **The watermark in `notes`.** Free text a client can't read. A key lets an app say "watermarked" in its own words
  and lets an agent filter on it.
- **The watermark in Audio's `supports` only.** Image and video offers would each need their own.
- **Reporting the watermark on each output.** The offer's fact covers every output it makes; a per-output field can
  follow if an offer ever marks some outputs and not others.
