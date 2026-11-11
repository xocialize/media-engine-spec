# Media Engine Specification — Mesh profile

| | |
|---|---|
| **Profile** | `mesh` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1, with what each offer supports (§6.4), users' acceptance ([RFC 0005](../../rfcs/0005-video-in-base.md)), and the `mesh` kind, mesh facts and licence attribution ([RFC 0007](../../rfcs/0007-mesh.md)) |
| **Schemas** | [`schemas/v0/profiles/mesh/`](../../schemas/v0/profiles/mesh/) |
| **Sources** | RFC [0007](../../rfcs/0007-mesh.md); Gaea AB-A-0261; TRELLIS.2 (`mlx-trellis2-swift`), SkinTokens (`mlx-skintokens-swift`) |

The Mesh profile defines two operations on 3D assets: generating a textured mesh from an image, and rigging a mesh
with a skeleton and skin weights. It defines how meshes travel (glTF 2.0 binary), where an object sits and how big it
is, the facts each result reports, the preview every result carries, and the facts each model offer states about
itself. An engine implementing this profile MAY offer either operation. For each operation it offers, it MUST honour
that operation's required inputs, outputs and behaviour.

**Why normalized.** A client asks for a mesh of this photo, at most 200,000 faces, textured at 2048, standing on the
ground and 1.8 m tall, once, and every model that can do it understands: the engine maps the request to its model, and
fixes the axes, the placement and the scale the model's exporter chose.

**Not in Mesh 0.1.** Several views of one object, text → 3D, editing a mesh, a turntable video, compressed meshes,
USDZ and animation come later (§7).

## 1. Conventions

1. **Format.** Meshes are glTF 2.0 binary (`model/gltf-binary`, GLB): one JSON chunk and one BIN chunk, every buffer
   and image inside the file (no external `uri`, no data URIs). Outputs MUST NOT list `extensionsRequired`; they MAY
   use extensions a viewer can ignore (`KHR_materials_*`, `KHR_texture_transform`). Mesh inputs (`mesh.rig`) MUST be
   accepted in this form; an input that needs an extension the engine doesn't read is 422 `input_invalid`.
2. **Geometry.** Triangles (`mode` 4) only, with `POSITION` (float, `min` and `max` set) and `NORMAL`, indexed with
   unsigned 16- or 32-bit indices or not indexed. Several nodes, meshes and primitives are allowed; every fact sums over
   them.
3. **Axes and units.** glTF's: right-handed, +Y up, metres. The object's front faces +Z: the input image's view is
   what a camera on the +Z axis looking at the origin sees.
4. **Placement and size.** With `placement: centered` (the default) the centre of the result's bounding box is the
   origin; with `grounded` it is centred on X and Z and its lowest point is at Y = 0. Either way it is scaled uniformly
   so its longest extent is `size_m` metres (default 1). `mesh.rig` doesn't move or scale the geometry (§3.2).
5. **Materials.** PBR metallic-roughness (glTF core). A textured mesh has `TEXCOORD_0` and a `baseColorTexture`, PNG or
   JPEG, square or not, in one atlas or several; it MAY add metallic-roughness and normal maps (`supports.maps`). An
   untextured mesh carries its colour as `COLOR_0`. `texture` picks which (§2).
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
   MESEngineKit applies the bounding-box check to every engine's results; an engine that measures principal axes
   warns or fails itself for a tilted card the box misses.
9. **Reductions.** When the model makes more faces than the request's `max_faces` or the offer's `limits.max_faces`,
   the engine decimates to fit. That is what the request asked for; but when only a limit forced it (the request had no
   `max_faces`), the engine warns `faces_reduced`. Likewise a texture scaled down to `limits.max_texture_size` without a
   `texture_size` in the request warns `texture_reduced`.
10. **Input images** follow Image §1.1 (formats and orientation). The engine resizes and crops to its model's input
    itself; that is not a warning. An image whose alpha channel has transparent pixels is already cut out: its alpha is
    the object's mask, and `background: remove` doesn't run again.
11. **AI-content disclosure.** Base §10.2 rules 1 to 3 apply, and the marking is a MUST:
    - a `mesh.generate` output says in the file that it is AI-generated: `asset.extras.mes.ai_generated` is `true` and
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
    preview) for `generate`, and `skeleton`, `skin`, `export` and `render` for `rig`, with `step` and `steps` within each.
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
| `texture` | `atlas` · `vertex_colors` | `generate`: a texture atlas, or colour per vertex (§1.5). Gate: `supports.textures`. Default: the offer's first |
| `texture_size` | `256` · `512` · `1024` · `2048` · `4096` · `8192` | `generate`: the atlas's side in pixels. Gate: `supports.texture_sizes`. Only with `texture: atlas` |
| `background` | `remove` · `keep` | `generate`: cut the object out of an opaque image first, or use the whole image. Absent: `remove` where the offer can, else `keep` with `background_kept` |
| `placement` | `centered` · `grounded` | Where the object sits (§1.4). Default `centered` |
| `size_m` | number, > 0, ≤ 10000 | The object's longest extent in metres (§1.4). Default 1 |
| `on_flat` | `warn` · `fail` | What a flat result does (§1.8). Default `warn` |
| `skeleton` | string | `rig`: a registered skeleton template (§3.2). Absent: the model's own skeleton. Gate: `supports.skeletons`, or `supports.auto_skeleton` when absent |

