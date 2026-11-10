#!/usr/bin/env bash
# Offline tests. A fake `aws` on PATH keeps state in files and simulates
# no-capacity, failed-state, pending, quota, permission and lost-response cases.
# Optional live check (needs AWS credentials, creates nothing):  LIVE=1 tests/test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
H="$here/gpu-hunter.sh"
mkdir -p "$tmp/bin"; export FAKE_DIR="$tmp/state"

# Stateful fake aws. Behaviour per scenario via FAKE_MODE:
#   ice-then-small : first 3 creates -> ICE, then only count <= 2 succeeds; 2nd success returns state 'failed'
#   pending        : create succeeds with state 'pending'
#   lost           : 1st create is applied on "AWS" but the client sees a read timeout
#   quota          : create -> InstanceLimitExceeded
#   nodescribe     : describe-capacity-reservations -> UnauthorizedOperation
#   chunk          : count > 2 -> ICE
#   lag            : describe never shows our reservations (eventual consistency); only 1 instance ever available
#   lost-always    : every create is applied on "AWS" but the client always sees a read timeout
#   throttle       : every create -> RequestLimitExceeded
#   pend-fail      : creates come back 'pending'; the first one later turns 'failed', later ones 'active'
cat > "$tmp/bin/aws" <<'F'
#!/usr/bin/env bash
mkdir -p "$FAKE_DIR"; n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0)
db="$FAKE_DIR/db"; touch "$db"
arg() { sed -n "s/.*--$1 \([^ ]*\).*/\1/p" <<<"$*"; }
case "$*" in
 *describe-instance-type-offerings*) echo "zz-test-1a zz-test-1b";;
 *describe-capacity-reservations*)
   [[ "$FAKE_MODE" == nodescribe ]] && { echo "An error occurred (UnauthorizedOperation)" >&2; exit 254; }
   [[ "$FAKE_MODE" == lag && "$*" == *"sum("* ]] && { echo 0; exit 0; }
   if [[ "$*" == *"--capacity-reservation-ids"* ]]; then          # state of one reservation
     id=$(arg capacity-reservation-ids "$*")
     if [[ "$FAKE_MODE" == pend-fail ]]; then [[ "$id" == cr-1 ]] && echo failed || echo active
     else awk -v i="$id" '$1==i{print $3}' "$db"; fi
     exit 0; fi
   if [[ "$*" == *"sum("* ]]; then
     if [[ "$FAKE_MODE" == pend-fail ]]; then awk '$1!="cr-1"{s+=$2} END{print s+0}' "$db"; else awk '$3!="failed"{s+=$2} END{print s+0}' "$db"; fi
   else echo 0; fi;;
 *create-capacity-reservation*)
   tok=$(arg client-token "$*")
   line=""; [[ -n "$tok" ]] && line=$(grep " tok=$tok\$" "$db")
   if [[ -n "$line" && "$FAKE_MODE" != lost-always ]]; then  # idempotent replay
     set -- $line; printf '%s\t%s\n' "$1" "$3"; exit 0; fi
   n=$((n+1)); echo $n > "$FAKE_DIR/n"; cnt=$(arg instance-count "$*")
   case "$FAKE_MODE" in
     quota) echo "An error occurred (InstanceLimitExceeded) vCPU limit" >&2; exit 254;;
     ice-then-small)
       if (( n <= 3 || cnt > 2 )); then echo "An error occurred (InsufficientInstanceCapacity)" >&2; exit 254; fi
       wins=$(grep -c . "$db"); st=active; (( wins == 1 )) && st=failed
       echo "cr-$n $cnt $st" >> "$db"; printf 'cr-%s\t%s\n' $n $st;;
     pending) echo "cr-$n $cnt pending" >> "$db"; printf 'cr-%s\tpending\n' $n;;
     lost)
       echo "cr-$n $cnt active tok=$tok" >> "$db"
       if (( n == 1 )); then echo "Read timeout on endpoint URL" >&2; exit 255; fi
       printf 'cr-%s\tactive\n' $n;;
     lag) (( cnt > 1 || n > 2 )) && { echo "An error occurred (InsufficientInstanceCapacity)" >&2; exit 254; }
       echo "cr-$n $cnt active" >> "$db"; printf 'cr-%s\tactive\n' $n;;
     lost-always) [[ -z "$line" ]] && echo "cr-$n $cnt active tok=$tok" >> "$db"; echo "Read timeout on endpoint URL" >&2; exit 255;;
     throttle) echo "An error occurred (RequestLimitExceeded) Request limit exceeded." >&2; exit 254;;
     pend-fail) echo "cr-$n $cnt pending" >> "$db"; printf 'cr-%s\tpending\n' $n;;
     chunk) (( cnt > 2 )) && { echo "An error occurred (InsufficientInstanceCapacity)" >&2; exit 254; }
       echo "cr-$n $cnt active" >> "$db"; printf 'cr-%s\tactive\n' $n;;
     nodescribe) echo "CREATED" >> "$FAKE_DIR/created"; printf 'cr-x\tactive\n';;
   esac;;
 *) echo "unexpected: $*" >&2; exit 1;;
