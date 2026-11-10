#!/usr/bin/env bash
# gpu-hunter.sh - keep trying to reserve On-Demand GPU capacity (ODCR) until the target is met.
#
# How it works:
#   - Tries each instance type (in your order) in each AZ where it is offered.
#   - Asks for all remaining instances; if AWS says InsufficientInstanceCapacity,
#     it halves the count and tries again (down to MIN_CHUNK).
#   - Every reservation it gets is kept and tagged (gpu-hunter=<tag>, gpu-hunter-run=<run id>).
#     Each round re-reads from AWS how much this run holds, so a lost response can't over-reserve.
#   - Waits longer after each failed round (backoff + jitter), resets after a win.
#   - Stops at once on quota / permission / parameter errors (retrying won't help).
#
# Usage:
#   ./gpu-hunter.sh -t g6e.12xlarge,g6e.24xlarge -n 4            # reserve 4 instances
#   ./gpu-hunter.sh -t p4d.24xlarge -n 2 -z eu-central-1a,eu-central-1b -s arn:aws:sns:...
#   ./gpu-hunter.sh -t g6.xlarge -n 2 --dry-run                   # test, creates nothing
#   ./gpu-hunter.sh --status                                      # list what we hold
#   ./gpu-hunter.sh --release                                     # cancel all our reservations
#
# Billing: an ODCR is billed at On-Demand price from the moment it is active,
# even if no instance runs in it. Cancel with --release when you no longer need it.

set -uo pipefail

REGION="${GPU_HUNTER_REGION:-eu-central-1}"   # use -r to change
TYPES=""
AZS=""
TARGET=1
MIN_CHUNK=1
PLATFORM="Linux/UNIX"
MATCH="open"            # open = any matching instance uses it; targeted = only when asked
INTERVAL=30             # first wait between rounds, seconds
MAX_INTERVAL=300        # longest wait
MAX_HOURS=0             # 0 = run forever
SNS_TOPIC=""
TAG="gpu-hunter"
DRY_RUN=0
MODE="hunt"
LOG="${GPU_HUNTER_LOG:-./gpu-hunter.log}"
EVENTS="${GPU_HUNTER_EVENTS:-}"   # one line per API attempt; default: one file per run (see RUN_ID)

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "${1:-0}"; }

need_val() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "option $1 needs a value"; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--types|-n|--count|-z|--azs|-r|--region|-m|--min-chunk|-i|--interval|--max-interval|--max-hours|-s|--sns|--platform|--tag)
      need_val "$@";;
  esac
  case "$1" in
    -t|--types) TYPES="$2"; shift 2;;
    -n|--count) TARGET="$2"; shift 2;;
    -z|--azs) AZS="$2"; shift 2;;
    -r|--region) REGION="$2"; shift 2;;
    -m|--min-chunk) MIN_CHUNK="$2"; shift 2;;
    -i|--interval) INTERVAL="$2"; shift 2;;
    --max-interval) MAX_INTERVAL="$2"; shift 2;;
    --max-hours) MAX_HOURS="$2"; shift 2;;
    -s|--sns) SNS_TOPIC="$2"; shift 2;;
    --targeted) MATCH="targeted"; shift;;
    --platform) PLATFORM="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --status) MODE="status"; shift;;
    --release) MODE="release"; shift;;
    -h|--help) usage 0;;
    *) echo "unknown option: $1"; usage 1;;
  esac
done

log() { local m="[$(date '+%F %T')] $*"; echo "$m"; echo "$m" >> "$LOG"; }

notify() {
  [[ -z "$SNS_TOPIC" ]] && return 0
  aws sns publish --region "$(cut -d: -f4 <<<"$SNS_TOPIC")" --topic-arn "$SNS_TOPIC" \
    --subject "gpu-hunter: $1" --message "$2" >/dev/null 2>&1 || log "WARN: SNS publish failed"
}

our_reservations() {
  aws ec2 describe-capacity-reservations --region "$REGION" \
    --filters "Name=tag:gpu-hunter,Values=$TAG" "Name=state,Values=active,pending" \
    --query 'CapacityReservations[].[CapacityReservationId,InstanceType,AvailabilityZone,TotalInstanceCount,AvailableInstanceCount,State]' \
    --output text
}

if [[ "$MODE" == "status" || "$MODE" == "release" ]]; then
  if ! list=$(our_reservations 2>&1); then
    echo "ERROR: cannot list Capacity Reservations in $REGION (credentials, region or ec2:DescribeCapacityReservations?):"
    echo "$list"
    exit 3
  fi
fi
if [[ "$MODE" == "status" ]]; then
  echo "Reservations tagged gpu-hunter=$TAG in $REGION (id type az total free state):"
  [[ -n "$list" ]] && echo "$list"
  exit 0
fi

