# RFC 0002: Streamed output

| | |
|---|---|
| **Status** | Accepted, amended (2026-10-30) |
| **Affects** | Base 0.1 (§4, §6, §7, §10.1, §11, §13, §15, §18) |
| **Author** | xocialize |
| **Decision** | A-1 in [`docs/AUDIO-EVALUATION.md`](../docs/AUDIO-EVALUATION.md) §8 (from §3.2). Reopens MES-PRD OQ-6 ("previews only in v1", D-32) for output. Decided by mlx-apps, as the spec's owner; landed in Base 0.1 §6, §7, §10.1, §11, §13 and MESKit v0.7.0 (see [Decision](#decision)) |
| **Depends on** | [RFC 0003](0003-offer-supports-and-voices.md) for which models stream (`supports.stream`) |

## Problem

An output exists only once its job reaches `holding`, so a client can't use any of it until the whole of it is made.

**Example.** A reading app asks `audio.speak` for a 30-second paragraph. With a model that runs near real time, the
first sample reaches the app after about 30 s. In-process, the same models start much sooner: MLXEngine streams TTS
through `StreamEmitting` (MLXToolKit 1.50), and the first audio arrives at:

| Package | First audio |
|---|---|
| MOSS-TTS-Nano | 62 ms |
| MOSS-TTS-Local, int8 | 149 ms |
| Gepard | ~790 ms (since v0.4.0, which holds the first chunk until it can rule out a silent decode) |

An app that wants that latency today has to link the model itself and drop MES.

`job.preview` isn't a stream:
- each preview replaces the one before, while audio chunks add up in order;
- previews are approximations, and nothing ties them to the output;
- one preview is at most 256 KiB, with no order or completeness.

OQ-6 chose "previews only in v1" before audio was the next profile (OQ-2). This RFC reopens it for streamed
**output** only. Streamed **input**, such as live microphone audio or text arriving while a voice speaks, is a
session, and stays out of Base 0.x (A-3).

## Proposal

A new optional feature, `streaming`. A client may ask for an output to arrive as ordered chunks while the job runs.
The chunks are the output: once the job is `holding`, the output is exactly what was streamed. A client that ignores
the chunks loses nothing.

In this draft only `audio` outputs with a single value stream.

### §4 Engine information

`features` gains `streaming`.

### §6 Capability descriptors

- An output spec MAY carry `stream: {encodings: [...]}`, the encodings this output can stream in. It MAY do so only
  for an output of kind `audio` whose `max` is 1.
- Stream encodings are raw, interleaved PCM, little-endian, without a header:

  | Encoding | Sample |
  |---|---|
  | `pcm_s16le` | 16-bit signed integer |
  | `pcm_f32le` | 32-bit IEEE float |

- Which models stream is per offer: the Base key `supports.stream` (RFC 0003, default `false`).

### §7.1 Submitting

A JobRequest gains `stream`: OPTIONAL, `[{output, encoding?}]`. It names the outputs to stream. `encoding` defaults to
the first one the output spec lists.

- **Not streamable.** An output without `stream` in its spec, or an encoding it doesn't list, is 422
  `unsupported_parameter` with `param: "stream"`.
- **Choosing the model.** Streaming implies its model, as an adapter does (§6.3 rule 2):
  - with no model named, the engine chooses among offers with `supports.stream`;
  - a named model without it is 422 `unsupported_parameter`;
  - so is a request that no offer the engine may choose can stream.

### §7.2 Lifecycle

The plan gains `streams: [{output, encoding, sample_rate, channels}]`, once the model is chosen. A client can set up
playback while the model loads. The stream's sample rate and channels are the output's, after any conversion the
request asked for (an Audio `output` format).

### §11 Events

A new event:

| Type | Data |
|---|---|
| `job.output_chunk` | `{output, index, offset_s, final, data}` |

