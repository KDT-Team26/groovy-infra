# Groovy 폴리레포 전환 계획서

> **작성일**: 2026-08-20
> **상태**: 확정본 — 코드/파일 이동은 아직 수행하지 않음, 레포 분리 범위·방침·이관 순서를 정리한
> 계획 단계(1차/2차로 나누지 않고 하나의 문서로 유지)
> **관련 문서**: [`Groovy_MSA_저장소_구조.md`](./Groovy_MSA_저장소_구조.md)(현재 저장소 구조),
> [`troubles/01-공통라이브러리-복사-vs-메이븐레지스트리.md`](./troubles/01-공통라이브러리-복사-vs-메이븐레지스트리.md)
> (공통 라이브러리 처리 방식을 정한 고민 과정 기록)

## 0. 배경 및 전제

- 현재 `dev` 브랜치는 백엔드가 이미 MSA 구조(6개 서비스 + 공유 라이브러리 5개)로 전환 완료된 상태다.
- k8s 도입은 진행 중이며 아직 완료되지 않았다. `helm/`, `k8s/`, `k8s-local/`는 여전히 레거시
  모놀리식 기준(단일 `backend` 이미지, 단일 `mysql`)이라 MSA 구조가 반영되어 있지 않다.
- 폴리레포는 **지금 한 번에 전면 전환하는 것이 아니라**, k8s가 완전히 적용되는 시점까지 서비스별로
  단계적/부분적으로 이관한다. 원본 `Groovy` 레포는 k8s 작업을 위해 계속 유지하고, k8s 작업이
  끝나면 원본 레포의 나머지 내용을 폴리레포로 이전한다.
- CI/CD 방식: **CI는 GitHub Actions**로 서비스별 빌드를 수행하고, **CD는 ArgoCD(GitOps)**로 k8s에
  배포한다.

## 1. 레포 목록 (8개, 확정)

| 레포 | 역할 | 현재 소스 위치(참고, 아직 이동 안 함) |
|---|---|---|
| `groovy-identity-service` | User, JWT 발급 | `backend/services/identity-service/` |
| `groovy-study-service` | 스터디 도메인 | `backend/services/study-service/` |
| `groovy-content-service` | 회고록 | `backend/services/content-service/` |
| `groovy-calendar-service` | 캘린더 | `backend/services/calendar-service/` |
| `groovy-notification-service` | 알림 | `backend/services/notification-service/` |
| `groovy-gateway-service` | API Gateway | `backend/services/api-gateway/` |
| `groovy-frontend` | 프론트엔드(React+Vite) | `front/` |
| `groovy-infra` | DB, k8s, 모니터링 등 공용 | `mysql-init/`, `kafka-init/`, `monitoring-msa/`, `alertmanager/`, `nginx/`, `helm/`, `k8s/`, `k8s-local/`, `docker-compose*.yml`, `.env.example`, 전역 `docs/`(Phase 문서 등) |

## 2. 공통 라이브러리(`backend/libs/`) 처리 방침 — 복사 방식 채택

5개 공유 라이브러리(`event-contract`, `observability`, `web-common`, `security-common`,
`client-common`)는 **Maven 레지스트리로 배포하지 않고, 각 서비스 레포가 실제로 쓰는 부분만
복사해서 자체 보유**하는 방식으로 결정했다. 결정에 이르기까지의 상세한 고민 과정(작동 방식 비교,
장단점, 서비스 규모를 고려한 재평가)은
[`troubles/01-공통라이브러리-복사-vs-메이븐레지스트리.md`](./troubles/01-공통라이브러리-복사-vs-메이븐레지스트리.md)에 별도로 기록했다.

### 2.1 서비스별 복사 대상 (현재 `build.gradle` 의존성 기준)

| 서비스 레포 | 복사해야 할 lib |
|---|---|
| `groovy-gateway-service` | `observability`(리소스 include 방식, 자바 코드 import 없음) |
| `groovy-identity-service` | `event-contract`, `observability`, `web-common` |
| `groovy-study-service` | `event-contract`, `observability`, `web-common`, `security-common`, `client-common` |
| `groovy-content-service` | `event-contract`, `observability`, `web-common`, `security-common`, `client-common` |
| `groovy-calendar-service` | `event-contract`, `observability`, `web-common`, `security-common`, `client-common` |
| `groovy-notification-service` | `event-contract`, `observability`, `web-common`, `security-common` |

