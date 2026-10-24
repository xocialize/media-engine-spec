# RFC 0003: What each model supports, and its voices

| | |
|---|---|
| **Status** | Draft |
| **Affects** | Base 0.1 (§6, §6.1, §10.1, §10.3, §15, §18); the profiles define their keys |
| **Author** | xocialize |
| **Decision** | A-4 in [`docs/AUDIO-EVALUATION.md`](../docs/AUDIO-EVALUATION.md) §8 (from §3.3) |

## Problem

One descriptor gathers models that accept different things, and the descriptor can only describe the operation as a
whole.

**Example.** An engine offers `audio.speak` with four models:

| Model | Voices | Cloning | Emotion | Languages | Seed |
|---|---|---|---|---|---|
| Kokoro-82M | 10 presets (`af_heart`, `bm_george`, …) | None | None | English | Ignored: the package reads none |
| Gepard-1.0 | None | A clip | None | English | Ignored: decoding is greedy (`GepardPackage.swift:29`) |
| IndexTTS-2.5 | None | A clip | 8 labels, and native target duration | zh, en, ja, es, ar | Used |
| Qwen3-TTS 1.7B | 9 presets, or designed from a description | A clip with its transcript | Instructions | Multilingual | Used |

A client sends a clip to clone, with `emotion: {label: "happy"}`, and names no model. Only IndexTTS-2.5 can serve it,
and nothing in the descriptor says so. Name Kokoro instead, and it speaks in its default voice: it falls back
silently, without a warning (`KokoroTTSPackage.swift:132-139`).

Base already asks for better:
- §6 rule 4 says what a model can't honour MUST be in the descriptor, not found by failure.
- §6 rule 1 forbids model-specific `params`.
- `limits` apply to the operation as a whole.

So there's nowhere to say it. Image has the same gap. Image §2 says engines "whose models can't use" a
`negative_prompt` omit it from the descriptor, which fails as soon as one model can and another can't. Its
`negative_prompt_ignored` warning applies "only when the descriptor didn't already say the model can't use one", and
the descriptor has nowhere to say that. A model limited to 1 MP has no way to say so beside one that allows 4 MP.

MLXEngine solved this in-process with declared controls: `TTSControls` (`emotionModes`, `supportsTargetDuration`,
`speakerTags`, `maxSpeakers`), `STTControls`, and `StreamGranularity`. A request for a control a package doesn't
declare is refused before admission (`checkDeclaredControls`). This RFC carries that rule over the wire.

## Proposal

A model offer gains two optional fields:
- `supports`: facts about what the model accepts;
- `limits`: its own, narrower limits.

A model's preset voices aren't in the descriptor. A client that has chosen a model asks for its voices with
`GET {path}/operations/{operation}/models/{model}/voices`, or over MCP with the `mes_list_voices` helper. The offer
only says how many there are (`supports.voices`). Search, filters, favourites and caching stay in the client.

A request then implies the offers that can serve it, as adapters already do (§6.3 rule 2).

### §6 Capability descriptors

The `models` row of the table gains `supports?` and `limits?` (§6.4). Voices are listed separately (§6.5).

### §6.4 What an offer supports (new)

`supports` on a model offer is an object. Each key states one fact about the model, beyond what every offer of the
operation accepts. Base defines a few keys, and each profile defines keys for its operations. A key's definition gives:
- its type and meaning;
- what an offer that omits it supports;
- its class, one of:

| Class | Meaning |
|---|---|
| **Gate** | Some request content uses the key: a parameter, an input, or a value of one. That request needs an offer that supports it. |
| **Warn** | An offer without the key still runs the request, and warns with the code the definition names. |
| **Fact** | No request uses the key. It informs clients, e.g. an output sample rate. |

An offer's `limits` take the descriptor's `limits` fields, and the limit fields the profile defines. Each value MUST
NOT exceed the operation's own: the operation's limits are the most any offer allows, and an offer's narrow them for
that model.

Rules:
1. **Absence.** A key's definition says what omitting it means. When a profile adds a key to an existing version, the
   default MUST be that version's current behaviour, so older offers keep their meaning. For example, Image's
   `negative_prompt` would default to `true`.
2. **A request implies its offers.** With no model named, the engine chooses among the offers whose gate keys and
   `limits` admit the request. It then applies §6 rule 2 (tier, policy, `named_only`, `default`) and §6.3 rule 2
   (adapters). If none admits the request, that is 422:
   - `unsupported_parameter` for a gate key;
   - `out_of_limits` for a limit.

   `param` names what no offer admits.
3. **A named model** that doesn't support what the request uses gets the same answers: 422 `unsupported_parameter`
   for a gate, and 422 `out_of_limits` for a limit. The engine MUST NOT ignore it or substitute a model.