- **`output`:** the output's name from the descriptor.
- **`index`:** 0, 1, 2, … per output, with no gaps.
- **`offset_s`:** where the chunk starts in the output. It is informative: the exact position is the frame count of
  the chunks before it.
- **`data`:** the chunk's samples in the plan's encoding, as base64. It holds whole frames only (one sample per
  channel), and at most 256 KiB of base64, as for previews.
- **`final`:** `true` on the last chunk of the output. The final chunk MAY be empty.

Rules:
1. **When.** Chunks are sent while the job is `running`. An output's final chunk comes before `job.output_ready`.
2. **Pace.** An engine sends chunks as it makes them, not at playback speed, and doesn't wait for the client. It
   SHOULD send at most 50 chunks a second per output.
3. **Channels.** Chunks go wherever the job's other events go: SSE, WebSocket, and the in-process transport.
4. **Replay.** Chunks are replayed like any other event while the job's outputs exist. After the outputs are purged,
   a replayed chunk carries no `data`.
5. **Failure.** A job that fails or is cancelled after streaming sends no final chunk. What it streamed isn't an
   output, and a client SHOULD treat it as incomplete.

### §7.3 Cancelling

Release while the job is running stops synthesis. Once the engine acts on it, it sends no more chunks, and SHOULD act
within one chunk's duration. That is barge-in: a voice app stops speaking when the user starts.

### §10.1 Results

A new paragraph:

> **Streamed outputs.** A streamed output is the concatenation of its chunks' samples, in `index` order, encoded as the
> output's media type. When that is PCM in the stream's sample format (e.g. `audio/wav` with 16-bit samples for
> `pcm_s16le`), the samples MUST be identical. An engine MUST NOT change audio it has streamed: no normalizing,
> trimming or re-synthesis afterwards. A streamed job need not match a non-streamed job with the same parameters and
> seed. An offer whose streamed results differ SHOULD say so in its `notes`.

The last two sentences describe how our packages work. Gepard's streamed output matched its batch output at 51 dB SNR
(E2): close, not identical. MES therefore promises that the output is what the client heard, and doesn't promise that
the output matches batch.

### §13 Retention guarantees

Rule 2 gains:

> A streamed output's chunks are part of that output. The engine keeps their data only as long as the output, and a
> job record (rule 4) keeps chunk events without `data`. A job that fails or is cancelled deletes its chunks' data
> within 60 s, as for inputs.

### §15 MCP binding

No change. A tool call returns once, so tools take no `stream` argument, and an engine doesn't stream for them. Agents
get the finished output.

### §18 Registries

- Features gain `streaming`.
- Event types gain `job.output_chunk`.
- A new registry, **stream encodings**, holds `pcm_s16le` and `pcm_f32le`.

### Schemas

| Schema | Change |
|---|---|
| `descriptor.schema.json` | `OutputSpec.stream: {encodings: [StreamEncoding], minItems 1}` |
| `job-request.schema.json` | `stream: [{output, encoding?}]`, `minItems` 1 |
| `job.schema.json` | `plan.streams: [{output, encoding, sample_rate, channels}]` |
| `event.schema.json` | `job.output_chunk`, with its `data` required: `output`, `index`, `offset_s`, `final`, `data` |
| `common.schema.json` | `StreamEncoding` enum; `Feature` gains `streaming` |

### Example

A streamed `audio.speak` on Gepard (22.05 kHz mono), over SSE:

```text
event: job.plan
data: {"model":{"id":"gepard-1.0",…},"effective":{…},"streams":[{"output":"audio","encoding":"pcm_s16le","sample_rate":22050,"channels":1}]}

event: job.output_chunk
data: {"output":"audio","index":0,"offset_s":0,"final":false,"data":"AAABAP7/…"}

event: job.output_chunk
data: {"output":"audio","index":1,"offset_s":0.48,"final":false,"data":"…"}

event: job.output_chunk
data: {"output":"audio","index":7,"offset_s":3.36,"final":true,"data":"…"}

event: job.output_ready
data: {"outputs":[{"index":0,"name":"audio","media_type":"audio/wav","duration_s":3.52,…}]}
```

