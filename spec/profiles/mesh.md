# Media Engine Specification — Mesh profile

| | |
|---|---|
| **Profile** | `mesh` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1, with what each offer supports (§6.4), users' acceptance ([RFC 0005](../../rfcs/0005-video-in-base.md)), the `mesh` kind, mesh facts and licence attribution ([RFC 0007](../../rfcs/0007-mesh.md)), and the `box` widget ([RFC 0009](../../rfcs/0009-mesh-generate-part.md)) |
| **Schemas** | [`schemas/v0/profiles/mesh/`](../../schemas/v0/profiles/mesh/) |
| **Sources** | RFCs [0007](../../rfcs/0007-mesh.md), [0009](../../rfcs/0009-mesh-generate-part.md); Gaea AB-A-0261, AB-A-0280; TRELLIS.2 (`mlx-trellis2-swift`), SkinTokens (`mlx-skintokens-swift`), HairDeck (`mlx-hairdeck-swift`) |

The Mesh profile defines three operations on 3D assets: generating a textured mesh from an image, rigging a mesh
with a skeleton and skin weights, and generating a rigged part (hair first) that fits a body. It defines how meshes
travel (glTF 2.0 binary), where an object sits and how big it is, the facts each result reports, the preview every
result carries, and the facts each model offer states about itself. An engine implementing this profile MAY offer any
of the operations. For each operation it offers, it MUST honour that operation's required inputs, outputs and
behaviour.

**Why normalized.** A client asks for a mesh of this photo, at most 200,000 faces, textured at 2048, standing on the
ground and 1.8 m tall, once, and every model that can do it understands: the engine maps the request to its model, and
fixes the axes, the placement and the scale the model's exporter chose. A part is the other case: it comes back
where its body is, and the engine leaves it there (§3.3).

**Not in Mesh 0.1.** Several views of one object, text → 3D, editing a mesh, a turntable video, compressed meshes,
USDZ and animation come later (§7).

## 1. Conventions

1. **Format.** Meshes are glTF 2.0 binary (`model/gltf-binary`, GLB): one JSON chunk and one BIN chunk, every buffer
   and image inside the file (no external `uri`, no data URIs). Outputs MUST NOT list `extensionsRequired`; they MAY
   use extensions a viewer can ignore (`KHR_materials_*`, `KHR_texture_transform`, and for a part `VRMC_springBone`
   and `VRMC_materials_mtoon`). Mesh inputs (`mesh.rig`) MUST be accepted in this form; an input that needs an
   extension the engine doesn't read is 422 `input_invalid`. The `body` of `mesh.generate_part` is not held to this
   rule or the next (§3.3).
2. **Geometry.** Triangles (`mode` 4) only, with `POSITION` (float, `min` and `max` set) and `NORMAL`, indexed with
   unsigned 16- or 32-bit indices or not indexed. Several nodes, meshes and primitives are allowed; every fact sums over
   them.
3. **Axes and units.** glTF's: right-handed, +Y up, metres. The object's front faces +Z: the input image's view is
   what a camera on the +Z axis looking at the origin sees.
4. **Placement and size.** With `placement: centered` (the default) the centre of the result's bounding box is the
   origin; with `grounded` it is centred on X and Z and its lowest point is at Y = 0. Either way it is scaled uniformly
   so its longest extent is `size_m` metres (default 1). `mesh.rig` doesn't move or scale the geometry (§3.2), and
   `mesh.generate_part` returns its part in the body's coordinates, never moved or scaled (§3.3).
5. **Materials.** PBR metallic-roughness (glTF core). A textured mesh has `TEXCOORD_0` and a `baseColorTexture`, PNG or
   JPEG, square or not, in one atlas or several; it MAY add metallic-roughness and normal maps (`supports.maps`). An
   untextured mesh carries its colour as `COLOR_0`, or with `texture: none` has no colour of its own: a plain
   material, no texture and no `COLOR_0`. `texture` picks which (§2).
6. **Facts.** Every `mesh` output reports `vertices`, `faces` and `bounds`, `texture_size` exactly when it has a
   texture, and `joints` exactly when it is skinned (Base §10.1, RFC 0007), and the file agrees with them.
