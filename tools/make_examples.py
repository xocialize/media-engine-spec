#!/usr/bin/env python3
"""Writes examples/v0/*.json: realistic MES messages that tools/validate.py checks against the schemas.

The values are illustrative. Model defaults (Z-Image Turbo: 8 steps, guidance 0; Klein 4B: 4 steps, guidance 1.0)
come from the ML[X] Image Server catalog; hashes and ids are made up but well-formed.
"""
import hashlib
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "examples" / "v0"
H = lambda s: hashlib.sha256(s.encode()).hexdigest()  # noqa: E731

APACHE = {"spdx": "Apache-2.0", "commercial_use": True, "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"}
QWEN_RESEARCH = {"spdx": "LicenseRef-Qwen-Research", "commercial_use": False,
                 "terms_url": "https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE",
                 "notice": "Research or evaluation use only.", "accepted_required": True}
ENGINE = {"id": "eng_6f1c2a", "name": "Studio Image Engine", "implementation": "pixel-agency-image-engine", "version": "0.1.0"}

examples = {
    "engine-info.json": {
        "id": "eng_6f1c2a",
        "name": "Studio Image Engine",
        "implementation": {"name": "pixel-agency-image-engine", "version": "0.1.0",
                           "url": "https://github.com/xocialize/pixel-agency-image-engine"},
        "base_versions": ["0.1"],
        "profiles": [{"id": "image", "versions": ["0.1"]}],
        "auth": "paired",
        "tls": {"fingerprint_sha256": H("engine-cert")},
        "features": ["uploads", "grants", "sse", "websocket", "mcp", "previews", "pairing"],
        "limits": {"max_upload_bytes": 268435456, "max_inline_bytes": 8388608, "max_queued_jobs_per_client": 32},
        "retention": {"outputs_ttl_s": 3600, "job_record_ttl_s": 86400},
    },
    "pairing-request.json": {"client_id": "cli_9a7b", "client_name": "Sam's Desktop",
                             "client_key": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4x7", "client_nonce": "q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6"},
    "pairing-created.json": {"pairing_id": "pair_31f0", "engine_nonce": "z9x8c7v6b5n4m3l2k1j0h9g8f7d6s5a4",
                             "expires_at": "2026-10-09T18:05:00Z"},
    "pairing-approved.json": {"token": "mes_tok_" + H("token")[:40], "client_id": "cli_9a7b"},
    "operations-image-fill.json": {
        "etag": "\"ops-" + H("ops")[:12] + "\"",
        "operations": [{
            "operation": "image.fill",
            "profile": "image",
            "profile_version": "0.1",
            "title": "Generative fill",
            "summary": "Fill the white part of the mask; everything else stays exactly as it was.",
            "inputs": [
                {"name": "image", "kind": "image", "required": True, "max": 1,
                 "media_types": ["image/png", "image/jpeg", "image/heic"]},
                {"name": "mask", "kind": "mask", "required": True, "max": 1, "media_types": ["image/png"]},
                {"name": "prompt", "kind": "text", "required": False},
            ],
            "params": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "quality": {"enum": ["draft", "standard", "best"], "default": "standard",
                                "x-mes-ui": {"label": "Quality", "widget": "picker", "order": 1}},
                    "strength": {"type": "number", "minimum": 0, "maximum": 1, "default": 0.75,
                                 "x-mes-ui": {"label": "Strength", "widget": "slider", "order": 2}},
                    "seed": {"type": "integer", "minimum": 0, "maximum": 9007199254740991,
                             "x-mes-ui": {"label": "Seed", "widget": "seed", "advanced": True}},
                },
            },
            "outputs": [{"name": "image", "kind": "image", "media_types": ["image/png"], "min": 1, "max": 1}],
            "limits": {"max_width": 4096, "max_height": 4096, "max_megapixels": 16},
            "quality_tiers": ["draft", "standard", "best"],
            "models": [
                {"id": "lama", "title": "LaMa", "license": APACHE, "memory_class": "small", "speed_class": "fast",
                 "quality_tiers": ["draft"]},
                {"id": "klein-4b", "title": "FLUX.2 Klein 4B", "license": APACHE, "memory_class": "medium",
                 "speed_class": "fast", "quality_tiers": ["standard"], "default": True},
                {"id": "qwen-image-edit", "title": "Qwen-Image-Edit", "license": APACHE, "memory_class": "xlarge",
                 "speed_class": "slow", "quality_tiers": ["best"]},
            ],
            "remote": {"possible": False},
        }],
    },
    "job-request-generate.json": {
        "operation": "image.generate",
        "inputs": {"prompt": "a lighthouse on a cliff at dusk, oil painting"},
        "params": {"size": {"width": 1000, "height": 750}, "quality": "standard", "seed": 42},
        "policy": {"license": "commercial-use", "remote": "forbid"},
        "client_ref": "ticket_8812",
    },
    "job-request-fill-upload.json": {
        "operation": "image.fill",
        "inputs": {"image": {"upload": "upl_a1"}, "mask": {"upload": "upl_a2"}, "prompt": "a red umbrella"},
        "params": {"quality": "standard"},
        "policy": {"license": "commercial-use"},
    },
    "job-request-fill-grant.json": {
        "operation": "image.fill",
        "inputs": {
            "image": {"grant": {"url": "https://sams-mac.local:51234/grants/g_77/0", "token": "gr_" + H("g0")[:32],
                                "media_type": "image/png", "bytes": 2483021, "sha256": H("photo")}},
            "mask": {"grant": {"url": "https://sams-mac.local:51234/grants/g_77/1", "token": "gr_" + H("g1")[:32],
                               "media_type": "image/png", "bytes": 40211, "sha256": H("mask")}},
            "prompt": "a red umbrella",
        },
        "params": {"quality": "best", "seed": 7},
        "client_ref": "ticket_8813",
    },
    "job-request-segment-points.json": {
        "operation": "image.segment",
        "inputs": {"image": {"upload": "upl_b1"},
                   "points": {"data": [{"x": 0.42, "y": 0.55, "label": "include"},
                                       {"x": 0.9, "y": 0.1, "label": "exclude"}]}},
        "params": {"count": 1},
    },
    "upload.json": {"upload_id": "upl_a1", "media_type": "image/png", "bytes": 2483021, "sha256": H("photo"),
                    "expires_at": "2026-10-09T18:00:00Z"},
    "job-holding-generate.json": {
        "id": "job_01J9ZK",
        "operation": "image.generate",
        "client_ref": "ticket_8812",
        "state": "holding",
        "outcome": "succeeded",
        "plan": {"model": {"id": "z-image-turbo", "title": "Z-Image Turbo", "license": APACHE},
                 "effective": {"quality": "standard", "size": {"width": 1008, "height": 752}, "seed": 42,
                               "model_params": {"steps": 8, "guidance": 0.0}}},
        "progress": {"stage": "finishing", "fraction": 1.0},
        "warnings": [{"code": "size_snapped", "message": "1000×750 → 1008×752 (model grid)", "param": "size"}],
        "result": {
            "outputs": [{"index": 0, "name": "images", "kind": "image", "media_type": "image/png", "bytes": 1893340,
                         "sha256": H("out0"), "href": "/mes/v0/jobs/job_01J9ZK/outputs/0", "width": 1008, "height": 752}],
            "effective": {"quality": "standard", "size": {"width": 1008, "height": 752}, "seed": 42,
                          "model_params": {"steps": 8, "guidance": 0.0}},
            "provenance": {"engine": ENGINE, "operation": "image.generate", "profile_version": "0.1",
                           "model": {"id": "z-image-turbo", "title": "Z-Image Turbo", "license": APACHE},
                           "seed": 42,
                           "timings": {"received_at": "2026-10-09T17:00:00Z", "started_at": "2026-10-09T17:00:01Z",
                                       "finished_at": "2026-10-09T17:00:13Z", "queue_ms": 900, "prepare_ms": 0,
                                       "run_ms": 12100}},
        },
        "retention": {"outputs_expire_at": "2026-10-09T18:00:13Z", "record_expires_at": "2026-10-10T17:00:13Z"},
        "created_at": "2026-10-09T17:00:00Z",
        "updated_at": "2026-10-09T17:00:13Z",
    },
    "job-holding-describe.json": {
        "id": "job_01J9ZM",
        "operation": "image.describe",
        "state": "holding",
        "outcome": "succeeded",
        "plan": {"model": {"id": "mage-vl", "title": "Mage-VL", "license": APACHE}, "effective": {"language": "en"}},
        "warnings": [],
        "result": {
            "outputs": [{"index": 0, "name": "description", "kind": "data", "media_type": "application/json",
                         "bytes": 182, "sha256": H("desc"), "href": "/mes/v0/jobs/job_01J9ZM/outputs/0",
                         "value": {"caption": "A white lighthouse on a rocky cliff at sunset.",
                                   "alt_text": "Lighthouse on a cliff under an orange sky",
                                   "tags": ["lighthouse", "cliff", "sunset", "coast"], "language": "en"}}],
            "effective": {"language": "en"},
            "provenance": {"engine": ENGINE, "operation": "image.describe", "profile_version": "0.1",
                           "model": {"id": "mage-vl", "title": "Mage-VL", "license": APACHE},
                           "timings": {"received_at": "2026-10-09T17:02:00Z", "run_ms": 1400}},
        },
        "retention": {"outputs_expire_at": "2026-10-09T18:02:02Z", "record_expires_at": "2026-10-10T17:02:02Z"},
        "created_at": "2026-10-09T17:02:00Z",
        "updated_at": "2026-10-09T17:02:02Z",
    },
    "job-failed.json": {
        "id": "job_01J9ZP",
        "operation": "image.fill",
        "client_ref": "ticket_8813",
        "state": "purged",
        "outcome": "failed",
        "warnings": [],
        "error": {"code": "input_fetch_failed", "message": "The grant for input 'image' was refused (401).",
                  "param": "image", "job": "job_01J9ZP"},
        "retention": {"record_expires_at": "2026-10-10T17:05:00Z"},
        "created_at": "2026-10-09T17:04:58Z",
        "updated_at": "2026-10-09T17:05:00Z",
    },
    "event-progress.json": {"type": "job.progress", "job": "job_01J9ZK", "seq": 14, "time": "2026-10-09T17:00:07Z",
                            "data": {"stage": "running", "step": 4, "steps": 8, "fraction": 0.5}},
    "event-output-ready.json": {
        "type": "job.output_ready", "job": "job_01J9ZK", "seq": 22, "time": "2026-10-09T17:00:13Z",
        "data": {"outputs": [{"index": 0, "name": "images", "kind": "image", "media_type": "image/png",
                              "bytes": 1893340, "sha256": H("out0"), "href": "/mes/v0/jobs/job_01J9ZK/outputs/0",
                              "width": 1008, "height": 752}]}},
    "event-ended.json": {"type": "job.ended", "job": "job_01J9ZP", "seq": 3, "time": "2026-10-09T17:05:00Z",
                         "data": {"outcome": "failed",
                                  "error": {"code": "input_fetch_failed", "message": "The grant for input 'image' was refused (401)."}}},
    "error-policy-unmet.json": {"error": {
        "code": "policy_unmet",
        "message": "No model for image.generate permits commercial use with the requested size.",
        "reason": "qwen-image-2.1 is LicenseRef-Qwen-Research (commercial_use: false)",
        "request_id": "req_5d2"}},
    "health.json": {"status": "ok", "queue_depth": 2, "running": "job_01J9ZK", "resident_models": ["z-image-turbo"],
                    "memory": {"headroom_bytes": 21474836480, "class": "large"}, "estimated_wait_s": 18},
    "model-offer-research.json": {"id": "qwen-image-2.1", "title": "Qwen-Image 2.1", "license": QWEN_RESEARCH,
                                  "memory_class": "large", "speed_class": "standard", "quality_tiers": ["best"]},
}

OUT.mkdir(parents=True, exist_ok=True)
for name, value in examples.items():
    (OUT / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {len(examples)} examples to {OUT.relative_to(ROOT)}")
