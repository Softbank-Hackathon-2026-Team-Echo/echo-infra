#!/usr/bin/env bash
# 장부 대조: 누락(gap)·중복 0 인지, 양쪽 max(n) 이 같은지.
source "$(dirname "$0")/common.sh"
for side in A B; do
  printf '%s: ' "$side"
  pg $side -c "SELECT count(*) AS total, count(DISTINCT n) AS distinct_n, COALESCE(max(n),0) AS max_n, (COALESCE(max(n),0) - COALESCE(min(n),0) + 1) - count(DISTINCT n) AS missing, count(*) - count(DISTINCT n) AS duplicates FROM demo.seq_write;" 2>/dev/null || echo "(없음)"
done
