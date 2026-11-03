#!/usr/bin/env bash
# 컷오버(A→B) 후 역방향 복제 B→A 를 세운다. A 를 warm standby 로 유지해 롤백에 대비한다(#8).
#
# 재동기화 선행: A 는 컷오버 전 데이터(1..N)만 있고 B 는 그 뒤로 더 썼으므로,
# A 를 비우고(TRUNCATE) B 를 copy_data=true 로 다시 받아 B 의 복제본으로 만든다.
# (SPEC §2 "재난 때는 A 가 죽어 역방향 복제가 끊기므로, A 복구 후 재동기화가 선행된다")
set -euo pipefail
cd "$(dirname "$0")/.."

A(){ docker compose exec -T pg_a psql -tAq -U postgres -d app -c "$1"; }
B(){ docker compose exec -T pg_b psql -tAq -U postgres -d app -c "$1"; }

echo "[rev-1] 정방향 객체 정리 (B 의 구독·A 의 발행 제거)"
B "DROP SUBSCRIPTION IF EXISTS sub_demo;" >/dev/null     # A 의 정방향 슬롯도 함께 제거
A "DROP PUBLICATION IF EXISTS pub_demo;" >/dev/null

echo "[rev-2] B 에 역방향 발행 생성 (pub_rev)"
B "CREATE PUBLICATION pub_rev FOR TABLE demo.seq_write;" >/dev/null

echo "[rev-3] A 비우고 B 재동기화 (copy_data=true)"
A "TRUNCATE demo.seq_write;" >/dev/null
A "CREATE SUBSCRIPTION sub_rev CONNECTION 'host=pg_b port=5432 dbname=app user=postgres' PUBLICATION pub_rev WITH (copy_data=true);" >/dev/null

echo "[rev-4] 초기 복사 완료 대기 (sub_rev 상태 = r)"
# 쓰기가 계속되면 max(n) 은 움직이는 값이라 == 비교가 어긋난다. 구독 동기화 상태(r=ready)로 기다린다.
until [ "$(A "SELECT COALESCE(string_agg(srsubstate,','),'') FROM pg_subscription_rel r JOIN pg_subscription s ON s.oid=r.srsubid WHERE s.subname='sub_rev';")" = "r" ]; do sleep 0.1; done
echo "[rev] 완료. 역방향 복제 B→A 가동 (A max(n)=$(A "SELECT COALESCE(max(n),0) FROM demo.seq_write;")). A 는 이제 warm standby."
echo "      다음: 쓰기를 더 흘린 뒤 scripts/rollback.sh 로 A 로 복귀."
