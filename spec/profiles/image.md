# Media Engine Specification — Image profile

| | |
|---|---|
| **Profile** | `image` |
| **Version** | 0.1 (draft) |
| **Requires** | [Base](../base.md) 0.1 |
| **Schemas** | [`schemas/v0/profiles/image/`](../../schemas/v0/profiles/image/) |

The Image profile defines fourteen operations on still images, the parameter vocabulary they share, and the
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
9. **Prompt enhancement.** Some models work best when a short prompt is rewritten into the detailed caption they were
   trained on, and an engine may do that rewrite before the model runs. An engine that may rewrite an operation's
   `prompt` or `instruction`:
   - MUST declare `prompt_enhance` (§2) on that operation, so a client can always have its text used as typed;
   - MUST warn `prompt_rewritten`, with `param` naming the input, whenever the model received other text;
   - SHOULD report the text the model received as `effective.prompt` or `effective.instruction`. An enhancer built into
     a model may not hand it back;
   - MUST list a separate model that did the rewrite in `provenance.helpers`, with the role `prompt_enhance`
     (Base §10.1);
   - reports the mode that applied as `effective.prompt_enhance`.

   It warns `prompt_enhance_ignored` when it can't honour the requested mode (no enhancer for the model, or one built
   into the model that can't be switched), and `prompt_enhance_failed` when an enhancement it attempted failed and the
   text went as typed. A job with a seed SHOULD reproduce its rewrite.
10. **Adapter slots.** An `ic` adapter's slots (Base §6.3) are filled from `references` for `image.generate` and from
    `images` for `image.edit`, starting with that input's first value. They're filled in the order the request lists
    its adapters, and each adapter's slots in order. A request with fewer values than its adapters' required slots is
    400 `invalid_request`.

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
| `prompt_enhance` | `auto` · `on` · `off` | Whether the engine may rewrite the `prompt` or `instruction` before the model sees it (§1.9). `auto` (default): as the model's makers recommend, typically for short prompts; `on`: whenever the engine has an enhancer for the model; `off`: the model receives the text as typed. |
| `target_operation` | operation id | `enhance_prompt`: the operation the prompt is for. Default `image.generate`. |
| `target_model` | model id | `enhance_prompt`: the model the prompt is for, one of the target operation's offers |

`size` and `aspect` are mutually exclusive: a request with both is 400 `invalid_request`. Model-specific knobs
(guidance, steps, scheduler) are never vocabulary. Engines expose them, if at all, as extensions (Base §6.2).
Adapters, such as LoRA, are chosen with the request's `adapters` (Base §6.3).

## 3. Operations

The required inputs, outputs and parameters of each operation are listed in
[`operations.json`](../../schemas/v0/profiles/image/operations.json), which the conformance suite reads.

