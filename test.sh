#!/bin/zsh
# Runs every Onyx self-test that only writes logs: no screenshots, nothing of yours is changed.
# Usage: ./test.sh [--no-build] [--full-ai]   (the full 100-question AI suite takes about 4 minutes; by default 20 of them run)
cd "$(dirname "$0")"
[[ "$*" == *--no-build* ]] || ./build.sh >/dev/null || { echo "Build failed"; exit 1; }
T=$(mktemp -d /tmp/onyx-tests.XXXX)
cp -R build/Onyx.app "$T/OnyxTest.app"
APP="$T/OnyxTest.app"
typeset -A RESULT
run() {   # name, log file, then env and args for the app
  local name=$1 log=$2; shift 2
  rm -f "$log"
  open -n -g -W -a "$APP" "$@" &   # each test quits when it's done
  local op=$! i=0
  while kill -0 $op 2>/dev/null; do sleep 2; i=$((i + 1)); [ $i -gt 450 ] && { pkill -f "$APP/Contents/MacOS"; echo "   (timed out)"; break; }; done
  if grep -q "^FAIL" "$log" 2>/dev/null; then RESULT[$name]="$(grep -c '^FAIL' "$log") FAILED"
  else RESULT[$name]=$(grep -E "ALL PASSED|FAILED|Onyx AI test:|PASS|FAIL" "$log" 2>/dev/null | tail -1); fi
  [[ "${RESULT[$name]}" == PASS* ]] && RESULT[$name]="ALL PASSED"
  echo "── $name: ${RESULT[$name]}"
  grep -E "^FAIL|^✗" "$log" | head -8
}
run features   "$T/extras.log"   --env ONYX_EXTRASTEST="$T/extras.log"
run ai-parts   "$T/aiplus.log"   --env ONYX_AIPLUSTEST="$T/aiplus.log"
run safety     "$T/safety.log"   --env ONYX_SAFETYTEST="$T/safety.log" --args -ai.provider anthropic
run battery    "$T/battery.log"  --env ONYX_LOWBATTERYTEST="$T/battery.log"
run autoclose  "$T/close.log"    --env ONYX_AUTOCLOSETEST="$T/close.log" --args -autoCloseDelay 5
run tour       "$T/tour.log"     --env ONYX_TOURTEST="$T/tour.log"
python3 Tests/mockai.py "$T/mock.log" >/dev/null 2>&1 & MOCK=$!; sleep 1
for p in anthropic openai; do
  run cloud-$p "$T/cloud-$p.log" --env ONYX_CLOUDTEST="$T/cloud-$p.log" --env ONYX_AI_BASE=http://127.0.0.1:8765/v1 --env ONYX_AI_TEST_KEY=mock-key --args -ai.provider $p
done
kill $MOCK 2>/dev/null
run energy     "$T/energy.log"   --env ONYX_ENERGYTEST="$T/energy.log"
if [[ "$*" == *--full-ai* ]]; then run ai-suite "$T/eval.log" --env ONYX_AIEVAL="$T/eval.log" --args -ai.effort medium -ai.provider apple
else run ai-suite "$T/eval.log" --env ONYX_AIEVAL="$T/eval.log" --env ONYX_AIEVAL_QUICK=1 --args -ai.effort medium -ai.provider apple; fi
echo; echo "Logs: $T"
fails=0; for k v in ${(kv)RESULT}; do [[ "$v" == *FAIL* || -z "$v" ]] && fails=$((fails + 1)); done
echo $([ $fails -eq 0 ] && echo "Everything passed" || echo "$fails test group(s) need a look")
