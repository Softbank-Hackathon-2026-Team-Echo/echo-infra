#!/usr/bin/env bash
# GCP(서울 B) 장애 시 온프레로 이전 (인프라 18 역방향).
# 평소: 온프레 PG 의 DB gcpcopy 가 서울 B 의 echo_pub 를 구독(echo_gcp_onprem_sub). 도쿄 A → 서울 B → 온프레로 이어진다.
# 온프레 메인 앱(demo-y6cz3jrc/app)은 평소 온프레 자체 DB(demo)를 본다.
#
#   prepare  : 앱용 Secret gcpcopy-env 를 기기 안에서 만든다(기존 DATABASE_URL 의 DB 이름만 gcpcopy 로). 비밀번호는 기기 밖으로 나오지 않는다
#   failover : 구독 끄기 → 시퀀스 +1000 → 앱이 gcpcopy 를 보게 env 덮기 → 재시작 → 요약 출력      (CONFIRM=yes)
#   back     : 앱 env 덮기를 지워 원래 DB(demo)로 → 구독 다시 켜기(밀린 변경을 받아 온다. 승격 뒤 쓴 행과 충돌할 수 있다)  (CONFIRM=yes)
#   status   : 구독·행 수·서울 B 와 비교
source "$(dirname "$0")/common.sh"
APP_NS=demo-y6cz3jrc
APP_HOST=${APP_HOST:-demo-onprem-y6cz3jrc.echoport.uk}
GSUB=echo_gcp_onprem_sub
# 시퀀스는 복제되지 않는다. 시퀀스는 demo.seq_write.id(identity) 하나뿐이다(11/7 확인, shop 표는 시퀀스 없음). promote.sh 와 같이 +1000.
SEQ_SQL="select setval(pg_get_serial_sequence('demo.seq_write','id'), (select coalesce(max(id),0) from demo.seq_write)+1000)"
SNAP="select 'seq_write '||count(*)||' max_n '||coalesce(max(n),0)||' md5 '||left(md5(coalesce(string_agg(t::text,'|' order by id),'')),12) from demo.seq_write t"

need_confirm() { [[ ${CONFIRM:-} == yes ]] || { echo "진행하려면 CONFIRM=yes $0 $1" >&2; exit 2; }; }

case "${1:-}" in
  prepare)
    onprem_sh <<EOF
set -e
U=\$(k3s kubectl -n $APP_NS get secret $APP_NS-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d)
case "\$U" in */demo) ;; *) echo "DATABASE_URL 이 /demo 로 끝나지 않는다. 멈춤"; exit 1;; esac
k3s kubectl -n $APP_NS create secret generic gcpcopy-env --from-literal=DATABASE_URL="\${U%/demo}/gcpcopy" --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
unset U; echo "Secret $APP_NS/gcpcopy-env 준비"
EOF
    ;;
  failover)
    need_confirm failover
    t0=$(date +%s.%N)
    onprem_sh <<EOF
set -e
P="k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -v ON_ERROR_STOP=1 -U demo -d gcpcopy"
\$P -c "select 'GCP 마지막 수신 '||coalesce(last_msg_receipt_time::text,'-') from pg_stat_subscription where subname='$GSUB'"
\$P -c "ALTER SUBSCRIPTION $GSUB DISABLE" >/dev/null
\$P -c "$SEQ_SQL" >/dev/null
\$P -c "$SNAP"
k3s kubectl -n $APP_NS set env deploy/app --from=secret/gcpcopy-env >/dev/null
k3s kubectl -n $APP_NS rollout status deploy/app --timeout=180s >/dev/null
echo "온프레 앱이 gcpcopy 로 전환됨"
EOF
    t1=$(date +%s.%N)
    echo "전환 걸린 시간: $(printf '%.1f' "$(echo "$t1-$t0" | bc -l)")s"
    curl -s -m 8 "https://$APP_HOST/api/writes/summary" | head -c 200; echo
    curl -s -m 8 -o /dev/null -w "쓰기 1건 %{http_code}\n" -X POST -H 'Content-Type: application/json' "https://$APP_HOST/api/writes" -d '{}'
    ;;
  back)
    need_confirm back
    onprem_sh <<EOF
set -e
k3s kubectl -n $APP_NS set env deploy/app DATABASE_URL- >/dev/null
k3s kubectl -n $APP_NS rollout status deploy/app --timeout=180s >/dev/null
k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d gcpcopy -c "ALTER SUBSCRIPTION $GSUB ENABLE" >/dev/null
echo "온프레 앱 원래 DB(demo)로, 구독 다시 켬"
EOF
    curl -s -m 8 "https://$APP_HOST/api/info"; echo
    ;;
  status)
    onprem_sh <<EOF
P="k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d gcpcopy"
\$P -c "select 'sub '||s.subenabled||' 수신 '||coalesce(now()-st.last_msg_receipt_time, null)::text from pg_subscription s left join pg_stat_subscription st on st.subid=s.oid where s.subname='$GSUB'"
\$P -c "select 'onprem gcpcopy '||($SNAP)"
EOF
    kubectl --context "$GCP_CTX" -n echo-data exec -i echo-pg-0 -c postgres -- psql -X -U postgres -d app -tA -c "select 'seoul B        '||($SNAP)"
    ;;
  *) echo "사용법: $0 prepare|failover|back|status" >&2; exit 2 ;;
esac