7. **Previews.** Every operation that outputs a mesh also outputs `preview`: a PNG still of that mesh for clients that
   can't show 3D. It is square, at least 512 pixels a side, on a transparent background, rendered with the mesh's
   materials from the front-right and above (azimuth 30° from +Z towards +X, elevation 20°), framed so the object fills
   most of it. It is a picture of the result, never of the input.
8. **Flat results.** A generator can collapse an object into a near-zero-thickness "card" (TRELLIS.2, AB-R-0059). The
   engine measures each `generate` result's thinnest extent against its longest, over the mesh's principal axes where it
   can (else the bounding box). Below **0.08** the result is flat: it warns `flat_result` with the ratio, or, when the
   request says `on_flat: fail`, the job fails with 422 `input_invalid`, `reason: "degenerate_result"`, so the client
   can try another seed or image. A flat result isn't wrong for a flat object, which is why warning is the default.
   MESEngineKit applies the bounding-box check to every engine's `generate` results; an engine that measures principal
   axes warns or fails itself for a tilted card the box misses. A part is never checked: hair cards are thin by
   design (§3.3).
9. **Reductions.** When the model makes more faces than the request's `max_faces` or the offer's `limits.max_faces`,
   the engine decimates to fit. That is what the request asked for; but when only a limit forced it (the request had no
   `max_faces`), the engine warns `faces_reduced`. Likewise a texture scaled down to `limits.max_texture_size` without a
   `texture_size` in the request warns `texture_reduced`. A part is never decimated (§3.3).
10. **Input images** follow Image §1.1 (formats and orientation). The engine resizes and crops to its model's input
    itself; that is not a warning. An image whose alpha channel has transparent pixels is already cut out: its alpha is
    the object's mask, and `background: remove` doesn't run again. `mesh.generate_part` has no `background`
    parameter: an opaque picture is cut out where the offer can, and refused where it can't (§3.3).
11. **AI-content disclosure.** Base §10.2 rules 1 to 3 apply, and the marking is a MUST:
    - a `mesh.generate` or `mesh.generate_part` output says in the file that it is AI-generated: `asset.extras.mes.ai_generated` is `true` and
      `asset.extras.mes.model` is the model's title; its `preview` carries `AI-generated` and the title in its PNG
      `Comment` (or EXIF `UserComment`, where ImageIO writes a PNG comment);
    - `mesh.rig` keeps the input's `asset.extras`, `asset.copyright` and any watermark or provenance manifest, and adds
      its own model as `asset.extras.mes.rigged_with`.
12. **Licences in the file.** Base §10.2 rule 2's GLB row: `asset.copyright` holds the licences' attributions, then
    their `spdx` ids; `asset.extras.mes` holds `license`, `notice` and `attribution`. The `preview` carries the same in its
    PNG `Copyright` and `Comment`. An engine writes them whenever a licence of the job has an `attribution` or a
    `notice`, or isn't `commercial_use: true`.
13. **Licences that bind users.** An offer whose licence has `user_accept_required` runs only for requests whose
    `policy.accepted` lists its `spdx` (Base §10.2 rule 4, §10.3).
14. **Seeds.** `seed` is 0 – 2⁵³ − 1. Results report it in `effective.seed`; a request without one gets one the engine
    picks. A model whose meshes aren't identical for the same seed declares `supports.deterministic: false`.
15. **Progress.** Phases are `matting`, `structure`, `shape`, `texture`, `decimate`, `export` and `render` (the
    preview) for `generate`; `skeleton`, `skin`, `export` and `render` for `rig`; and `matting`, `shape`, `texture`,
    `skin`, `export` and `render` for `generate_part`, with `step` and `steps` within each.
    Preparing a model (downloading, loading) is stage `preparing` (Base §7.2).

## 2. Vocabulary

These names MUST be used in descriptors whenever the operation exposes the concept. They are defined in
[`vocabulary.schema.json`](../../schemas/v0/profiles/mesh/vocabulary.schema.json).