if [[ "$MODE" == "release" ]]; then
  ids=$(awk '{print $1}' <<<"$list"); rc_rel=0
  [[ -z "$ids" ]] && { echo "nothing to release"; exit 0; }
  for id in $ids; do
    if out=$(aws ec2 cancel-capacity-reservation --region "$REGION" --capacity-reservation-id "$id" 2>&1 >/dev/null); then
      log "released $id"
    else
      log "ERROR: could not release $id: $out"
      log "  (a reservation still 'pending' can't be cancelled yet; run --release again in a few minutes)"
      rc_rel=1
    fi
  done
  exit $rc_rel
fi

[[ -z "$TYPES" ]] && { echo "need -t <types>"; usage 1; }
for v in TARGET:1 MIN_CHUNK:1 INTERVAL:1 MAX_INTERVAL:1 MAX_HOURS:0; do
  name=${v%%:*}; min=${v##*:}; val=${!name}
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "$name must be a whole number >= $min (got '$val')"; exit 1; }
  val=$((10#$val)); printf -v "$name" '%d' "$val"     # '010' means 10, not octal 8
  (( val >= min )) || { echo "$name must be a whole number >= $min (got '$val')"; exit 1; }
done
(( MAX_INTERVAL < INTERVAL )) && MAX_INTERVAL=$INTERVAL
IFS=',' read -ra TYPE_LIST <<< "$TYPES"

# Which AZs offer each type (skip combos that can never work)
declare -A OFFERED=()
NOFF=0
for t in "${TYPE_LIST[@]}"; do
  zs=$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
        --filters "Name=instance-type,Values=$t" --query 'InstanceTypeOfferings[].Location' --output text 2>&1) \
     || { log "ERROR: cannot list offerings: $zs"; exit 2; }
  if [[ -n "$AZS" ]]; then
    keep=""; for z in $zs; do [[ ",$AZS," == *",$z,"* ]] && keep="$keep $z"; done; zs="$keep"
  fi
  zs=$(tr ' \t' '\n\n' <<<"$zs" | grep . | sort | tr '\n' ' ')
  if [[ -z "${zs// }" ]]; then log "WARN: $t is not offered in the chosen AZs of $REGION, skipping"; continue; fi
  OFFERED[$t]="$zs"; NOFF=$((NOFF+1))
  log "$t offered in: $zs"
done
(( NOFF == 0 )) && { log "ERROR: no usable type/AZ"; exit 2; }

# We must be able to read reservations: --status/--release and the per-round check depend on it.
pf=$(aws ec2 describe-capacity-reservations --region "$REGION" --max-results 5 --query 'length(CapacityReservations)' --output text 2>&1) \
  || { log "FATAL: cannot read capacity reservations (need ec2:DescribeCapacityReservations): $pf"; exit 3; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
[[ -z "$EVENTS" ]] && EVENTS="./gpu-hunter-events-$RUN_ID.csv"
REMAINING=$TARGET
WAIT=$INTERVAL
START=$(date +%s)
PENDING=()                                   # "id count" of reservations won while still 'pending'
PENDING_POLL="${GPU_HUNTER_PENDING_POLL:-15}"  # seconds between pending checks
PENDING_MAX="${GPU_HUNTER_PENDING_MAX:-360}"   # docs: state can take up to ~5 min to show 'active'
THROTTLE_SEEN=0; N_TRY=0; N_ICE=0; N_THROTTLE=0; N_WIN=0; T_FIRST=""; T_FULL=""
[[ -s "$EVENTS" ]] || echo "time_utc,elapsed_s,round,type,az,count,result,api_ms" > "$EVENTS"
event() {  # type az count result api_ms
  echo "$(date -u +%FT%TZ),$(( $(date +%s) - START )),$ROUND,$1,$2,$3,$4,$5" >> "$EVENTS"
}
summary() {
  local el=$(( $(date +%s) - START ))
  log "SUMMARY: reserved $((TARGET-REMAINING))/$TARGET in ${el}s, rounds=$ROUND, attempts=$N_TRY, wins=$N_WIN, no-capacity=$N_ICE, throttled=$N_THROTTLE, first-win=${T_FIRST:--}s, full=${T_FULL:--}s, events=$EVENTS"
}
trap 'summary' EXIT
trap 'log "stopped by signal; reservations already won are kept (see --status)"; exit 130' INT TERM
ROUND=0
GOT=()

# reserved_so_far -> instances this run holds right now (active or pending), read from AWS.
# AWS is the source of truth, so a lost response (timeout) can't make us over- or under-count.
reserved_so_far() {
  aws ec2 describe-capacity-reservations --region "$REGION" \
    --filters "Name=tag:gpu-hunter-run,Values=$RUN_ID" "Name=state,Values=active,pending" \
    --query 'sum(CapacityReservations[].TotalInstanceCount)' --output text 2>/dev/null
}

is_unclear() {  # rc out -> 0 if we can't tell whether AWS applied the request
  [[ $1 -ne 0 && "$2" =~ (Could\ not\ connect|timed\ out|Read\ timeout|Connect\ timeout|EndpointConnectionError|InternalError|ServiceUnavailable|Unavailable) ]]
}

# try_reserve TYPE AZ COUNT -> 0 won, 1 no capacity (try smaller / elsewhere),
#                              2 fatal, 3 stop this round now (throttled, or result unclear)
try_reserve() {
  local t="$1" z="$2" c="$3" out rc
  local args=(ec2 create-capacity-reservation --region "$REGION" --instance-type "$t"
              --instance-platform "$PLATFORM" --availability-zone "$z" --instance-count "$c"
              --instance-match-criteria "$MATCH" --end-date-type unlimited
              --tag-specifications "ResourceType=capacity-reservation,Tags=[{Key=gpu-hunter,Value=$TAG},{Key=gpu-hunter-run,Value=$RUN_ID}]"
              --query 'CapacityReservation.[CapacityReservationId,State]' --output text)
  [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
  # ClientToken makes the request idempotent: if a response is lost, sending the SAME
  # request again returns the original result instead of creating a second reservation.
  args+=(--client-token "gh-$RUN_ID-$N_TRY-$RANDOM")
  # AWS_MAX_ATTEMPTS=1: no hidden CLI retries, our own backoff sets the pace
  local t0 ms k=0
  while :; do
    t0=$(date +%s%N)
    out=$(AWS_MAX_ATTEMPTS=1 aws "${args[@]}" 2>&1); rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))       # latency of this one call only
    # only an unclear result (network / 5xx) is re-sent, with the same ClientToken, at most 2 times
    is_unclear "$rc" "$out" || break
    (( k >= 2 )) && break
    k=$((k+1))
    log "unclear result ($(head -c 80 <<<"$out")...), re-sending the same request ($k of 2)"
    sleep $((k * 2))
  done
  N_TRY=$((N_TRY+1))
  if [[ $rc -eq 0 ]]; then
    read -r LAST_ID LAST_STATE <<<"$out"
    # 'pending' is normal: the API is eventually consistent and the state can take
    # up to ~5 minutes to show 'active'. The capacity is already ours, so count it.
    if [[ "$LAST_STATE" == "failed" ]]; then
      N_ICE=$((N_ICE+1)); event "$t" "$z" "$c" failed-state "$ms"; return 1
    fi
    [[ "$LAST_STATE" == "pending" ]] && PENDING+=("$LAST_ID $c")
    event "$t" "$z" "$c" "won-$LAST_STATE" "$ms"; return 0
  fi
  case "$out" in
    *DryRunOperation*) LAST_ID="dry-run"; event "$t" "$z" "$c" dry-run "$ms"; return 0;;
    *InsufficientInstanceCapacity*|*InsufficientCapacity*)
      N_ICE=$((N_ICE+1)); event "$t" "$z" "$c" no-capacity "$ms"; return 1;;
    *RequestLimitExceeded*|*Throttling*)
      N_THROTTLE=$((N_THROTTLE+1)); event "$t" "$z" "$c" throttled "$ms"; return 3;;
    *Unavailable*|*InternalError*|*"Could not connect"*|*"timed out"*|*"Read timeout"*|*"Connect timeout"*|*EndpointConnectionError*)
      # it may or may not have been applied: send nothing new this round (that could
      # over-reserve); the next round first re-reads from AWS what this run holds
      log "result still unclear after 2 re-sends; stopping this round"
      event "$t" "$z" "$c" aws-or-network-error "$ms"; return 3;;
    *InstanceLimitExceeded*|*ReservationCapacityExceeded*|*VcpuLimitExceeded*|*exceed*quota*|*LimitExceeded*)
      event "$t" "$z" "$c" quota "$ms"; log "FATAL quota: $out"; LAST_ERR="quota"; return 2;;
    *)
      event "$t" "$z" "$c" fatal "$ms"; log "FATAL: $out"; LAST_ERR="other"; return 2;;
  esac
}

