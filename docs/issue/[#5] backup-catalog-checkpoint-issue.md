# [#5][meta] 백업 카탈로그와 Checkpoint를 기록한다

> 선행: #4(백업 저장). Offset은 #2·#3에서 온다. [ADR-0001](<../adr/[ADR-0001] 데이터 정합성 — 복제 시점이 아니라 복구 기준점으로.md>), [데이터 정의 7·9·10·12번](<../관리해야 하는 데이터 정의.md>) 참고.

### 배경

백업과 복제만으로는 복구를 못 한다. "무엇을 어디에 저장했는가(카탈로그)"와 "어느 지점으로 서비스를 올려야 하는가(Checkpoint)"를 알아야 한다.

ADR-0001은 복구를 **서비스 단위 기준점(Checkpoint)**으로 맞추기로 했다. 저장소별 Offset만으로는 "여러 저장소가 같은 시점인지"를 모르기 때문에, 서비스가 쓰는 모든 소스를 한 묶음으로 보는 Checkpoint가 필요하다.

이 메타데이터 자체가 정합성의 기준(Single Source)이 된다. 그래서 이것도 보호 대상이다(아래 4번).

### 설계

**1. 백업 카탈로그**

각 백업 산출물(Snapshot·Binlog 구간)을 다음으로 기록한다.

| 필드 | 뜻 |
| --- | --- |
| `kind` | `snapshot` / `binlog` |
| `source_id` | 어느 소스의 것인지 |
| `location` | Object Storage 상의 경로 |
| `gtid_range` | 이 산출물이 덮는 GTID 범위 |
| `created_at` | 저장 시각 |
| `checksum`, `size` | 무결성 검증용 |

이게 없으면 백업이 있어도 못 찾고, 복구 후 검증도 못 한다.

**2. Checkpoint**

서비스 단위로 "되돌아가 서비스를 올릴 수 있는 일관 지점"을 기록한다.

```
checkpoint C  (서비스 shop-api, 시각 T)
├─ 소스별 offset   : { db-main: GTID ...:1-10452, ... }
├─ schema_version : 0007
└─ image_ref      : repo@sha256:9f2c...
```

- **소스를 멈추지 않고 찍는다.** 주기적으로 각 소스의 현재 Offset을 한 번에 읽어 기록한다(Crash-consistent). 앱을 멈추는 방식(Application-consistent)은 무중단에 반해서 쓰지 않는다.
- **schema_version·image_ref를 함께 묶는다.** 데이터만 맞고 코드·스키마가 어긋나면 깨지기 때문이다. `image_ref`는 Tag가 아니라 Digest로 고정한다(echo-was 공유 규칙).
- **주기 값은 RPO 목표와 각 저장소의 스냅샷 간격이 정해지면 확정한다(판단 항목).**

**3. schema_version·image_ref 출처 (경계 — echo-was와 조율)**

`image_ref`와 배포 버전은 echo-was DB(`current_deployment`)가 들고 있다. 여기서 자체 저장할지 echo-was를 읽을지는 echo-was와 정한다. 이 이슈는 "묶는다"까지만 정의하고, 출처 연동은 계약이 정해진 뒤 채운다.

**4. 메타 자체의 보호**

카탈로그·Checkpoint·Offset이 날아가면 데이터가 멀쩡해도 "어디로 올려야 할지"를 잃는다. 그래서 이 메타 저장소도 복제·백업 대상으로 둔다.

### 작업

- 카탈로그 저장소(스키마 + 기록·조회).
- Checkpoint writer(주기적으로 소스 Offset + schema_version + image_ref 묶어 기록).
- 메타 저장소 자체의 백업 경로.

### 완료 조건

- 백업이 생길 때마다 카탈로그에 한 줄이 쌓이고, GTID 범위·체크섬으로 조회된다.
- 서비스별 Checkpoint가 주기적으로 기록되고, 소스 Offset·schema_version·image_ref를 모두 포함한다.
- 메타 저장소가 유실돼도 복원할 백업 경로가 있다.

### 이번에 하지 않는 것

- 실제 복구 실행(#6)은 이 메타를 "읽어서" 쓴다. 여기서는 "쓰기"까지만.
- 다중 소스를 한 Checkpoint로 조율하는 세부(데모는 단일 DB부터, ADR-0001).
- echo-was 연동 계약 자체(별도 조율).
