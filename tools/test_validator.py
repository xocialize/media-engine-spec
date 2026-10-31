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


def main():
    results = [check(*c) for c in CASES] + [profile_case()]
    failed = [r for r in results if not r[1]]
    for why, rejected, errs in results:
        print(f"{'ok  ' if rejected else 'MISS'} {why}" + (f"  — {errs[0]}" if errs else ""))
    print(f"{len(results) - len(failed)}/{len(results)} mutations rejected")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
