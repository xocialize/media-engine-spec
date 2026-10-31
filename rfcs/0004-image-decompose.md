# RFC 0004: Decomposing an image into layers

| | |
|---|---|
| **Status** | Accepted, amended (2026-10-30) |
| **Affects** | Image 0.1 (§1.5, §2, §3, §3.2, §5); `schemas/v0/profiles/image/` |
| **Author** | xocialize |
| **Context** | Gaea AB-T-0388 and AB-T-0389; MLXEngine contract 1.48.0 `layerDecompose` (`capability-contract.md`) |
| **Decision** | mlx-apps, as the spec's owner, on AB-A-0228. Landed in the Image 0.1 draft and MESKit v0.6.0 (see [Decision](#decision)) |

## Problem

A client can't turn a flat design into the layers it was made from.

**Example.** A signage app has a finished poster as one PNG: a background, a product photo, a badge, and a headline.
The user wants to move the headline and recolour the badge. The app needs the poster as a stack of RGBA layers, front
to back, each holding one element, with the pixels it hid filled in, so that the stack composites back to the poster.

Models now do this:
- **Ming-Image 0.1 Design-Layer** (inclusionAI, MIT) is ported to MLX (ming-image-swift, `MingImageLayerPackage`). It
  is parity-gated: the composite and four layers are within 1/255 of the reference (AB-R-0341). It takes the image and
  a per-layer plan ("Layer 1: the headline text …"), and returns up to 12 straight-alpha layers plus its own
  reconstruction of the whole canvas. MLXEngine has carried it as the `layerDecompose` capability since contract
  1.48.0.
- **Qwen-Image-Layered** is another public model of the same shape.

No Image operation fits:

| Operation | Why not |
|---|---|
| `image.segment` | Masks of what is visible. A layer also needs the pixels the layers in front of it hid. |
| `image.matte` | One foreground and one alpha. A design has several layers, and their order is the point. |
| `image.edit` | One output image. |
| An extension | Base §6 rule 6 lets an engine offer only operations a profile defines. An extension can add parameters, not a new output shape. |

The plugin that serves Ming-Image Design in Gaea (gaea-plugin-ming-image 0.2.0) ships the generator. The Design-Layer
checkpoint waits on this RFC.

## Proposal