esac
F
chmod +x "$tmp/bin/aws"
run() { rm -rf "$FAKE_DIR" "$tmp"/gpu-hunter-events-*.csv; (cd "$tmp" && PATH="$tmp/bin:$PATH" FAKE_MODE="$1" GPU_HUNTER_PENDING_POLL=1 GPU_HUNTER_PENDING_MAX=5 timeout "${T:-60}" "$H" -r zz-test-1 "${@:2}" 2>&1); }

out=$(run ice-then-small -t g6e.12xlarge -n 4 -i 1 --max-interval 2); rc=$?
[[ $rc -eq 0 && "$out" == *"DONE: reserved 4"* ]] && ok "retries + halving reach the target" || { bad "retries + halving (rc=$rc)"; echo "$out"; }
[[ "$out" == *"next try in"* ]] && ok "waits between rounds" || bad "waits between rounds"
[[ $(awk '$3=="active"{s+=$2} END{print s}' "$FAKE_DIR/db") == 4 ]] && ok "a reservation that comes back 'failed' is not counted" || { bad "failed-state counting"; cat "$FAKE_DIR/db"; }
ev=$(ls "$tmp"/gpu-hunter-events-*.csv 2>/dev/null | head -1)
[[ "$out" == *"SUMMARY: reserved 4/4"* && -s "$ev" && $(grep -c won "$ev") -ge 2 ]] && ok "summary line + events CSV written" || { bad "summary/events"; echo "$out" | tail -3; }

out=$(run pending -t g6.xlarge -n 2); rc=$?
[[ $rc -eq 0 && "$out" == *"DONE: reserved 2"* && $(grep -c . "$FAKE_DIR/db") == 1 ]] && ok "'pending' counts as won, nothing cancelled" || { bad "pending (rc=$rc)"; echo "$out"; }

out=$(run lost -t g6.xlarge -n 2 -i 1 --max-interval 1); rc=$?
total=$(awk '{s+=$2} END{print s}' "$FAKE_DIR/db")
[[ $rc -eq 0 && "$total" == 2 && "$out" == *"re-sending the same request"* ]] && ok "lost response: same ClientToken re-sent, no over-reserve (held=$total)" || { bad "lost response (rc=$rc, held=$total)"; echo "$out"; }

out=$(run quota -t p4d.24xlarge -n 1); rc=$?
[[ $rc -eq 3 && "$out" == *"FATAL quota"* ]] && ok "quota error stops (exit 3)" || { bad "quota stop (rc=$rc)"; echo "$out"; }

out=$(run nodescribe -t g6.xlarge -n 1); rc=$?
[[ $rc -eq 3 && ! -s "$FAKE_DIR/created" ]] && ok "no describe permission stops before creating" || { bad "describe preflight (rc=$rc)"; echo "$out"; }

out=$(run chunk -t g6.xlarge -n 3 -m 2 -i 1 --max-interval 1); rc=$?
[[ $rc -eq 0 && "$out" == *"GOT 2 x"* && "$out" == *"GOT 1 x"* ]] && ok "remainder below --min-chunk is still tried" || { bad "min-chunk remainder (rc=$rc)"; echo "$out"; }

out=$(T=6 run lag -t g6.xlarge -n 3 -i 1 --max-interval 1)
held=$(awk '{s+=$2} END{print s+0}' "$FAKE_DIR/db")
[[ "$held" == 1 && "$out" != *"reconcile:"* && "$out" == *"round 2: no more capacity now, remaining=2"* ]] && ok "describe lag never raises the count (held=$held, remaining stays 2)" || { bad "describe lag (held=$held)"; echo "$out" | tail -5; }

# review finding 1: all sends unclear -> stop the round, never a NEW request with a new token
out=$(T=8 run lost-always -t g6.xlarge -n 4 -i 1 --max-interval 1); held=$(awk '{s+=$2} END{print s+0}' "$FAKE_DIR/db")
[[ "$held" -le 4 && "$out" == *"stopping this round"* ]] && ok "unclear results never over-reserve (held=$held of 4)" || { bad "unclear over-reserve (held=$held)"; echo "$out" | head -20; }
[[ "$out" == *"(2 of 2)"* && "$out" != *"(3 of"* ]] && ok "exactly 2 re-sends of the same request" || bad "re-send count"

