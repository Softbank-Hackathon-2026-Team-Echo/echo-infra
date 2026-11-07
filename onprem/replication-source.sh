#!/usr/bin/env bash
# 온프레 PG(echo-demo/demo-db) 를 논리 복제 출발점으로 준비한다 (인프라 18). 온프레 기기에서 root 로 실행. 다시 돌려도 같은 결과.
# 11/7 echo-onprem-demo 에 이 스크립트로 적용했다. 매니페스트(demo-app.yaml)는 바꾸지 않고 StatefulSet 을 patch 한다(TLS Secret 이 없는 새 설치를 깨지 않게).
# 1) TLS Secret  2) 복제 계정·발행  3) pg_hba  4) StatefulSet: ssl=on + max_slot_wal_keep_size (재시작 1회)  5) 5432 LB 서비스
# 비밀값은 출력하지 않는다. StatefulSet 이 120초 안에 Ready 가 안 되면 원래 정의로 되돌린다.
set -euo pipefail
K="k3s kubectl -n echo-demo"
TS=$(date +%Y%m%d%H%M%S)
$K get sts demo-db -o yaml > /root/demo-db-sts-backup-$TS.yaml
echo "[0] 백업 /root/demo-db-sts-backup-$TS.yaml"

# 1) TLS (자체 서명, 키는 이 호스트 밖으로 나가지 않는다)
if ! $K get secret demo-db-tls >/dev/null 2>&1; then
  d=$(mktemp -d); openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=echo-onprem-pg" \
    -keyout $d/tls.key -out $d/tls.crt 2>/dev/null
  $K create secret tls demo-db-tls --cert=$d/tls.crt --key=$d/tls.key >/dev/null; rm -rf "$d"
fi
echo "[1] TLS Secret demo-db-tls 있음"

# 2) 복제 계정 비밀번호 (Secret demo-db-repl, 처음 한 번만)
if ! $K get secret demo-db-repl >/dev/null 2>&1; then
  openssl rand -hex 24 | tr -d '\n' > /root/.repl_pw; chmod 600 /root/.repl_pw
  $K create secret generic demo-db-repl --from-file=password=/root/.repl_pw >/dev/null; rm -f /root/.repl_pw
fi
PW=$($K get secret demo-db-repl -o jsonpath='{.data.password}' | base64 -d)
{ printf "SET client_min_messages=warning;\n"
  printf "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='repl_onprem') THEN CREATE ROLE repl_onprem LOGIN REPLICATION; END IF; END\$\$;\n"
  printf "ALTER ROLE repl_onprem PASSWORD '%s';\n" "$PW"
  printf "GRANT pg_read_all_data TO repl_onprem;\n"
  printf "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname='echo_onprem_pub') THEN CREATE PUBLICATION echo_onprem_pub FOR ALL TABLES; END IF; END\$\$;\n"
} | $K exec -i demo-db-0 -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -U demo -d demo
unset PW
echo "[2] 복제 계정 repl_onprem, 발행 echo_onprem_pub"

# 3) pg_hba: 복제 계정은 TLS 로만 (맨 앞에 넣는다, 이미 있으면 건너뜀)
$K exec -i demo-db-0 -c postgres -- sh -c '
  f=$PGDATA/pg_hba.conf
  grep -q "repl_onprem" "$f" || { cp "$f" "$f.bak"; { echo "hostnossl all repl_onprem all reject"; echo "hostssl demo repl_onprem all scram-sha-256"; cat "$f.bak"; } > "$f"; }
  grep repl_onprem "$f"'
echo "[3] pg_hba 반영 (재시작 때 읽힘)"

# 4) StatefulSet: TLS·WAL 상한 (도쿄 A 와 같은 마운트 방식: fsGroup 999 + 0600)
cur=$($K get sts demo-db -o jsonpath='{.spec.template.spec.containers[0].args}')
if echo "$cur" | grep -q "ssl=on"; then
  echo "[4] 이미 ssl=on, 재시작 생략"
else
  $K patch sts demo-db --type json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-c","wal_level=logical","-c","ssl=on","-c","ssl_cert_file=/etc/postgresql/tls/tls.crt","-c","ssl_key_file=/etc/postgresql/tls/tls.key","-c","max_slot_wal_keep_size=2GB"]},
    {"op":"add","path":"/spec/template/spec/securityContext","value":{"fsGroup":999}},
    {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"tls","secret":{"secretName":"demo-db-tls","defaultMode":384}}]},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"tls","mountPath":"/etc/postgresql/tls","readOnly":true}}
  ]' >/dev/null
  $K delete pod demo-db-0 --wait=false >/dev/null 2>&1 || true
  if ! $K rollout status sts/demo-db --timeout=120s; then
    echo "[4] 실패 → 되돌림"; $K logs demo-db-0 -c postgres --tail=20 || true
    $K replace -f /root/demo-db-sts-backup-$TS.yaml >/dev/null; $K delete pod demo-db-0 --wait=false >/dev/null
    $K rollout status sts/demo-db --timeout=120s; exit 1
  fi
  echo "[4] 재시작 완료"
fi

# 5) 5432 를 호스트로 노출 (k3s ServiceLB). 보안 그룹이 닫혀 있어 아직 밖에서는 닿지 않는다.
if ! $K get svc demo-db-external >/dev/null 2>&1; then
  cat <<'YAML' | $K apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: { name: demo-db-external, namespace: echo-demo }
spec:
  type: LoadBalancer
  selector: { app: demo-db }
  ports: [ { name: postgres, port: 5432, targetPort: 5432 } ]
YAML
fi
sleep 5
echo "[5] 서비스"; $K get svc demo-db-external --no-headers
k3s kubectl -n kube-system get pods --no-headers | grep svclb-demo-db || echo "(svclb 파드 없음)"

echo "=== 검증"
$K exec -i demo-db-0 -c postgres -- psql -X -U demo -d demo -At <<'SQL'
SELECT 'ssl='||current_setting('ssl'), 'max_slot_wal_keep_size='||current_setting('max_slot_wal_keep_size'), 'wal_level='||current_setting('wal_level');
SELECT 'pub='||pubname||' all_tables='||puballtables FROM pg_publication;
SELECT 'role='||rolname||' repl='||rolreplication FROM pg_roles WHERE rolname='repl_onprem';
SELECT 'rows='||count(*) FROM demo.seq_write;
SQL
echo "[TLS 로그인 시험: 호스트 → 5432]"
PGPW=$($K get secret demo-db-repl -o jsonpath='{.data.password}' | base64 -d)
HIP=$(hostname -I | awk '{print $1}')
printf %s "$PGPW" | $K exec -i demo-db-0 -c postgres -- sh -c "PGPASSWORD=\$(cat) psql -X 'host=$HIP port=5432 dbname=demo user=repl_onprem sslmode=require' -Atc \"SELECT 'tls_login_ok ssl='||ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid();\"" 2>&1 | tail -1
echo "[평문 접속은 거부돼야 함]"
printf %s "$PGPW" | $K exec -i demo-db-0 -c postgres -- sh -c "PGPASSWORD=\$(cat) psql -X 'host=$HIP port=5432 dbname=demo user=repl_onprem sslmode=disable' -Atc 'SELECT 1'" 2>&1 | tail -1 || true  # 거부가 정상(종료 코드 2)
unset PGPW
for h in demo-onprem-y6cz3jrc.echoport.uk demo-onprem-3okaz96x.echoport.uk; do echo "$h readyz=$(curl -s -o /dev/null -w '%{http_code}' -m 5 https://$h/readyz)"; done
