#!/usr/bin/env bash
# grab-gpu.sh - keep trying to reserve On-Demand GPU capacity (ODCR) until the target is met.
#
# How it works:
#   - Tries each instance type (in your order) in each AZ where it is offered.
#   - Asks for all remaining instances; if AWS says InsufficientInstanceCapacity,
#     it halves the count and tries again (down to MIN_CHUNK).
#   - Every reservation it gets is kept and tagged, so you never lose what you won.
#   - Waits longer after each failed round (backoff + jitter), resets after a win.
#   - Stops at once on quota / permission / parameter errors (retrying won't help).
#
# Usage:
#   ./grab-gpu.sh -t g6e.12xlarge,g6e.24xlarge -n 4            # grab 4 instances
#   ./grab-gpu.sh -t p4d.24xlarge -n 2 -z eu-central-1a,eu-central-1b -s arn:aws:sns:...
#   ./grab-gpu.sh -t g6.xlarge -n 2 --dry-run                   # test, creates nothing
#   ./grab-gpu.sh --status                                      # list what we hold
#   ./grab-gpu.sh --release                                     # cancel all our reservations
#
# Billing: an ODCR is billed at On-Demand price from the moment it is active,
# even if no instance runs in it. Cancel with --release when you no longer need it.

set -uo pipefail

REGION="${GRAB_REGION:-eu-central-1}"   # use -r to change
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
TAG="grab-gpu"
DRY_RUN=0
MODE="grab"
LOG="${GRAB_LOG:-./grab-gpu.log}"

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
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
    --subject "grab-gpu: $1" --message "$2" >/dev/null 2>&1 || log "WARN: SNS publish failed"
}

our_reservations() {
  aws ec2 describe-capacity-reservations --region "$REGION" \
    --filters "Name=tag:grab-gpu,Values=$TAG" "Name=state,Values=active,pending" \
    --query 'CapacityReservations[].[CapacityReservationId,InstanceType,AvailabilityZone,TotalInstanceCount,AvailableInstanceCount,State]' \
    --output text
}

if [[ "$MODE" == "status" ]]; then
  echo "Reservations tagged grab-gpu=$TAG in $REGION (id type az total free state):"
  our_reservations
  exit 0
fi

if [[ "$MODE" == "release" ]]; then
  ids=$(our_reservations | awk '{print $1}')
  [[ -z "$ids" ]] && { echo "nothing to release"; exit 0; }
  for id in $ids; do
    if aws ec2 cancel-capacity-reservation --region "$REGION" --capacity-reservation-id "$id" >/dev/null; then
      log "released $id"
    else
      log "ERROR: could not release $id"
    fi
  done
  exit 0
fi

[[ -z "$TYPES" ]] && { echo "need -t <types>"; usage 1; }
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

REMAINING=$TARGET
WAIT=$INTERVAL
START=$(date +%s)
ROUND=0
GOT=()

# try_reserve TYPE AZ COUNT -> 0 ok, 1 no capacity (retry later), 2 fatal
try_reserve() {
  local t="$1" z="$2" c="$3" out rc
  local args=(ec2 create-capacity-reservation --region "$REGION" --instance-type "$t"
              --instance-platform "$PLATFORM" --availability-zone "$z" --instance-count "$c"
              --instance-match-criteria "$MATCH" --end-date-type unlimited
              --tag-specifications "ResourceType=capacity-reservation,Tags=[{Key=grab-gpu,Value=$TAG}]"
              --query 'CapacityReservation.CapacityReservationId' --output text)
  [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
  out=$(aws "${args[@]}" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    LAST_ID="$out"; return 0
  fi
  case "$out" in
    *DryRunOperation*) LAST_ID="dry-run"; return 0;;
    *InsufficientInstanceCapacity*|*InsufficientCapacity*|*Unavailable*|*RequestLimitExceeded*|*Throttling*|*InternalError*)
      return 1;;
    *InstanceLimitExceeded*|*ReservationCapacityExceeded*|*VcpuLimitExceeded*|*exceed*quota*|*LimitExceeded*)
      log "FATAL quota: $out"; LAST_ERR="quota"; return 2;;
    *)
      log "FATAL: $out"; LAST_ERR="other"; return 2;;
  esac
}

log "start: target=$TARGET types=$TYPES region=$REGION match=$MATCH dry_run=$DRY_RUN"
while (( REMAINING > 0 )); do
  ROUND=$((ROUND+1))
  won=0
  for t in "${TYPE_LIST[@]}"; do
    [[ -z "${OFFERED[$t]:-}" ]] && continue
    for z in ${OFFERED[$t]}; do
      (( REMAINING <= 0 )) && break 2
      c=$REMAINING
      while (( c >= MIN_CHUNK )); do
        try_reserve "$t" "$z" "$c"; r=$?
        if [[ $r -eq 0 ]]; then
          REMAINING=$((REMAINING - c)); won=1
          GOT+=("$LAST_ID $t $z x$c")
          log "GOT $c x $t in $z ($LAST_ID). remaining=$REMAINING"
          notify "got $c x $t" "Reserved $c x $t in $z ($LAST_ID). Remaining: $REMAINING of $TARGET."
          break
        elif [[ $r -eq 2 ]]; then
          notify "stopped ($LAST_ERR)" "Stopped with an error, see $LOG. Got so far: ${GOT[*]:-none}"
          exit 3
        fi
        c=$((c / 2))
      done
    done
  done
  (( REMAINING <= 0 )) && break
  if (( MAX_HOURS > 0 )) && (( $(date +%s) - START > MAX_HOURS * 3600 )); then
    log "time limit reached. still missing $REMAINING"; notify "time limit" "Missing $REMAINING of $TARGET. Got: ${GOT[*]:-none}"
    exit 4
  fi
  if (( won )); then WAIT=$INTERVAL; else WAIT=$(( WAIT * 3 / 2 )); (( WAIT > MAX_INTERVAL )) && WAIT=$MAX_INTERVAL; fi
  sleep_s=$(( WAIT + RANDOM % (WAIT / 3 + 1) ))
  log "round $ROUND: no more capacity now, remaining=$REMAINING, next try in ${sleep_s}s"
  sleep "$sleep_s"
done

log "DONE: reserved $TARGET. ${GOT[*]}"
notify "done" "All $TARGET reserved: ${GOT[*]}"
