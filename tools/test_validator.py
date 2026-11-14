#!/usr/bin/env python3
"""Negative tests: each mutation of a valid example must be rejected, or the schemas are weaker than the spec says.

  tools/test_validator.py
"""
import copy
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import validate as v  # noqa: E402


def check(example, target, mutate, why):
    file_part, _, frag = target.partition("#")
    schema_file = (v.SCHEMAS / file_part).resolve()
    schema = v.pointer(v.load(schema_file), frag) if frag else v.load(schema_file)
    doc = copy.deepcopy(v.load(v.EXAMPLES / example))
    assert not v.validate(doc, schema, schema_file), f"{example} should start valid"
    mutate(doc)
    errs = v.validate(doc, schema, schema_file)
    return (why, bool(errs), errs[:1])


def setp(path, value):
    def f(doc):
        node = doc
        for k in path[:-1]:
            node = node[k]
        node[path[-1]] = value
    return f


def delp(path):
    def f(doc):
        node = doc
        for k in path[:-1]:
            node = node[k]
        del node[path[-1]]
    return f


CASES = [
    ("job-request-speak-stream.json", "profiles/audio/job-request.schema.json", setp(["params", "guidance"], 3),
     "audio request param outside the vocabulary"),
    ("job-request-speak-stream.json", "profiles/audio/job-request.schema.json", delp(["inputs", "text"]), "speak without its text"),
    ("job-request-speak-stream.json", "profiles/audio/job-request.schema.json", setp(["params", "seed"], 4294967296),
     "audio seed above 2^32-1"),
    ("job-request-speak-stream.json", "profiles/audio/job-request.schema.json", setp(["params", "emotion"], {"label": "smug"}),
     "unregistered emotion label"),
    ("job-request-speak-stream.json", "base/job-request.schema.json", setp(["stream", 0, "encoding"], "opus"),
     "unregistered stream encoding"),
    ("job-request-edit-speech.json", "profiles/audio/job-request.schema.json", delp(["params", "edit"]), "edit_speech without an edit"),
    ("job-request-compose.json", "profiles/audio/job-request.schema.json", setp(["params", "anchors", "key"], "E"),
     "anchor key without a mode"),
    ("event-output-chunk.json", "base/event.schema.json", delp(["data", "index"]), "chunk without an index"),
    ("asset.json", "base/asset.schema.json", delp(["expires_at"]), "asset without an expiry"),
    ("operations-audio-speak.json", "base/operations-list.schema.json",
     setp(["operations", 0, "models", 0, "supports", "seed"], "no"), "Base supports key of the wrong type"),
    ("job-request-generate.json", "base/job-request.schema.json", setp(["policy", "license"], "free"), "unknown licence policy"),
    ("job-request-generate.json", "base/job-request.schema.json", setp(["operation"], "Generate"), "operation id not profile.verb"),
    ("job-request-generate.json", "base/job-request.schema.json", setp(["extensions"], {"lora": {}}), "extension without x-vendor. prefix"),
    ("job-request-fill-upload.json", "base/job-request.schema.json",
     setp(["inputs", "image"], {"upload": "upl_a1", "inline": {"media_type": "image/png", "data": "AA=="}}), "two input forms at once"),
    ("job-request-fill-grant.json", "base/job-request.schema.json", setp(["inputs", "image", "grant", "url"], "ftp://x/y"), "grant url not http(s)"),
    ("job-request-fill-grant.json", "base/job-request.schema.json", setp(["inputs", "image", "grant", "sha256"], "abc"), "bad sha256"),
    ("job-holding-generate.json", "base/job.schema.json", setp(["state"], "done"), "unknown state"),
    ("job-holding-generate.json", "base/job.schema.json", delp(["retention"]), "missing retention"),
    ("job-holding-generate.json", "base/job.schema.json", setp(["result", "provenance", "seed"], 2 ** 53), "seed beyond 2^53-1"),
    ("job-holding-generate.json", "base/job.schema.json", setp(["result", "outputs"], []), "holding with no outputs"),
    ("job-holding-generate.json", "base/job.schema.json",
     setp(["plan", "model", "license", "commercial_use"], "yes"), "commercial_use not true/false/unknown"),
    ("event-progress.json", "base/event.schema.json", delp(["data", "stage"]), "progress without stage"),
    ("event-progress.json", "base/event.schema.json", setp(["data", "fraction"], 1.5), "fraction above 1"),
    ("event-ended.json", "base/event.schema.json", delp(["data", "outcome"]), "ended without outcome"),
    ("event-output-ready.json", "base/event.schema.json", setp(["data", "outputs"], []), "output_ready with no outputs"),
    ("pairing-approved.json", "base/pairing.schema.json#/$defs/Approved", setp(["token"], "short"), "token too short"),
    ("engine-info.json", "base/engine-info.schema.json", setp(["auth"], "none"), "unknown auth mode"),
    ("engine-info.json", "base/engine-info.schema.json", setp(["retention", "outputs_ttl_s"], 100000), "outputs TTL above 24 h"),
    ("engine-info.json", "base/engine-info.schema.json", setp(["features"], ["uploads", "teleport"]), "unknown feature"),
    ("operations-image-fill.json", "base/operations-list.schema.json",
     setp(["operations", 0, "params", "properties", "seed", "x-mes-ui", "widget"], "dial"), "unknown UI widget"),
    ("operations-image-fill.json", "base/operations-list.schema.json",
     setp(["operations", 0, "quality_tiers"], []), "no quality tiers"),
    ("error-policy-unmet.json", "base/error.schema.json", setp(["error", "code"], "Policy Unmet"), "error code not snake_case"),
    ("health.json", "base/health.schema.json", setp(["status"], "fine"), "unknown health status"),
    ("model-offer-research.json", "base/descriptor.schema.json#/$defs/ModelOffer", setp(["notes"], ""), "empty model notes"),
    ("model-offer-research.json", "base/descriptor.schema.json#/$defs/ModelOffer", setp(["notes"], "x" * 1001), "model notes over 1000 characters"),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer",
     delp(["adapters", 1, "slots"]), "an ic adapter without slots"),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer",
     setp(["adapters", 0, "kind"], "lora"), "unknown adapter kind"),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer",
     delp(["adapters", 0, "strength", "default"]), "adapter strength without a default"),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer",
     delp(["adapters", 0, "license"]), "adapter without a licence"),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer", setp(["max_adapters"], 0), "max_adapters below 1"),
    ("job-request-edit-adapters.json", "base/job-request.schema.json", setp(["adapters", 0], {"strength": 1}), "adapter request without an id"),
    ("job-request-edit-adapters.json", "base/job-request.schema.json", setp(["adapters"], []), "an empty adapters list"),
    ("job-holding-edit-adapters.json", "base/job.schema.json",
     delp(["result", "provenance", "adapters", 0, "license"]), "provenance adapter without a licence"),
    ("job-holding-edit-adapters.json", "base/job.schema.json",
     delp(["result", "provenance", "adapters", 0, "strength"]), "provenance adapter without its strength"),
    ("job-holding-generate-enhanced.json", "base/job.schema.json",
     delp(["result", "provenance", "helpers", 0, "role"]), "helper without a role"),
    # Video 0.1 and RFC 0005
    ("job-request-video-retake.json", "profiles/video/job-request.schema.json", delp(["params", "end_s"]),
     "a retake without end_s"),
    ("job-request-video-retake.json", "profiles/video/job-request.schema.json", setp(["params", "retake"], "everything"),
     "a retake mode outside the vocabulary"),
    ("job-request-video-generate.json", "profiles/video/job-request.schema.json", setp(["params", "steps"], 8),
     "a model knob (steps) on video.generate"),
    ("job-request-video-generate.json", "profiles/video/job-request.schema.json", setp(["inputs", "audio"], {"upload": "upl_1"}),
     "an input video.generate doesn't define"),
    ("job-request-video-generate.json", "profiles/video/job-request.schema.json", setp(["policy", "accepted"], [""]),
     "an empty licence id in policy.accepted"),
    ("job-holding-video-generate.json", "base/job.schema.json", setp(["result", "outputs", 0, "frames"], 0),
     "a video output with zero frames"),
    ("event-preview-frame.json", "base/event.schema.json", setp(["data", "at_s"], -1), "a preview at a negative time"),
    ("health.json", "base/health.schema.json", setp(["workers"], 3), "a health member that's neither Base's nor x-"),
    ("health.json", "base/health.schema.json", setp(["memory", "idle_unload_s"], -1), "a negative idle_unload_s"),
    ("health.json", "base/health.schema.json", setp(["resident_until", "z-image-turbo"], "soon"), "resident_until not a timestamp"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", setp(["params", "steps"], 12),
     "a model knob (steps) on mesh.generate"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", setp(["params", "texture"], "vertex_colors"),
     "texture_size with vertex_colors"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", setp(["params", "texture_size"], 3000),
     "a texture size that isn't a registered power of two"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", setp(["params", "placement"], "floating"),
     "an unregistered placement"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", delp(["inputs", "image"]), "generate without its image"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", setp(["params", "size_m"], 0), "size_m of 0"),
    ("job-request-mesh-rig.json", "profiles/mesh/job-request.schema.json", setp(["inputs", "image"], {"upload": "upl_1"}),
     "an input mesh.rig doesn't define"),
    ("job-request-mesh-rig.json", "profiles/mesh/job-request.schema.json", setp(["params", "skeleton"], "Mixamo Rig"),
     "a skeleton name that isn't a template id"),
    ("job-request-mesh-rig.json", "profiles/mesh/job-request.schema.json", setp(["params", "max_faces"], 1000),
     "a generate parameter on rig"),
    # RFC 0009: mesh.generate_part
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", delp(["inputs", "body"]), "a part without its body"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "placement"], "grounded"), "placement on a part, which is never placed"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "max_faces"], 5000), "max_faces on a part, which is never decimated"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "background"], "keep"), "background on a part"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "subject_box", "x"], 1.2), "a subject_box starting outside the image"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "subject_box", "width"], 0), "a subject_box with no area"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", delp(["params", "subject_box", "height"]), "a subject_box without its height"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "subject_box"], [0.25, 0.1, 0.75, 0.5]), "a subject_box as corner numbers"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "part"], "Long Hair"), "a part that isn't a tag"),
    ("job-request-mesh-generate-part.json", "profiles/mesh/job-request.schema.json", setp(["params", "physics"], "on"), "physics that isn't a boolean"),
    ("job-request-mesh-generate.json", "profiles/mesh/job-request.schema.json", lambda d: d["params"].update(texture="none"), "texture_size with texture: none"),
    ("operations-mesh.json", "base/operations-list.schema.json",
     setp(["operations", 2, "params", "properties", "subject_box", "x-mes-ui", "widget"], "lasso"), "a widget Base doesn't register"),
    ("job-holding-mesh-generate.json", "base/job.schema.json", delp(["result", "outputs", 0, "bounds"]), "a mesh output without bounds"),
    ("job-holding-mesh-generate.json", "base/job.schema.json", setp(["result", "outputs", 0, "bounds", "max"], [1, 2]),
     "bounds with two coordinates"),
    ("job-holding-mesh-generate.json", "base/job.schema.json", delp(["result", "outputs", 0, "faces"]), "a mesh output without faces"),
    ("job-holding-mesh-generate.json", "base/job.schema.json", setp(["result", "provenance", "model", "license", "attribution"], ""),
     "an empty attribution"),
    ("job-holding-mesh-generate.json", "base/job.schema.json", setp(["result", "outputs", 0, "kind"], "model"), "an unregistered kind"),
    ("operations-video-upscale-interpolate.json", "base/operations-list.schema.json",
     setp(["operations", 0, "models", 0, "license", "user_accept_required"], "yes"), "user_accept_required that isn't a boolean"),
    # RFC 0006 (v0.10.0): separation, and AuK's edits
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", setp(["params", "stems"], ["karaoke"]),
     "an unregistered stem"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", setp(["params", "stems"], []), "an empty stems list"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json",
     setp(["params", "speaker"], {"ordinal": 2, "saying": "hello"}), "a speaker picked two ways"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", setp(["params", "speaker"], {"ordinal": 0}),
     "a speaker ordinal of 0 (the first is 1)"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", setp(["params", "speaker"], {}), "an empty speaker pick"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", setp(["inputs", "source"], {"upload": "upl_1"}),
     "an input audio.separate doesn't define"),
    ("job-request-separate.json", "profiles/audio/job-request.schema.json", delp(["inputs", "audio"]), "separate without its mixture"),
    ("job-request-edit-speech-fit.json", "profiles/audio/job-request.schema.json", setp(["params", "target_duration_s"], 0),
     "an edit fitted to zero seconds"),
    ("job-request-edit-speech-fit.json", "profiles/audio/job-request.schema.json",
     setp(["params", "edit"], {"kind": "add_cue", "cue": "humming"}), "a cue outside the registry (hum is the label)"),
    # RFC 0008 (v0.13.0): a described target, spans, and an offer's watermark
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json", setp(["params", "describe"], "   "),
     "a description of spaces"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json", setp(["params", "describe"], ""),
     "an empty description"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json", delp(["params", "describe"]),
     "spans without a description"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json", setp(["params", "spans"], []),
     "an empty spans list"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json",
     setp(["params", "spans"], [{"start_s": 1, "end_s": 2}]), "a span that doesn't say whether the sound is present"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json",
     setp(["params", "spans"], [{"start_s": -1, "end_s": 2, "present": True}]), "a span that starts before the mixture"),
    ("job-request-separate-described.json", "profiles/audio/job-request.schema.json",
     setp(["params", "spans", 0, "label"], "bark"), "a span with a field the profile doesn't define"),
    ("operations-audio-separate.json", "base/operations-list.schema.json",
     setp(["operations", 0, "models", 3, "supports", "watermark"], "AudioSeal v2"), "a watermark that isn't a lowercase scheme id"),
    ("operations-audio-separate.json", "base/operations-list.schema.json",
     setp(["operations", 0, "models", 3, "supports", "watermark"], True), "a watermark that isn't a string"),
]


