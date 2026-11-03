# Replication 구축 제안

레퍼런스:

- https://www.lgcns.com/kr/moa/insight/detail.41298
- https://www.mongodb.com/ko-kr/docs/manual/replication/

- 작성자: 서동옥
- 작성일: 2026-11-03

---

이 문서는 서울 리전(Primary)에서 도쿄 리전(Secondary)으로 재해복구(DR) 환경을 구축할 때, 각 서비스가 제공하는 **Replication(복제) 기능**을 활용하여 비용을 절감하고 구현을 쉽게 진행한 내용을 담고 있습니다.

### 1. Aurora RDS DR 구성

- **제공 기능**: Aurora Global Database 기능 활용
- **구동 방식**:
    - **Primary 리전(서울)**: Writer 인스턴스 존재
    - **Secondary 리전(도쿄)**: Reader 인스턴스를 추가하여 부하 분산 도모
    - 재해 복구 상황 발생 시 Secondary 리전을 승격(Promote)시켜 Primary 리전으로 동작 수행
- **성능 및 RPO/RTO**:
    - 데이터 복제 지연 시간: 1초 미만
    - 재해 복구 소요 시간: 1분 이내

### 2. ECR (Elastic Container Registry) DR 구성

- **제공 기능**: Private Image Replication 기능 활용
- **구동 방식**:
    - ECR에 이미지를 Push하면 자동으로 다른 리전(도쿄)으로 이미지 Replication 수행
    - Repository 단위가 아닌 리전 단위로 지정하며, 필터 조건(Prefix name 등)을 추가해 일부 Repository만 복제하도록 제한 가능
- **특징 및 주의사항**:
    - 설정 완료 후 **Push되는 이미지부터** 복제 적용
    - 복제 시 Destination 리전에 Repository가 없으면 **자동 생성 후 복제**
    - Source 리전에서 이미지가 삭제될 때는 **자동으로 삭제(Replication)되지 않으므로 수동 제거** 필요

### 3. 기타 Replication 지원 서비스

- Aurora RDS 외에도 **S3, ECR, Secrets Manager** 등이 리전 간 Replication 기능을 기본 제공하여 손쉽게 DR 환경을 구축할 수 있도록 지원

### 4. 프로젝트 적용 제안

- AWS에서 제공하는 Replication 기능을 활용하면 별도 데이터 복제 시스템을 구축하는 부담을 줄이고 DR 환경의 운영 복잡성을 낮출 수 있습니다.
- 프로젝트에서는 AWS와 GCP를 활용한 멀티클라우드 DR을 목표로 하므로, AWS의 리전 간 복제 기능을 GCP에 직접 적용할 수는 없으므로, AWS의 관리형 Replication을 참고하되, 데이터베이스는 CDC 기반 복제, 컨테이너 이미지는 별도 레지스트리 동기화 방식을 검토 제안