4. **Warn keys** never narrow the choice. An offer without the key runs the request and warns.
5. **Names.** An engine uses only keys that Base or the operation's profile defines, or `x-<vendor>.<name>` keys as
   for extensions (§6.2). Clients MUST ignore keys they don't know.
6. **Discovery first.** Clients read `supports` and `limits` before naming a model. An engine older than this
   section declares neither, and its offers behave as each key's absence says.

**Base keys:**

| Key | Type | Absent | Class | Meaning |
|---|---|---|---|---|
| `stream` | boolean | `false` | Gate: a request's `stream` ([RFC 0002](0002-streamed-output.md)) | The model can stream its output |
| `seed` | boolean | `true` | Warn: `seed_ignored` | `false`: the result doesn't depend on a seed, e.g. greedy decoding |
| `voices` | integer | `0` | Fact (the voice rules are in §6.5) | How many preset voices the model offers. Above 0, the client can list them (§6.5). |

### §6.5 Voices (new)

A **voice** is a speaker identity a model offers by name: a preset voice. Engines offer only voices the model ships or
the operator installed. A client's own voice is a reference input, and an asset when reused
([RFC 0001](0001-assets.md)), not a voice.

**Listing.** `GET {path}/operations/{operation}/models/{model}/voices` returns `{voices: [Voice], etag}` for a model
whose `supports.voices` is above 0. It supports `ETag` and `If-None-Match`, as `GET {path}/operations` does. A model
the operation doesn't offer is 404 `not_found`, and so is a model with no voices.

Each Voice has:

| Field | Meaning |
|---|---|
| `id`, `title` | The voice. An id names the same voice in every model that lists it. |
| `languages` | OPTIONAL. The BCP 47 tags the voice speaks well. When absent, the model's own languages apply. |
| `tags` | OPTIONAL. Descriptive words for pickers and agents: e.g. `female`, `british`, `calm`, `narration`. A profile MAY suggest a vocabulary. |
| `notes` | OPTIONAL. Usage guidance, as for model offers (§6 rule 5) |
| `sample` | OPTIONAL. An `href` on the engine to a short audio sample of the voice. It is fetched with the usual authorization. |
| `license` | OPTIONAL. The voice's own terms (§10.2), on top of its model's, such as a voice actor's consent terms |

**Changes.** When an operator adds or removes voices, `supports.voices` changes, and with it the descriptor. That
change is announced with `engine.operations_changed` (§6 rule 3, §11). A client that keeps a model's list revalidates
it with its `etag`.

**The catalogue is the client's.** The engine serves the list and nothing more. Searching, filtering by language or
tag, favourites, recently used and caching belong to the client, which is free to present the list any way it likes.

Rules:
1. **Requests.** A profile parameter names the voice by id (Audio: `voice`). Base adds no request field.
2. **A voice implies its model**, as an adapter does (§6.3 rule 2). With no model named, the engine chooses among the
   offers that list the voice. These are 422 `unsupported_parameter`, with `param` naming the profile's parameter:
   - a voice no offer lists;
   - a voice the named model doesn't list;
   - a voice listed only by offers the engine may not choose.
3. **Licences.** The licence policy covers voices (§10.3), and provenance names the voice that spoke (§10.1).

### §6.1 UI hints

`widget` gains `voice`: a picker filled from the chosen model's voice list (§6.5), which can play each `sample`.

### §10.1 Results

`provenance` gains `voice? {id, title?, license?}`, present when a job used one of the model's voices (§6.5).

### §10.3 Policy

`license: commercial-use` also requires a voice's own `license`, when it has one, to permit commercial use. If it
doesn't, the request is 422 `policy_unmet`, as for adapters.

### §15 MCP binding

- **Model lines.** Each model's line in the tool description gains its gate keys and limits in short form, e.g.
  `supports: stream, emotion=label`. A model with voices says how many, e.g. `10 voices (mes_list_voices)`.
- **Helper tools** gain `mes_list_voices {operation, model}`. It returns the model's voice list (§6.5): one line per
  voice in the text content (id, title, languages, tags, licence), and the list as `structuredContent`. An agent
  names a model, lists its voices, then calls the operation's tool with `model` and `voice`.

### §18 Registries

- A new registry, **Base `supports` keys**, holds `stream`, `seed` and `voices`.
- Profiles register their own keys, with their limit fields.
- UI widgets gain `voice`.

### Schemas

| Schema | Change |
|---|---|
| `descriptor.schema.json` | `ModelOffer.supports`: an object, with `propertyNames` `^([a-z][a-z0-9_]*|x-[a-z0-9]+\.[a-z0-9_]+)$`. The Base keys are typed, and profile schemas type their own. |
| `descriptor.schema.json` | `ModelOffer.limits`: the descriptor's `limits` object, open to profile limit fields |
| `voices.schema.json` (new) | `{voices: [Voice], etag}`; `Voice` is `{id, title, languages?, tags?, notes?, sample?, license?}` |
| `descriptor.schema.json` | `UiHints.widget` gains `voice` |
| `job.schema.json` | `provenance.voice?` (a new `VoiceRef` in `common.schema.json`) |