### 2.2 예외 처리 필요 항목

- **`security-common`**(JWT 검증 로직 등): 보안이 걸린 코드이므로, 수정이 필요할 때 관련된 모든
  레포(`study`/`content`/`calendar`/`notification`-service)에 동일 수정을 적용해야 한다는 것을
  팀이 인지하고 있어야 한다. 후속 작업으로 PR 템플릿 체크리스트 등 최소한의 프로세스를 마련할 것.
- **`event-contract`**: 단순 복사만으로는 서비스 간 계약(Kafka payload 스키마) 드리프트를 막을
  안전장치가 없다. 3장의 CI 스키마 검증으로 보완한다.

## 3. `event-contract` 계약 안전장치 (CI 스키마 검증)

**목적**: `study`/`calendar`/`content-service`(발행자)와 `notification-service`(구독자) 사이의
Kafka payload가, 지금처럼 컴파일 타임에 같은 소스를 공유하지 않아도 조용히 어긋나지 않게 한다.

**1차 방식(상세 구현은 후속 작업)**:
- payload 클래스별 JSON 스키마 또는 고정 샘플(fixture)을 각 레포에 둔다.
- 각 레포 CI 파이프라인에 "이 서비스가 발행/구독하는 payload가 고정된 스키마와 일치하는가"를
  검증하는 테스트 스텝을 추가한다.
- payload 스키마가 바뀌면, 관련된 모든 레포(발행자 + 구독자)의 스키마 픽스처를 함께 갱신해야
  함을 명시적인 규칙으로 둔다(리뷰 체크리스트 등).

## 4. MySQL/DB 배치

- mysql 컨테이너 1개, 논리 DB 5개(서비스별 전용 스키마+계정)라는 현재 구조를 그대로 유지한다.
- **컨테이너 프로비저닝**(compose/k8s의 `mysql` 서비스 정의, `mysql-init/*.sql` — DB+계정 생성만
  담당)은 **`groovy-infra`가 소유**한다. 공유 컨테이너의 라이프사이클을 특정 서비스 레포가 갖는 건
  소유권 경계상 맞지 않는다.
- **테이블 스키마 진화**는 5개 DB 소유 서비스가 이미 Flyway로 직접 관리하고 있으므로(`ddl-auto:
  validate` 확인됨), 그대로 **각 서비스 레포**에 남는다. 서비스가 테이블을 추가/변경해도
  `groovy-infra`를 건드릴 필요가 없다.

## 5. CI/CD 구조

- **CI (GitHub Actions)**: 레포별 워크플로우. 빌드 + 테스트(2·3장의 lib 복사분 검증, event-contract
  스키마 검증 포함) + 이미지 빌드/푸시.
- **CD (ArgoCD, GitOps)**: `groovy-infra`가 배포 매니페스트의 단일 소스가 된다. 서비스 소스 코드가
  아직 모노레포에 남아 있어도, MSA를 반영한 k8s 매니페스트는 지금부터 `groovy-infra`에 구성할 수
  있다 — 소스 이관과 배포 이관을 별도 트랙으로 진행 가능.
- **파이프라인 흐름**:
  ```
  서비스 레포 CI(GH Actions) → 이미지 빌드/푸시
                                      │
                    groovy-infra의 해당 서비스 매니페스트 이미지 태그 갱신
                                      │
                            ArgoCD가 감지 → k8s 클러스터 동기화
  ```
- 이 파이프라인은 `groovy-infra`가 구성되는 6장 3단계부터 실제로 가동된다. 그 전(1·2단계)에는
  CI(빌드+테스트+이미지 푸시)까지만 각 레포에서 동작하고, 배포는 기존 방식을 유지한다.

## 6. 단계적 이관 순서 (확정)

0장에서 밝힌 대로 k8s가 완전히 도입되기 전까지는 폴리레포를 한 번에 전면 가동하지 않는다.
**프론트엔드 → 서비스 모듈 → 인프라 모듈** 순으로 3단계에 걸쳐 진행한다.

