# Media Engine Specification — Image profile

| | |
|---|---|
| **Profile** | `image` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1 |
| **Schemas** | [`schemas/v0/profiles/image/`](../../schemas/v0/profiles/image/) |

The Image profile defines thirteen operations on still images, the parameter vocabulary they share, and the
conventions every image engine follows. An engine implementing this profile MAY offer any subset of the
operations. For each operation it offers, it MUST honour that operation's required inputs, outputs and behaviour.

## 1. Conventions

1. **Media types.** Engines MUST accept `image/png` and `image/jpeg` inputs, and SHOULD accept `image/heic`,
   `image/webp` and `image/tiff`. Outputs default to `image/png`.
2. **Output format.** Clients MAY request another format with the `output` parameter:
   `{media_type, bit_depth: 8|16}`. An engine that can't honour it MUST refuse with 422 `unsupported_parameter`.
3. **Colour.** The working space is **sRGB**. Inputs with another embedded profile are converted, with the warning
   `color_converted`, and outputs are tagged sRGB.
4. **Orientation.** EXIF orientation MUST be applied before processing. Outputs are upright and carry no rotation
   flag.
5. **Alpha.** Alpha is **straight** (not premultiplied).
   - Operations that don't change transparency preserve it.
   - When a model can't carry alpha, the engine re-applies the input's alpha channel and warns `alpha_reapplied`.
6. **Masks.** A mask is an 8-bit greyscale PNG the same size as its image.
   - **White (255) means change, black (0) means keep,** and values in between blend.
   - An engine MAY resample a mask of another size, with the warning `mask_resampled`.
   - Masks from `image.matte` and `image.segment` follow the same convention, so they can be fed straight back into
     `fill` or `erase`.
7. **Untouched pixels stay untouched.** For `fill` and `erase`, pixels where the mask is black MUST equal the input
   exactly in the output. Engines composite the model's result over the original.
8. **Size defaults.** Operations that take an image produce their output at the input's size, except where stated
   (`upscale`, `extend`).

## 2. Vocabulary

These names MUST be used in descriptors whenever the operation exposes the concept. They are defined in
[`vocabulary.schema.json`](../../schemas/v0/profiles/image/vocabulary.schema.json).

| Name | Type | Meaning |
|---|---|---|
| `prompt` | string, ≤ 4000 characters | What to make, or what to put in the masked region |
| `negative_prompt` | string | What to avoid. Engines whose models can't use one omit it from the descriptor. |
| `seed` | integer, 0 – 2⁵³−1 | Repeatability. If absent, the engine picks one and reports it in `effective.seed`. |
| `quality` | `draft` · `standard` · `best` | Speed versus fidelity. The engine maps it to models, steps and guidance. Default `standard`. |
| `size` | `{width, height}` in pixels | The output size. The engine may snap to a model's grid, with the warning `size_snapped`. |
| `aspect` | string `W:H`, e.g. `16:9` | Alternative to `size`, combined with `megapixels` |
| `megapixels` | number, 0.25 – 16 | The output area when `aspect` is used. Default 1. |
| `strength` | number, 0 – 1 | How far the result may depart from the input (edit, fill, relight). Default 0.75. |
| `count` | integer, 1 – 8 | How many results. Default 1; each uses `seed + i`. |
| `scale` | `2` or `4` | Enlargement factor |
| `content` | `photo` · `drawn` | What the image is, so engines pick the right model (e.g. anime or illustration upscalers). Default `photo`. |
| `output` | `{media_type, bit_depth}` | Output encoding (§1) |

`size` and `aspect` are mutually exclusive: a request with both is 400 `invalid_request`. Model-specific knobs
(guidance, steps, scheduler, LoRA) are never vocabulary. Engines expose them, if at all, as extensions (Base §6.2).

## 3. Operations