| Name | Type | Meaning |
|---|---|---|
| `seed` | integer, 0 – 2⁵³ − 1 | Repeatability (§1.14) |
| `quality` | `draft` · `standard` · `best` | Speed versus detail. The engine maps it to its models and their resolutions (TRELLIS.2: 512, 1024, 1536). Default `standard` |
| `resolution` | integer, 64 – 4096 | `generate`: the model's working resolution, its main detail and cost knob, overriding what `quality` picks within the offer. Gate: `supports.resolutions` |
| `max_faces` | integer, 100 – 50,000,000 | `generate`: the most triangles the result may have (§1.9). Absent: the offer's default, reported |
| `texture` | `atlas` · `vertex_colors` · `none` | `generate`, `generate_part`: a texture atlas, colour per vertex, or neither (§1.5). Gate: `supports.textures`. Default: the offer's first |
| `texture_size` | `256` · `512` · `1024` · `2048` · `4096` · `8192` | `generate`: the atlas's side in pixels. Gate: `supports.texture_sizes`. Only with `texture: atlas` |
| `background` | `remove` · `keep` | `generate`: cut the object out of an opaque image first, or use the whole image. Absent: `remove` where the offer can, else `keep` with `background_kept` |
| `placement` | `centered` · `grounded` | Where the object sits (§1.4). Default `centered` |
| `size_m` | number, > 0, ≤ 10000 | The object's longest extent in metres (§1.4). Default 1 |
| `on_flat` | `warn` · `fail` | What a flat result does (§1.8). Default `warn` |
| `skeleton` | string | `rig`: a registered skeleton template (§3.2). Absent: the model's own skeleton. Gate: `supports.skeletons`, or `supports.auto_skeleton` when absent |
| `part` | string | `generate_part`: which part to make, a registered tag (§3.3) or `x-<vendor>.<name>`. Default: the offer's first. Gate: `supports.parts` |
| `subject_box` | `{x, y, width, height}` | `generate_part`: where in the picture the part is read from; for `hair`, the head. Each a share of the upright image from its top-left corner, 0 – 1; `width` and `height` > 0; `x + width` and `y + height` ≤ 1. Gate: `supports.subject_box` |
| `physics` | boolean | `generate_part`: chain bones and `VRMC_springBone`. Default: `true` where the offer has `supports.physics`, else `false`. Gate: `supports.physics`, for `true` |

`texture_size` with `texture: vertex_colors` or `none` is 400 `invalid_request`. A `subject_box` that isn't four
numbers, has no area or reaches outside the image is malformed: 400 `invalid_request`, never `out_of_limits`. Model-specific knobs (sampling steps, guidance,
decimation and unwrapping methods, beam widths) are never vocabulary; engines expose them, if at all, as extensions
(Base §6.2), e.g. `x-trellis.steps`.

## 3. Operations

The required inputs, outputs and parameters of each operation are listed in
[`operations.json`](../../schemas/v0/profiles/mesh/operations.json), which the conformance suite reads.
[`job-request.schema.json`](../../schemas/v0/profiles/mesh/job-request.schema.json) validates a Mesh job request
against it.

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `mesh.generate` | `image` (image, required, 1) | `seed`, `quality`, `resolution`, `max_faces`, `texture`, `texture_size`, `background`, `placement`, `size_m`, `on_flat` | `mesh` (mesh, 1); `preview` (image, 1) | A textured mesh of the object in the image (§3.1) |
| `mesh.rig` | `mesh` (mesh, required, 1) | `skeleton`, `seed`, `quality` | `mesh` (mesh, 1); `preview` (image, 1) | The input with a skeleton and skin weights, its geometry kept exactly (§3.2) |
| `mesh.generate_part` | `image` (image, required, 1); `body` (mesh, required, 1) | `part`, `subject_box`, `physics`, `texture`, `seed`, `quality` | `mesh` (mesh, 1); `preview` (image, 1) | A rigged part, read from the image and placed on the body (§3.3) |

### 3.1 Generating a mesh