### How the profiles would use it (illustrative, not part of this RFC)

**Audio 0.1 draft, `audio.speak`.** The Audio profile defines these keys. The full list, with the normalized emotion,
style and cue labels, is in the evaluation's §4.3–§4.7.

| Key | Type | Absent | Class |
|---|---|---|---|
| `languages` | `[BCP 47]` | Any | Gate: `language` |
| `default_voice` | boolean | `false` | Gate: a request with neither `voice` nor `voice_ref` |
| `voice_ref` | boolean | `false` | Gate: the `voice_ref` input |
| `voice_ref_text` | `unused` · `optional` · `required` | `unused` | Gate: `required` needs `voice_ref_text` |
| `emotions` | `[label]`, from the profile's list (`happy`, `sad`, `angry`, `afraid`, …) | `[neutral]` | Gate: `emotion.label` |
| `emotion_intensity` | boolean | `false` | Warn: `emotion_intensity_ignored` |
| `cues` | `[cue]`, from the profile's list (`laugh`, `cough`, `sigh`, …) | `[pause]` | Warn: `cue_unsupported` |
| `target_duration` | boolean | `false` | Gate: `target_duration_s` |
| `sample_rate` | integer | none | Fact |

Limit fields: `max_text_chars` and `max_voice_ref_s`.

Three of the offers from the example:

```json
[
  {"id": "kokoro-82m", "title": "Kokoro 82M", "quality_tiers": ["draft"], "license": {…},
   "supports": {"seed": false, "voices": 10, "languages": ["en-US", "en-GB"], "default_voice": true,
                "sample_rate": 24000},
   "limits": {"max_text_chars": 2000}},
  {"id": "gepard-1.0", "title": "Gepard 1.0", "quality_tiers": ["standard"], "license": {…},
   "supports": {"stream": true, "seed": false, "languages": ["en"], "voice_ref": true, "sample_rate": 22050}},
  {"id": "indextts-2.5", "title": "IndexTTS 2.5", "quality_tiers": ["best"], "license": {…},
   "supports": {"languages": ["zh", "en", "ja", "es", "ar"], "voice_ref": true,
                "emotions": ["neutral", "happy", "angry", "sad", "afraid", "disgusted", "melancholic", "surprised",
                             "calm"],
                "emotion_intensity": true, "target_duration": true, "sample_rate": 22050}}
]
```

A client that picks Kokoro asks for its voices, `GET {path}/operations/audio.speak/models/kokoro-82m/voices`:

```json
{"etag": "\"v1\"",
 "voices": [
   {"id": "af_heart", "title": "Heart", "languages": ["en-US"], "tags": ["female", "american"],
    "sample": "/mes/v0/operations/audio.speak/models/kokoro-82m/voices/af_heart/sample"},
   {"id": "bm_george", "title": "George", "languages": ["en-GB"], "tags": ["male", "british"]}
 ]}
```

With these, the example request routes as expected:
- A clone with `emotion: {label: "happy"}` and no model named goes to IndexTTS-2.5.
- The same request naming Kokoro is 422 `unsupported_parameter` with `param: "voice_ref"`, instead of a default voice.
- A seed sent to Gepard or Kokoro runs, with `seed_ignored`.

**Image 0.1.** It could add `negative_prompt` (boolean; absent `true`; class Warn: `negative_prompt_ignored`) and
per-offer `limits.max_megapixels`. That gives Image §2's "engines whose models can't use one" a place to say so. Both
are changes to the Image profile, not to this RFC.

**MLXEngine mapping (DLV-9).** The adapter can fill most keys from what the packages already declare:

| `supports` key | From |
|---|---|
| `emotions`, `emotion_description` | `TTSControls.emotionModes`, with the package's labels mapped to the profile's (the E12 packages already share them) |
| `target_duration` | `TTSControls.supportsTargetDuration` |
| `stream` | `StreamGranularity.audioChunk` |

Three things aren't declared anywhere in MLXEngine yet: voice catalogues (E6's speaker half), languages per surface,
and output sample rate per surface (evaluation §6). Until they are, the adapter would need a table per package, which
the contract set out to retire.

**A voice-list helper on our packages.** The voice list endpoint needs something to read. Each TTS package with
presets would gain a helper the adapter calls when a client names that model and asks for its voices, e.g.
`voices() -> [VoiceInfo]` (id, title, languages, tags, an optional sample clip). Kokoro's 10 voices (`KokoroVoice`) and
Qwen3-TTS CustomVoice's 9 are hardcoded in their packages and in clients today. This is the speaker half of E6, and
it belongs to the MLXEngine contract and the audio packages, not to this RFC.

