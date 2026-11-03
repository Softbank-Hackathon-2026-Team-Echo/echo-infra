# A Postgres TLS (cross-cloud 전송 암호화)

B(서울)가 인터넷을 건너 A 에 붙으므로 `ssl=on` 이 필요하다. 자체 서명 인증서(검증 없음, `sslmode=require`) — 해커톤 범위. 적용은 사람이:

```bash
# 1) 인증서 Secret (1년). 값은 저장소에 두지 않는다.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=echo-pg-a" -keyout /tmp/pg.key -out /tmp/pg.crt
kubectl --context echo-dev-eks -n echo-data create secret tls echo-pg-tls --cert=/tmp/pg.crt --key=/tmp/pg.key
rm -f /tmp/pg.key /tmp/pg.crt

# 2) StatefulSet 에 ssl 인자·마운트 추가 (10-postgres.yaml 의 TLS 블록, 아래 패치) → 롤링 재시작 1회
kubectl --context echo-dev-eks -n echo-data patch statefulset echo-pg --type json -p "$(cat replication/k8s/aws-tokyo/tls-patch.json)"
kubectl --context echo-dev-eks -n echo-data rollout status statefulset/echo-pg
```

확인: `kubectl -n echo-data exec echo-pg-0 -- psql -U postgres -d app -tAc "SHOW ssl;"` → `on`.