| Operation | Inputs | Parameters (vocabulary) | Outputs | Required behaviour |
|---|---|---|---|---|
| `image.generate` | `prompt` (text, required); `references` (image, 0–n) | `negative_prompt`, `size` / `aspect` + `megapixels`, `quality`, `seed`, `count`, `prompt_enhance` | `images` (image, `count`) | One image per count, each with a reported seed |
| `image.edit` | `images` (image, 1–n, the first sets the size); `instruction` (text, required) | `strength`, `quality`, `seed`, `size`, `prompt_enhance` | `image` | Follows the instruction while keeping what it doesn't mention |
| `image.fill` | `image`; `mask`; `prompt` (text, optional) | `negative_prompt`, `strength`, `quality`, `seed`, `prompt_enhance` | `image` | Black-mask pixels unchanged (§1.7); with no prompt, a plausible continuation |
| `image.erase` | `image`; `mask` | `quality` | `image` | Removes what the mask covers; black-mask pixels unchanged |
| `image.extend` | `image`; `prompt` (text, optional) | `canvas`: `{left, top, right, bottom}` in pixels, or `{size, anchor}`; `quality`, `seed`, `prompt_enhance` | `image` (the new canvas) | The original pixels appear unchanged in the extended canvas |
| `image.upscale` | `image` | `scale`, `content`, `quality` | `image` | Output size = input size × `scale`, exactly |
| `image.restore` | `image` | `kind`: `general` · `denoise` · `deblur` · `faces` · `scratches`; `quality` | `image` | Same size |
| `image.relight` | `image`; `prompt` (text, optional) | `preset` (engine-defined enum), `strength`, `quality`, `seed`, `prompt_enhance` | `image` | Same size and composition |
| `image.colorize` | `image` | `quality`, `seed` | `image` | Same size |
| `image.matte` | `image` | `outputs`: any of `mask`, `extract` (default both) | `mask` (mask); `extract` (image, RGBA cut-out) | The mask follows §1.6; `extract` is the input with alpha set from the mask |
| `image.segment` | `image`; `prompt` (text, optional); `points` (data, optional) | `count` (masks to return) | `masks` (mask, 1–n) | At least one of `prompt` or `points`. Points are `[{x, y, label: include\|exclude}]`, normalized 0–1. |
| `image.describe` | `image` | `language` (BCP 47, default `en`) | `description` (data: `{caption, alt_text, tags[]}`) | Tags are lowercase |
| `image.score` | `image` | — | `score` (data: `{score, scale}`) | `score` is normalized 0–1, higher is better; `scale` names the method |
| `image.enhance_prompt` | `prompt` (text, required); `images` (image, 0–n) | `target_operation`, `target_model`, `seed` | `enhanced` (data: `{prompt, applied, size?}`) | Returns the text the target would run, without running it (§3.1) |

### 3.1 Previewing a prompt enhancement

`image.enhance_prompt` lets a client show the rewrite (§1.9), and let its user edit it, before spending a run on it.
- **Target.** `target_operation` and `target_model` say which job the prompt is for. An omitted `target_model` is the
  model the target operation would choose for a request naming none. `effective.target_model` names the model used.
- **Same enhancer.** The engine rewrites as the target would with `prompt_enhance: on`, so the preview is what that
  job would run.
- **Inputs.** `prompt` is the text to rewrite: the target's `prompt`, or its `instruction` for `image.edit`. `images`
  are the images the target job will get, for an enhancer that looks at them. An engine whose enhancer doesn't MAY
  ignore them.
- **Result.** `enhanced.prompt` is the text to send, and `applied` says whether it differs from the input. `size`,
  when present, is a size the enhancer suggests for the target job, since some models choose one from the prompt.
  Clients MAY ignore it.
- **No enhancer.** A target with no enhancer returns the prompt unchanged with `applied: false`, and the warning
  `prompt_enhance_ignored`.
- **Running it.** The client runs the target with the text (edited or not), the same `target_model` named, and
  `prompt_enhance: off`, so the model receives exactly that text.
- **Models.** The operation's model offers are the enhancers (e.g. a small text model), with their licences. A job
  with a seed SHOULD reproduce its rewrite.

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
| `prompt_rewritten` | The model received a rewritten `prompt` or `instruction` (§1.9) |
| `prompt_enhance_ignored` | The requested `prompt_enhance` mode couldn't be honoured, or `enhance_prompt`'s target has no enhancer |
| `prompt_enhance_failed` | A prompt enhancement failed, and the text went as typed |

**Helper roles** (Base §10.1): `prompt_enhance`, a model that rewrote the prompt or instruction.

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
| IMAGE-009 | Each descriptor matches the operations table: its required inputs and its outputs exist with the right kinds, and it requires no parameter outside the operation's vocabulary |
| IMAGE-010 | An output the operation doesn't offer is refused with 422 `unsupported_parameter` |
| IMAGE-011 | `enhance_prompt` returns `enhanced` data with `prompt` and `applied`, for a target model the target operation offers |
| IMAGE-012 | With `prompt_enhance: off` the text goes as typed: no `prompt_rewritten` unless `prompt_enhance_ignored` says why |
| IMAGE-013 | An `ic` adapter's required slots are counted: too few `references` or `images` is 400 |
