# RFC 0004: Decomposing an image into layers

| | |
|---|---|
| **Status** | Draft |
| **Affects** | Image 0.1 (§1.5, §2, §3, §4, §5); `schemas/v0/profiles/image/` |
| **Author** | xocialize |
| **Context** | Gaea AB-T-0388 and AB-T-0389; MLXEngine contract 1.48.0 `layerDecompose` (`capability-contract.md`) |

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

A new operation, `image.decompose`, in the Image 0.1 draft.

### §3 Operations

A new row:

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `image.decompose` | `image`; `prompt` (text, optional) | `layer_count`, `outputs`, `quality`, `seed`, `prompt_enhance` | `layers` (image, 1–n); `composite` (image, optional) | §3.2 |

### §3.2 Decomposing an image (new)

`image.decompose` returns an image as a stack of layers that composites back to it.
- **Order.** `layers` is front-most first. The last layer is the background. Compositing the layers back to front,
  last to first, with straight-alpha "over" (§1.5), approximates the input. How closely is the model's quality, not a
  conformance rule.
- **Every layer** is an RGBA image with straight alpha, the same size as the input (§1.5, IMAGE-003). An engine whose
  model works at a smaller size scales the layers back up. Outputs are PNG unless the request's `output` asks for
  another format that carries alpha.
- **Hidden pixels.** A layer holds its whole element, including the parts that layers in front of it cover, as far as
  the model can infer them.
- **Count.** `layer_count` is how many layers to return, excluding `composite`. With it, the engine MUST return exactly
  that many, or refuse the request. Without it, the engine chooses (from the prompt, or a model default) and reports
  the count in `effective.layer_count`. The descriptor's `layer_count` schema states the most layers a model allows
  (§6 rule 4), and a request above that is 422 `out_of_limits`.
- **The prompt** is the layer plan, front-most first: what each layer holds ("Layer 1: the headline 'SALE'. Layer 2:
  the red badge behind it …"). It may be rough. A prompt that states a count contradicting `layer_count` is 400
  `invalid_request`. `prompt_enhance` (§1.9) applies: an enhancer may rewrite a rough plan into a precise one by looking
  at the image, as Ming-Image's reference pipeline does, with the warning `prompt_rewritten`.
- **`composite`** is the model's own reconstruction of the whole canvas, for a model that makes one. It is a check, never
  needed to rebuild the stack. An engine offers it only for a model that produces it, and a client asks for it with
  `outputs: ["layers", "composite"]`. `outputs` defaults to `["layers"]`, and an output the model can't give is 422
  `unsupported_parameter` (IMAGE-010).
- **An input with alpha.** Pixels that are transparent in the input SHOULD be transparent in every layer. An engine
  whose model can't keep them re-applies the input's alpha to each layer and warns `alpha_reapplied` (§1.5).
- **Variants.** The stack keeps the input's content, so a client may store it as a layered version of the image
  rather than as a new one (§3, "Variants and versions").

### §2 Vocabulary

| Name | Type | Meaning |
|---|---|---|
| `layer_count` | integer, 1 – 32 | `decompose`: how many layers to return, excluding `composite`. A model's descriptor narrows the range. |

`outputs` gains `decompose`'s values, as it has `matte`'s: any of `layers` and `composite`, with `layers` required.

### §1.5 Alpha

One sentence added: "`image.decompose` returns every layer with straight alpha (§3.2)."

### §4 Warnings

No new codes. `prompt_rewritten`, `prompt_enhance_ignored` and `alpha_reapplied` apply as they do elsewhere.

### Schemas

- `operations.json`: an `image.decompose` entry with:
  - inputs: `image` (image, required) and `prompt` (text);
  - outputs: `layers` (image, multiple) and `composite` (image);
  - vocabulary: `layer_count`, `outputs` (`decompose_outputs`), `quality`, `seed` and `prompt_enhance`;
  - `keeps_input_size: true`.
- `vocabulary.schema.json`: `layer_count` (integer, 1–32), and `decompose_outputs` (array of `layers` and `composite`,
  at least one item, containing `layers`).

### How an engine would carry it (illustrative, not part of this RFC)

- **Over MLXEngine** it maps one to one onto `layerDecompose`:
  - the input and prompt become `image` and `spec`;
  - `layer_count` becomes `layerCount`;
  - `quality` picks the working bucket: `draft` is 512 and `standard` or `best` is 1024;
  - `layers[0]` stays front-most, and `composite` is passed through.
- **In Gaea**, the Ming-Image plugin would add a `ming-image-layer` model on `image.decompose`, with int8, bf16 and
  int4 lanes and a `layer_count` maximum of 12. The normalizer would need a decompose route that scales the layers to
  the input size and re-applies alpha.
- **The planner** is a prompt-enhance profile: a vision-language model reads the image and the rough plan, and writes
  the per-layer plan the model expects.

## Compatibility

- **Additive.** Image 0.1 is still a draft, so this joins it without a version bump. Engines that don't offer
  `image.decompose` are unaffected.
- **Older clients** don't list the operation. A client built on `operations.json` gains it when it updates the schema.
- **`outputs`** keeps its meaning for `matte`. Its allowed values are per operation, as now.

## Conformance

| Test | Checks | Spec |
|---|---|---|
| IMAGE-014 | `decompose` with `layer_count` n returns exactly n `layers`, each an RGBA PNG the size of the input; without it, `effective.layer_count` equals the number returned | §3.2 |
| IMAGE-015 | `layer_count` above the descriptor's maximum is 422 `out_of_limits`; `composite` from a model that doesn't offer it is 422 `unsupported_parameter` | §3.2, §6 rule 4 |
| IMAGE-016 | The layers composited back to front, straight-alpha "over", are close to the input: the mean absolute error is reported, never failed | §3.2 |

IMAGE-003 (same size) and IMAGE-009 (the operations table) cover the rest. The mock engine can carry IMAGE-014 and
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

## Open questions

1. **The cap.** 32 for the vocabulary, with models narrowing it (Ming: 12, its measured memory envelope). Is 32 right?
2. **Element kinds.** Should a layer carry a label (`text`, `subject`, `background`), as data beside the PNG? Ming
   doesn't return one. A client can ask `image.describe` per layer.
3. **Text layers as text.** A designer would want the headline as editable text, not pixels. That's OCR and a type
   match, and it belongs to another operation.
4. **Composite.** Should `composite` be dropped entirely? It is only a check, and a client can composite the layers
   itself.