인프라 이관을 마지막에 두는 이유: k8s 도입 작업이 원본 `Groovy` 레포에서 별도로 계속 진행
중이다. 지금 `groovy-infra`의 배포 매니페스트를 먼저 작성해두면 원본 레포 쪽 k8s 작업이 바뀔
때마다 같은 작업을 두 번(지금 한 번, k8s 완료 후 이전할 때 또 한 번) 하게 될 위험이 있다.
k8s가 원본 레포에서 MSA 구조로 안정화된 뒤 그 결과물을 `groovy-infra`로 옮기는 편이 효율적이다.

### 1단계 — 프론트엔드 레포 분리 (`groovy-frontend`)

- 공유 lib 의존, DB 의존이 없어 8개 레포 중 결합도가 가장 낮다.
- 이미 `.github/workflows/docker-build-push-frontend.yml`로 검증된 CI(빌드+이미지 푸시)가
  있어, 레포 분리 후에도 워크플로우를 거의 그대로 옮기면 된다.
- 폴리레포 전환 프로세스(레포 생성 → CI 이전 → 검증) 자체를 가장 낮은 위험으로 처음
  연습해볼 수 있는 대상이라 첫 단계로 삼는다.

### 2단계 — 서비스 모듈 분리 (6개 서비스 레포)

2장에서 공통 라이브러리 처리 방침(복사 방식)이 정해져 있어, 서비스 분리의 기술적 걸림돌은
해소된 상태다. 서비스 간 결합도(HTTP 동기 호출 방향)를 기준으로 하위 순서를 둔다.

1. **파일럿**: `groovy-gateway-service`, `groovy-notification-service` — 결합도가 가장 낮은
   두 서비스(gateway는 도메인 로직/DB 없음, notification은 나가는 동기 호출이 없는 leaf)로
   "레포 생성 → CI → 이미지 푸시" 프로세스를 먼저 검증한다.
2. `groovy-identity-service` — 나머지 서비스 전부가 JWKS 검증에 의존하는 서비스이므로,
   파일럿에서 프로세스가 검증된 뒤 이동한다.
3. `groovy-study-service` — `calendar`/`content-service`가 이 서비스를 호출하므로 먼저 이동.
4. `groovy-calendar-service`, `groovy-content-service`.

**과도기 참고**: `groovy-infra`가 아직 없는 이 단계에서는, 분리된 서비스 레포들의 로컬 개발·
통합 테스트가 당분간 원본 `Groovy` 레포의 `docker-compose.local.yml`(mysql/redis/kafka 등)을
그대로 참조한다. ArgoCD도 아직 구성되지 않으므로, 이 단계의 CI는 빌드+테스트+이미지 푸시까지만
수행하고 실제 배포는 기존 방식을 유지한다.

### 3단계 — 인프라 모듈 분리 (`groovy-infra`)

- 원본 `Groovy` 레포에서 진행 중인 k8s 도입이 MSA 구조를 반영해 안정화된 뒤 시작한다.
- `mysql-init/`, `kafka-init/`, `monitoring-msa/`, `alertmanager/`, `nginx/`, 완성된 helm/k8s
  매니페스트, 전역 `docs/`를 이 시점에 `groovy-infra`로 옮긴다.
- 이 시점부터 5장의 CI(GH Actions) → CD(ArgoCD) 파이프라인이 실제로 가동된다. 1·2단계에서
  먼저 분리한 프론트엔드/서비스 레포들의 이미지를 `groovy-infra`의 매니페스트에 연결하는 작업이
  함께 필요하다.

## 7. 미결 사항 / 후속 결정 필요

- `security-common` 등 복사된 lib 수정 시 다중 레포 동시 수정을 강제/추적하는 프로세스의 구체적
  형태(체크리스트, 이슈 템플릿 등).
- 각 서비스 레포 분리 시 필요한 독립 `settings.gradle`/`build.gradle`/Gradle wrapper 구성(현재는
  `backend/` 루트에서 공유 중).
- 2단계(서비스 분리) 기간 동안 로컬 개발·통합 테스트용 `docker-compose`를 원본 레포 것을 계속
  참조할지, 서비스 레포마다 최소 구성을 자체적으로 둘지.
