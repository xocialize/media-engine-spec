# RFC 0009: A part made to fit a body (`mesh.generate_part`)

| | |
|---|---|
| **Status** | Accepted (2026-11-13) |
| **Affects** | Mesh 0.1 (§1, §2, §3, new §3.3, §4, §6, §7); Base 0.1 (§6.1); `schemas/v0/profiles/mesh/` (`operations.json`, `operations.schema.json`, `vocabulary.schema.json`, `supports.schema.json`, `job-request.schema.json`); `schemas/v0/base/descriptor.schema.json` |
| **Author** | xocialize |
| **Context** | Gaea AB-A-0280 (task AB-T-0482), the shape agreed with mlx-3d in AB-A-0278. HairDeck in Swift-MLX: `mlx-hairdeck-swift` (plan AB-P-0012, receipts AB-R-0845 to 0850); the head box is the client's, AB-D-0227. The engine contract's side is AB-A-0277: capability `characterPart`, mlx-engine-swift 0.78.0 |
| **Decision** | mlx-apps, as the spec's owner, on AB-A-0280. Landed in MESKit v0.14.0 (see [Decision](#decision)) |

## Problem

HairDeck makes a hair item for an avatar: one picture of a character, the box around the head in that picture, and
the avatar's VRM give a GLB of hair cards with a colour texture, a skin, chain bones and `VRMC_springBone`, already
where the avatar's head is. Item Studio merges that item into the VRM. The operator will use it through Gaea.
Garments and accessories are the next models of the same shape.

`mesh.generate` (Mesh §3.1) can't carry it:

1. **No body.** Its only input is `image`. The body is a file; extensions carry values, not files.
2. **The engine moves the result.** §1.4 and MESH-004 centre every result and scale its longest extent to `size_m`.
   A part is already placed on its body. Moved or rescaled it is no longer on the head, and its spring-bone radii are
   no longer metres.
3. **The engine may reduce or refuse it.** §1.8 warns about (or refuses) a thin result, and hair cards are thin by
   design. §1.9 decimates to `max_faces`, which breaks a skin.
4. **No box.** HairDeck doesn't find the head itself (AB-D-0227). Nothing carries where in the picture to look.

## Proposal

### Mesh §3: a third operation

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `mesh.generate_part` | `image` (image, required, 1); `body` (mesh, required, 1) | `part`, `subject_box`, `physics`, `texture`, `seed`, `quality` | `mesh` (mesh, 1); `preview` (image, 1) | A rigged part, read from the image and placed on the body (§3.3) |

It joins Mesh 0.1, as RFC 0006 and RFC 0008 joined Audio 0.1: the profile is a draft, and the addition changes
nothing for the two operations it has.

**Inputs.**
- `image`: a picture of the character wearing the part. Formats and orientation as Image §1.1. A picture with
  transparent pixels is already cut out, and its alpha is the subject's mask (§1.10). An opaque picture is cut out by
  the model, which needs the offer's `supports.background_removal`. There is no `background` parameter: keeping the
  background has no meaning for a part. An opaque picture to an offer without `background_removal` is refused,
  `unsupported_parameter` with `param: "image"`: 422 at submission, or as the job's error when the engine reads the
  picture only as the job starts. `effective.background` reports `remove` or `alpha`.
- `body`: the rigged GLB or `.vrm` the part goes on (VRM 0.x and 1.0 files are GLBs), `model/gltf-binary`. It may be
  a file or an asset (Base §8.1), so a client making many parts for one body uploads it once. The engine reads it and
  never changes or returns it. A body is **not** held to §1.1 and §1.2: a VRM may list `extensionsRequired`, carry
  KTX textures and morph targets. It must be a GLB the engine can read, with the bone the part hangs from. Otherwise
  it is 422 `input_invalid` with `param: "body"`, at submission or as the job's error.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `part` | string | Which part to make: a registered tag, or `x-<vendor>.<name>`. Default: the offer's first. Gate: `supports.parts` |