`generate` makes a mesh of the object in `image`.
- **The object.** With `background: remove` (or absent, on an offer with `supports.background_removal`) the engine cuts
  the object out of an opaque image first; with `keep`, or on an offer without removal, it uses the image as it is,
  and warns `background_kept` when the request didn't ask to keep it. An image with transparency is used as cut out
  (§1.10). `effective.background` reports what happened: `remove`, `keep` or `alpha`.
- **Detail.** `quality` picks the offer and its default resolution; `resolution` (one of `supports.resolutions`)
  overrides it within the offer. `effective.resolution` reports the resolution that ran, for an offer that has them.
- **Size of the result.** At most `max_faces` triangles (or the offer's default), within the offer's `min_faces` and
  `max_faces` limits (§4.2); `effective.max_faces` reports the cap applied, and the output's `faces` what was made.
- **Surface.** `texture` and `texture_size` as asked (§1.5), each reported in `effective`.
- **Placement** and **size** per §1.4, reported as `effective.placement` and `effective.size_m`.
- **Flat results** per §1.8.

### 3.2 Rigging a mesh

`rig` adds a skeleton and skin weights to `mesh`, and changes nothing else.
- **Geometry kept.** Every primitive keeps its vertices, in order, with the same positions, normals, texture
  coordinates and colours, and its triangles; materials, textures and the node transforms of the meshes are kept. The
  output's `vertices`, `faces` and `bounds` equal the input's.
- **The skin.** The output has one `skin`. Its joints are nodes forming one tree with one root; its
  `inverseBindMatrices` bind the input's pose (the pose in the file is the bind pose). Every primitive of the skinned
  meshes gets `JOINTS_0` and `WEIGHTS_0`: at most `supports.max_influences` non-zero weights per vertex (absent: 4, one
  set), each vertex's weights summing to 1 (± 0.001). The output reports `joints`.
- **`skeleton`** names a template from `supports.skeletons`; its joints are named as the template names them, and the
  template's root is the skin's root. A template joint the mesh has no part for (a tail on a person) may be left out,
  with `joints_dropped` naming them; the rest MUST be present. Absent, the model predicts a skeleton of its own
  (`supports.auto_skeleton`), with unique joint names it chooses.
- **Templates** registered in 0.1 (a template is registered when one model uses it):

  | Template | Skeleton | Used by |
  |---|---|---|
  | `vrm_humanoid` | VRM's humanoid bones as VRoid names them (`J_Bip_C_Hips` … `J_Bip_R_ToeBase`, 52 joints rooted at the hips; to be checked against SkinTokens' `configs/skeleton/vroid.yaml` when its port lands): the list in [`vocabulary.schema.json`](../../schemas/v0/profiles/mesh/vocabulary.schema.json) `$defs/vrm_humanoid_joints` | SkinTokens (its `vroid` class) |

- **The input.** A mesh that is already skinned is rigged afresh: the old skin is removed, with `skin_replaced`.
  Animations are dropped, with `animations_dropped`. A mesh above `limits.max_input_faces` is 422 `out_of_limits`;
  a skeleton above `limits.max_joints` is never made. The template assumes §1.3's axes (up +Y, facing +Z).
- **Disclosure** per §1.11.

### 3.3 Generating a part for a body

`generate_part` makes one part of a character (its hair, first) from a picture, as a rigged item placed on `body`
([RFC 0009](../../rfcs/0009-mesh-generate-part.md)). The result is the part alone. Merging it into the body's file is
the client's.

- **The picture.** `image` shows the character wearing the part. One with transparency is used as cut out (§1.10).
  An opaque one is cut out by the model, on an offer with `supports.background_removal`; sent to an offer without, it
  is refused `unsupported_parameter` with `param: "image"`: 422 at submission, or as the job's error when the engine
  reads the picture only as the job starts. `effective.background` reports `remove` or `alpha`.
- **The body.** `body` is the rigged GLB or `.vrm` the part goes on (VRM 0.x and 1.0 files are GLBs), sent as a file
  or as an asset (Base §8.1), so a client making many parts for one body uploads it once. The engine reads it and
  never changes or returns it. It is not held to §1.1 and §1.2: a VRM may list `extensionsRequired` and carry KTX
  textures and morph targets. A body the engine can't read as a GLB, or can't find the part's bone in, is 422
  `input_invalid` with `param: "body"`, at submission or as the job's error.
