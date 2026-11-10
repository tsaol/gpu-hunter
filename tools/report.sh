#!/usr/bin/env bash
# report.sh - summarise one gpu-hunter events CSV, to judge how well a run did.
# Usage: tools/report.sh [events.csv]   (default: the newest ./gpu-hunter-events-*.csv)
# Columns: time_utc,elapsed_s,round,type,az,count,result,api_ms
set -uo pipefail
f="${1:-$(ls -t ./gpu-hunter-events-*.csv 2>/dev/null | head -1)}"
[[ -n "$f" && -s "$f" ]] || { echo "no events file found (looked for ${1:-./gpu-hunter-events-*.csv})"; exit 1; }
echo "file: $f"
awk -F, 'NR==1{next}
{
  k=$4" "$5; tries[k]++; ms[k]+=$8; n++; last=$2; rounds=($3>rounds?$3:rounds)
  if ($7 ~ /^won/) { wins[k]++; got+=$6; if (first=="") first=$2; full=$2 }
  else res[$7]++
}
END{
  printf "attempts=%d rounds=%d run_length=%ss first_win=%ss last_win=%ss instances_won=%d\n", n, rounds, last, (first==""?"-":first), (full==""?"-":full), got
  printf "\n%-24s %8s %6s %9s %10s\n","type az","attempts","wins","win_rate","avg_api_ms"
  for (k in tries) printf "%-24s %8d %6d %8.1f%% %10d\n", k, tries[k], wins[k]+0, 100*(wins[k]+0)/tries[k], ms[k]/tries[k]
  printf "\nnon-win results:"; for (r in res) printf " %s=%d", r, res[r]; print ""
}' "$f"
# latency percentiles (nearest rank), sorted with sort -n so big files stay fast
tail -n +2 "$f" | cut -d, -f8 | sort -n | awk '{a[NR]=$1} END{ if(NR){ m=int((NR+1)/2); p=int(NR*0.9); if(p<NR*0.9)p++; if(p<1)p=1; printf "api_ms median=%d p90=%d\n", a[m], a[p] } }'