| `subject_box` | `{x, y, width, height}` | Where in the picture the part is read from; for `hair`, the head (hair and face). Each number is a share of the upright image from its top-left corner, 0 to 1, as `image.segment`'s points are. `width` and `height` are above 0, and `x + width` and `y + height` are at most 1. Gate: `supports.subject_box` |
| `physics` | boolean | Chain bones and `VRMC_springBone` for secondary motion. Default: `true` where the offer has `supports.physics`, else `false`. Gate: `supports.physics`, for `true` |
| `texture` | `atlas` · `vertex_colors` · `none` | As §2, with a new value `none`: no texture and no `COLOR_0`, a plain material. Default: the offer's first. Gate: `supports.textures` |
| `seed`, `quality` | | As §2 |

`placement`, `size_m`, `on_flat`, `max_faces`, `texture_size`, `resolution` and `background` are not parameters of
this operation. Sending one is refused as any parameter a descriptor doesn't list (422 `unsupported_parameter`).

**Parts.** A tag is registered when one model makes it, as skeleton templates are.

| Part | What it is | Hangs from | Made by |
|---|---|---|---|
| `hair` | The character's hair | The body's head bone | HairDeck |

`garment` and `accessory` are reserved for the first models that make them (the engine contract names them already).
Each registration says which bones the part hangs from.

**The box.**
- A box that isn't four numbers, has no area or reaches outside the image is malformed: 400 `invalid_request`
  (`param: "subject_box"`), never `out_of_limits`. No offer's limit decides it.
- `supports.subject_box` says what an offer does with one: `"required"` (the model doesn't locate the part: HairDeck),
  `"optional"` (it locates the part itself, and a box overrides that), or absent (it always locates the part itself).
- A box sent to an offer without the key is 422 `unsupported_parameter`. An ignored box would be the wrong head in a
  picture with two.
- A request without a box is never routed to an offer that requires one. Sent to a named offer that requires one, or
  when only such offers may run it, it is 422 `unsupported_parameter` with `param: "subject_box"`.
- `effective.subject_box` is the box used.

**The result** (new §3.3).
1. **In the body's coordinates.** The part's vertices and joints are in the coordinates of the body's file (glTF
   axes, metres), where the part sits on that body in its rest pose. A VRM 0.x body faces −Z in its file, and the
   part faces the same way. The engine never moves, scales, re-roots or decimates the result: §1.4, §1.8 and §1.9
   don't apply, and it reports no `flat_result`.
2. **The part alone.** The file holds the part, never the body.
3. **One skin, hung from the body's bones.** The output has one `skin` and reports `joints`. The joints that stand
   for bones of the body are named as the body names them and sit where the body has them at rest (the same global
   transform). The skin's root joint is one of them. Joints of the part's own (hair chains) are beneath them. For
   `hair` there is one body bone, the head: the root joint has the name of the body's head bone. A client attaches
   the part by putting the root joint's children under the body's bone of that name. The pose in the file is the
   bind pose. Every primitive has `JOINTS_0` and `WEIGHTS_0` as §3.2 asks of a rig.
