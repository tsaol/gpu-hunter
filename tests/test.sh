#!/usr/bin/env bash
# Offline tests: a fake `aws` on PATH simulates capacity errors and quota errors.
# Optional live check (needs AWS credentials, creates nothing):  LIVE=1 tests/test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

mkdir -p "$tmp/bin"
# Fake 1: first 3 create calls get InsufficientInstanceCapacity, then only chunks <= 2 succeed.
cat > "$tmp/bin/aws" <<'F'
#!/usr/bin/env bash
st="$FAKE_STATE"; n=$(cat "$st" 2>/dev/null || echo 0)
case "$*" in
 *describe-instance-type-offerings*) echo "zz-test-1a zz-test-1b";;
 *create-capacity-reservation*)
   echo $((n+1)) > "$st"
   cnt=$(sed -n 's/.*--instance-count \([0-9]*\).*/\1/p' <<<"$*")
   if (( n < 3 || cnt > 2 )); then echo "An error occurred (InsufficientInstanceCapacity)" >&2; exit 254; fi
   echo "cr-test$n";;
 *) echo "unexpected: $*" >&2; exit 1;;
esac
F
chmod +x "$tmp/bin/aws"
out=$(cd "$tmp" && FAKE_STATE="$tmp/s1" PATH="$tmp/bin:$PATH" timeout 60 "$here/grab-gpu.sh" -r zz-test-1 -t g6e.12xlarge -n 4 -i 1 --max-interval 2 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"DONE: reserved 4"* ]] && ok "retries + halving reach the target" || { bad "retries + halving (rc=$rc)"; echo "$out"; }
[[ "$out" == *"next try in"* ]] && ok "waits between rounds" || bad "waits between rounds"

# Fake 2: quota error must stop at once with exit 3.
cat > "$tmp/bin/aws" <<'F'
#!/usr/bin/env bash
case "$*" in *offerings*) echo zz-test-1a;; *) echo "An error occurred (InstanceLimitExceeded) vCPU limit" >&2; exit 254;; esac
F
out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" timeout 20 "$here/grab-gpu.sh" -r zz-test-1 -t p4d.24xlarge -n 1 2>&1); rc=$?
[[ $rc -eq 3 && "$out" == *"FATAL quota"* ]] && ok "quota error stops (exit 3)" || { bad "quota stop (rc=$rc)"; echo "$out"; }

# Fake 3: type not offered anywhere -> exit 2.
cat > "$tmp/bin/aws" <<'F'
#!/usr/bin/env bash
case "$*" in *offerings*) echo "";; *) exit 1;; esac
F
out=$(cd "$tmp" && PATH="$tmp/bin:$PATH" timeout 20 "$here/grab-gpu.sh" -r zz-test-1 -t p9.huge -n 1 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "no usable type/AZ exits 2" || { bad "not offered (rc=$rc)"; echo "$out"; }

if [[ "${LIVE:-0}" == 1 ]]; then
  out=$(cd "$tmp" && "$here/grab-gpu.sh" -r "${LIVE_REGION:-eu-central-1}" -t "${LIVE_TYPE:-g6.xlarge}" -n 2 --dry-run 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == *"(dry-run)"* ]] && ok "live dry-run against the real API" || { bad "live dry-run (rc=$rc)"; echo "$out"; }
fi
echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]
