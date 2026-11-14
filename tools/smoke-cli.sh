#!/bin/zsh
# R0c exit check: `mes` against the mock engine end to end — discovery, pairing, generate → matte → fill (each
# output feeding the next), download and confirm; then Audio 0.1 — a designed voice kept as an asset, speech streamed
# with it (the chunks written as they arrive equal the finished output), a preset voice, the asset deleted, the take
# separated into stems, and into a described sound and the rest; then Video
# 0.1 — a clip generated under a licence its users accept, refused without that acceptance, then interpolated; then
# Mesh 0.1 — a GLB generated from the picture, then rigged, then hair made for the rigged mesh sent as a .vrm (RFC 0009);
# then unpair. Everything runs in a temporary directory.
#
#   tools/smoke-cli.sh            # builds, then runs
set -euo pipefail

repo=${0:A:h:h}
cd "$repo"
swift build --product mes --product mes-mock-engine >/dev/null
bin="$repo/.build/debug"
work=$(mktemp -d -t mes-smoke)
port=17650
engine_pid=""
cleanup() { [[ -n "$engine_pid" ]] && kill "$engine_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

step() { print -P "\n%B▶ $*%b" }
mes() { "$bin/mes" "$@" --state-dir "$work/client" }

step "Mock engine, paired mode, auto-approving pairings, on loopback only (advertised on this machine)"
"$bin/mes-mock-engine" --port $port --paired --host 127.0.0.1 --approve auto --spool "$work/spool" --state "$work/state" \
  > "$work/engine.log" 2>&1 &
engine_pid=$!
for _ in {1..50}; do grep -q listening "$work/engine.log" && break; sleep 0.1; done
cat "$work/engine.log"

step "mes discover"
"$bin/mes" discover | tee "$work/discover.txt"
grep -q "MES Mock Engine" "$work/discover.txt"

step "mes pair (by discovered name)"
"$bin/mes" pair "MES Mock" --name "smoke test" --state-dir "$work/client"

step "mes info · mes describe image.fill"
mes info
mes describe image.fill

step "mes run image.generate"
mes run image.generate -i prompt="a lighthouse at dusk" -p size=64x48 -p seed=7 -o "$work/out" | tee "$work/gen.txt"
generated=$(grep '^saved ' "$work/gen.txt" | head -1 | cut -c7-)

step "mes run image.matte (the generated image as input)"
mes run image.matte -i image="$generated" -o "$work/out" | tee "$work/matte.txt"
mask=$(grep '^saved ' "$work/matte.txt" | head -1 | cut -c7-)

step "mes run image.fill (image + mask + prompt), kept on the engine"
mes run image.fill -i image="$generated" -i mask="$mask" -i prompt="clear sky" -o "$work/fill" --no-confirm \
  | tee "$work/fill.txt"
job=$(head -1 "$work/fill.txt" | cut -d' ' -f1)

step "mes jobs --state holding · mes download · mes confirm"
mes jobs --state holding
mes download "$job" -o "$work/fill-again"
cmp "$work/fill/$job-0.png" "$work/fill-again/$job-0.png" && print "download matches"
mes confirm "$job"

step "Outputs"
ls -l "$work/out" "$work/fill"
file "$work/fill/$job-0.png"

step "mes voices audio.speak mock-presets · mes describe audio.speak"
mes voices audio.speak mock-presets | tee "$work/voices.txt"
grep -q "^mock-tenor  Tenor" "$work/voices.txt"
mes describe audio.speak | tee "$work/speak-describe.txt"
grep -q "Streams (--stream): audio as pcm_s16le|pcm_f32le" "$work/speak-describe.txt"

step "mes run audio.design_voice (a reference voice)"
mes run audio.design_voice -i description="a calm, low narrator" -i text="This is the voice." -o "$work/voice" | tee "$work/design.txt"
designed=$(grep '^saved ' "$work/design.txt" | head -1 | cut -c7-)

step "mes run audio.speak --stream, the designed voice as an asset (asset:<file>), outputs kept"
mes run audio.speak -i text="Streamed while it is spoken." -i voice_ref="asset:$designed" --stream -o "$work/speak" --no-confirm \
  | tee "$work/speak.txt"
streamed=$(grep '^streamed ' "$work/speak.txt" | head -1 | cut -c10-)
spoken=$(grep '^saved ' "$work/speak.txt" | head -1 | cut -c7-)
cmp "$streamed" "$spoken" && print "the chunks written as they arrived equal the finished output"
speak_job=$(grep -m1 '  audio.speak  ' "$work/speak.txt" | cut -d' ' -f1)
mes confirm "$speak_job" >/dev/null

step "mes assets · reuse by id · mes assets rm"
mes assets | tee "$work/assets.txt"
asset=$(grep -m1 '^ast_' "$work/assets.txt" | cut -d' ' -f1)
mes run audio.speak -i text="Again, by asset id." -i voice_ref="asset:$asset" -o "$work/speak2" > "$work/speak2.txt"
grep -q '(succeeded)' "$work/speak2.txt"
mes assets rm "$asset"
mes assets > "$work/assets-after.txt"
grep -q "No assets." "$work/assets-after.txt"

step "mes run audio.speak with a preset voice"
mes run audio.speak -i text="A preset voice." -p voice=mock-tenor -o "$work/preset" --json > "$work/preset.json"
grep -q '"voice":{"id":"mock-tenor"' "$work/preset.json" && print "spoke with mock-tenor"

step "mes run audio.separate on the preset take (RFC 0006): an output per stem; a speaker picked by words"
take=$(ls "$work/preset"/*.wav | head -1)
mes run audio.separate -i audio="$take" -o "$work/stems" | tee "$work/stems.txt"
grep -q "output 0 vocals" "$work/stems.txt" && grep -q "output 1 instrumental" "$work/stems.txt"
mes run audio.separate -i audio="$take" -p stems='["speaker"]' -p speaker='{"saying":"a preset voice"}' -p quality=draft \
  -o "$work/speaker" | tee "$work/speaker.txt"
grep -q "output 0 speaker" "$work/speaker.txt"

step "mes run audio.separate by description (RFC 0008): the target and the residual, with a span"
mes run audio.separate -i audio="$take" -p describe="speech" -p spans='[{"start_s":0.1,"end_s":0.4,"present":true}]' \
  -o "$work/described" | tee "$work/described.txt"
grep -q "output 0 target" "$work/described.txt" && grep -q "output 1 residual" "$work/described.txt"

step "mes describe video.generate · mes run video.generate --accept · refused without it"
mes describe video.generate | grep "users accept its terms"
mes run video.generate -i prompt="a kite over green hills" -p size=128x96 -p duration_s=0.375 -p quality=draft \
  --model mock-ltx-compact --accept LicenseRef-Mock-Video-Community -o "$work/clip" | tee "$work/clip.txt"
clip=$(grep '^saved ' "$work/clip.txt" | head -1 | cut -c7-)
if mes run video.generate -i prompt="a kite" -p duration_s=0.375 -p quality=draft --model mock-ltx-compact -o "$work/no" > "$work/no.txt" 2>&1; then
  print "unexpected: ran without accepting the terms"; exit 1
fi
grep -q "policy.accepted" "$work/no.txt" && print "refused without the user's acceptance, naming what to accept"

step "mes run video.interpolate on the generated clip"
mes run video.interpolate -i video="$clip" -p factor=2 -o "$work/tween" | tee "$work/tween.txt"
grep -q '(succeeded)' "$work/tween.txt"

step "mes run mesh.generate on the generated picture · mes run mesh.rig on the mesh"
mes run mesh.generate -i image="$generated" -p max_faces=1280 -p placement=grounded -p size_m=1.8 -o "$work/mesh" | tee "$work/mesh.txt"
grep -q "Built with Mock DINOv3" "$work/mesh.txt" && grep -q "output 0 mesh: model/gltf-binary 642 vertices · 1280 faces" "$work/mesh.txt"
glb=$(grep '^saved .*\.glb$' "$work/mesh.txt" | head -1 | cut -c7-)
mes run mesh.rig -i mesh="$glb" -p skeleton=vrm_humanoid -o "$work/rig" | tee "$work/rig.txt"
grep -q "642 vertices · 1280 faces .* · 22 joints" "$work/rig.txt"

step "mes run mesh.generate_part (RFC 0009): hair for the rigged mesh, from the picture and a box, with the body as a .vrm"
cp "$(grep '^saved .*\.glb$' "$work/rig.txt" | head -1 | cut -c7-)" "$work/avatar.vrm"
mes run mesh.generate_part -i image="$generated" -i body="$work/avatar.vrm" -p subject_box='{"x":0.25,"y":0.1,"width":0.5,"height":0.4}' \
  -o "$work/hair" | tee "$work/hair.txt"
grep -q "Built with Mock DINOv3" "$work/hair.txt" && grep -q "output 0 mesh: model/gltf-binary 6 vertices · 4 faces .* · 4 joints" "$work/hair.txt"
if mes run mesh.generate_part -i image="$generated" -i body="$work/avatar.vrm" --model mock-hairdeck -o "$work/nobox" > "$work/nobox.txt" 2>&1; then
  print "unexpected: a part ran on a model that needs a box, without one"; exit 1
fi
grep -q "subject_box" "$work/nobox.txt" && print "refused without the box the model needs"

step "mes unpair"
mes unpair "MES Mock"
if mes ops >/dev/null 2>&1; then print "unexpected: still authorized"; exit 1; fi
print "\n✅ mes end to end: discover → pair → generate → matte → fill → download → confirm → voices → design → speak --stream with an asset → preset voice → separate → separate by description → video generate (accepted) → interpolate → mesh generate → rig → a part for it → unpair"