4. **The head bone** of a VRM body is its humanoid `head` bone (`VRMC_vrm`, or VRM 0.x's `VRM` extension). In
   another rigged GLB the engine finds it by its own means, and says in the offer's `notes` which bodies it reads.
5. **Physics.** With `physics: true` the file carries `VRMC_springBone` (spec version 1.0) over the part's own
   joints, listed in `extensionsUsed` and never in `extensionsRequired`. With `false` it has no `VRMC_springBone`
   and no chain joints: the part is skinned to the body's bones alone.
6. **§1.1 and §1.2 hold** for the result otherwise: everything embedded, no `extensionsRequired`, triangles with
   normals. It may use extensions a viewer can ignore (`VRMC_materials_mtoon`, `KHR_materials_unlit`,
   `KHR_texture_transform`).
7. **Facts** as §1.6: `vertices`, `faces`, `bounds`, `joints`, and `texture_size` exactly when it has a texture
   (never with `texture: none`).
8. **The preview** (§1.7) shows the part alone, in its bind pose.
9. **Disclosure and licences** as `mesh.generate` (§1.11, §1.12): `asset.extras.mes.ai_generated`, `model`, and the
   licence's attribution in `asset.copyright`. HairDeck's offer carries "Built with DINOv3", as TRELLIS.2's does.
10. **What the engine writes into the file is `asset` only.** An engine that stamps a model's file keeps everything
    else as the model wrote it: nodes, skins, inverse bind matrices, materials and their extensions,
    `extensions.VRMC_springBone`, `extensionsUsed`.
11. **`effective`** reports `part`, `physics`, `texture`, `background`, `seed`, and `subject_box` when one was used.

**For clients** (not an engine rule): a client that merges the part into the body carries the part's
`asset.copyright` into the merged file. For a VRM that is `meta.thirdPartyLicenses`.

**Progress.** The phases are those §1.15 has: `matting`, `shape`, `texture`, `skin`, `export`, `render`.

### Mesh §4: what each offer supports

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `parts` | `generate_part` | `[string]` | REQUIRED | Gate: `part`. The first is the default |
| `subject_box` | `generate_part` | `required` · `optional` | the model locates the part | Gate: `subject_box`, and with `required` a request without one |
| `physics` | `generate_part` | boolean | `false` | Gate: `physics: true` |
| `background_removal` | `generate`, `generate_part` | boolean | `false` | Gate: `background: remove` (`generate`); an opaque picture (`generate_part`) |
| `textures` | `generate`, `generate_part` | `[atlas · vertex_colors · none]` | `[atlas]` | Gate: `texture` |
| `deterministic` | all | boolean | `true` | Fact |

`none` joins `texture`'s vocabulary for the profile. A `mesh.generate` offer may list it too, for geometry alone.
`texture_size` goes only with `texture: atlas`: with `vertex_colors` or `none` it is 400.

`generate_part` has no limit fields of its own. An offer may state Base's image limits (`max_width`, `max_height`,
`max_megapixels`) for the picture.