The required inputs, outputs and parameters of each operation are listed in
[`operations.json`](../../schemas/v0/profiles/image/operations.json), which the conformance suite reads.

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `image.generate` | `prompt` (text, required); `references` (image, 0–n) | `negative_prompt`, `size` / `aspect` + `megapixels`, `quality`, `seed`, `count` | `images` (image, `count`) | One image per count, each with a reported seed |
| `image.edit` | `images` (image, 1–n, the first sets the size); `instruction` (text, required) | `strength`, `quality`, `seed`, `size` | `image` | Follows the instruction while keeping what it doesn't mention |
| `image.fill` | `image`; `mask`; `prompt` (text, optional) | `negative_prompt`, `strength`, `quality`, `seed` | `image` | Black-mask pixels unchanged (§1.7); with no prompt, a plausible continuation |
| `image.erase` | `image`; `mask` | `quality` | `image` | Removes what the mask covers; black-mask pixels unchanged |
| `image.extend` | `image`; `prompt` (text, optional) | `canvas`: `{left, top, right, bottom}` in pixels, or `{size, anchor}`; `quality`, `seed` | `image` (the new canvas) | The original pixels appear unchanged in the extended canvas |
| `image.upscale` | `image` | `scale`, `content`, `quality` | `image` | Output size = input size × `scale`, exactly |
| `image.restore` | `image` | `kind`: `general` · `denoise` · `deblur` · `faces` · `scratches`; `quality` | `image` | Same size |
| `image.relight` | `image`; `prompt` (text, optional) | `preset` (engine-defined enum), `strength`, `quality`, `seed` | `image` | Same size and composition |
| `image.colorize` | `image` | `quality`, `seed` | `image` | Same size |
| `image.matte` | `image` | `outputs`: any of `mask`, `extract` (default both) | `mask` (mask); `extract` (image, RGBA cut-out) | The mask follows §1.6; `extract` is the input with alpha set from the mask |
| `image.segment` | `image`; `prompt` (text, optional); `points` (data, optional) | `count` (masks to return) | `masks` (mask, 1–n) | At least one of `prompt` or `points`. Points are `[{x, y, label: include\|exclude}]`, normalized 0–1. |
| `image.describe` | `image` | `language` (BCP 47, default `en`) | `description` (data: `{caption, alt_text, tags[]}`) | Tags are lowercase |
| `image.score` | `image` | — | `score` (data: `{score, scale}`) | `score` is normalized 0–1, higher is better; `scale` names the method |

**Variants and versions.** `upscale`, `restore` and `matte` keep an image's content, so clients such as Pixel Agency
Desktop store their results as variants. `generate`, `edit`, `fill`, `extend` and `relight` change content, so their
results are new images. The profile doesn't impose this distinction; it describes it.

## 4. Warnings

The profile adds these warning codes to Base's:

| Code | When |
|---|---|
| `size_snapped` | Output size adjusted to the model's grid |
| `mask_resampled` | Mask resized to match its image |
| `color_converted` | An input was converted to sRGB |
| `alpha_reapplied` | The model dropped alpha, and the input's alpha was re-applied |
| `negative_prompt_ignored` | Only when the descriptor didn't already say the model can't use one |
| `count_reduced` | Fewer results than `count`, e.g. after a safety filter |

## 5. Conformance (IMAGE-nnn)

An engine conforms to Image 0.1 for the operations it offers when:
- every offered operation's descriptor lists its required inputs and outputs (`operations.json`);
- the parameters it exposes use the vocabulary names;
- these tests pass:

| Test | Checks |
|---|---|
| IMAGE-001 | `fill` and `erase` keep black-mask pixels byte-identical |
| IMAGE-002 | `upscale` returns exactly `input size × scale` |
| IMAGE-003 | Image-input operations keep the input size, except `upscale` and `extend` |
| IMAGE-004 | `matte` masks are 8-bit grey; `extract` carries alpha |
| IMAGE-005 | EXIF orientation is applied |
| IMAGE-006 | A non-sRGB input yields `color_converted` and an sRGB output |
| IMAGE-007 | `seed` is reported, and the same seed reproduces the result where the model is deterministic |
| IMAGE-008 | `size` and `aspect` together → 400 |
