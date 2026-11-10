#!/usr/bin/env bash
# report.sh - summarise a gpu-hunter events CSV, to judge how well a run did.
# Usage: tools/report.sh [gpu-hunter-events.csv]
# Columns: time_utc,elapsed_s,round,type,az,count,result,api_ms
set -uo pipefail
f="${1:-./gpu-hunter-events.csv}"
[[ -s "$f" ]] || { echo "no events file: $f"; exit 1; }
awk -F, 'NR==1{next}
{
  k=$4" "$5; tries[k]++; ms[k]+=$8; all_ms[++n]=$8; last=$2; rounds=($3>rounds?$3:rounds)
  if ($7 ~ /^won/) { wins[k]++; got+=$6; if (first=="") first=$2; full=$2 }
  else res[$7]++
}
END{
  printf "attempts=%d rounds=%d run_length=%ss first_win=%ss last_win=%ss instances_won=%d\n", n, rounds, last, (first==""?"-":first), (full==""?"-":full), got
  printf "\n%-24s %8s %6s %9s %10s\n","type az","attempts","wins","win_rate","avg_api_ms"
  for (k in tries) printf "%-24s %8d %6d %8.1f%% %10d\n", k, tries[k], wins[k]+0, 100*(wins[k]+0)/tries[k], ms[k]/tries[k]
  printf "\nnon-win results:"; for (r in res) printf " %s=%d", r, res[r]; print ""
  # median API latency
  for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (all_ms[j]<all_ms[i]) {t=all_ms[i];all_ms[i]=all_ms[j];all_ms[j]=t}
  p90=int(n*0.9); if (p90<n*0.9) p90++; if (p90<1) p90=1   # nearest-rank
  printf "api_ms median=%d p90=%d\n", all_ms[int((n+1)/2)], all_ms[p90]
}' "$f"
