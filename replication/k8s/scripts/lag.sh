#!/usr/bin/env bash
# 복제 지연 읽기. 정방향(A→B)이면 A 의 pg_stat_replication, 역방향이면 B 의 것. echo-was DataSyncChecker 가 같은 질의를 쓰면 된다.
source "$(dirname "$0")/common.sh"
for side in A B; do
  echo "== $side (publisher 관점: 붙어 있는 구독자와 지연) =="
  pg $side -c "SELECT application_name, state, COALESCE(EXTRACT(EPOCH FROM replay_lag),0) AS replay_lag_s, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind FROM pg_stat_replication;" || true
  echo "== $side (subscriber 관점) =="
  pg $side -c "SELECT subname, pid IS NOT NULL AS running, latest_end_time FROM pg_stat_subscription;" || true
done
