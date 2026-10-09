#!/bin/zsh
# R0c exit check: `mes` against the mock engine end to end — discovery, pairing, generate → matte → fill (each
# output feeding the next), download and confirm, then unpair. Everything runs in a temporary directory.
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
grep -q "MES Mock Image Engine" "$work/discover.txt"

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

step "mes unpair"
mes unpair "MES Mock"
if mes ops >/dev/null 2>&1; then print "unexpected: still authorized"; exit 1; fi
print "\n✅ mes end to end: discover → pair → generate → matte → fill → download → confirm → unpair"