A new operation, `image.decompose`, in the Image 0.1 draft. This section is as accepted, with the amendments marked
(A1–A8, listed under [Decision](#decision)).

### §3 Operations

A new row:

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `image.decompose` | `image`; `prompt` (text, optional) | `layer_count`, `outputs`, `quality`, `seed`, `output`, `prompt_enhance` | `layers` (image, 1–n); `composite` (image, optional) | §3.2 |

### §3.2 Decomposing an image (new)

`image.decompose` returns an image as a stack of layers that composites back to it.
- **Order.** `layers` is front-most first. The last layer is the background. Compositing the layers back to front,
  last to first, with straight-alpha "over" (§1.5), approximates the input. How closely is the model's quality, not a
  conformance rule.
- **Every layer** is an RGBA image with straight alpha, the same size as the input (§1.5, IMAGE-003). An engine whose
  model works at a smaller size scales the layers back up. Outputs are PNG unless the request's `output` asks for
  another format that carries alpha. A descriptor's `output` leaves out formats without alpha (`image/jpeg`), so
  asking for one is 422 `unsupported_parameter` (§1.2). *(A1)*
- **Hidden pixels.** A layer holds its whole element, including the parts that layers in front of it cover, as far as
  the model can infer them.
- **Count.** `layer_count` is how many layers to return, excluding `composite`. With it, the engine MUST return exactly
  that many, or refuse the request. Without it, the engine chooses (from the prompt, or a model default). Either way it
  reports the count in `effective.layer_count`. *(A2)* The descriptor's `layer_count` schema states the most layers its
  offers allow (§6 rule 4), and a request above that is 422 `out_of_limits`. *(A5)* An engine whose model returns
  another number of layers fails the job with `engine_error`; it never pads or drops layers to meet the count. *(A3)*
- **The prompt** is the layer plan, front-most first: what each layer holds ("Layer 1: the headline 'SALE'. Layer 2:
  the red badge behind it …"). It may be rough. When the plan lists layers, `layers[i]` SHOULD hold its (i + 1)-th
  entry, so the plan is how a client names its layers. *(A4)* A count the engine reads from the prompt is held to the
  same rules as `layer_count`: one that contradicts `layer_count` is 400 `invalid_request`, and one above the maximum
  is 422 `out_of_limits`. *(A3)* `prompt_enhance` (§1.9) applies: an enhancer may rewrite a rough plan into a precise
  one by looking at the image, as Ming-Image's reference pipeline does, with the warning `prompt_rewritten`.
- **`composite`** is the model's own reconstruction of the whole canvas, for a model that makes one. It is a check, never
  needed to rebuild the stack. An engine offers it only for a model that produces it, and a client asks for it with
  `outputs: ["layers", "composite"]`. `outputs` defaults to `["layers"]`. An `outputs` without `layers` is 400
  `invalid_request`, and one the descriptor doesn't offer is 422 `unsupported_parameter` (IMAGE-010). *(A6)*
- **An input with alpha.** Pixels that are transparent in the input SHOULD be transparent in every layer. An engine
  whose model can't keep them re-applies the input's alpha to each layer and warns `alpha_reapplied` (§1.5).
- **Variants.** The stack keeps the input's content, so a client may store it as a layered version of the image
  rather than as a new one (§3, "Variants and versions"). *(A8: `decompose` joins that paragraph's list.)*

### §2 Vocabulary

| Name | Type | Meaning |
|---|---|---|
| `layer_count` | integer, 1 – 32 | `decompose`: how many layers to return, excluding `composite`. The descriptor narrows the range to what its offers allow. |

`outputs` gains `decompose`'s values, as it has `matte`'s: any of `layers` and `composite`, with `layers` required.

### §1.5 Alpha

One sentence added: "`image.decompose` returns every layer with straight alpha (§3.2)."

### §4 Warnings

No new codes. `prompt_rewritten`, `prompt_enhance_ignored` and `alpha_reapplied` apply as they do elsewhere.

### Schemas

- `operations.json`: an `image.decompose` entry with:
  - inputs: `image` (image, required) and `prompt` (text);
  - outputs: `layers` (image, multiple) and `composite` (image);
  - vocabulary: `layer_count`, `outputs` (`decompose_outputs`), `quality`, `seed`, `output` *(A1)* and `prompt_enhance`;
  - `keeps_input_size: true`.
- `vocabulary.schema.json`: `layer_count` (integer, 1–32), and `decompose_outputs` (array of `layers` and `composite`,
  at least one item). That `layers` is required is §3.2's rule, not the schema's: the JSON Schema subset MES's
  validators implement has no `contains`. *(A6)*

### How an engine would carry it (illustrative, not part of this RFC)

- **Over MLXEngine** it maps one to one onto `layerDecompose`:
  - the input and prompt become `image` and `spec`;
  - `layer_count` becomes `layerCount`;
  - `quality` picks the working bucket: `draft` is 512 and `standard` or `best` is 1024;
  - `layers[0]` stays front-most, and `composite` is passed through.
  - The package refuses a spec whose stated count contradicts `layerCount` (`unsupportedRequestFeature`); an engine
    answers that 400 `invalid_request`, as §3.2 says.
- **In Gaea**, the Ming-Image plugin would add a `ming-image-layer` model on `image.decompose`, with int8, bf16 and
  int4 lanes and a `layer_count` maximum of 12. The normalizer would need a decompose route that scales the layers to
  the input size and re-applies alpha.
- **The planner** is a prompt-enhance profile: a vision-language model reads the image and the rough plan, and writes
  the per-layer plan the model expects.

## Compatibility

- **Additive.** Image 0.1 is still a draft, so this joins it without a version bump. Engines that don't offer
  `image.decompose` are unaffected.
- **Older clients** don't list the operation. A client built on `operations.json` gains it when it updates the schema.
- **`outputs`** keeps its meaning for `matte`. Its allowed values are per operation, as now. One change reaches `matte`
  too *(A6)*: MESKit used to answer an `outputs` value outside the descriptor's list with 422 `out_of_limits`, and now
  answers 422 `unsupported_parameter`, as it already did for `output` (§1.2, IMAGE-010).

## Conformance

| Test | Checks | Spec |
|---|---|---|
| IMAGE-014 | `decompose` with `layer_count` n returns exactly n `layers`, each an RGBA PNG the size of the input; without it, `effective.layer_count` equals the number returned; a `composite` asked for is one image the size of the input *(A7)* | §3.2 |
| IMAGE-015 | `layer_count` above the descriptor's maximum is 422 `out_of_limits`; `outputs` without `layers` is 400 `invalid_request` *(A7)*; `composite` from a descriptor that doesn't offer it is 422 `unsupported_parameter` | §3.2, §6 rule 4 |
| IMAGE-016 | The layers composited back to front, straight-alpha "over", are close to the input: the mean absolute error is reported, never failed | §3.2 |

IMAGE-003 (same size) and IMAGE-009 (the operations table) cover the rest. The mock engine carries IMAGE-014 and
IMAGE-015 with a trivial decomposer: a background layer, and one layer per vertical band.

## Alternatives considered

- **Masks from `image.segment`, filled with `image.fill`.** A client could build layers this way, but it would need N
  segment calls and N fills, and still have no order. A decomposition model does it in one pass with the order built in.
- **One output holding the whole stack** (a PSD, a TIFF with layers, or a zip). Opaque to clients that don't read that
  format, and layered TIFF is poorly supported. Typed `layers` keep each layer a plain PNG. A layered file can come later
  as an `output` media type, such as `image/vnd.adobe.photoshop`, built from the same layers.
- **Back-most first.** Compositing order would be the array order. But a plan reads front to back ("the headline, then
  the badge …"), as Ming's does, and the engine contract already fixes front-most first.
- **A layer plan as data** (`[{description, kind}]`) instead of the prompt. More structure than the models take today:
  Ming reads free text, and its reference planner writes free text. A data input can be added later beside `prompt`.
- **`count` instead of `layer_count`.** `count` means more results, each with `seed + i`. Here it would mean something
  else on one operation.

## Decision

**Accepted, amended.** The gap is real: no Image operation returns an ordered stack, and Base §6 rule 6 closes the
extension route, so the choice is a profile operation or nothing. The operation is small, maps one to one onto an
engine contract that already ships (`layerDecompose`, 1.48.0) and a provider that is parity-gated (AB-R-0341), and
Image 0.1 is a draft, so it joins without a version bump. Its shape follows `matte` (opt-in outputs) and `segment`
(an image list), so clients and the kit need nothing new beyond one parameter.

Amendments:
- **A1. `output` joins the vocabulary.** The draft's §3.2 used it ("unless the request's `output` asks for another
  format") but left it out of the list. Formats without alpha are left out of the descriptor, and asking for one is
  §1.2's 422.
- **A2. `effective.layer_count` is always reported,** not only when the request omitted it, so a client reads one place.
- **A3. The count is exact both ways.** A count read from the prompt meets the same rules as `layer_count` (Ming's
  package already refuses a contradiction, and refuses a stated count above its maximum). A model that returns another
  number fails the job: a padded or truncated stack would break `layers[i]` ↔ plan entry i.
- **A4. Plan order is layer order** (SHOULD). This is the answer to open question 2.
- **A5. The descriptor, not "a model's descriptor", narrows `layer_count`.** Offers don't have descriptors. Until
  [RFC 0003](0003-offer-supports-and-voices.md) lands, the operation's range is the most any offer allows, and a
  named model that allows fewer refuses with 422 `out_of_limits` before it runs. When RFC 0003 lands, Image defines an
  offer limit `max_layer_count` and a gate key `supports.composite` (boolean, absent `false`, gating an `outputs` that
  contains `composite`). *(2026-10-30: RFC 0003 landed; its A4 makes `supports.composite` absent `true`, the
  current behaviour, as its rule 1 requires.)*
- **A6. `outputs` refusals.** `layers` is required by §3.2, not the schema (no `contains` in the validators' subset):
  without it, 400 `invalid_request`. An `outputs` value the descriptor doesn't list is 422 `unsupported_parameter`,
  like `output` (§1.2), for `matte` as well.
- **A7. Conformance** gains the composite check in IMAGE-014 and the `outputs` refusal in IMAGE-015.
- **A8. Variants.** `decompose` joins `upscale`, `restore` and `matte` in §3's "Variants and versions".

### Open questions, answered

1. **The cap: 32. Keep it.** The vocabulary bounds what a descriptor may offer, not what a model must do, and each
   descriptor narrows it. Ming is measured to 12: its multi-frame denoise grows about 0.7 GB per layer at the 1024
   bucket, and overtakes conditioning at 12 layers in the int4 tier (`MingImageLayerPackage.swift`, AB-R-0341). 32 is
   room for variable-count models such as Qwen-Image-Layered without letting a descriptor promise a stack no client
   panel is built for. Widening a vocabulary range later is compatible, since clients read the descriptor's own range.
   The floor stays 1: a one-layer stack is a degenerate but valid request, and Ming accepts it.
2. **Layer labels: no, not in 0.1.** No model returns one today, and a taxonomy (`text`, `subject`, `background`) fixed
   without a model to produce it would be a guess. The plan already names the layers (A4). Without a plan, a client asks
   `image.describe` of each layer. If a model comes to return labels, a `layer_info` data output beside `layers`, one
   entry per layer, can be added without breaking anyone.
3. **Text layers as text: out of scope.** `decompose` returns pixels, and a text element is a raster layer like any
   other. Editable text is recognition plus a type match: a data output from a different model. It belongs to a future
   operation, which a client would run on the text layer that `decompose` returns. Nothing is reserved for it now.
4. **Composite: keep it, opt-in.** Ming produces it as frame 0 of the same denoise, so it costs nothing to return. It is
   the model's own view of the canvas it decomposed, which lets a client tell a decomposition that drifted from a
   compositing bug of its own. `outputs` defaults to `["layers"]`, so a client that doesn't ask pays nothing, and an
   output nobody asks for is easier to keep than one removed after clients use it.