**The first offer**, as its plugin states it (the plugin's to settle, shown here to test the shape):

```json
{
  "id": "hairdeck",
  "title": "HairDeck",
  "license": { "spdx": "LicenseRef-DINOv3", "commercial_use": true, "terms_url": "…",
               "attribution": "Built with DINOv3", "notice": "HairDeck is Apache-2.0; its DINOv3 conditioner is under Meta's DINOv3 License." },
  "notes": "Hair for a VRM avatar. Drag the box around the head: hair and face.",
  "supports": {
    "parts": ["hair"],
    "subject_box": "required",
    "physics": true,
    "textures": ["atlas", "none"],
    "background_removal": true
  }
}
```

A request, and what it reports:

```json
{
  "operation": "mesh.generate_part",
  "inputs": { "image": { "upload": "upl_h1" }, "body": { "asset": "ast_avatar7" } },
  "params": { "subject_box": { "x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4 }, "seed": 7 }
}
```

Outputs `mesh` (reporting `joints`) and `preview`. `effective`: `part: "hair"`, `physics: true`, `texture: "atlas"`,
`background: "remove"`, `subject_box` as sent, `seed: 7`.

### Base §6.1: a `box` widget

`x-mes-ui.widget` gains `box`: a rectangle drawn on an image input, for a parameter shaped `{x, y, width, height}` in
shares of that image. A client that can't draw one edits the four numbers. Gaea's descriptor emits it for
`subject_box`, and the descriptor schema lists the widgets, so it has to be registered.

### Schemas

| File | Change |
|---|---|
| `mesh/operations.json` | `mesh.generate_part`: inputs `image` and `body`, outputs `mesh` and `preview`, its vocabulary, `seeded`, and a new flag `fits_body` |
| `mesh/operations.schema.json` | `fits_body`: the result is in the body's coordinates and never placed, scaled or decimated |
| `mesh/vocabulary.schema.json` | `texture` gains `none`; new `part`, `part_kind` (the registered tags), `subject_box`, `physics` |
| `mesh/supports.schema.json` | `generate_part_supports` (`parts` required) and `generate_part_limits`; `textures` takes `none` |
| `mesh/job-request.schema.json` | `mesh.generate_part`: both inputs required, its parameters; `texture_size` refused with `none` on `generate` |
| `base/descriptor.schema.json` | `x-mes-ui.widget` takes `box` |

That a box stays inside the image (`x + width` ≤ 1) is checked by MESKit, `tools/validate.py` and MESH-017: the
schemas' keyword subset can't add two properties.

### MESKit

- **MESCore:** `MeshProfile` gains `Param.part`, `.subjectBox`, `.physics`; `Input.body`; `SupportsKey.parts`,
  `.subjectBox`, `.physics`; `Part.hair`; `SubjectBox`, the box as a value, with its checks and its pixels in an image
  of a given size; `GLB.humanoidBone(_:)` and `GLB.worldMatrix(node:)`, to find the bone a part hangs from.
- **MESEngineKit:** `MeshProfileRules` applies the gates above, and the kit checks the box's structure ahead of the
  descriptor's schema, so a bad box is 400 whatever the schema would answer. The flat check already ran for
  `mesh.generate` alone, and now goes by the table's `places` flag. `MeshProfileRules.partDefaults` gives an engine
  the part, physics and texture a request left to its offer.
- **MESClientKit:** `MediaType.infer` gives a `.vrm` file `model/gltf-binary` (the system has no type for the
  extension), so `mes run … -i body=avatar.vrm` and an asset made from a `.vrm` are sent as what they are.
  `JobResult.meshes` and `downloadMesh` already cover the output.
- **MESFormsUI:** a `box` widget: `ImageBoxPicker`, a rectangle dragged on the picture, for a host to put on its
  image well, and the four numbers as a row in the form. The form says before sending that the chosen model needs a
  box. `MeshInputWell` takes `.vrm` files.
- **mes-mock-engine:** `mock-hairdeck` (needs a box; physics; `atlas` or `none`; cuts out an opaque picture; a licence
  with an attribution) and `mock-part-finder` (locates the part itself, so it takes no box; no physics; needs a
  cut-out picture). Each makes a small tuft on the body's head bone, as wide as the box.

## Compatibility

Additive while Mesh and Base are 0.1.
- A new operation: a 0.13 client doesn't know it and never sends it. A 0.13 engine never offers it.
- `none` is a new `texture` value, gated by `supports.textures`, whose absent value is still `[atlas]`. No offer
  lists it until it makes untextured meshes.
- The `box` widget: clients MAY ignore hints (Base §6.1). A 0.13 client's schema check of a descriptor that uses it
  fails; run the 0.14 schemas.
- A 0.13 conformance tool reports `mesh.generate_part` as an operation it doesn't know (MESH-001): run the 0.14
  tool.

## Conformance

The body the suite sends is a small VRM 1.0 figure, 1.57 m tall, standing on the ground and facing +Z, whose head
bone is `J_Bip_C_Head`. The picture is the red ball, cut out, and the box is the ball's.

| Test | Checks |
|---|---|
| MESH-013 | `generate_part` leaves the result on the body: its bounds lie inside the body's grown by half the body's height, it reaches above the body's head bone, and it carries no `flat_result` |
| MESH-014 | `generate_part`: one skin and `joints` reported; the root joint has the name of the body's head bone and sits where the body has it; `JOINTS_0` and `WEIGHTS_0` on every primitive, weights summing to 1 |
| MESH-015 | `generate_part` physics: `VRMC_springBone` is in `extensions` and `extensionsUsed` with `physics` true and absent with false; `physics: true` to an offer without `supports.physics` is 422 |
| MESH-016 | `generate_part` textures: `texture: none` gives no texture, no `COLOR_0` and no `texture_size`; a `texture` the named offer doesn't list is 422; `effective` reports `part`, `physics`, `texture` and `background` |
| MESH-017 | `subject_box`: a box outside the image or with no area is 400; a box to an offer without `supports.subject_box` is 422; no box to a named offer that requires one is 422; `effective.subject_box` echoes the box |
| MESH-018 | `generate_part` inputs: a request without `body` is 400; bytes that aren't a GLB are `input_invalid`; a `part` the named offer doesn't list is 422; an opaque picture runs where the offer has `background_removal` and is refused where it doesn't |

MESH-001 to 003, 005, 009 and 010 run on the new operation too: its descriptor and offers, the GLB conventions and
facts, the preview, the disclosure and attribution, and the seed. MESH-002 also checks that every offer of it lists
`parts`. MESH-004 (placement) and MESH-008 (`on_flat`) stay `mesh.generate`'s.

## How this lines up with the engine contract (AB-A-0277)

The MES shape doesn't wait on the contract: a plugin maps one to the other (GaeaPluginKit's `CharacterParts`).

