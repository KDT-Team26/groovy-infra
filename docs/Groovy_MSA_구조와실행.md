# Groovy MSA 구조 개요 및 실행 방법

> 상세 설계/검증 근거는 [`Groovy_MSA_전환계획.md`](순서1/Groovy_MSA_전환계획.md)와 각 Phase 문서
> (`Groovy_MSA_Phase0_의존성분석.md` ~ `Groovy_MSA_Phase13_테스트전략확장.md`) 참고. 이 문서는
> "지금 뭐가 어떻게 떠 있는지"만 간단히 정리한다.

## 1. MSA 전환 완료

Notification/User(인증+Tag)/Study(+Application+Waitlist+StudyTag)/Calendar/Memoir(+댓글/좋아요)
5개 도메인이 전부 레거시 모놀리스(`groovy/`)에서 독립 서비스로 추출됐고, `groovy/` 디렉터리
자체는 삭제됐다. `api-gateway`가 모든 요청의 단일 진입점이며, 경로별로 각 서비스로 직접
라우팅한다(`backend/services/api-gateway/src/main/resources/application.yml`).

## 2. 두 가지 Docker Compose 파일

서비스 구성(13개 컨테이너: 백엔드 8개 + mysql/redis/kafka/tempo/loki/alloy/grafana)은 두 파일
모두 동일하고, 용도에 따라 포트 노출/비밀값 처리만 다르다.

| 파일 | 용도 | 호스트 포트 노출 | 비밀값 |
|---|---|---|---|
| `docker-compose.local.yml` | 로컬 개발. 모든 서비스를 직접 호출하며 디버깅 | 전부 노출 | 안전한 로컬 전용 기본값 |
| `docker-compose.example.yml` | 구조를 보여주는 온보딩/참고용 | 전부 노출(local과 동일) | 눈에 띄는 `CHANGE_ME_*` 플레이스홀더 |

운영 배포용 compose/env 파일은 이 저장소에 두지 않고 운영 서버에서 직접 작성·관리한다 —
원본 Groovy 레포로 통합할 때 이 저장소 기준으로 다시 만들어야 할 목록은
[`원본 레포 통합 시 주의점.md`](./원본%20레포%20통합%20시%20주의점.md) 참고.

frontend/nginx(리버스 프록시)/certbot 통합은 두 파일 모두 범위 밖이다 — 별도로 진행한다.
모든 서비스를 소스에서 직접 빌드한다(`context: ./backend`) — 서비스별 이미지를 Docker Hub에
미리 빌드·푸시하는 CI가 아직 없다(frontend만 기존 CI로 이미지가 빌드된다).

## 3. 실행

```bash
cp .env.example .env   # 값 수정(기본값 그대로도 로컬에서 동작)

docker compose -f docker-compose.local.yml up -d --build
docker compose -f docker-compose.local.yml ps
docker compose -f docker-compose.local.yml down
```

## 4. 서비스 목록과 포트

포트 열은 `docker-compose.local.yml`/`docker-compose.example.yml` 기준(기본값, `.env`로
변경 가능). "prod 노출" 열은 운영 배포 시 지향해야 할 노출 범위(설계 목표)를 적어둔 것이며,
현재 이 저장소에는 그 설정을 실제로 담은 파일이 없다 — "P" 표시만 호스트에 노출하고 나머지는
내부 네트워크로만 접근하게 만드는 것을 목표로 한다.

### 애플리케이션

| 서비스 | 역할 | 컨테이너 포트 | 호스트 포트(local/example) | prod 노출 |
|---|---|---|---|---|
| `api-gateway` | 모든 요청의 단일 진입점(Spring Cloud Gateway MVC). 경로별로 각 서비스로 라우팅 | 8080 (mgmt 8090) | `API_GATEWAY_PORT`=8080, `API_GATEWAY_MGMT_PORT`=8090 | **P** (8080만, mgmt는 내부 전용) |
| `identity-service` | User(인증) + Tag(마스터/선호 태그). 유일한 JWT 발급자(JWKS) | 8081 | `IDENTITY_SERVICE_PORT`=8081 | 내부 전용 |
| `study-service` | Study/Application/Waitlist/StudyTag | 8082 | `STUDY_SERVICE_PORT`=8082 | 내부 전용 |
| `content-service` | Memoir(+댓글/좋아요) | 8083 | `CONTENT_SERVICE_PORT`=8083 | 내부 전용 |
| `calendar-service` | 개인 일정 + 스터디 약속 | 8084 | `CALENDAR_SERVICE_PORT`=8084 | 내부 전용 |
| `notification-service` | 알림 저장 + SSE 푸시(Redis pub/sub) + Kafka 이벤트 소비 | 8085 | `NOTIFICATION_SERVICE_PORT`=8085 | 내부 전용 |