## Compatibility

- **Additive.** It lands in the Base 0.1 draft in the next minor release, alongside RFC 0001.
- **Older engines** don't list `streaming`. By the schema, they refuse `stream` as an unknown field with 400
  `invalid_request`. MESKit up to v0.4.0 doesn't check requests for unknown fields (`JobRequest` uses synthesized
  `Codable`). It ignores `stream` and runs the job without chunks. So, as with adapters (§6.3 rule 5), a client checks
  `features` and the offer's `supports` before asking.
- **Older clients** don't ask for streams, so they never see chunks.
- **Without RFC 0003** there is no `supports.stream`. The fallback would be that every offer of an operation whose
  output declares `stream` MUST stream it. That is workable, but it keeps best-tier models that don't stream yet, such
  as Qwen3-TTS and VoxCPM2, out of such an operation.
- **PRD.** Accepting this reverses OQ-6 for output. The MES-PRD owner records it as a new decision. This RFC doesn't
  edit the PRD.

### What it takes to implement

- **MESEngineCore:**
  - `RunReporter` gains `chunk(output:data:final:)`, and `RunContext` tells the engine which outputs to stream in
    which encoding.
  - The kit writes the output file from the chunks itself, so parity holds by construction.
  - `JobRegistry` keeps every event for the life of the job record (`record.events`), so it must drop chunk payloads
    at purge.
- **MESClientKit:** chunks as an `AsyncSequence` per output, beside the event stream.
- **MESInProcess:** the same chunks with no sockets. An app that embeds an engine gets streamed TTS through the MES
  API. It still can't stream input (A-3).
- **The MLXEngine adapter (DLV-9)** maps `TTSStreamHandle.chunks` (`TTSStreamChunk`: samples, rate, index, final)
  onto `chunk(…)`, and `cancel` onto release. Five packages stream today: Gepard, Audio8, Audio8-Mini, MOSS-TTS-Nano
  and MOSS-TTS-Local.
- **Conformance needs an operation that streams.** The mock offers only Image operations, and Base §6 rule 6 allows
  only profile-defined ones. So the Base tests below run once the Audio 0.1 draft exists and the mock offers a streamed
  `audio.speak`, such as a tone generator.

## Conformance

| Test | Checks | Spec |
|---|---|---|
| BASE-053 | Stream declarations: only on `audio` outputs with `max` 1, with known encodings; an engine claims `streaming` exactly when some offer has `supports.stream` | §6 |
| BASE-054 | A streamed job: `plan.streams` gives the format; chunks are indexed from 0 with no gaps, hold whole frames, end with one `final`, and all come before `job.output_ready`; the output's samples equal the chunks' samples | §7, §10.1, §11 |
| BASE-055 | Release mid-stream: the outcome is `cancelled`, there is no final chunk, and no chunk follows the cancelled state | §7.3, §11 |
| BASE-056 | `stream` on an output that can't stream, an unknown encoding, or a named model without `supports.stream` is 422 `unsupported_parameter` | §7.1 |
| BASE-057 | After confirm, a replayed chunk carries no `data` | §11 rule 4, §13 |

## Alternatives considered

1. **Previews that append** (`job.preview` with `append: true`). It overloads one event with two meanings:
   approximations that replace each other, and parts that add up. A client that handles only one meaning gets the
   other wrong.
2. **Serving the output while it grows**, over chunked HTTP: a `GET` returning a WAV whose header says the length is
   unknown. Players such as `AVPlayer` and the browser's `<audio>` can play that directly, it's binary, and TCP paces
   it. But it isn't an output yet, so it has no index, SHA-256 or byte ranges. It needs a second connection per
   output, and it does nothing for the WebSocket or in-process transports. It could be added later as a convenience
   on top of chunks.
