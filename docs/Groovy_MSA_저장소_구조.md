# Groovy MSA 저장소 구조 가이드

> "지금 뭐가 어떻게 떠 있는지"는 [`Groovy_MSA_구조와실행.md`](./Groovy_MSA_구조와실행.md) 참고.
> 이 문서는 그와 달리 **저장소 안에 어떤 디렉토리/모듈/설정 파일이 있고 각각 무슨 역할인지**를
> 정리한다. `front/`(React 프론트엔드)는 이 문서 범위에서 제외한다.

## 1. 최상위 디렉토리 개요

| 디렉토리 | 역할 |
|---|---|
| `backend/` | MSA를 이루는 Spring Boot 멀티모듈 Gradle 프로젝트. 6개 서비스 + 공유 라이브러리 2개. 상세는 2장. |
| `docs/` | MSA 전환 과정을 Phase별로 기록한 설계/실행 문서 모음(`Groovy_MSA_Phase0_의존성분석.md` ~ `Phase13_테스트전략확장.md`, 전환계획서, 구조 요약, 도메인 경계 재검토)과 `images/`(아키텍처 다이어그램). |
| `mysql-init/` | MySQL 컨테이너 최초 기동 시 자동 실행되는 `.sql` 5개. 서비스별 전용 스키마(`identity_db`/`study_db`/`calendar_db`/`content_db`/`notification_db`)와 그 스키마에만 권한 있는 전용 계정을 생성한다. |
| `kafka-init/` | `adminclient.conf` 하나. Kafka가 SASL_PLAINTEXT 인증을 쓰기 때문에, healthcheck용 `kafka-broker-api-versions.sh`가 인증 정보 없이도 브로커 상태를 확인하게 해주는 admin client 설정. |
| `monitoring-msa/` | MSA 전용 관측성 설정. `loki/`, `alloy/`(레거시 모놀리식 시절 `monitoring/`에서 옮겨온 원본, 변경 없이 그대로 재사용 — Alloy가 Docker 소켓으로 컨테이너를 자동 탐지해서 스택이 바뀌어도 그대로 동작), `tempo/`(분산 트레이싱), `prometheus/`(서비스별 scrape job으로 새로 짠 설정), `grafana/provisioning/`(Prometheus/Loki/Tempo datasource + 대시보드 2개). 레거시 `monitoring/` 디렉토리는 기능이 이 디렉토리로 완전히 흡수되어 삭제됨. |
| `alertmanager/` | Prometheus 알림을 Slack으로 보내는 Alertmanager 설정. `alertmanager.yml`(라우팅 규칙), `slack_webhook_url`(실제 웹훅 URL, gitignore 대상이라 로컬에서 각자 채워야 함). |
| `nginx/` | `nginx.conf` 하나. 운영 배포용 리버스 프록시(SSL 종료, Let's Encrypt, SSE 구독 경로 특별 처리). 다만 `proxy_pass http://backend:8080`처럼 레거시 모놀리식 시절 hostname을 그대로 참조하고 있어 MSA 구조(`api-gateway`)에 맞게 갱신되지 않은 상태. |
| `.github/` | `workflows/docker-build-push-frontend.yml`만 존재. 백엔드용 워크플로우는 삭제된 상태. |
| `.idea/` | IntelliJ 프로젝트 설정. `.gitignore`에 등록되어 커밋되지 않음. |
| `out/` | IntelliJ가 레거시 `Groovy` 모듈을 빌드할 때 생긴 산출물(gradlew/build.gradle 사본 등) 9개 파일이 **`.gitignore`에 안 걸려 실제로 git에 커밋된 상태** — 실수로 커밋된 빌드 아티팩트로 보인다. |

**최상위 주요 파일**: `docker-compose.local.yml`(로컬 개발용, 현재 사용 중), `docker-compose.example.yml`(값 채우는 법을 보여주는 온보딩용 사본, local과 서비스 구성 동일), `.env.example`(위 compose들이 읽는 환경변수 예시), `README.md`(프로젝트 소개). 운영 배포용 compose/env 파일은 이 저장소가 아니라 운영 서버에서 직접 관리한다.

---

## 2. `backend/` 상세

### 2.1 Gradle 멀티모듈 구조

`backend/settings.gradle`이 8개 서브모듈을 include 한다:

```groovy
rootProject.name = 'groovy-backend-msa'

include 'libs:event-contract'
include 'libs:observability'

include 'services:api-gateway'
include 'services:identity-service'
include 'services:study-service'
include 'services:content-service'
include 'services:calendar-service'
include 'services:notification-service'
```

`backend/build.gradle`(루트)은 공통 설정만 최소한으로 잡는다 — `group`/`version`, `mavenCentral()` repository, 그리고 `io.spring.dependency-management` 플러그인을 `apply false`로 한 번만 선언. Spring Boot 플러그인 버전은 **각 서비스 `build.gradle`이 직접 선언**한다(같은 빌드 안에서 같은 플러그인 id에 서로 다른 버전을 요청할 수 없다는 Gradle 제약 때문에, api-gateway만 Spring Cloud Gateway 호환을 위해 Boot 4.0.7을 쓰고 나머지 5개는 4.1.0을 쓰는 걸 이 방식으로 수용).

### 2.2 `backend/libs/` — 공유 라이브러리 모듈

서비스 코드가 아니라 여러 서비스가 의존하는 순수 라이브러리다. 두 모듈 다 프레임워크 의존성이 거의 없다.

- **`libs/event-contract`**: Kafka로 오가는 이벤트 payload 클래스 모음. `EventEnvelope`/`EventTypes`(공통 봉투 포맷)와, 도메인별 패키지(`study/`, `calendar/`, `identity/`, `content/`)에 `StudyCreatedPayload`, `StudyApplicationSubmittedPayload`, `StudyApplicationDecidedPayload`, `StudySeatAvailablePayload`, `StudyMemberLeftPayload`, `StudyLevelUpPayload`, `StudyScheduleChangedPayload`, `UserDeletedPayload`, `MemoirCommentAddedPayload`, `MemoirLikeAddedPayload` 등. 이벤트를 발행/구독하는 모든 서비스(study/calendar/content/notification-service)가 이 모듈에 의존해 payload 스키마를 공유한다.
- **`libs/observability`**: 공통 로그 포맷. `observability/logback-json.xml`(JSON 구조화 로그 설정, Alloy가 컨테이너 stdout에서 이 포맷을 파싱해 Loki로 보낸다)과 `LogFields`(로그에 실을 필드 상수). 6개 서비스 전부가 의존한다.

### 2.3 `backend/services/` — 공통 패턴

6개 서비스 전부 다음 구조를 공유한다:

- **Dockerfile**: 멀티스테이지 빌드(`eclipse-temurin:21-jdk` → `eclipse-temurin:21-jre`). 빌드 컨텍스트는 반드시 `backend/` 루트여야 한다(Gradle 멀티모듈이라 서비스 하나만 떼어 빌드할 수 없고, `libs/event-contract`·`libs/observability`를 함께 봐야 `:services:<name>:bootJar`가 성립). 논루트 `groovy` 유저로 실행, actuator health 기반 `HEALTHCHECK` 내장.
- **패키지 구조**(`com.groovy.backend.<service>` 하위): `config`(SecurityConfig 등), `controller`, `dto`, `exception`, `repository`, `service`가 기본. 자체 DB를 갖는 5개 서비스(api-gateway 제외)는 추가로 `auth`(JwtAuthenticationFilter/TokenProvider — 발급이 아닌 검증), `common.entity`/`common.response`(공통 베이스 엔티티·응답 포맷)를 갖는다. Kafka를 발행하는 3개 서비스(study/calendar/content)는 `outbox`(Transactional Outbox), `notification`(발행 헬퍼), `client`(다른 서비스 동기 호출용 Feign 유사 클라이언트) 패키지가 추가된다. notification-service는 발행이 아니라 소비 쪽이라 `event`(Kafka consumer), `inbox`(멱등 처리) 패키지를 갖는다.
- **의존성 공통**: `spring-boot-starter-actuator`, `spring-boot-micrometer-tracing` + `spring-boot-opentelemetry` + `micrometer-tracing-bridge-otel` + `opentelemetry-exporter-otlp`(Tempo 분산 트레이싱), `io.micrometer:micrometer-registry-prometheus`(Prometheus 메트릭 노출 — 이번에 6개 서비스 전부에 추가), `libs:observability`.
- **application.yml 공통 `management` 블록**(이번에 6개 서비스 전부 동일하게 추가):
  ```yaml
  management:
    otlp:
      tracing:
        endpoint: ${OTLP_TRACING_ENDPOINT:http://tempo:4318/v1/traces}
    tracing:
      sampling:
        probability: ${TRACING_SAMPLING_PROBABILITY:1.0}
    endpoints:
      web:
        exposure:
          include: health,prometheus
    endpoint:
      health:
        show-details: always
    prometheus:
      metrics:
        export:
          enabled: true
    metrics:
      tags:
        application: ${spring.application.name}
      distribution:
        percentiles-histogram:
          http.server.requests: true
  ```

### 2.4 서비스별 상세

#### `api-gateway`

- **역할**: 모든 요청의 단일 진입점. 도메인 로직 없이 경로 기반 라우팅만 한다.
- **build.gradle 특이점**: Boot **4.0.7**로 고정(Spring Cloud 2025.1.2가 검증한 버전, 나머지 5개는 4.1.0). `spring-cloud-starter-gateway-server-webmvc`(서블릿/MVC 기반 Gateway — 나머지 서비스들과 스택을 통일하려고 WebFlux 버전 대신 선택) + `spring-boot-starter-actuator`. DB/JWT 관련 의존성이 전혀 없다(라우팅 전담이라 SecurityConfig 자체도 없음).
- **application.yml**: 라우트 정의(`spring.cloud.gateway.server.webmvc.routes`)가 핵심 — YAML 리스트 순서가 매칭 우선순위이며, 매칭되는 라우트가 없으면 게이트웨이가 그대로 404를 반환한다. `notification-service`(`/api/notifications/**`), `identity-service`(`/api/auth/**`, `/api/users/me` exact, `/api/tags/**`), `study-service`(`/api/studies/**`, `/api/users/me/studies`, `/api/users/me/applications`), `calendar-service`(`/api/calendars/**`), `content-service`(`/api/memoirs/**`)로 라우팅. `server.port: 8080`, actuator는 별도 관리 포트 `management.server.port: 8090`으로 분리(매칭 안 되는 라우팅 대상 포트와 섞이지 않게).

#### `identity-service` (포트 8081)

- **역할**: User(인증) + Tag(마스터/선호 태그) 도메인. 유일한 JWT **발급자**(`JwtKeyProvider`/`JwksController`가 여기 있고, 나머지 서비스는 이 서비스의 JWKS로 검증만 한다).
- **build.gradle 특이점**: `spring-boot-starter-security`, `spring-boot-starter-data-jpa`, `spring-boot-flyway`+`flyway-mysql`(자기 스키마 마이그레이션 직접 관리), `io.jsonwebtoken:jjwt-*`(JWT 발급용, 나머지 서비스는 검증만 하므로 이 라이브러리가 없음), `mysql-connector-j`.
- **application.yml**: `spring.datasource`(`identity_db`, 계정 `identity_service`, HikariCP `IdentityHikariPool`), `cors.allowed-origins`(프론트가 로그인/회원가입을 직접 호출하는 이유로 별도 CORS 설정 — 단, 실제 CORS 적용은 api-gateway의 `CorsFilter` 한 곳에서만 하도록 최근 정리됨, `SecurityConfig`에는 더 이상 CORS 설정 없음), `server.port: 8081`.

#### `study-service` (포트 8082)

- **역할**: Study/Application/Waitlist(+StudyTag) 도메인. identity-service의 JWKS로 검증만(발급자 아님).
- **build.gradle 특이점**: `spring-boot-starter-kafka`(Outbox 이벤트 발행), `resilience4j-circuitbreaker`/`resilience4j-retry`(identity-service 호출에 적용 — Spring Cloud CircuitBreaker 대신 순수 Java 라이브러리 직접 조립, Boot 버전 호환 리스크 회피).
- **application.yml**: `spring.datasource`(`study_db`), `spring.kafka`(SASL_PLAINTEXT, `notification-events` 토픽 발행), `jwt.jwks-url`(identity-service JWKS 주소), `identity-service.url`(leaderName/applicantName 배치 조회 + 선호 태그 조회용 클라이언트 주소).

#### `calendar-service` (포트 8084)

- **역할**: 개인 일정 + 스터디 약속 캘린더.
- **build.gradle**: study-service와 동일 패턴(Kafka, Resilience4j).
- **application.yml**: `spring.datasource`(`calendar_db`), `study-service.url`(멤버십·승인 멤버 목록·"내 스터디 옵션" 조회 클라이언트), `jwt.jwks-url`.

#### `content-service` (포트 8083)

- **역할**: Memoir(회고록) + 댓글 + 좋아요.
- **build.gradle**: study/calendar-service와 동일 패턴.
- **application.yml**: `spring.datasource`(`content_db`), `study-service.url` + `identity-service.url`(작성자/댓글 작성자 이름 배치 조회) 둘 다 갖는 유일한 서비스.

#### `notification-service` (포트 8085)

- **역할**: 알림 생성 + SSE 실시간 전송. Phase 6에서 가장 먼저 추출된 leaf 도메인(나가는 의존성 없음).
- **build.gradle 특이점**: `spring-boot-starter-data-redis`(SSE 인스턴스간 pub/sub + 구독 티켓 저장 — 이 서비스만 Redis를 쓴다), `spring-boot-starter-kafka`(발행이 아니라 `@KafkaListener`로 **소비**).
- **application.yml**: `spring.datasource`(`notification_db`), `spring.data.redis`, `spring.kafka.consumer`(`group-id: notification-service`), `jwt.jwks-url`(기본값이 아직 `legacy-monolith:8080`을 가리키는 흔적이 남아있음 — 실제로는 docker-compose 환경변수로 identity-service 주소를 덮어써서 동작하므로 실행엔 문제없지만 기본값 자체는 정리가 안 된 상태).

### 2.5 서비스 간 의존성 요약

```
api-gateway  → (라우팅만, 도메인 의존 없음)
identity-service → (다른 서비스 호출 없음, JWT 발급자)
study-service → identity-service(JWKS 검증, leaderName/태그 조회)
calendar-service → identity-service(JWKS 검증), study-service(멤버십 확인)
content-service → identity-service(JWKS 검증, 이름 조회), study-service(멤버십/경험치)
notification-service → identity-service(JWKS 검증), Kafka로 study/calendar/content-service의 이벤트를 소비
```
