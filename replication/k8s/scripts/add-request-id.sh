#!/usr/bin/env bash
# 시연 앱 멱등 쓰기(echo-demo-app specs/infra-12.4-idempotent-writes.md)의 request_id 칸을 운영 두 DB 에 넣는다 (인프라 12.4).
# 논리 복제는 DDL 을 옮기지 않고, 구독 쪽에 없는 칸이 오면 구독이 멈춘다 → 지금 사본(구독하는 쪽)에 먼저, 원본에 나중에.
# 칸은 NULL 허용 + 부분 고유 색인이라 기존 행·지금 앱에는 영향이 없다. 여러 번 실행해도 안전(IF NOT EXISTS).
# 사용: replication/k8s/scripts/add-request-id.sh            넣고 확인
#       replication/k8s/scripts/add-request-id.sh --check    양쪽에 있는지만 확인(없으면 종료 1)
source "$(dirname "$0")/common.sh"

DDL="ALTER TABLE demo.seq_write ADD COLUMN IF NOT EXISTS request_id text;
CREATE UNIQUE INDEX IF NOT EXISTS seq_write_request_id_key ON demo.seq_write (request_id) WHERE request_id IS NOT NULL;"
has() { pg "$1" -c "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema='demo' AND table_name='seq_write' AND column_name='request_id')::int
  + (SELECT count(*) FROM pg_indexes WHERE schemaname='demo' AND indexname='seq_write_request_id_key')::int;"; }

if [[ ${1:-} == --check ]]; then
  a=$(has A) b=$(has B)
  echo "A: $([[ $a == 2 ]] && echo 있음 || echo 없음) · B: $([[ $b == 2 ]] && echo 있음 || echo 없음)"
  [[ $a == 2 && $b == 2 ]]; exit
fi

w=$(writer_side)
case $w in
  A) first=B second=A ;;   # 평소: B 가 A 를 구독 → B 먼저
  B) first=A second=B ;;   # 컷오버 뒤: A 가 B 를 구독 → A 먼저
  *) echo "[중단] 쓰기 담당을 판단할 수 없다: $w" >&2; exit 2 ;;
esac
for s in $first $second; do
  pg "$s" <<<"$DDL" >/dev/null
  [[ $(has "$s") == 2 ]] || { echo "[실패] $s 에 request_id 칸·색인이 없다" >&2; exit 1; }
  echo "넣음: $s (칸 + 부분 고유 색인)"
done
echo "구독 확인:"; pg "$first" -c "SELECT subname||' '||subenabled FROM pg_subscription;" | sed 's/^/  /'