# check_pending: re-read 'pending' reservations; a failed one gives its count back to REMAINING
check_pending() {
  (( ${#PENDING[@]} == 0 )) && return 0
  local keep=() e id cnt st
  for e in "${PENDING[@]}"; do
    read -r id cnt <<<"$e"
    st=$(aws ec2 describe-capacity-reservations --region "$REGION" --capacity-reservation-ids "$id" \
          --query 'CapacityReservations[0].State' --output text 2>/dev/null)
    case "$st" in
      active) log "pending $id is now active";;
      failed|cancelled|expired)
        REMAINING=$((REMAINING + cnt)); T_FULL=""
        log "pending $id ended as '$st'; $cnt instance(s) back to hunt, remaining=$REMAINING";;
      *) keep+=("$e");;
    esac
  done
  PENDING=(${keep[@]+"${keep[@]}"})   # safe on bash 4.0-4.3 with set -u
}

log "start: run=$RUN_ID target=$TARGET types=$TYPES region=$REGION match=$MATCH dry_run=$DRY_RUN"
while :; do                      # outer loop: hunt, then confirm 'pending' wins
while (( REMAINING > 0 )); do
  ROUND=$((ROUND+1))
  won=0
  check_pending
  if (( DRY_RUN == 0 && ROUND > 1 )); then
    have=$(reserved_so_far)
    # Only ever LOWER the remaining count: describe is eventually consistent, so a reservation
    # we just won may not show up yet, and raising the count would over-reserve.
    if [[ "$have" =~ ^[0-9]+$ ]] && (( TARGET - have < REMAINING )); then
      log "reconcile: AWS says this run holds $have, adjusting remaining $REMAINING -> $((TARGET - have))"
      REMAINING=$(( TARGET - have ))
      (( REMAINING <= 0 )) && { [[ -z "$T_FULL" ]] && T_FULL=$(( $(date +%s) - START )); break; }
    fi
  fi
  for t in "${TYPE_LIST[@]}"; do
    [[ -z "${OFFERED[$t]:-}" ]] && continue
    for z in ${OFFERED[$t]}; do
      (( REMAINING <= 0 )) && break 2
      c=$REMAINING
      floor=$(( REMAINING < MIN_CHUNK ? REMAINING : MIN_CHUNK ))   # last few may be fewer than MIN_CHUNK
      while (( c >= floor )); do
        try_reserve "$t" "$z" "$c"; r=$?
        if [[ $r -eq 0 ]]; then
          REMAINING=$((REMAINING - c)); won=1; N_WIN=$((N_WIN+1))
          [[ -z "$T_FIRST" ]] && T_FIRST=$(( $(date +%s) - START ))
          (( REMAINING <= 0 )) && T_FULL=$(( $(date +%s) - START ))
          GOT+=("$LAST_ID $t $z x$c")
          log "GOT $c x $t in $z ($LAST_ID). remaining=$REMAINING"
          notify "got $c x $t" "Reserved $c x $t in $z ($LAST_ID). Remaining: $REMAINING of $TARGET."
          break
        elif [[ $r -eq 2 ]]; then
          notify "stopped ($LAST_ERR)" "Stopped with an error, see $LOG. Got so far: ${GOT[*]:-none}"
          exit 3
        elif [[ $r -eq 3 ]]; then
          break 3      # throttled or unclear: no more requests this round
        fi
        (( c == floor )) && break
        c=$((c / 2)); (( c < floor )) && c=$floor
      done
    done
  done
  (( REMAINING <= 0 )) && break
  if (( MAX_HOURS > 0 )) && (( $(date +%s) - START > MAX_HOURS * 3600 )); then
    log "time limit reached. still missing $REMAINING"; notify "time limit" "Missing $REMAINING of $TARGET. Got: ${GOT[*]:-none}"
    exit 4
  fi
  if (( won )); then WAIT=$INTERVAL; else WAIT=$(( WAIT * 3 / 2 )); (( WAIT > MAX_INTERVAL )) && WAIT=$MAX_INTERVAL; fi
  (( N_THROTTLE > THROTTLE_SEEN )) && { WAIT=$MAX_INTERVAL; log "API throttling seen, waiting the max interval"; }
  THROTTLE_SEEN=$N_THROTTLE
  sleep_s=$(( WAIT + RANDOM % (WAIT / 3 + 1) ))
  log "round $ROUND: no more capacity now, remaining=$REMAINING, next try in ${sleep_s}s"
  sleep "$sleep_s"
done
# All counted. Before saying DONE, wait for 'pending' wins to settle (a pending one can still fail).
waited=0
while (( ${#PENDING[@]} > 0 && waited < PENDING_MAX )); do
  log "waiting for ${#PENDING[@]} pending reservation(s) to become active (${waited}s so far)"
  sleep "$PENDING_POLL"; waited=$((waited + PENDING_POLL)); check_pending
  (( REMAINING > 0 )) && break
done
(( REMAINING > 0 )) && { log "back to hunting: remaining=$REMAINING"; continue; }
(( ${#PENDING[@]} > 0 )) && log "WARN: ${#PENDING[@]} reservation(s) still 'pending' after ${PENDING_MAX}s; counted as won, check with --status"
break
done

log "DONE: reserved $TARGET. ${GOT[*]}"
notify "done" "All $TARGET reserved: ${GOT[*]}"