3. **WebSocket binary frames.** They save base64's third, but need a binary header (job, output, index). At 24 kHz
   16-bit mono a stream is 48 KB/s, 64 KB/s as base64, which is small on a LAN. Left for later.
4. **`audio/L16`** (RFC 2586) as the stream format. It is big-endian, so every Apple and x86 client would swap bytes.
   It also carries rate and channels as media-type parameters, which `MediaType` in `common.schema.json` doesn't
   allow. Named encodings with the format in the plan are simpler to read and to validate. The evaluation sketched
   `audio/L16;rate=…`, and this RFC replaces it.
5. **A session protocol** covering both directions (A-3). Output-only streaming covers TTS, and keeps the job model.

## Open questions

- **Other kinds.** Video frames (VID-2), or structured items as a model makes them. The event's shape allows them
  through new encodings, such as `json` items, but this draft defines audio only. Speech-to-text is out of MES's scope
  for now (it stays client-side), so streamed transcripts aren't a case.
- **Outputs with several values**, such as separation stems. A chunk would need the value's position as well as the
  output's name.
- **Compressed streams** (`opus` packets) for clients on slow links.

## Decision

**Accepted, amended (2026-10-30).** Interactive speech needs first audio in well under a second, and five of our
packages already stream in-process. Output-only chunks keep the job model, cost a client that ignores them nothing,
and make the finished output exactly what was heard. It lands in the Base 0.1 draft as the optional `streaming`
feature, with Audio 0.1, in v0.7.0. Reversing OQ-6 for output is recorded here; the MES-PRD owner records it there.

Amendments:
- **A1. `data` is optional in the schema.** It is present while the job's outputs exist and absent once they are
  purged (rule 4), so `event.schema.json` requires `output`, `index`, `offset_s` and `final` only. This reconciles
  rule 4 with the draft's schema line.
- **A2. The final chunk waits for success.** Rule 5 (no final chunk from a job that fails) is only implementable if the
  final chunk is sent once the run has succeeded, right before `job.output_ready`. MESKit holds the engine's last
  chunk back until then.
- **A3. The stream's format is known before the run.** `plan.streams` takes the request's `output` sample rate and
  channels, else the offer's own; so a profile states them as Facts, and an Audio offer with `supports.stream` MUST
  declare `supports.sample_rate` (Audio §4.1).
- **A4. Encodings.** An encoding not in the registry is 400 by the schema; a registered one the output doesn't list
  is 422 `unsupported_parameter`.
- **A5. Progress gains `phase` and `media_s`** (evaluation §3.4), since a streamed take has no `fraction` until it
  ends. A new `phase` always passes an engine's progress throttle (MESKit; AB-A-0156).
- **A6. Kit.** `RunReporter.chunk(_:samples:final:)` and `RunContext.streams`; the kit carries a partial frame to the
  next chunk, splits chunks to 256 KiB of base64, writes the output (WAV) from the chunks itself so parity holds by
  construction, and strips chunk data from the record at purge. An engine returns `ProducedOutput.streamed(name)` for
  a streamed output. MESKit writes streamed outputs as `audio/wav` only, so it refuses `stream` with another
  `output.media_type`.

### Open questions, answered

1. **Other kinds: not yet.** Video frames wait for the Video profile; speech-to-text is outside MES.
2. **Outputs with several values: not yet.** Stems come with `audio.separate`, later.
3. **Compressed streams: no.** A LAN stream of 24 kHz 16-bit mono is 64 KB/s as base64.

### Conformance, as shipped

BASE-053 (declarations, and `streaming` claimed exactly when an offer streams), BASE-054 (format, order, frames, one
final, parity with the output), BASE-055 (release mid-stream), BASE-056 (refusals) and BASE-057 (replay after
confirm), on the mock's streamed `audio.speak`.
