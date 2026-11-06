# 시연용 합성 트래픽 (loadgen)

진입점(Envoy)으로 **초당 50건**을 고르게 보내는 k6 디플로이먼트. 판정이 "요청 N건 처리 확인"(건수 기반)으로 바뀌어서, 요청이 흘러야 단계가 넘어간다. 설계 문서에는 "시연용 합성 트래픽"이라고 밝힌다.

- **어디서**: GKE `echo-dev-gke`(서울) 네임스페이스 `echo-loadgen`. Cloud NAT(`<GCP_NAT_IP>`)를 거쳐 진입점 **공인 주소** 80 으로 간다 → 도쿄 재난 장면에서도 끊기지 않고, 고객과 같은 경로를 탄다.
- **평소 0 개**. 시연 때만 1 개로 올린다. 초당 50 건은 e2-standard-2 노드 한 칸(100m CPU)으로 충분하다.

```sh
make loadgen-apply                 # 처음 한 번 (네임스페이스·스크립트·설정)
make loadgen-on                    # 시작 (replicas 1)
make loadgen-off                   # 끝 (replicas 0)
kubectl -n echo-loadgen logs deploy/loadgen -f        # 60초마다 요약: http_reqs(초당), http_req_failed(실패율), 지연
kubectl -n echo-loadgen set env deploy/loadgen RATE=100   # 속도 바꾸기 (재시작됨)
```

설정은 `kustomization.yaml` 의 `loadgen-config`: `TARGET_URL`(진입점 공인 주소) · `TARGET_HOST`(시연 앱 고정 주소, 진입점 뒤 인그레스가 Host 로 앱을 고른다) · `TARGET_PATH` · `RATE`. 바꾸면 `make loadgen-apply` 다시.

확인은 진입점 쪽에서: 가중치 API `GET /counters`(환경별 누적 요청·오류) 또는 Grafana(요청 수·5xx·p95). `kubectl` 은 `gcloud container clusters get-credentials echo-dev-gke --zone asia-northeast3-a` 로 붙는다 (`gke-gcloud-auth-plugin` 필요).
