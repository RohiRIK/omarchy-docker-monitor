#!/bin/bash
#
# Bounded helper test: runs docker-helper.py against a fake docker CLI that
# hangs, floods output, or emits one oversized log line, and checks that the
# helper stops it within its deadline and keeps its own output small.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT

cat >"$FAKE/docker" <<'FAKE'
#!/bin/bash
case "$FAKE_MODE:$1" in
  *:version) echo 29.0.0 ;;
  *:ps) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  hang:inspect) sleep 60 ;;
  flood:inspect) yes '{"id":"aaaaaaaaaaaa","name":"/x","labels":{}}' ;;
  *:inspect) echo '{"id":"aaaaaaaaaaaaaaaa","name":"/web","image":"<b>img</b>","status":"running","memLimitBytes":0,"labels":{},"health":"","restarts":0,"ports":{},"networks":{}}' ;;
  *:stats) echo 'web|1%|1MiB / 1GiB|0.1%' ;;
  hugeline:logs) head -c 200000000 /dev/zero | tr '\0' x ;;
  hang:logs) echo '2026-01-01T00:00:00Z started'; sleep 60 ;;
  *:logs) echo '2026-01-01T00:00:02Z out'; echo '2026-01-01T00:00:01Z err' >&2 ;;
  *:stop) echo stopped ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE/docker"

fail=0
check() {
  if eval "$1"; then echo "ok - $2"; else echo "not ok - $2" >&2; fail=1; fi
}

helper() {
  local mode=$1
  shift
  PATH="$FAKE:$PATH" FAKE_MODE=$mode python3 "$ROOT/docker-helper.py" "$@"
}

out=$(helper normal snapshot)
check '[[ $(node -e "const s=require(process.argv[1]).parseSnapshot(process.argv[2]); console.log(s.containers.length, s.containers[0].image, s.error||\"\")" "$ROOT/Model.js" "$out") == "1 <b>img</b> " ]]' \
  "snapshot parses through the helper"

start=$SECONDS
out=$(helper hang snapshot)
check '(( SECONDS - start <= 14 ))' "stuck inspect is killed by the snapshot deadline"
check '[[ $out == *"timed out"* ]]' "stuck inspect reports a timeout"

out=$(helper flood snapshot)
check '(( ${#out} <= 5 * 1024 * 1024 ))' "flooding inspect output is capped (${#out} bytes)"
check '[[ $out == *"size limit"* ]]' "flooding inspect reports the size limit"

out=$(helper normal logs aaaaaaaaaaaa)
check '[[ $(node -e "console.log(JSON.parse(process.argv[1]).text)" "$out") == $'"'"'2026-01-01T00:00:01Z err\n2026-01-01T00:00:02Z out'"'"' ]]' \
  "logs merge stdout and stderr by timestamp"

out=$(helper normal grouplogs aaaaaaaaaaaa bbbbbbbbbbbb)
check '[[ $(node -e "const d=JSON.parse(process.argv[1]); console.log(d.lines.length, d.lines.map(l => l[0] + l[2]).join(\",\"))" "$out") == "4 0err,1err,0out,1out" ]]' \
  "group logs merge containers by timestamp and tag each line"

out=$(helper normal grouplogs 'bad id')
check '[[ $out == *"Invalid container ids"* ]]' "group logs reject invalid ids"

start=$SECONDS
out=$(helper hugeline logs aaaaaaaaaaaa)
check '(( SECONDS - start <= 12 ))' "an oversized log line stops at the read limit"
check '(( ${#out} <= 70000 ))' "an oversized log line yields bounded output (${#out} bytes)"
check '[[ $out == *"line truncated"* && $out == *"exceeded"* ]]' "an oversized log line is marked truncated"

start=$SECONDS
out=$(helper hang logs aaaaaaaaaaaa)
check '(( SECONDS - start <= 12 ))' "hanging logs are killed by the deadline"
check '[[ $out == *started* && $out == *"timed out"* ]]' "hanging logs keep what was read"

check '[[ $(helper normal logs "--help") == *"Invalid container id"* ]]' "logs reject option-like ids"
check '[[ $(helper normal action rm aaaaaaaaaaaa) == *"Invalid action"* ]]' "actions reject unknown verbs"
check '[[ $(helper normal action stop aaaaaaaaaaaa) == "{\"code\": 0, \"text\": \"\"}" ]]' "actions run allowed verbs"
check '[[ $(helper normal memory "-x" 512) == *"Invalid memory update"* ]]' "memory updates reject option-like names"

exit $fail
