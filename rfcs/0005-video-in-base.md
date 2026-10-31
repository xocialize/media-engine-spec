# RFC 0005: What Base needs for video

| | |
|---|---|
| **Status** | Accepted (2026-10-31) |
| **Affects** | Base 0.1 (§7.1, §10.1, §10.2, §10.3, §11, §12, §15, §18); Audio 0.1 §1.12; `schemas/v0/base/` (`job.schema.json`, `event.schema.json`, `common.schema.json`, `descriptor.schema.json`, `job-request.schema.json`) |
| **Author** | xocialize |
| **Context** | [`docs/VIDEO-EVALUATION.md`](../docs/VIDEO-EVALUATION.md) §4 (B-1 to B-5); Gaea AB-A-0235 (Plan §5 G3 order 1, PRD VID-6) |
| **Decision** | mlx-apps, as the spec's owner, on AB-A-0235. Landed with Video 0.1 in MESKit v0.9.0 (see [Decision](#decision)) |

## Problem

Video 0.1 needs five things Base doesn't have:

1. **A frame count** (B-1). A clip's length is its frames. LTX makes 8k + 1 of them; `duration_s` × `fps` is a float
   product, and at 23.976 fps it isn't even a round number. Gaea's plan (G3 order 2) asks that outputs report frames
   and audio facts, and a client can't tell a silent clip from one with sound without opening it.
2. **Previews with a time** (B-2). `job.preview` has no schema. A video preview is a still of one moment; nothing says
   which.
3. **Licence notices for every profile** (B-3). Audio §1.12 made a `notice` something a client MUST show with a
   result (A-8) and asked engines to write licences into files (A-9), for Audio only. The LTX-2 Community Licence
   needs both for video, and Image's research offers always did.
4. **Terms a client's user must accept** (B-4). The LTX licence binds every user and requires a host to pass its use
   restrictions on as enforceable terms. Gaea hosts LTX for every client on the LAN. `accepted_required` is the
   operator's acceptance (Gaea VID-6: "shown when LTX is first enabled"); nothing reaches the person at a client.
5. **AI-content markings travel** (B-5). LTX requires outputs to be disclosed as machine-generated; Engines-PRD VID-8
   says watermarks and provenance are never removed. An upscale re-encodes every frame and, done naively, drops all
   of it.

## Proposal

### §10.1 Results

Output media facts gain **`frames`**: the number of video frames, on a `video` output. On a `video` output,
`sample_rate`, `channels` and `bit_depth` describe its audio track, and are present exactly when it has one.

### §10.2 Licence (rewritten in part)

The licence object gains one field:

| Field | Meaning |
|---|---|
| `user_accept_required` | OPTIONAL. `true` when the terms bind each person who uses the model through a client, so a client's user must accept them (§10.3) |

And these rules:

1. **Notices are shown** (A-8, from Audio §1.12). A `notice` is text a client MUST show: with the offer, wherever it
   presents a result whose provenance names that model, adapter, helper or voice, and in the MCP text summary,
   whatever `commercial_use` says. A licence has a `notice` only when its terms require something shown; advisory
   text belongs in the offer's `notes`. When `commercial_use` isn't `true` and there is no notice, the client shows the
   `spdx` and `terms_url` instead.
2. **Licences go into the file** (A-9). An engine SHOULD write the `spdx` id and `notice` into an output's own
   metadata, where its format has a place, whenever the job's licences carry a notice or aren't all
   `commercial_use: true`. It MAY for every output. The output's `sha256` covers the file as written.

   | Format | Where |
   |---|---|
   | WAV | `LIST/INFO` `ICOP` and `ICMT` |
   | FLAC, Ogg | `LICENSE` and `COPYRIGHT` comments |
   | MP3 | ID3 `TCOP` and `COMM` |
   | MP4, QuickTime | the copyright item (`cprt`; `com.apple.quicktime.copyright`) and the comment item (`©cmt`; `com.apple.quicktime.comment`) |
   | PNG | `iTXt` `Copyright` and `Comment` |
   | JPEG | EXIF `Copyright` and `UserComment` |

3. **AI-content markings travel** (B-5). An engine SHOULD mark what a generative operation makes as AI-generated in
   the file (the comment item, and the IPTC digital source type `trainedAlgorithmicMedia` where it writes XMP). It MUST
   NOT remove an AI-content marking, a watermark or a provenance manifest (such as C2PA) that an input carries, and when
   it transforms that input it carries them into the output, where the format allows. A profile MAY make the marking
   a MUST (Video §1.9).