## Compatibility

- **Additive.** It lands in the Base 0.1 draft in the next minor release, with RFCs 0001 and 0002.
- **Older engines** declare no `supports` or `limits`, and serve no voice lists. Their offers behave as each key's
  absence says, which rule 1 makes their current behaviour.
- **Older clients** ignore the new fields when they decode. A client that names a model, and asks it for something
  the offer now says it doesn't support, gets 422 where it used to get a silent fallback. §6 rule 4 already required
  that, so this is a fix.
- **The MLXEngine-backed engine** changes behaviour: Kokoro refuses a clone request, and Gepard warns on a seed. Both
  are §5.4 fixes in the evaluation.

### What it takes to implement

- **MESCore:** `ModelOffer` gains `supports` and `limits`, a `Voice` type, and the profile tables gain their keys,
  with each key's class and what it gates.
- **MESEngineCore:**
  - Model choice (`JobRegistry`, where adapters already narrow the candidates) filters offers by gate keys, limits and
    voices before §6 rule 2 picks. `defaultModel(for:…)` keeps getting only offers that admit the request. Warn keys
    produce their warnings through the kit, so engines don't each implement them.
  - `MediaEngine` gains `voices(operation:model:) async -> [Voice]`, with a default that returns none. The kit serves
    the route, its ETag and `mes_list_voices` from it.
- **MESClientKit:** `voices(operation:model:)`, revalidated by ETag. The catalogue UI is the app's.
- **MESFormsUI:** the `voice` widget, and controls hidden or disabled for what the chosen model doesn't support.

## Conformance

| Test | Checks | Spec |
|---|---|---|
| BASE-014 | Offers' declarations are consistent: known keys of the right types; offer limits within the operation's | §6.4 |
| BASE-018 | Voice lists: a model with `supports.voices` above 0 serves that many voices with an ETag, and If-None-Match answers 304; ids are unique, and one id names one voice in every model; a model without voices, or not offered, is 404 | §6.5 |
| BASE-015 | A gate the named model doesn't support, or a limit it doesn't allow, is 422 `unsupported_parameter` or `out_of_limits`; with no model named, the plan names an offer that admits the request | §6.4 rules 2–3 |
| BASE-016 | A voice implies its model: the plan names an offer that lists it; an unlisted voice, or one the named model doesn't list, is 422; provenance names the voice | §6.5, §10.1 |
| BASE-017 | `supports.seed: false`: a request with a seed runs, and warns `seed_ignored` | §6.4 |

The mock engine can carry these on Image: two `image.generate` offers that differ in `negative_prompt` and
`limits.max_megapixels`. The voice tests (BASE-016, BASE-018) need the Audio draft, or a mock offer with voices.
BASE-080 extends to the `mes_list_voices` helper.

## Alternatives considered

1. **One descriptor per model** (`audio.speak` repeated, or `audio.speak.kokoro`). It breaks MES's premise that
   clients ask for operations, not models, and §6 rule 6.
2. **Model-specific `params`, keyed by model.** §6 rule 1 forbids it for a reason: clients would learn every model.
3. **Per-offer `params` schemas.** They are exact, but heavy. Clients would merge schemas to draw one form, and the
   keys that matter here (languages, emotion modes, a voice list) are facts a picker reads, not shapes to validate.
4. **Refusing at run time only,** with a clear error. Simpler, but it breaks §6 rule 4. A client finds out after
   uploading a clip and queueing.
5. **Voices as a profile-only concept.** Voices are Audio's for now. But Video with sound (LTX, VID-2) will take a
   voice, and voices have the same shape as adapters (an id, a licence, a model they imply), so Base defines the shape
   once. This follows A-4.
6. **Voices inline in the descriptor,** like adapters (the first draft of this RFC). A client then has every model's
   catalogue in one fetch, but the descriptor grows with every preset, and a model with hundreds of voices makes it
   large. Fetching a named model's voices when asked keeps descriptors small. It also keeps the catalogue, how it's
   searched and shown, in the client.

## Open questions

- **Tags vocabulary.** The evaluation sketched a `gender` field. This draft uses free `tags`, so the spec doesn't fix
  a taxonomy of speakers. Should the Audio profile suggest a list (`female`, `male`, `child`, accents, styles)?
- **Voices across tiers.** Qwen3-TTS's presets exist at more than one quantization. One id across offers covers it,
  but a voice listed by both a `draft` and a `best` offer then routes by tier, which may surprise a client that
  picked the voice for its sound.
- **Paging.** A model with thousands of voices would want `?after=` paging on the list. Our largest has 10, so this
  draft leaves it out.
- **One list for the operation.** A client that wants a voice before it picks a model would need
  `GET {path}/operations/{op}/voices` across models. This draft keeps the list per model: name the model, then list.