- **`part`** names what to make, from `supports.parts`; absent, the offer's first. Registered in 0.1 (a part is
  registered when one model makes it, and its row says which bones it hangs from):

  | Part | What it is | Hangs from | Made by |
  |---|---|---|---|
  | `hair` | The character's hair | The body's head bone | HairDeck |

  `garment` and `accessory` are reserved for the first models that make them.
- **`subject_box`** says where in the picture the part is read from (for `hair`, the head: hair and face), in shares
  of the upright image (§2). `supports.subject_box` says what an offer does with one: `required` (the model doesn't
  locate the part), `optional` (it locates the part, and a box overrides that), or absent (it always locates the part
  itself). A box to an offer without the key is 422 `unsupported_parameter`. A request without a box is never routed
  to an offer that requires one; to a named offer that requires one, or when only such offers may run it, it is 422
  `unsupported_parameter` with `param: "subject_box"`. `effective.subject_box` is the box used.
- **In the body's coordinates.** The part's vertices and joints are in the coordinates of the body's file (glTF axes,
  metres), where the part sits on that body in its rest pose. A VRM 0.x body faces −Z in its file, and the part faces
  the same way. The engine MUST NOT move, scale, re-root or decimate the result: §1.4, §1.8 and §1.9 don't apply, and
  no `flat_result` is reported.
- **The skin.** The output has one `skin` and reports `joints`. The joints that stand for bones of the body are named
  as the body names them and have the global transform the body gives them at rest; the skin's root joint is one of
  them, and the part's own joints (hair chains) are beneath them. For `hair` the root joint is the body's head bone,
  by name. A client attaches the part by putting the root joint's children under the body's bone of that name. The
  pose in the file is the bind pose, and every primitive has `JOINTS_0` and `WEIGHTS_0` as §3.2 asks.
