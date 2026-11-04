#!/usr/bin/env bash
# 컷오버·롤백 결과 표 echo_ops.cutover_runs 를 A·B 양쪽에 만들고 echo_monitor 에 읽기 권한을 준다(인프라 7.2, echo-infra#57).
# 이미 있으면 그대로 두고, 켜진 구독 중 이 표가 빠진 것만 REFRESH PUBLICATION 한다. 여러 번 돌려도 같다.
# cutover.sh·rollback.sh·subscribe.sh 도 시작할 때 같은 함수(ops_table_ensure)를 부르므로 A 를 새로 세워도 다시 생긴다.
# 사용: replication/k8s/scripts/ops-table.sh
source "$(dirname "$0")/common.sh"
ops_table_ensure
for side in A B; do
  printf '%s: ' "$side"
  pg "$side" -c "SELECT 'echo_ops.cutover_runs ' || count(*) || '행, echo_monitor 읽기=' || has_table_privilege('echo_monitor', 'echo_ops.cutover_runs', 'SELECT') FROM echo_ops.cutover_runs;"
done
