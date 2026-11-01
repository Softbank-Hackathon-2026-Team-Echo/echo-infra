# 인프라 용어 사전

- **기준**: 팀 용어 사전은 echo-was 의 [`.claude/rules/term-dictionary.md`](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-was/blob/main/.claude/rules/term-dictionary.md) 하나다. 여기에는 **인프라 파트가 더하는 용어만** 둔다. 충돌하면 echo-was 쪽을 따른다.
- **근거**: 본선 원장 `final_features_v6.md`(F1~F17, NFR)

## echo-was 와 맞닿는 용어

| 한국어 | 표준 영문 | 이 저장소에서 | 근거 |
|---|---|---|---|
| 환경 | Environment | 배포 대상 클러스터 하나. AWS 는 EKS 클러스터 | F2 |
| 환경 종류 | Environment kind | `aws`·`gcp`·`onprem` | F2, NFR-15 |
| aws 환경 설정 | AwsEnvironmentConfig | `region`(`ap-northeast-2`), `cluster_name` → Terraform 출력값 `region`·`eks_cluster_name` | F2 |
| 비밀 참조 | secretRef | `aws-sm:<이름|ARN>` = Secrets Manager | NFR-17 |

## 인프라 파트 용어

| 한국어 | 표준 영문 | 식별자 | 뜻 | 근거 |
|---|---|---|---|---|
| 상태 저장소 | State bucket | `echo-tfstate-<account_id>` | Terraform state 를 두는 S3 버킷 | NFR-16 |
| 비용 알림 | Budget alert | `aws_budgets_budget` | 비용 상한 알림 | NFR-13 |
| 재구축 | Rebuild | `make up` / `make down` | 환경 하나를 명령 2개 이내로 다시 세우기 | NFR-16 |