- **The head bone** of a VRM body is its humanoid `head` bone (`VRMC_vrm`, or VRM 0.x's `VRM`). In another rigged GLB
  the engine finds it by its own means, and its offers' `notes` say which bodies it reads.
- **`physics`.** With `true` the file carries `VRMC_springBone` (spec version 1.0) over the part's own joints, in
  `extensionsUsed` and never in `extensionsRequired`. With `false` it has no `VRMC_springBone` and no chain joints:
  the part is skinned to the body's bones alone. Absent, it is `true` where the offer has `supports.physics`.
- **Surface.** `texture` as asked (§1.5): `atlas`, `vertex_colors` or `none`, from `supports.textures`.
- **The file otherwise** follows §1.1 and §1.2, reports its facts (§1.6) and comes with a `preview` of the part alone
  in its bind pose (§1.7). An engine that stamps a model's file (§1.11, §1.12) changes `asset` only: nodes, skins,
  inverse bind matrices, materials and their extensions, `extensions.VRMC_springBone` and `extensionsUsed` stay as
  the model wrote them.
- **`effective`** reports `part`, `physics`, `texture`, `background`, `seed`, and `subject_box` when one was used.
- **For clients.** One that merges the part into the body carries the part's `asset.copyright` into the merged file
  (a VRM's `meta.thirdPartyLicenses`). This is a note, not an engine rule.

**Variants and versions.** `rig` keeps a mesh's geometry, so clients may store its result as a version of the input;
`generate` and `generate_part` make new meshes. The profile describes this distinction; it doesn't impose it.

## 4. What each offer supports

### 4.1 `supports` keys

Model offers state what they support with `supports` (Base §6.4). Base defines `stream`, `seed`, `voices` and `watermark`; the Mesh
profile defines these. [`supports.schema.json`](../../schemas/v0/profiles/mesh/supports.schema.json) types them per
operation.

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `background_removal` | `generate`, `generate_part` | boolean | `false` | Gate: `background: remove` (`generate`); an opaque picture (`generate_part`, §3.3) |
| `resolutions` | `generate` | `[integer]` | none | Gate: `resolution`. Fact: the resolutions the offer runs at |
| `textures` | `generate`, `generate_part` | `[atlas · vertex_colors · none]` | `[atlas]` | Gate: `texture` |
| `texture_sizes` | `generate` | `[integer]` | none | Gate: `texture_size` |
| `maps` | `generate` | `[base_color · metallic_roughness · normal · emissive]` | `[base_color]` | Fact: the material maps the offer writes |
| `skeletons` | `rig` | `[string]` | `[]` | Gate: `skeleton` |
| `auto_skeleton` | `rig` | boolean | `true` | Gate: a request without `skeleton` |
| `max_influences` | `rig` | integer, 1 – 8 | `4` | Fact: non-zero weights per vertex at most |
| `parts` | `generate_part` | `[string]` | REQUIRED | Gate: `part`. The first is the default |
| `subject_box` | `generate_part` | `required` · `optional` | the model locates the part | Gate: `subject_box`; with `required`, also a request without one |
| `physics` | `generate_part` | boolean | `false` | Gate: `physics: true` |
| `deterministic` | all | boolean | `true` | Fact: the same seed gives the same mesh |

A request implies the offers whose gates admit it (Base §6.4 rule 2); a named offer that doesn't is 422
`unsupported_parameter`, never a substitute (rule 3). MESEngineKit applies every key in this table and every limit it can
read from the request itself (`max_faces`, `texture_size`), for the engine. Limits on the input media (a mesh's faces)
and what only the media show (an opaque picture, a body without the bone) are the engine's to check once it has read
them.

### 4.2 Limit fields

A descriptor's `limits`, and an offer's narrower ones, take these fields:

| Field | Operations | Bounds |
|---|---|---|
| `min_faces` | `generate` | `max_faces` in a request; below it is 422 `out_of_limits` |
| `max_faces` | `generate` | `max_faces` in a request, and every result (§1.9) |
| `max_texture_size` | `generate` | `texture_size` in a request, and every result (§1.9) |
| `max_input_faces` | `rig` | The input mesh; more is 422, not decimated |
| `max_joints` | `rig` | The skeleton made |

`generate_part` has no limit fields of its own; an offer may state Base's image limits for the picture.

## 5. Warnings

The profile adds these warning codes to Base's:

| Code | When |
|---|---|
| `flat_result` | The result's thinnest extent is under 0.08 of its longest (§1.8) |
| `faces_reduced` | The mesh was decimated to an offer's limit the request didn't ask for (§1.9) |
| `texture_reduced` | The texture was scaled down to an offer's limit the request didn't ask for (§1.9) |
| `background_kept` | The image was opaque and the offer can't remove its background (§3.1) |
| `joints_dropped` | Template joints the mesh has no part for were left out (§3.2) |
| `skin_replaced` | The input's skin was replaced (§3.2) |
| `animations_dropped` | The input's animations were dropped (§3.2) |

**Error reasons** (Base §12): `degenerate_result`, with `input_invalid`: a flat result refused by `on_flat: fail`.

## 6. Conformance (MESH-nnn)

An engine conforms to Mesh 0.1 for the operations it offers when:
- every offered operation's descriptor lists its required inputs and outputs (`operations.json`);
- the parameters it exposes use the vocabulary names, and its offers' `supports` the keys of §4;
- these tests pass. Each asks for an offer's cheapest tier and its fewest faces. The image input is a 256×256 PNG of a
  red ball on white; the mesh input is a 1,280-face textured sphere. For `generate_part` the picture is the ball cut
  out, the box is the ball's, and the body is a small VRM 1.0 figure, 1.57 m tall, standing on the ground and facing
  +Z, whose head bone is `J_Bip_C_Head`.

| Test | Checks |
|---|---|
| MESH-001 | Descriptors match the operations table: required inputs and outputs of the right kinds, only vocabulary parameters, the required ones present |
| MESH-002 | Offers' `supports` keys have the profile's types and their limits are the profile's fields; every `generate_part` offer lists `parts` |
| MESH-003 | Mesh outputs are GLB 2.0 by §1.1 and §1.2 (one JSON and one BIN chunk, nothing external, no `extensionsRequired`, triangles with normals), report `vertices`, `faces` and `bounds`, and the file agrees; `texture_size` exactly when textured and `joints` exactly when skinned, agreeing; a flat result carries `flat_result` |
| MESH-004 | Placement: `centered` puts the bounding box's centre at the origin, `grounded` its lowest point at Y = 0, and the longest extent is `size_m` (1 by default) |
| MESH-005 | Every mesh output comes with a `preview`: a square PNG of at least 512 pixels with transparent pixels |
| MESH-006 | `generate`: `faces` ≤ `max_faces`; `max_faces` below the offer's `min_faces` is 422; a `resolution`, `texture` or `texture_size` the named offer doesn't list is 422; `texture_size` with `vertex_colors` is 400; `effective` reports `seed`, `max_faces`, `texture`, `placement` and `size_m` |
| MESH-007 | `generate`: `background: remove` to an offer without `background_removal` is 422; an image with transparency is accepted and reported as `alpha` |
| MESH-008 | `on_flat` is accepted with both values; a result refused for flatness fails with `input_invalid` and `reason: "degenerate_result"` |
| MESH-009 | Disclosure and licences: a generated mesh or part says `ai_generated` in `asset.extras.mes`; an offer's `attribution` is in the file's `asset.copyright` |
| MESH-010 | `seed` is reported; the same seed reproduces the same mesh where the offer is `deterministic` (the difference is reported where it isn't) |
| MESH-011 | `rig`: the input's vertices, faces and bounds kept; one skin, `JOINTS_0` and `WEIGHTS_0` on every primitive, weights summing to 1, no more influences than `max_influences`; `joints` agrees; a template's joint names are the template's; a `skeleton` the named offer doesn't list is 422, and so is no `skeleton` to an offer without `auto_skeleton` |
| MESH-012 | `rig` input: a GLB with an embedded texture is accepted; bytes that aren't a GLB are 422 `input_invalid` |
| MESH-013 | `generate_part` leaves the result on the body: its bounds lie inside the body's grown by half the body's height, it reaches above the body's head bone, and it carries no `flat_result` |
| MESH-014 | `generate_part`: one skin and `joints` reported; the root joint has the name of the body's head bone and sits where the body has it; `JOINTS_0` and `WEIGHTS_0` on every primitive, weights summing to 1 |
| MESH-015 | `generate_part` physics: `VRMC_springBone` is in `extensions` and `extensionsUsed` with `physics` true and absent with false; `physics: true` to an offer without `supports.physics` is 422 |
| MESH-016 | `generate_part` textures: `texture: none` gives no texture, no `COLOR_0` and no `texture_size`; a `texture` the named offer doesn't list is 422; `effective` reports `part`, `physics`, `texture` and `background` |
| MESH-017 | `subject_box`: a box outside the image or with no area is 400; a box to an offer without `supports.subject_box` is 422; no box to a named offer that requires one is 422; `effective.subject_box` echoes the box |
| MESH-018 | `generate_part` inputs: a request without `body` is 400; bytes that aren't a GLB are `input_invalid`; a `part` the named offer doesn't list is 422; an opaque picture runs where the offer has `background_removal` and is refused where it doesn't |

Base's tests of what each offer supports (BASE-014 to BASE-018) and of users' acceptance (BASE-019) run on the Mesh
operations an engine offers.

## 7. Later, and outside

- **Later:** several views of one object (`views`, with their angles), a turntable video beside the preview, compressed
  meshes (Draco, meshopt) and USDZ as `output` options, text → 3D, `mesh.edit` (TRELLIS.2's mesh → structured-latent
  encoder exists only for CUDA, AB-B-0027), retopology, animating a rigged mesh, parts beyond hair (`garment`,
  `accessory`), and a part from a point cloud of its shape (HairDeck reads one; the engine contract carries it).
- **Outside MES:** viewing and editing meshes, and merging a part into its body, which are the client's.