# review finding 2: throttled -> one create, then the round stops and waits the max interval
out=$(T=4 run throttle -t g6.xlarge,g5.xlarge -n 8 -i 1 --max-interval 3); r1=$(awk -F, '$3==1' "$tmp"/gpu-hunter-events-*.csv | wc -l)
[[ "$r1" -eq 1 && "$out" == *"API throttling seen"* ]] && ok "throttling stops the round after 1 request (round-1 requests=$r1)" || { bad "throttle round (round-1 requests=$r1)"; echo "$out" | head; }

# review finding 3: a 'pending' win that later fails is hunted again, DONE only when really held
out=$(T=30 run pend-fail -t g6.xlarge -n 2 -i 1 --max-interval 1); rc=$?
[[ $rc -eq 0 && "$out" == *"ended as 'failed'"* && "$out" == *"back to hunting"* && "$out" == *"DONE: reserved 2"* ]] && ok "pending that turns failed is hunted again" || { bad "pending->failed (rc=$rc)"; echo "$out"; }

# review finding 4: --status / --release fail loudly when listing fails
out=$(T=10 run nodescribe --release); rc=$?
[[ $rc -eq 3 && "$out" == *"cannot list"* && "$out" != *"nothing to release"* ]] && ok "--release reports a listing error (exit 3)" || { bad "--release listing error (rc=$rc)"; echo "$out"; }

# review finding 6: api_ms is one call, not including re-send sleeps (fake calls are fast)
out=$(run lost -t g6.xlarge -n 2 -i 1 --max-interval 1); maxms=$(tail -n +2 "$tmp"/gpu-hunter-events-*.csv | cut -d, -f8 | sort -n | tail -1)
[[ "$maxms" -lt 1500 ]] && ok "api_ms excludes re-send sleeps (max=${maxms}ms)" || bad "api_ms includes sleeps (max=${maxms}ms)"

# octal: -n 010 means 10
out=$(run chunk -t g6.xlarge -n 010 -i 1 --max-interval 1); [[ "$out" == *"target=10 "* ]] && ok "-n 010 is read as 10" || { bad "octal"; echo "$out" | head -3; }

# type not offered anywhere -> exit 2
cat > "$tmp/bin/aws2" <<'F'
#!/usr/bin/env bash
case "$*" in *offerings*) echo "";; *) exit 1;; esac
F
mkdir -p "$tmp/bin2"; mv "$tmp/bin/aws2" "$tmp/bin2/aws"; chmod +x "$tmp/bin2/aws"
out=$(cd "$tmp" && PATH="$tmp/bin2:$PATH" timeout 20 "$H" -r zz-test-1 -t p9.huge -n 1 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "no usable type/AZ exits 2" || { bad "not offered (rc=$rc)"; echo "$out"; }

for a in "-n 0" "-i 0" "-n abc" "-t"; do
  out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" timeout 10 "$H" -r zz-test-1 $( [[ "$a" == "-t" ]] || echo -t g6.xlarge ) $a 2>&1); rc=$?
  [[ $rc -eq 1 ]] && ok "rejects '$a'" || { bad "rejects '$a' (rc=$rc)"; echo "$out"; }
done

out=$("$H" -h); [[ "$out" != *"set -uo"* && "$out" == *"Usage:"* && "$out" == *"--release"* ]] && ok "--help shows the whole header and no code" || { bad "--help"; echo "$out"; }

printf 'time_utc,elapsed_s,round,type,az,count,result,api_ms\n2026-01-01T00:00:00Z,0,1,g6.xlarge,a,1,no-capacity,1300\n2026-01-01T00:00:41Z,41,2,g6.xlarge,b,2,won-active,1500\n' > "$tmp/ev.csv"
out=$("$here/tools/report.sh" "$tmp/ev.csv"); [[ "$out" == *"attempts=2 rounds=2"*"first_win=41s"*"instances_won=2"* && "$out" == *"no-capacity=1"* ]] && ok "report.sh summarises an events file" || { bad "report.sh"; echo "$out"; }

(cd "$tmp" && rm -f gpu-hunter-events-*.csv && cp "$tmp/ev.csv" gpu-hunter-events-20990101T000000Z-1.csv && out=$("$here/tools/report.sh") && [[ "$out" == *"gpu-hunter-events-20990101T000000Z-1.csv"* ]]) && ok "report.sh with no argument uses the newest events file" || bad "report.sh default file"

if [[ "${LIVE:-0}" == 1 ]]; then
  out=$(cd "$tmp" && "$H" -r "${LIVE_REGION:-eu-central-1}" -t "${LIVE_TYPE:-g6.xlarge}" -n 2 --dry-run 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == *"(dry-run)"* ]] && ok "live dry-run against the real API" || { bad "live dry-run (rc=$rc)"; echo "$out"; }
fi
echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]
