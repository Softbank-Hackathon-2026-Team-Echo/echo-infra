# A Postgres TLS (cross-cloud 전송 암호화)

B(서울)가 인터넷을 건너 A 에 붙으므로 `ssl=on` 이 필요하다. 자체 서명 인증서(검증 없음, `sslmode=require`) — 해커톤 범위. `ssl` 인자와 마운트는 `10-postgres.yaml` 본문에 있다(11/4 패치를 본문에 합침). 손으로 만드는 것은 인증서 Secret 하나다.

```bash
# 인증서 Secret (1년). 값은 저장소에 두지 않는다. Secret 이 없으면 echo-pg 파드가 뜨지 않으므로 apply -k 보다 먼저.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=echo-pg-a" -keyout /tmp/pg.key -out /tmp/pg.crt
kubectl --context echo-dev-eks -n echo-data create secret tls echo-pg-tls --cert=/tmp/pg.crt --key=/tmp/pg.key
kubectl --context echo-dev-eks -n echo-data label secret echo-pg-tls echo/managed-by=dohyun-manual
rm -f /tmp/pg.key /tmp/pg.crt
```

- 확인: `kubectl -n echo-data exec echo-pg-0 -- psql -U postgres -d app -tAc "SHOW ssl;"` → `on`.
- **지금 인증서**: `CN=echo-pg-a`, 만료 **2027-11-04 01:36 UTC**(11/4 생성). 갱신은 Secret 을 바꾼 뒤 `kubectl -n echo-data rollout restart statefulset/echo-pg`(재시작 1회).