4. **Users' acceptance** (B-4). For a licence with `user_accept_required`, a client MUST show its user the `notice` and
   `terms_url` and have the user accept the terms before that user's first job that may run on it, and then sends the
   licence's `spdx` in `policy.accepted` (§10.3). Acceptance is the person's: a client keeps it per user, and an agent
   carries the acceptance of the person who configured it. `accepted_required` remains the engine operator's
   acceptance before first use; the two are independent.

### §10.3 Policy

`policy` gains **`accepted`**: the `spdx` ids of licences whose terms the client's user has accepted (≤ 32 ids).

- An engine MUST NOT run a model, adapter, helper or voice whose licence has `user_accept_required` for a request
  whose `policy.accepted` doesn't list that licence's `spdx`.
- It is a policy rule like `license: commercial-use`: with no model named, the engine chooses among the offers the
  policy allows (§6 rule 2); a named model, a requested adapter or voice it doesn't allow, or a request no offer the
  engine may choose serves, is 422 `policy_unmet` with `param: "policy"` and `reason: "terms_not_accepted"`, naming
  the licence in the message. A helper is left out with `helper_skipped_by_policy`, as now.
- Listing a licence no offer uses is harmless.

### §11 Events

`job.preview` data is `{media_type, href?, data?, output?, at_s?, frame?}`:
- one of `href` or inline `data` (≤ 256 KiB of base64);
- `output`, the output it previews, by name;
- `at_s` and `frame`, for a still of a video: the moment in that output it shows, and that frame's index.

A preview is advisory: its bytes needn't be in the result, and a client MUST NOT rely on previews arriving.

### §15 MCP binding

A model line names a licence with `user_accept_required` ("users must accept these terms: pass policy.accepted"), and
the tools' `policy` argument takes `accepted`. A tool result whose provenance carries a `notice` puts it in the text
summary (rule 1).

### §18 Registries

Error `reason`: `terms_not_accepted` (with `policy_unmet`).

### Audio §1.12

Becomes a pointer to Base §10.2 rules 1 and 2, keeping Audio's formats.

## Compatibility

Additive while Base is 0.1:
- `frames`, `user_accept_required`, `policy.accepted` and the preview fields are optional. Older clients ignore them;
  older engines never send them.
- An older client sends no `policy.accepted`, so an engine never runs a `user_accept_required` offer for it: that is
  the point. It gets `policy_unmet` with a reason and the licence named, and other offers still serve it.
- A-8's MUST was already Audio's; it now covers Image and Video results. Clients that already show notices for audio
  show them for everything.

## Conformance

- **BASE-019:** an offer whose licence has `user_accept_required` is refused 422 `policy_unmet` (`reason:
  "terms_not_accepted"`) when named without `policy.accepted`, and runs when the request lists its `spdx`.
- **VIDEO-003:** a video output reports `frames`, and `sample_rate`/`channels` exactly when it has an audio track.
- **VIDEO-013:** AI-content markings (Video §1.9): generated outputs carry one; transformations keep an input's.
- **VIDEO-014:** previews from an offer with `supports.previews` are stills with `at_s` inside the clip.

## Alternatives considered

- **Clients SHOULD ask users to accept, unenforced.** A client written from the spec alone would never know it had to,
  and the host couldn't show its licence's §3 compliance.
- **Acceptance at pairing.** Couples licences to pairing; `open` mode has none; acceptance is a person's, not a
  device's.
- **Overloading `accepted_required`.** It already means the operator, and Gaea's first-enable acceptance needs it.
- **`commercial_use: conditional` (A-6) for LTX's $10M threshold.** The operator accepts at first enable, as for
  MiniMax Music 3 (AB-D-0157), so the offer declares `true` with the threshold in its notice. A-6 stays open for a
  threshold nobody has accepted.
- **`duration_s` only, no `frames`.** Rounding differs between clients, and grids are in frames.

## Decision

Accepted on 2026-10-31, as proposed, with Video 0.1. Landed in MESKit v0.9.0:
- `Output.frames`, `License.userAcceptRequired`, `Policy.accepted` (MESCore); the kit's policy filter refuses with
  `reason: "terms_not_accepted"` (MESEngineCore); `RunReporter.preview(_:mediaType:output:atSeconds:frame:)`;
  `ProducedOutput.video(…)`.
- MCP model lines and the `policy` argument (MESEngineKit).
- MESFormsUI asks for acceptance once per licence (`LicenseAcceptances`) and sends `policy.accepted`.
- BASE-019, VIDEO-003, VIDEO-013 and VIDEO-014.
