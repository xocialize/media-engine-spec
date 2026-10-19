# Media Engine Specification (MES)

An open specification for talking to **media engines**: local or LAN services that run AI models on images, video
and other media. A client asks for an operation ("fill this masked region", "upscale this 2×"); the engine
normalizes how a specific model is used, and reports what it actually did. Any compliant client can use any
compliant engine, on any platform.

> **Status:** Base 0.1 and Image profile 0.1 are **drafts**, tagged `v0.1.0`. **MESKit works:** MESCore; the engine kit in
> open and paired modes (TLS, pairing, tokens, DNS-SD) with SSE, the WebSocket channel and the MCP binding; the client
> kit (discovery, pairing, jobs, events, grants) and an in-process transport; the `mes` CLI; MESFormsUI (SwiftUI forms
> from descriptors); the conformance suite for engines and clients; and a mock Image engine. The mock and `mes` both
> conform. 55 tests pass. **R0 is complete** ([build plan](docs/BUILD-PLAN.md)).
>
> Two implementations use it: [Pixel Agency Lite](https://github.com/xocialize/pixel-agency-lite), the reference
> client, and the [Pixel Agency Image Engine](https://github.com/xocialize/pixel-agency-image-engine), the reference
> Image engine, which passes the conformance suite against real models.

## Contents

| Path | What |
|---|---|
| [`spec/base.md`](spec/base.md) | **Base 0.1:**<br/>• discovery, pairing and descriptors;<br/>• jobs, uploads, grants and events;<br/>• results, provenance and policy;<br/>• retention guarantees, errors and the MCP binding. |
| [`spec/profiles/image.md`](spec/profiles/image.md) | **Image profile 0.1:** 13 operations, the shared vocabulary, conventions (sRGB, masks, alpha), warnings, conformance tests |
| [`schemas/v0/`](schemas/v0/) | JSON Schemas (draft 2020-12) for every Base message, the Image vocabulary, and the operations table |
| [`examples/v0/`](examples/v0/) | Realistic messages, each validated against its schema |
| [`tools/`](tools/) | `validate.py` (schemas + examples + profile rules, no dependencies), `test_validator.py` (negative tests), `make_examples.py` |
| [`Package.swift`](Package.swift), `Sources/`, `Tests/` | **MESKit:**<br/>• **MESCore:** types, a schema validator, the Image tables, the pairing code.<br/>• **MESEngineCore:** the engine core (jobs, spool, retention), no networking.<br/>• **MESEngineKit:** the engine side of Base on Hummingbird 2.<br/>• **MESClientKit:** the client side (discovery, pairing, jobs, events, grants).<br/>• **MESInProcess:** an in-process engine behind the client API.<br/>• **MESFormsUI:** SwiftUI forms rendered from descriptors, and `mes-forms-gallery`.<br/>• **MESEngineUI:** an engine app's own console (queue, enabled set of models, System monitor, menu-bar item), and `mes-console-gallery`.<br/>• **MESConformance:** the conformance suite and `mes-conformance`.<br/>• **`mes`:** the command-line client.<br/>• **MockEngineCore** and **`mes-mock-engine`.** |
| [`docs/BUILD-PLAN.md`](docs/BUILD-PLAN.md) | R0: the Swift SDKs, mock engine, conformance suite and `mes` CLI |
| [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) | The conformance catalogue: every BASE and IMAGE test, and how to run them |
| [`rfcs/`](rfcs/) | How changes are proposed |

## Checking the documents

```bash
python3 tools/validate.py
```

```bash
python3 tools/test_validator.py
```

## Running the mock engine

```bash
swift run mes-mock-engine --port 17600
```

```bash
curl -s http://127.0.0.1:17600/mes/v0/operations
```

Use it from an agent over MCP. Each operation is a tool (`image_generate`, `image_fill`, …):

```bash
claude mcp add --transport http mes-mock http://127.0.0.1:17600/mes/v0/mcp
```

Paired mode (TLS and pairing), approving each pairing at the prompt:

```bash
swift run mes-mock-engine --paired --approve prompt
```

The `mes` command-line client finds, pairs with and drives any engine:

```bash
swift run mes discover
```

```bash
swift run mes run image.generate -i prompt="a lighthouse at dusk" -p size=1024x768
```

```bash
tools/smoke-cli.sh
```

MESFormsUI renders an operation's controls from its descriptor: parameters by UI hint, model offers with their
licences, and extensions. The gallery shows every mock operation's form, with the request it makes:

```bash
swift run mes-forms-gallery
```

![Generate, rendered from its descriptor](docs/images/forms-image.generate-light.png)

MESEngineUI is an engine app's console, shared by every Pixel Agency engine (Engines-PRD ENG-9). An engine supplies an
`EngineConsoleBackend`: `MESEngineServer`'s operator API (every client's jobs, operator cancel, descriptor reload) and its
own catalog, downloads and memory. MESEngineUI supplies the rest:
- **Queue:** the job running now with its stage, step and elapsed time; what's waiting, in the order the slot takes it;
  recent results. Any job can be cancelled.
- **Models:** the engine's enabled set (`ModelEnablement`). Engines pick models themselves, by operation and tier, so the
  operator switches models on and off instead of loading them. Autoswitch shows what a request that names no model gets.
  Each model's card says what it does, how to name it (CLI, JSON, MCP), how to prompt it, its licence, and its state on
  this Mac. An opt-in model asks for its terms to be accepted first, and runs only when named.
- **System:** live CPU, GPU, memory (with the engine's own footprint), disk and sensors, from Nativ's system monitor.
  The `SystemSensors` trait (on by default) reads temperatures, fans and power through private interfaces. An App Store
  build turns it off and keeps thermal pressure.
- **Menu bar:** the engine's icon with its active-job count, or live CPU, GPU and memory readings; its menu shows the running
  job, what's waiting and what's in memory.

The gallery runs it over the mock engine, with jobs arriving every few seconds:

```bash
swift run mes-console-gallery
```

Test an engine against the spec (the report lands in `mes-conformance-report/`):

```bash
swift run mes-conformance engine http://127.0.0.1:17600/mes/v0
```

Test a client against a scenario-mode mock engine (`mes` by default, or any CLI with `--command`):

```bash
swift run mes-conformance client
```

```bash
swift test
```

## Serving an engine from Swift

```swift
let server = MESEngineServer(engine: MyEngine(), configuration: config)
try await server.run { port in print("listening on \(port)") }
```

In an engine process, SIGTERM or SIGINT stops the server gracefully: requests in flight get
`config.shutdownGracePeriod` (5 s), then `run` returns. An app that embeds the server sets
`config.handlesShutdownSignals = false` and stops it by cancelling the task. Otherwise the signal stops only the
server, and the app keeps running without it.

## Licences

- **Code, schemas, examples and tools:** Apache-2.0 ([LICENSE](LICENSE)).
- **Specification prose** (`spec/`, `docs/`, `rfcs/`): CC-BY-4.0 ([LICENSE-docs.md](LICENSE-docs.md)).

## Relationship to Pixel Agency

MES is neutral. Pixel Agency's apps (Desktop, Lite) and reference engines (Image, Video) are clients and engines
like any other, with no private extensions. The decisions behind the spec are in the Pixel Agency PRD set
(`ml(x)/PixelAgency/Docs/`, D-1, D-2, D-12).
