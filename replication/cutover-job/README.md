# 컷오버 Job (인프라 12.2, echo-infra#67)

`cutover.sh`·`rollback.sh`·`promote.sh` 를 운영자 노트북 대신 **서울 GKE `echo-ops` 네임스페이스의 Job** 으로 돌린다. echo-was 는 Job 을 만들고 상태·로그만 읽는다(echo-was#75). DB 권한은 이 Job 의 전용 신원에만 있다.

```text
echo-was 일꾼 ──Job 생성(PLAN_ID·KIND·ALLOW_PROMOTE)──▶ echo-ops/echo-cutover-<계획8>-<시도>
                                                          │  cutover-entry: kubeconfig 두 개
                                                          │   B = in-cluster SA 토큰
                                                          │   A = GKE 메타데이터 Google ID 토큰 → AWS STS(cutover 역할) → EKS 토큰
                                                          │  A·B 주소 = 각 클러스터 Service echo-pg-external
                                                          ▼
                                    A·B echo-data: kubectl exec (Role echo-cutover) → 스크립트 그대로
```

| 파일 | 무엇 |
|---|---|
| `Dockerfile`, `cutover-entry.sh` | 이미지: `amazon/aws-cli:2.39.4` + kubectl `v1.36.6`(sha256 확인) + `replication/k8s/scripts`. 사용자 65532 |
| `manifests/echo-data-rbac.yaml` | A·B 둘 다: `echo-data` Role (pods get·list, pods/exec, PgBouncer Deployment get, Service `echo-pg-external` get, ConfigMap `echo-pgbouncer-ini` get·patch). **secrets 없음** |
| `manifests/gke-binding.yaml` | B: Role ↔ KSA `echo-ops/echo-cutover` |
| `manifests/eks-binding.yaml` | A: Role ↔ 그룹 `echo-cutover`(Terraform access entry) |
| `manifests/echo-ops.yaml` | B: 네임스페이스·KSA·echo-was 의 Job 권한·**VAP**(Job·Pod 모양 고정) |
| `job.example.yaml` | 사람이 직접 돌릴 때의 Job 한 개 |
| `tests/policy-test.sh` | k3s(Docker)에서 RBAC `can-i` 와 VAP 허용·거부 시험 (보안 #24 근거) |

## 지키는 것 (보안 #24, 김형래 11/5 리뷰)

1. 컷오버 신원은 A·B 모두 `echo-data` 만, secrets 읽기 없음. `pods/exec` 는 `echo-data` 전체(PgBouncer 가 Deployment 라 파드 이름이 바뀌고 `resourceNames` 는 와일드카드를 받지 않음)
2. AWS 는 cutover 전용 IAM 역할(신뢰 = cutover GSA 만, `terraform/environments/aws/dev/cutover.tf`) + access entry 는 그룹 `echo-cutover` 만(클러스터 정책 없음)
3. VAP 가 Job·Pod 모양 전체를 고정: SA `echo-cutover`, 컨테이너 1개(init·ephemeral 없음), 이미지 = 고정 digest, command·args 덮어쓰기 금지, 환경 변수는 `PLAN_ID`(uuid)·`KIND`(cutover·rollback·promote)·`ALLOW_PROMOTE`(true·false) 값만, 볼륨은 SA 토큰만, host 네임스페이스·privileged 금지
4. 로그에 토큰·자격 증명·접속 문자열을 찍지 않는다(`set -x` 없음, 토큰은 파일·변수로만)

알려진 차이: echo-was 관제탑 GSA 는 지금 프로젝트 단위 `container.developer`, EKS 실행기 역할은 `AmazonEKSClusterAdminPolicy` 라 **echo-was 신원으로도 `echo-data` exec 가 된다.** 마감 전에 줄이면 배포가 깨질 위험이 커서 #24 후속(마감 뒤)으로 둔다. 그때까지 실제 경계는 위 VAP 다.

## Job 이 죽을 때 (서동옥 11/5 리뷰)

- `activeDeadlineSeconds`(120초)·파드 종료로 **SIGTERM** 이 오면 스크립트가 받는다(`exec` 로 PID 1). 쓰기 정지 중이면 양쪽 RESUME 후 종료 1, 전환 도중이면 RESUME 하지 않고 종료 2(복제되지 않는 쪽에 쓰기가 쌓이지 않게) → `replication/k8s/README.md` "부분 상태 복구"
- SIGKILL·노드 유실은 잡을 수 없다. echo-was 는 Job 이 실패·사라지면 쓰기 담당을 다시 확인하고 사람을 부른다(echo-was#75)

## 적용 (사람이, 인프라 담당 확인 뒤)

```bash
# 0) Terraform: GCP 를 먼저(컷오버 GSA), 그 출력으로 AWS(cutover 역할·access entry)
terraform -chdir=terraform/environments/gcp/dev apply          # → cutover_service_account, cutover_service_account_unique_id
#   aws/dev terraform.tfvars 에 cutover_google_service_account_id = "<위 unique_id>"
terraform -chdir=terraform/environments/aws/dev apply          # → cutover_role_arn

# 1) 이미지: 빌드 → Artifact Registry push → digest 확인
AR=asia-northeast3-docker.pkg.dev/<project>/echo
docker build -f replication/cutover-job/Dockerfile --build-arg AWS_ROLE_ARN=<cutover_role_arn> -t $AR/cutover:<git-sha> replication
docker push $AR/cutover:<git-sha>
IMG=$(gcloud artifacts docker images describe $AR/cutover:<git-sha> --format='value(image_summary.fully_qualified_digest)')

# 2) B(GKE): Role → echo-ops(네임스페이스·KSA·VAP) → 바인딩
kubectl --context <GKE> apply -f replication/cutover-job/manifests/echo-data-rbac.yaml
sed -e "s|__CUTOVER_GSA__|<cutover_service_account>|" -e "s|__CUTOVER_IMAGE__|$IMG|" replication/cutover-job/manifests/echo-ops.yaml | kubectl --context <GKE> apply -f -
kubectl --context <GKE> apply -f replication/cutover-job/manifests/gke-binding.yaml

# 3) A(EKS): Role → 그룹 바인딩
kubectl --context <EKS> apply -f replication/cutover-job/manifests/echo-data-rbac.yaml
kubectl --context <EKS> apply -f replication/cutover-job/manifests/eks-binding.yaml

# 4) 확인 (README 표의 can-i 를 운영에서도): 
kubectl --context <GKE> auth can-i create pods --subresource=exec -n echo-data --as=system:serviceaccount:echo-ops:echo-cutover   # yes
kubectl --context <GKE> auth can-i get secrets -n echo-data --as=system:serviceaccount:echo-ops:echo-cutover                     # no
```

이미지를 다시 빌드하면 digest 가 바뀐다 → `echo-ops.yaml` 을 새 digest 로 다시 적용해야 Job 이 허용된다(VAP).

## 시험

`bash replication/cutover-job/tests/policy-test.sh` — k3s `v1.36.5-k3s1`(온프레와 같은 버전)에 매니페스트를 그대로 적용한다. **38개 통과 · 실패 0** (11/5).

| 대상 | 확인 |
|---|---|
| 컷오버 KSA (GKE) | echo-data exec·pods get·ConfigMap `echo-pgbouncer-ini` patch·Service get **yes** / 다른 ConfigMap·secrets get·list·다른 네임스페이스 exec·pods delete·jobs create **no** |
| 그룹 echo-cutover (EKS) | echo-data exec **yes** / secrets·kube-system exec·nodes **no** |
| echo-was KSA | echo-ops jobs create·pods/log **yes** / pods create·jobs delete **no** |
| VAP 허용 | 정상 Job(cutover), promote + ALLOW_PROMOTE=true, Job 컨트롤러가 만든 Pod(SA 토큰 볼륨) |
| VAP 거부 | 다른 이미지·태그 이미지·다른 SA·환경 변수 추가·KIND/ALLOW_PROMOTE/PLAN_ID 형식·command 덮어쓰기·envFrom·valueFrom·hostPath·initContainer·privileged·hostNetwork, 클러스터 관리자가 만든 다른 이미지 Job |
