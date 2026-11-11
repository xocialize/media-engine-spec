#!/usr/bin/env python3
"""Validates the MES schemas and examples, with no third-party dependencies.

  tools/validate.py          check every schema resolves, every example validates, and the profile rules hold

It implements the subset of JSON Schema draft 2020-12 these schemas use. Keywords outside that subset are an error,
so a typo in a schema can't silently weaken it:
  type enum const properties required additionalProperties propertyNames minProperties items minItems maxItems
  minimum maximum exclusiveMinimum minLength maxLength pattern oneOf anyOf allOf if then $ref
Annotations ($schema title description default $defs x-*) are ignored. The Swift conformance suite (R0d) replaces
this for runtime checks; this keeps the documents honest meanwhile.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMAS = ROOT / "schemas" / "v0"
EXAMPLES = ROOT / "examples" / "v0"

ASSERTIONS = {"type", "enum", "const", "properties", "required", "additionalProperties", "propertyNames",
              "minProperties", "items", "minItems", "maxItems", "minimum", "maximum", "exclusiveMinimum",
              "minLength", "maxLength", "pattern", "oneOf", "anyOf", "allOf", "if", "then", "$ref"}
ANNOTATIONS = {"$schema", "title", "description", "default", "$defs", "$comment"}

# example file -> schema (file, optional JSON pointer)
MANIFEST = {
    "engine-info.json": "base/engine-info.schema.json",
    "pairing-request.json": "base/pairing.schema.json#/$defs/Request",
    "pairing-created.json": "base/pairing.schema.json#/$defs/Created",
    "pairing-approved.json": "base/pairing.schema.json#/$defs/Approved",
    "operations-image-fill.json": "base/operations-list.schema.json",
    "job-request-generate.json": "base/job-request.schema.json",
    "job-request-fill-upload.json": "base/job-request.schema.json",
    "job-request-fill-grant.json": "base/job-request.schema.json",
    "job-request-segment-points.json": "base/job-request.schema.json",
    "upload.json": "base/upload.schema.json",
    "job-holding-generate.json": "base/job.schema.json",
    "job-holding-describe.json": "base/job.schema.json",
    "job-failed.json": "base/job.schema.json",
    "event-progress.json": "base/event.schema.json",
    "event-output-ready.json": "base/event.schema.json",
    "event-ended.json": "base/event.schema.json",
    "error-policy-unmet.json": "base/error.schema.json",
    "health.json": "base/health.schema.json",
    "model-offer-research.json": "base/descriptor.schema.json#/$defs/ModelOffer",
    "model-offer-adapters.json": "base/descriptor.schema.json#/$defs/ModelOffer",
    "job-request-edit-adapters.json": "base/job-request.schema.json",
    "job-holding-generate-enhanced.json": "base/job.schema.json",
    "job-holding-enhance-prompt.json": "base/job.schema.json",
    "job-holding-edit-adapters.json": "base/job.schema.json",
    "operations-image-decompose.json": "base/operations-list.schema.json",
    "job-holding-decompose.json": "base/job.schema.json",
    "operations-audio-speak.json": "base/operations-list.schema.json",
    "operations-audio-edit-generate.json": "base/operations-list.schema.json",
    "operations-audio-compose.json": "base/operations-list.schema.json",
    "voices-kokoro.json": "base/voices.schema.json",
    "asset.json": "base/asset.schema.json",
    "job-request-speak-stream.json": "profiles/audio/job-request.schema.json",
    "job-request-edit-speech.json": "profiles/audio/job-request.schema.json",
    "job-request-compose.json": "profiles/audio/job-request.schema.json",
    "event-output-chunk.json": "base/event.schema.json",
    "job-holding-speak.json": "base/job.schema.json",
    "job-holding-compose.json": "base/job.schema.json",
    "operations-video-generate.json": "base/operations-list.schema.json",
    "operations-video-upscale-interpolate.json": "base/operations-list.schema.json",
    "job-request-video-generate.json": "profiles/video/job-request.schema.json",
    "job-request-video-retake.json": "profiles/video/job-request.schema.json",
    "job-holding-video-generate.json": "base/job.schema.json",
    "event-preview-frame.json": "base/event.schema.json",
    "error-terms-not-accepted.json": "base/error.schema.json",
    "job-request-edit-speech-fit.json": "profiles/audio/job-request.schema.json",
    "operations-audio-separate.json": "base/operations-list.schema.json",
    "job-request-separate.json": "profiles/audio/job-request.schema.json",
    "job-holding-separate.json": "base/job.schema.json",
    "job-request-separate-described.json": "profiles/audio/job-request.schema.json",
    "job-holding-separate-described.json": "base/job.schema.json",
    "operations-mesh.json": "base/operations-list.schema.json",
    "job-request-mesh-generate.json": "profiles/mesh/job-request.schema.json",
    "job-request-mesh-rig.json": "profiles/mesh/job-request.schema.json",
    "job-holding-mesh-generate.json": "base/job.schema.json",
    "job-holding-mesh-rig.json": "base/job.schema.json",
    "job-failed-mesh-flat.json": "base/job.schema.json",
}

_cache = {}


def load(path):
    path = path.resolve()
    if path not in _cache:
        _cache[path] = json.loads(path.read_text())
    return _cache[path]


def pointer(doc, ptr):
    node = doc
    for part in [p for p in ptr.lstrip("/").split("/") if p]:
        part = part.replace("~1", "/").replace("~0", "~")
        node = node[part]
    return node


def resolve(ref, base_file):
    file_part, _, frag = ref.partition("#")
    target = (base_file.parent / file_part) if file_part else base_file
    return pointer(load(target), frag), target.resolve()


def type_ok(value, t):
    if isinstance(t, list):
        return any(type_ok(value, x) for x in t)
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[t]


def same(a, b):
    return type(a) is type(b) and a == b


def validate(value, schema, file, path="$"):
    """Returns a list of error strings."""
    if schema is True or schema == {}:
        return []
    if schema is False:
        return [f"{path}: not allowed"]
    unknown = {k for k in schema if k not in ASSERTIONS | ANNOTATIONS and not k.startswith("x-")}
    if unknown:
        return [f"{path}: schema uses unsupported keywords {sorted(unknown)} ({file.name})"]
    errs = []
    if "$ref" in schema:
        target, tfile = resolve(schema["$ref"], file)
        errs += validate(value, target, tfile, path)
    if "type" in schema and not type_ok(value, schema["type"]):
        return errs + [f"{path}: expected {schema['type']}, got {type(value).__name__}"]
    if "enum" in schema and not any(same(value, e) for e in schema["enum"]):
        errs.append(f"{path}: {value!r} not in {schema['enum']}")
    if "const" in schema and not same(value, schema["const"]):
        errs.append(f"{path}: expected {schema['const']!r}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errs.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errs.append(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errs.append(f"{path}: {value!r} doesn't match {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errs.append(f"{path}: above {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errs.append(f"{path}: not above {schema['exclusiveMinimum']}")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errs.append(f"{path}: missing required '{key}'")
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            errs.append(f"{path}: fewer than {schema['minProperties']} properties")
        for key, sub in value.items():
            if "propertyNames" in schema:
                errs += validate(key, schema["propertyNames"], file, f"{path}.<name {key}>")
            if key in props:
                errs += validate(sub, props[key], file, f"{path}.{key}")
            elif "additionalProperties" in schema:
                ap = schema["additionalProperties"]
                if ap is False:
                    errs.append(f"{path}: unexpected property '{key}'")
                elif isinstance(ap, dict):
                    errs += validate(sub, ap, file, f"{path}.{key}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errs.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errs.append(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for i, item in enumerate(value):
                errs += validate(item, schema["items"], file, f"{path}[{i}]")
    for sub in schema.get("allOf", []):
        errs += validate(value, sub, file, path)
    if "anyOf" in schema and not any(not validate(value, s, file, path) for s in schema["anyOf"]):
        errs.append(f"{path}: matches none of anyOf")
    if "oneOf" in schema:
        matches = [s for s in schema["oneOf"] if not validate(value, s, file, path)]
        if len(matches) != 1:
            errs.append(f"{path}: matches {len(matches)} of oneOf (needs exactly 1)")
    if "if" in schema and not validate(value, schema["if"], file, path) and "then" in schema:
        errs += validate(value, schema["then"], file, path)
    return errs


def walk_refs(node, file, seen):
    """Every $ref in every schema must resolve."""
    errs = []
    if isinstance(node, dict):
        if "$ref" in node:
            try:
                target, tfile = resolve(node["$ref"], file)
                key = (str(tfile), node["$ref"].partition("#")[2])
                if key not in seen:
                    seen.add(key)
            except (KeyError, FileNotFoundError) as e:
                errs.append(f"{file.name}: unresolved $ref {node['$ref']} ({e})")
        for v in node.values():
            errs += walk_refs(v, file, seen)
    elif isinstance(node, list):
        for v in node:
            errs += walk_refs(v, file, seen)
    return errs


def profile_checks():
    """Descriptors in examples must honour their profile's operations.json: required inputs, outputs, vocabulary
    shapes; Audio and Video offers' supports and limits must have the profile's types (supports.schema.json)."""
    errs = []
    tables = {}
    for profile in ("image", "audio", "video", "mesh"):
        ops_file = SCHEMAS / "profiles" / profile / "operations.json"
        ops = load(ops_file)
        errs += validate(ops, load(SCHEMAS / "profiles" / profile / "operations.schema.json"),
                         SCHEMAS / "profiles" / profile / "operations.schema.json", f"{profile}/operations.json")
        vocab = load(SCHEMAS / "profiles" / profile / "vocabulary.schema.json")["$defs"]
        for op, spec in ops["operations"].items():
            for name in spec["vocabulary"]:
                def_name = spec.get("vocabulary_defs", {}).get(name, name)
                if def_name not in vocab:
                    errs.append(f"{profile}/operations.json {op}: vocabulary '{name}' has no definition '{def_name}'")
        tables[profile] = (ops_file, ops, vocab)
    supports_files = {pr: SCHEMAS / "profiles" / pr / "supports.schema.json" for pr in ("audio", "video", "mesh")}
    full_limits = ("video", "mesh")  # profiles whose limits schemas list Base's fields too
    for ex in sorted(EXAMPLES.glob("operations-*.json")):
        for d in load(ex)["operations"]:
            if d["profile"] not in tables:
                continue
            ops_file, ops, vocab = tables[d["profile"]]
            spec = ops["operations"].get(d["operation"])
            if spec is None:
                errs.append(f"{ex.name}: {d['operation']} isn't a {d['profile']} operation")
                continue
            names = {i["name"]: i for i in d["inputs"]}
            for name, req in spec["inputs"].items():
                if req["required"] and name not in names:
                    errs.append(f"{ex.name} {d['operation']}: required input '{name}' missing")
                if name in names and names[name]["kind"] != req["kind"]:
                    errs.append(f"{ex.name} {d['operation']}: input '{name}' kind {names[name]['kind']} != {req['kind']}")
            outs = {o["name"]: o for o in d["outputs"]}
            stems = {name for name, out in spec["outputs"].items() if out.get("stem")}
            if stems:
                # Audio §3.6: outputs named by stem, the ones the offers produce, at least one; nothing else
                if not stems & set(outs):
                    errs.append(f"{ex.name} {d['operation']}: lists no stem output")
                errs += [f"{ex.name} {d['operation']}: output '{n}' isn't a registered stem" for n in outs if n not in spec["outputs"]]
            for name, out in spec["outputs"].items():
                if name not in outs:
                    if not out.get("stem"):
                        errs.append(f"{ex.name} {d['operation']}: output '{name}' missing")
                elif "stream" in outs[name] and not out.get("streamable"):
                    errs.append(f"{ex.name} {d['operation']}: output '{name}' declares stream; the profile doesn't let it")
            for pname, pschema in d["params"]["properties"].items():
                if pname in spec["vocabulary"]:
                    def_name = spec.get("vocabulary_defs", {}).get(pname, pname)
                    # the descriptor's shape must accept the vocabulary's default and be no wider in enums
                    vdef = vocab[def_name]
                    if "enum" in vdef and "enum" in pschema and not set(map(str, pschema["enum"])) <= set(map(str, vdef["enum"])):
                        errs.append(f"{ex.name} {d['operation']}: '{pname}' widens the vocabulary enum")
                elif not pname.startswith("x-"):
                    errs.append(f"{ex.name} {d['operation']}: param '{pname}' is not in the profile vocabulary "
                                f"(model-specific knobs go in extensions)")
            if d["profile"] in supports_files:
                supports_file = supports_files[d["profile"]]
                supports = load(supports_file)
                short = d["operation"].split(".")[1]
                if d["profile"] in full_limits:
                    errs += [f"{ex.name} {d['operation']} limits: {e}" for e in
                             validate(d.get("limits", {}), supports["$defs"][f"{short}_limits"], supports_file)]
                for m in d["models"]:
                    errs += [f"{ex.name} {m['id']} supports: {e}" for e in
                             validate(m.get("supports", {}), supports["$defs"][f"{short}_supports"], supports_file)]
                    if d["operation"] == "audio.separate":
                        errs += [f"{ex.name} {m['id']}: {e}" for e in described_target_checks(m.get("supports", {}))]
                    lim = m.get("limits", {}) if d["profile"] in full_limits else {
                        k: v for k, v in m.get("limits", {}).items()
                        if k not in ("max_width", "max_height", "max_megapixels", "max_duration_s", "max_inputs")}
                    errs += [f"{ex.name} {m['id']} limits: {e}" for e in
                             validate(lim, supports["$defs"][f"{short}_limits"], supports_file)]
                    for k, v in m.get("limits", {}).items():
                        bound = d.get("limits", {}).get(k)
                        if bound is not None and (v < bound if k.startswith("min_") else v > bound):
                            errs.append(f"{ex.name} {m['id']}: limits.{k} {v} is outside the operation's {bound}")
            if d["profile"] == "mesh":
                errs += [f"{ex.name} {e}" for e in mesh_descriptor_checks(d)]
    for ex in sorted(EXAMPLES.glob("job-*.json")):
        doc = load(ex)
        if doc.get("operation", "").startswith("mesh.") and "state" in doc:
            errs += [f"{ex.name}: {e}" for e in mesh_job_checks(doc)]
    for ex in sorted(EXAMPLES.glob("*.json")):
        doc = load(ex)
        err = doc.get("error") if isinstance(doc, dict) else None
        if isinstance(err, dict) and err.get("reason") in REASONS and REASONS[err["reason"]] != err.get("code"):
            errs.append(f"{ex.name}: reason '{err['reason']}' isn't registered for code '{err.get('code')}' (Base §12, §18; Mesh §5)")
    for ex in sorted(EXAMPLES.glob("job-holding-*.json")):
        job = load(ex)
        profile = job["operation"].split(".")[0]
        if profile not in tables:
            continue
        ops_file, ops, _ = tables[profile]
        spec = ops["operations"].get(job["operation"])
        for out in job.get("result", {}).get("outputs", []):
            vs = spec and spec["outputs"].get(out["name"], {}).get("value_schema")
            if vs and "value" in out:
                target, tfile = resolve(vs, ops_file)
                errs += [f"{ex.name}: {e}" for e in validate(out["value"], target, tfile, "$.value")]
    return errs


# Error reasons and the codes they refine (Base §10.3, §18; Mesh §5).
REASONS = {"terms_not_accepted": "policy_unmet", "degenerate_result": "input_invalid"}
FLAT_RATIO = 0.08  # Mesh §1.8


def mesh_descriptor_checks(d):
    """Mesh §1.7: every operation that outputs a mesh outputs a preview PNG. §2: texture_size goes with an atlas, so an
    offer listing texture_sizes must be able to make one. §4.1: offers' gate lists stay within the descriptor's params."""
    errs = []
    outs = {o["name"]: o for o in d["outputs"]}
    if "mesh" in outs:
        prev = outs.get("preview")
        if not prev or prev["kind"] != "image" or prev.get("min", 0) < 1 or "image/png" not in prev.get("media_types", ["image/png"]):
            errs.append(f"{d['operation']}: a mesh output needs a preview PNG output, min 1 (Mesh §1.7)")
        if outs["mesh"].get("media_types") and "model/gltf-binary" not in outs["mesh"]["media_types"]:
            errs.append(f"{d['operation']}: the mesh output must offer model/gltf-binary (Mesh §1.1)")
    props = d["params"]["properties"]
    for m in d["models"]:
        sup = m.get("supports", {})
        if sup.get("texture_sizes") and "atlas" not in sup.get("textures", ["atlas"]):
            errs.append(f"{m['id']}: texture_sizes without an atlas texture (Mesh §2)")
        for key, param in (("resolutions", "resolution"), ("texture_sizes", "texture_size"), ("textures", "texture"),
                           ("skeletons", "skeleton")):
            enum = props.get(param, {}).get("enum")
            if key in sup and enum is not None and not set(sup[key]) <= set(enum):
                errs.append(f"{m['id']}: supports.{key} lists values the descriptor's '{param}' doesn't take")
    return errs


def described_target_checks(sup):
    """Audio §4.1 (RFC 0008): described_target goes with the target stem, residual with target, spans with described_target."""
    errs, stems = [], sup.get("stems", [])
    if ("target" in stems) != (sup.get("described_target") is True):
        errs.append("supports.described_target must be true exactly when stems lists target")
    if "residual" in stems and "target" not in stems:
        errs.append("supports.stems lists residual without target")
    if sup.get("spans") is True and sup.get("described_target") is not True:
        errs.append("supports.spans needs described_target")
    return errs


def mesh_job_checks(job):
    """Mesh results: a preview per mesh (§1.7), bounds ordered, joints exactly on rig outputs (§3.2), a flat result warned
    (§1.8) and the placement honoured (§1.4)."""
    errs = []
    result = job.get("result")
    if not result:
        return errs
    outs = result["outputs"]
    meshes = [o for o in outs if o["kind"] == "mesh"]
    if meshes and not any(o["name"] == "preview" and o["media_type"] == "image/png" for o in outs):
        errs.append("a mesh result without its preview PNG (Mesh §1.7)")
    for o in outs:
        if o["name"] == "preview" and o["kind"] == "image" and (o.get("width") != o.get("height") or (o.get("width") or 0) < 512):
            errs.append("the preview isn't square and at least 512 px (Mesh §1.7)")
    eff = result.get("effective", {})
    for o in meshes:
        lo, hi = o["bounds"]["min"], o["bounds"]["max"]
        if any(a > b for a, b in zip(lo, hi)):
            errs.append(f"output {o['index']}: bounds min above max")
            continue
        ext = [b - a for a, b in zip(lo, hi)]
        if job["operation"] == "mesh.rig" and "joints" not in o:
            errs.append(f"output {o['index']}: a rigged mesh without joints (Mesh §3.2)")
        if job["operation"] == "mesh.generate":
            if "joints" in o:
                errs.append(f"output {o['index']}: joints on an unskinned generate result")
            if max(ext) > 0 and min(ext) / max(ext) < FLAT_RATIO and not any(w["code"] == "flat_result" for w in job.get("warnings", [])):
                errs.append(f"output {o['index']}: thinnest/longest {min(ext) / max(ext):.3f} < {FLAT_RATIO} without flat_result (Mesh §1.8)")
            size = eff.get("size_m", 1)
            if abs(max(ext) - size) > 0.01 * size:
                errs.append(f"output {o['index']}: longest extent {max(ext)} isn't size_m {size} (Mesh §1.4)")
            if eff.get("placement", "centered") == "grounded":
                if abs(lo[1]) > 0.01 * size:
                    errs.append(f"output {o['index']}: grounded, but the lowest point is at y={lo[1]} (Mesh §1.4)")
            else:
                if any(abs((a + b) / 2) > 0.01 * size for a, b in zip(lo, hi)):
                    errs.append(f"output {o['index']}: centered, but the box's centre isn't the origin (Mesh §1.4)")
        if "texture_size" in o and eff.get("texture") == "vertex_colors":
            errs.append(f"output {o['index']}: texture_size on a vertex-coloured result")
    return errs


def main():
    errs = []
    schema_files = sorted(SCHEMAS.rglob("*.schema.json"))
    seen = set()
    for f in schema_files:
        try:
            errs += walk_refs(load(f), f.resolve(), seen)
        except json.JSONDecodeError as e:
            errs.append(f"{f.name}: invalid JSON ({e})")
    examples = sorted(EXAMPLES.glob("*.json"))
    unmapped = [e.name for e in examples if e.name not in MANIFEST]
    errs += [f"{n}: no schema mapped in MANIFEST" for n in unmapped]
    for name, target in MANIFEST.items():
        file_part, _, frag = target.partition("#")
        schema_file = (SCHEMAS / file_part).resolve()
        schema = pointer(load(schema_file), frag) if frag else load(schema_file)
        ex_file = EXAMPLES / name
        if not ex_file.exists():
            errs.append(f"{name}: example missing")
            continue
        errs += [f"{name}: {e}" for e in validate(load(ex_file), schema, schema_file)]
    errs += profile_checks()
    print(f"schemas: {len(schema_files)} · examples: {len(examples)} · refs resolved: {len(seen)}")
    if errs:
        print("\n".join("FAIL " + e for e in errs))
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