`texture_size` with `texture: vertex_colors` is 400 `invalid_request`. Model-specific knobs (sampling steps, guidance,
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

**Variants and versions.** `rig` keeps a mesh's geometry, so clients may store its result as a version of the input;
`generate` makes new meshes. The profile describes this distinction; it doesn't impose it.

## 4. What each offer supports

### 4.1 `supports` keys

Model offers state what they support with `supports` (Base §6.4). Base defines `stream`, `seed`, `voices` and `watermark`; the Mesh
profile defines these. [`supports.schema.json`](../../schemas/v0/profiles/mesh/supports.schema.json) types them per
operation.

| Key | Operations | Type | Absent | Class |
|---|---|---|---|---|
| `background_removal` | `generate` | boolean | `false` | Gate: `background: remove` |
| `resolutions` | `generate` | `[integer]` | none | Gate: `resolution`. Fact: the resolutions the offer runs at |
| `textures` | `generate` | `[atlas · vertex_colors]` | `[atlas]` | Gate: `texture` |
| `texture_sizes` | `generate` | `[integer]` | none | Gate: `texture_size` |
| `maps` | `generate` | `[base_color · metallic_roughness · normal · emissive]` | `[base_color]` | Fact: the material maps the offer writes |
| `skeletons` | `rig` | `[string]` | `[]` | Gate: `skeleton` |
| `auto_skeleton` | `rig` | boolean | `true` | Gate: a request without `skeleton` |
| `max_influences` | `rig` | integer, 1 – 8 | `4` | Fact: non-zero weights per vertex at most |
| `deterministic` | all | boolean | `true` | Fact: the same seed gives the same mesh |

A request implies the offers whose gates admit it (Base §6.4 rule 2); a named offer that doesn't is 422
`unsupported_parameter`, never a substitute (rule 3). MESEngineKit applies every key in this table and every limit it can
read from the request itself (`max_faces`, `texture_size`), for the engine. Limits on the input media (a mesh's faces)
are the engine's to check once it has read them.

### 4.2 Limit fields

A descriptor's `limits`, and an offer's narrower ones, take these fields:

| Field | Operations | Bounds |
|---|---|---|
| `min_faces` | `generate` | `max_faces` in a request; below it is 422 `out_of_limits` |
| `max_faces` | `generate` | `max_faces` in a request, and every result (§1.9) |
| `max_texture_size` | `generate` | `texture_size` in a request, and every result (§1.9) |
| `max_input_faces` | `rig` | The input mesh; more is 422, not decimated |
| `max_joints` | `rig` | The skeleton made |

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
  red ball on white; the mesh input is a 1,280-face textured sphere.

| Test | Checks |
|---|---|
| MESH-001 | Descriptors match the operations table: required inputs and outputs of the right kinds, only vocabulary parameters, the required ones present |
| MESH-002 | Offers' `supports` keys have the profile's types and their limits are the profile's fields |
| MESH-003 | Mesh outputs are GLB 2.0 by §1.1 and §1.2 (one JSON and one BIN chunk, nothing external, no `extensionsRequired`, triangles with normals), report `vertices`, `faces` and `bounds`, and the file agrees; `texture_size` exactly when textured and `joints` exactly when skinned, agreeing; a flat result carries `flat_result` |
| MESH-004 | Placement: `centered` puts the bounding box's centre at the origin, `grounded` its lowest point at Y = 0, and the longest extent is `size_m` (1 by default) |
| MESH-005 | Every mesh output comes with a `preview`: a square PNG of at least 512 pixels with transparent pixels |
| MESH-006 | `generate`: `faces` ≤ `max_faces`; `max_faces` below the offer's `min_faces` is 422; a `resolution`, `texture` or `texture_size` the named offer doesn't list is 422; `texture_size` with `vertex_colors` is 400; `effective` reports `seed`, `max_faces`, `texture`, `placement` and `size_m` |
| MESH-007 | `generate`: `background: remove` to an offer without `background_removal` is 422; an image with transparency is accepted and reported as `alpha` |
| MESH-008 | `on_flat` is accepted with both values; a result refused for flatness fails with `input_invalid` and `reason: "degenerate_result"` |
| MESH-009 | Disclosure and licences: a generated mesh says `ai_generated` in `asset.extras.mes`; an offer's `attribution` is in the file's `asset.copyright` |
| MESH-010 | `seed` is reported; the same seed reproduces the same mesh where the offer is `deterministic` (the difference is reported where it isn't) |
| MESH-011 | `rig`: the input's vertices, faces and bounds kept; one skin, `JOINTS_0` and `WEIGHTS_0` on every primitive, weights summing to 1, no more influences than `max_influences`; `joints` agrees; a template's joint names are the template's; a `skeleton` the named offer doesn't list is 422, and so is no `skeleton` to an offer without `auto_skeleton` |
| MESH-012 | `rig` input: a GLB with an embedded texture is accepted; bytes that aren't a GLB are 422 `input_invalid` |

Base's tests of what each offer supports (BASE-014 to BASE-018) and of users' acceptance (BASE-019) run on the Mesh
operations an engine offers.

## 7. Later, and outside

- **Later:** several views of one object (`views`, with their angles), a turntable video beside the preview, compressed
  meshes (Draco, meshopt) and USDZ as `output` options, text → 3D, `mesh.edit` (TRELLIS.2's mesh → structured-latent
  encoder exists only for CUDA, AB-B-0027), retopology, and animating a rigged mesh.
- **Outside MES:** viewing and editing meshes, which is the client's.
