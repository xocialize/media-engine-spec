# Media Engine Specification (MES)

An open specification for talking to **media engines**: local or LAN services that run AI models on images, video
and other media. A client asks for an operation ("fill this masked region", "upscale this 2×"); the engine
normalizes how a specific model is used, and reports what it actually did. Any compliant client can use any
compliant engine, on any platform.

> **Status:** Base 0.1 and Image profile 0.1 are **drafts in review** (R0a). The SDKs, mock engine and conformance
> suite follow ([build plan](docs/BUILD-PLAN.md)). Nothing here is published yet.

## Contents

| Path | What |
|---|---|
| [`spec/base.md`](spec/base.md) | **Base 0.1:**<br/>• discovery, pairing and descriptors;<br/>• jobs, uploads, grants and events;<br/>• results, provenance and policy;<br/>• retention guarantees, errors and the MCP binding. |
| [`spec/profiles/image.md`](spec/profiles/image.md) | **Image profile 0.1:** 13 operations, the shared vocabulary, conventions (sRGB, masks, alpha), warnings, conformance tests |
| [`schemas/v0/`](schemas/v0/) | JSON Schemas (draft 2020-12) for every Base message, the Image vocabulary, and the operations table |
| [`examples/v0/`](examples/v0/) | Realistic messages, each validated against its schema |
| [`tools/`](tools/) | `validate.py` (schemas + examples + profile rules, no dependencies), `test_validator.py` (negative tests), `make_examples.py` |
| [`docs/BUILD-PLAN.md`](docs/BUILD-PLAN.md) | R0: the Swift SDKs, mock engine, conformance suite and `mes` CLI |
| [`rfcs/`](rfcs/) | How changes are proposed |

## Checking the documents

```bash
python3 tools/validate.py
```

```bash
python3 tools/test_validator.py
```

## Licences

- **Code, schemas, examples and tools:** Apache-2.0 ([LICENSE](LICENSE)).
- **Specification prose** (`spec/`, `docs/`, `rfcs/`): CC-BY-4.0 ([LICENSE-docs.md](LICENSE-docs.md)).

## Relationship to Pixel Agency

MES is neutral. Pixel Agency's apps (Desktop, Lite) and reference engines (Image, Video) are clients and engines
like any other, with no private extensions. The decisions behind the spec are in the Pixel Agency PRD set
(`ml(x)/PixelAgency/Docs/`, D-1, D-2, D-12).
