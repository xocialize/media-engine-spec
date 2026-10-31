# RFC 0001: Assets

| | |
|---|---|
| **Status** | Accepted, amended (2026-10-30) |
| **Affects** | Base 0.1 (§4, §7.1, §8, §13, §15, §17, §18) |
| **Author** | xocialize |
| **Decision** | A-2 in [`docs/AUDIO-EVALUATION.md`](../docs/AUDIO-EVALUATION.md) §8 (from §3.1). Decided by mlx-apps, as the spec's owner, for Gaea's phase G2; landed in Base 0.1 §8.1 and §13 rule 6, and MESKit v0.7.0 (see [Decision](#decision)) |

## Problem

A client often uses the same input in many jobs, and Base lets an engine keep neither the input nor what it learned
from it.

**Example.** A dubbing app renders a 500-line scene in two cloned voices with `audio.speak`.
- **Uploads are single-use** (§8). The app uploads the same two reference clips 500 times, or inlines them 500 times.
- **Nothing derived may outlive the job** (§13 rule 4). Every cloning TTS model encodes the reference before it
  speaks: a speaker embedding, VAE features or a speaker prefix. Doing that once instead of 500 times is most of the
  first-audio latency. Gepard measures ~1000 ms to first audio cold and 143 ms with the encoding cached (mlxengine-audio
  E1). Under rule 4 an engine must throw the encoding away after each job.

Our engine packages already cache, and so break rule 4 as soon as a second job runs. IndexTTS-2.5, VoxCPM2 and
Gepard each keep the most recent encoded reference, keyed by a hash of the clip's bytes, until the package unloads
(`IndexTTS2Package.swift:110` and `:159`, `VoxCPM2TTSPackage.swift:110` and `:152`, `GepardPackage`). An MES adapter
can't clear that cache without unloading the model.

Image has the same shape: a product shot used as the reference in every image of a campaign, or an `ic` adapter's
reference images (§6.3), reused across a batch.

## Proposal

A new optional feature, `assets`: files the client asks the engine to keep for any number of its jobs, until the client
deletes them or they expire. The client chooses what is kept and for how long, so the retention guarantees stay
honest, and the engine may cache what it derives from an asset for as long as the asset lives.

### §4 Engine information

- `features` gains `assets`.
- `limits` gains, for engines with the feature:
  - `max_asset_ttl_s`: REQUIRED. The longest an asset may be kept. At most 604 800 (7 days).
  - `max_asset_bytes_per_client`: OPTIONAL. The total size of one client's assets.
- An asset's size is limited by `max_upload_bytes`.

### §8.1 Assets (new)

An **asset** is a file a client stores on the engine for reuse. Any number of the client's jobs may name it.

- **Creating.** `POST {path}/assets?ttl_s=<s>` sends one file's bytes as the raw body, with its `Content-Type`, as for
  an upload. The client SHOULD include `Content-Digest`, which the engine then MUST verify.
  - `ttl_s` is REQUIRED, at least 60. An engine grants at most `limits.max_asset_ttl_s`, and `expires_at` says what it
    granted.
  - The engine answers 201 with an Asset (`asset.schema.json`, new):
    `{asset_id, media_type, bytes, sha256, created_at, expires_at}`.
  - Bigger than `limits.max_upload_bytes` → 413 `too_large`. Over `limits.max_asset_bytes_per_client` → 413
    `too_large`, with a `reason` that names the quota.
- **Using.** In `inputs`, an asset is `{"asset": "<asset_id>"}`. It may stand wherever an upload may, alongside other
  InputValues in the same input.
  - The engine resolves the assets when it accepts the job. An asset that is unknown, expired, deleted or another
    client's is 422 `input_invalid`, with `param` naming the input.
  - A media type the input doesn't accept is refused as it would be for an upload.
- **Listing.** `GET {path}/assets` returns `{assets: [Asset]}`: the caller's own. `GET {path}/assets/{id}` returns one
  Asset. An engine never serves an asset's bytes back.
- **Deleting.** `DELETE {path}/assets/{id}` answers 204, or 404 `not_found` for an asset the caller doesn't have.
  A job already accepted keeps its input. Its copy follows §13 rule 1, like any other input.
- **Ownership.** An asset belongs to the client that created it, as a job does (§7.3). A client never sees, uses or
  deletes another client's assets. `open` mode has no client identity, so its local callers share assets as they
  share jobs. MESKit treats them all as one client, `local`.
- **Unpairing.** Removing a pairing (§5 rule 7) deletes that client's assets.
- **Restarts.** An engine MAY drop its assets when it restarts. A client that gets 422 `input_invalid` for an asset it
  holds MUST treat it as gone, and create it again.

### §7.1 Submitting

The InputValue list in the `inputs` row gains `{"asset"}` (§8.1).

### §13 Retention guarantees

Rule 4 becomes "beyond rules 1–3 and 6". A new rule 6:

> 6. **Assets.** An engine MAY keep an asset's bytes, and anything it derives from those bytes alone for reuse (an
>    encoded speaker reference, image features), until the asset is deleted or expires. It MUST delete them within
>    60 s of that, and within 60 s of the client's pairing being removed. What it derives from an asset serves only
>    jobs that name that asset. Anything derived from a job's other inputs, or from an asset together with them,
>    follows rules 1–4.

The last two sentences keep the change narrow:
- **Only jobs that name the asset.** An engine that keys its cache by asset can't leak it to a job that uploaded the
  same bytes, or to another client. A cache keyed by bytes could, and a cache hit is a timing signal that someone
  else holds that clip.
- **Derived from the asset alone.** An encoded voice is kept. A transcript, or a model state that also holds the job's
  text, is not.

### §15 MCP binding

Tool inputs accept `asset:<id>` wherever they accept `upload:<id>`. The binding doesn't create assets: an agent uses
assets that its client created over HTTP.

### §17 Security and privacy considerations

A new bullet:
- **Assets** are the only client media an engine keeps past a job, for at most `max_asset_ttl_s`. An engine SHOULD
  keep them where only it can read them, and SHOULD exclude them from backups.

### §18 Registries

Features gain `assets`.

### Schemas

| Schema | Change |
|---|---|
| `asset.schema.json` (new) | `{asset_id, media_type, bytes, sha256, created_at, expires_at}`, all required |
| `job-request.schema.json` | `InputValue` gains `{"asset": Id}` |
| `engine-info.schema.json` | `limits.max_asset_ttl_s` (1–604 800) and `limits.max_asset_bytes_per_client` |
| `common.schema.json` | `Feature` gains `assets` |

## Compatibility

- **Additive.** It lands in the Base 0.1 draft, as adapters did in v0.4.0, in the next minor release (v0.5.0).
- **Older engines** don't list `assets` in `features`. They answer `POST {path}/assets` with 404, and refuse an
  `{"asset"}` input with 400 `invalid_request`: MESCore's `InputValue` decoder accepts exactly one of the keys it
  knows. A client checks `features` before creating assets.
- **Older clients** never create assets, so for them nothing changes. Rule 6 relaxes rule 4 only for media a client
  explicitly made an asset.

### What it takes to implement

- **MESEngineCore:**
  - An asset store beside the spool (`Spool.swift`), resolved at submit.
  - A sweep for expiry and unpairing.
  - A way for the engine to know which inputs are assets: `RunContext` reports the asset id per input, so the engine
    can key a cache by it.
  - A `MediaEngine` hook, `assetRemoved(_ id: String) async`, that defaults to doing nothing. The engine drops its
    cached derivations there.
- **MLXEngine adapter (DLV-9).** The packages' caches are single-entry, keyed by a hash of the bytes, and cleared only
  at unload. To conform, the adapter needs one of these from the audio packages:
  - an eviction call, so a reference from a job that didn't name an asset doesn't outlive that job;
  - better, E1's possible follow-up, `prepareVoice(reference:transcript:) -> VoiceHandle`, held per asset and
    released on `assetRemoved`.

  Without either, an engine on today's packages must unload the package after every cloning job whose reference
  isn't an asset, and pay the load time again.
- **MESClientKit:** create, list and delete. It should create the asset again when a job answers 422 for an asset it
  holds.
- **Profiles.** Nothing changes: Audio's `voice_ref` and Image's `references` take assets like any InputValue. The
  Audio profile should recommend an asset for any voice used more than once.

## Conformance

| Test | Checks | Spec |
|---|---|---|
| BASE-032 | Assets: 201 with the right size and SHA-256, `expires_at` within `max_asset_ttl_s`; listed; two jobs use it; `DELETE` is 204; afterwards a job naming it is 422 `input_invalid`, and `GET` is 404 | §8.1 |
| BASE-033 | An asset whose `Content-Digest` doesn't match is refused | §8.1 |
| BASE-034 | An asset expires: one created with `ttl_s=60` is gone after its `expires_at` (runs when `--max-ttl-wait` is at least 120) | §8.1, §13 rule 6 |
| BASE-035 | Paired mode, with a second pairing: another client's asset isn't listed and is 422 in a job; unpairing deletes the client's assets | §8.1 |

Rule 6's limits on derived data aren't observable from outside, as rule 4 isn't today. The rule binds the
implementation, and the MLXEngine adapter's eviction is where it's checked.

## Alternatives considered

1. **Say that an in-memory cache isn't a copy.** It needs no protocol at all, but it weakens the guarantee clients
   rely on (R5, custody). A client can't tell what is kept, or end it.
2. **Multi-use uploads with a short TTL.** It fixes the re-uploading, but changes what an upload promises: clients
   today rely on an upload being gone once its job leaves `running`. A separate resource leaves that promise intact.
3. **A per-job opt-in** (`policy.cache: allow`). The engine may cache what it derives from the job's inputs, until it
   decides not to. This leaves no id to delete and no expiry to see, so the client opts in to something it can't
   bound.
4. **Grants for reuse.** The client serves the clip from its own server each time (§9). That keeps custody of the
   bytes, but the encoding still can't be kept.
5. **Voices only, installed by the operator** (RFC 0003). That covers preset voices, but not a user's own voice.

## Open questions

- **Renewal.** Should a client be able to extend `expires_at` (`POST {path}/assets/{id}/renew`)? Creating the asset
  again is cheap on a LAN (a 10 s clip is about 0.5 MB), so this draft leaves it out.
- **Creation over MCP.** A `mes_create_asset` helper tool taking a data URL would let agents keep a voice. It shares
  the size problem of long audio over MCP (evaluation §3.5), so it waits for that answer.
- **A count limit** (`max_assets_per_client`) as well as the byte quota.

## Decision

**Accepted, amended (2026-10-30).** The problem is real and blocks every cloning engine: all of our TTS packages cache
the encoded reference, and Base forbade it. A client-owned resource is the only option that keeps custody honest (the
client chooses what is kept and ends it) while making the cache legal, and it serves Image's reused references too. It
lands in the Base 0.1 draft as the optional `assets` feature, with Audio 0.1, in v0.7.0.

Amendments:
- **A1. Errors named.** A missing or short `ttl_s` (under 60) is 400 `invalid_request`. A wrong `Content-Digest` is
  400 `invalid_request`, as for uploads.
- **A2. A job keeps its asset.** The draft's "a job already accepted keeps its input" is made concrete: the engine
  takes the job's copy when it accepts the job, so deleting the asset afterwards doesn't fail the job. MESKit clones
  the file (APFS) at submit.
- **A3. `GET {path}/assets/{id}`** returns one Asset; the list is `{assets: [Asset]}` (`asset.schema.json#/$defs/List`).
- **A4. Rule 6 says why bytes-keyed caches are out.** A cache keyed by a clip's bytes could serve another client's
  identical upload, and a hit is a timing signal; the rule now says so in Base §13.
- **A5. Kit.** MESEngineCore keeps assets beside the spool and wipes them on restart (§8.1 allows it), claims `assets`
  by default (`EngineConfiguration.assets`, `maxAssetTTLSeconds` 1 day, `maxAssetBytesPerClient` 1 GiB), tells the
  engine which inputs are assets (`RunContext.assets`), and calls `MediaEngine.assetRemoved(_:)` on delete, expiry and
  unpairing.

### Open questions, answered

1. **Renewal: no.** Creating an asset again is cheap on a LAN, and a renewal would let a client keep media
   indefinitely without re-sending it, which the TTL exists to bound.
2. **Creation over MCP: not in 0.x.** It shares long audio's size problem over MCP. Agents use assets their client
   created over HTTP, by `asset:<id>`.
3. **A count limit: no.** `max_asset_bytes_per_client` bounds what matters; an engine that wants a count can refuse
   with 413 and a `reason`.

### Conformance, as shipped

BASE-032 (lifecycle), BASE-033 (digest and `ttl_s`), BASE-034 (expiry; runs with `--max-ttl-wait` 75 or more) and
BASE-035 (a second pairing's assets are invisible and unusable; paired mode with `--pair`). That unpairing deletes a
client's assets, and rule 6's limits on derived data, aren't observable from outside: the rule binds the
implementation.