def profile_case():
    """A descriptor param outside the vocabulary must fail the profile check."""
    ex = v.EXAMPLES / "operations-image-fill.json"
    original = ex.read_text()
    doc = json.loads(original)
    doc["operations"][0]["params"]["properties"]["guidance"] = {"type": "number"}
    try:
        ex.write_text(json.dumps(doc))
        v._cache.clear()
        errs = v.profile_checks()
    finally:
        ex.write_text(original)
        v._cache.clear()
    return ("model-specific param outside the vocabulary", any("guidance" in e for e in errs), errs[:1])


def example_case(example, mutate, needle, why):
    """A mutated example must fail the profile checks (validate.profile_checks), with an error mentioning `needle`."""
    ex = v.EXAMPLES / example
    original = ex.read_text()
    doc = json.loads(original)
    mutate(doc)
    try:
        ex.write_text(json.dumps(doc))
        v._cache.clear()
        errs = v.profile_checks()
    finally:
        ex.write_text(original)
        v._cache.clear()
    hits = [e for e in errs if needle in e]
    return (why, bool(hits), hits[:1])


def flat(doc):
    doc["result"]["outputs"][0]["bounds"] = {"min": [-0.5, 0, -0.0001], "max": [0.5, 1.8, 0.0001]}


def main():
    results = [check(*c) for c in CASES] + [profile_case()] + [
        example_case("job-holding-mesh-generate.json", flat, "flat_result", "a flat mesh result without flat_result"),
        example_case("job-holding-mesh-generate.json", lambda d: d["result"]["outputs"].pop(1), "preview", "a mesh result without its preview"),
        example_case("job-holding-mesh-generate.json", setp(["result", "effective", "size_m"], 1.0), "size_m", "a mesh whose longest extent isn't size_m"),
        example_case("job-holding-mesh-generate.json", setp(["result", "outputs", 0, "bounds", "min", 1], -0.9), "grounded", "a grounded mesh below y = 0"),
        example_case("job-holding-mesh-rig.json", delp(["result", "outputs", 0, "joints"]), "joints", "a rigged mesh without joints"),
        example_case("job-holding-mesh-generate.json", setp(["result", "outputs", 1, "width"], 256), "preview", "a preview smaller than 512 px"),
        example_case("operations-mesh.json", lambda d: d["operations"][0]["outputs"].pop(1), "preview PNG", "a mesh descriptor without a preview output"),
        example_case("operations-mesh.json", setp(["operations", 0, "models", 0, "supports", "textures"], ["vertex_colors"]), "atlas",
                     "texture_sizes on an offer that makes no atlas"),
        example_case("operations-mesh.json", setp(["operations", 0, "models", 0, "supports", "resolutions"], [512, 2048]), "resolution",
                     "an offer resolution the descriptor doesn't take"),
        example_case("operations-mesh.json", setp(["operations", 1, "models", 0, "supports", "max_influences"], 9), "supports",
                     "max_influences above 8"),
        example_case("operations-mesh.json", setp(["operations", 0, "models", 0, "limits", "max_joints"], 12), "limits",
                     "a rig limit on a generate offer"),
        example_case("job-failed-mesh-flat.json", setp(["error", "code"], "engine_error"), "reason", "degenerate_result on the wrong code"),
        # RFC 0009: mesh.generate_part
        example_case("job-request-mesh-generate-part.json", setp(["params", "subject_box", "width"], 0.9), "right edge",
                     "a subject_box reaching past the image"),
        example_case("job-holding-mesh-generate-part.json", delp(["result", "outputs", 0, "joints"]), "joints", "a part without joints"),
        example_case("job-holding-mesh-generate-part.json", delp(["result", "effective", "physics"]), "physics",
                     "a part result that doesn't report physics"),
        example_case("job-holding-mesh-generate-part.json", setp(["result", "effective", "texture"], "none"), "texture_size",
                     "texture_size on a part made with texture: none"),
        example_case("job-holding-mesh-generate-part.json", setp(["result", "effective", "background"], "keep"), "background",
                     "a part whose background was kept"),
        example_case("operations-mesh.json", lambda d: d["operations"][2]["models"][0]["supports"].pop("parts"), "supports",
                     "a generate_part offer without parts"),
        example_case("operations-mesh.json", setp(["operations", 2, "models", 0, "supports", "subject_box"], True), "supports",
                     "supports.subject_box as a boolean"),
        example_case("operations-mesh.json", setp(["operations", 2, "models", 0, "supports", "parts"], ["hair", "garment"]), "part",
                     "an offer part the descriptor doesn't take"),
        example_case("operations-mesh.json", lambda d: d["operations"][2]["params"]["properties"].pop("subject_box"), "subject_box",
                     "an offer that needs a box on a descriptor without the parameter"),
    ]
    failed = [r for r in results if not r[1]]
    for why, rejected, errs in results:
        print(f"{'ok  ' if rejected else 'MISS'} {why}" + (f"  — {errs[0]}" if errs else ""))
    print(f"{len(results) - len(failed)}/{len(results)} mutations rejected")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