| MES | `CharacterPartRequest` / `CharacterPartControls` |
|---|---|
| `image` | `image` |
| `body` | `body` (`bodyFit`); MES always sends one |
| `subject_box`, shares of the upright image | `subjectBox`, `[x0, y0, x1, y1]` in pixels of the image the worker receives |
| `supports.subject_box: required` | `requiresSubjectBox` |
| `part`, `supports.parts` | `part`, `parts` |
| `physics`, `supports.physics` | `springBones`, the `springBones` feature |
| `texture: atlas` / `none` | `colors: true` / `false` |
| not in MES | `pointCloud`: a second source, left for a later RFC |

## Alternatives considered

- **`mesh.generate` with a `body` input and a `fit` mode.** Every rule that makes `generate` useful (placement, size,
  the flat check, decimation) would grow an exception, and a client couldn't tell from the operation whether its
  result is an object or a part.
- **The body as numbers** (face width, head bone name and rest transform) in an extension. The package already reads
  them from the file, a client would have to parse a VRM to send them, and the next part needs other numbers.
- **The box in pixels.** The engine may turn or convert the picture (Image §1.1), so pixels of which file? Shares of
  the upright image are what `image.segment`'s points use.
- **`subject_box` as a boolean gate plus a `requires_subject_box` key.** Two keys that must agree. One key with two
  values can't contradict itself.
- **Routing a request without a box to an offer that requires one, and failing there.** The refusal belongs at
  submission, where a form can still ask for the box.
- **A `background` parameter with `keep` refused.** A value that is always refused is not a parameter.
- **`colors` as a boolean**, as the engine contract has it. `texture` already says how a mesh carries its colour, and
  `none` is the missing third answer; a vertex-coloured part needs no new word.
- **Returning the body with the part on it.** Merging is the client's: it knows its own file's metadata, materials
  and expressions, and a VRM round trip through an engine that doesn't know VRM would lose them.
- **Naming the attachment bone in the result's facts.** The root joint's name is in the file, where a merger reads
  it; a fact would be a second place to disagree.
- **Holding the body to §1.1 and §1.2.** Real VRMs break them (KTX textures, required extensions). The engine only
  reads bones and bounds.
- **Mesh 0.2.** Nothing changes for 0.1's operations, and Audio took two additions inside 0.1.

## Decision

Accepted on 2026-11-13 by the operator, as proposed. Landed in MESKit v0.14.0:
- `mesh.generate_part` in the Mesh tables and schemas; `MeshProfile`'s names for it, `SubjectBox`, `GLB.bodyBone(for:)`,
  `humanoidBone(_:)` and `worldMatrix(node:)` (MESCore).
- `MeshProfileRules` (MESEngineCore): the gates for `part`, `subject_box`, `physics` and `texture`, `partDefaults`, and
  the flat check by the table's `places` flag; `ProfileRules.validateStructure`, which makes a malformed box 400 ahead
  of the descriptor's schema.
- `mes-mock-engine` offers `mock-hairdeck` and `mock-part-finder`; `MockMeshEngine.bodyGLB()` is the suite's body.
- MESFormsUI: `ImageBoxPicker`, the box row, a form that follows the offers, `.vrm` in `MeshInputWell`. MESClientKit
  sends a `.vrm` as `model/gltf-binary`.
- MESH-013 to MESH-018; MESH-001 to 003, 005, 009 and 010 on the new operation.

Where this differs from the shape AB-A-0280 proposed: the operation stays in Mesh 0.1; `effective.background` is
reported; a malformed box is 400 and a parameter the operation doesn't have is 422 `unsupported_parameter`, as for
every operation; `none` is a `texture` value for the whole profile; `hair` alone is registered; the root joint has the
body bone's place as well as its name; Base registers the `box` widget.

Still open on other sides: Gaea 1.7.0 adopts this release (AB-T-0482), and mlx-3d's `gaea-plugin-hairdeck` goes on
top (AB-A-0278). Neither changes this RFC.