### 인프라

| 서비스 | 역할 | 컨테이너 포트 | 호스트 포트(local/example) | prod 노출 |
|---|---|---|---|---|
| `mysql` | 컨테이너 1개 안에서 서비스별 전용 스키마(`identity_db`/`study_db`/`content_db`/`calendar_db`/`notification_db`) + 전용 계정으로 분리 | 3306 | `MYSQL_PORT`=3306 | 내부 전용 |
| `redis` | notification-service의 SSE 인스턴스 간 pub/sub + 구독 티켓 저장 | 6379 | 미노출 | 내부 전용 |
| `kafka` | 단일 노드 KRaft 모드. study/calendar/content-service의 Outbox → notification-service 소비(SASL/PLAIN 인증) | 9092 | 미노출 | 내부 전용 |

### 관측(Observability)

| 서비스 | 역할 | 컨테이너 포트 | 호스트 포트(local/example) | prod 노출 |
|---|---|---|---|---|
| `tempo` | 분산 트레이싱 백엔드(OTLP 수신) | 3200 | `TEMPO_QUERY_PORT`=3200 | 내부 전용 |
| `loki` | 로그 저장/검색(레거시 모놀리식 `monitoring/`에서 옮겨온 설정 재사용) | 3100 | `LOKI_PORT`=3100 | 내부 전용 |
| `alloy` | Docker 컨테이너 stdout을 자동 수집해 Loki로 전송 | - | 미노출 | 내부 전용 |
| `grafana` | Tempo+Loki 데이터소스로 트레이스/로그 조회 | 3000 | `GRAFANA_PORT`=3000 | **P** |

## 5. 요청 흐름 예시

```
브라우저/클라이언트
   │
   ▼
api-gateway :8080
   ├─ Path=/api/auth/**                        → identity-service :8081
   ├─ Path=/api/users/me (exact)                → identity-service :8081
   ├─ Path=/api/tags/**                         → identity-service :8081
   ├─ Path=/api/studies/**                      → study-service :8082
   ├─ Path=/api/users/me/studies                → study-service :8082
   ├─ Path=/api/users/me/applications           → study-service :8082
   ├─ Path=/api/memoirs/**                      → content-service :8083
   ├─ Path=/api/calendars/**                    → calendar-service :8084
   └─ Path=/api/notifications/**                → notification-service :8085
```

Study 참여 신청처럼 알림을 발생시키는 동작은 해당 서비스(study/calendar/content-service)가
처리 후 같은 트랜잭션 안에서 자신의 `outbox_events`에 기록하고(Transactional Outbox), 별도
스케줄러가 Kafka로 발행하면 notification-service가 소비해 알림을 저장+SSE 푸시한다
(At-least-once + Inbox로 멱등 처리).

인증은 identity-service가 RSA 키로 서명하고(`/.well-known/jwks.json`으로 공개키 공개), 나머지
모든 서비스는 이 공개키만 가져다 서명을 검증한다 — 시크릿을 공유하지 않는다.

## 6. 알려진 한계

- `identity_db`/`study_db`/`content_db`/`calendar_db`/`notification_db`가 물리적으로 분리된
  별개 스키마라, 정합성은 순전히 애플리케이션 레벨(ID 참조 + 서비스 간 동기 HTTP 호출)로만
  유지된다. Tag 마스터 데이터는 identity-service가 정본을 소유하고 study-service가 로컬
  사본(FK 무결성용)을 별도로 관리한다 — 실시간 동기화는 아직 없다(수동 시드 필요).
- 서비스 간 인증은 "유효한 JWT면 통과"뿐이다 — 서비스-투-서비스 mTLS 등 별도 인증은 없다.
- frontend/nginx(리버스 프록시)/certbot 통합, 그리고 각 서비스 이미지를 Docker Hub에
  빌드·푸시하는 CI는 아직 없다 — 지금은 항상 소스에서 직접 빌드한다.
