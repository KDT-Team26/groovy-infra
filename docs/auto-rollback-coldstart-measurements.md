# 백엔드 콜드스타트 실측 (auto-rollback P1b)

`progressDeadlineSeconds` / startupProbe 예산을 정하기 위한 근거. 각 서비스의 P1a
(`/actuator/health/**` permit + health probes 그룹) 배포 롤아웃 때 신규 pod의
**container Started → Ready** 시간을 `kubectl` 조건 타임스탬프로 측정.

- 측정: `.status.containerStatuses[0].state.running.startedAt` →
  `.status.conditions[type=Ready].lastTransitionTime` 의 차이(초).
- 이미지 pull ≈ 3s(캐시)로 위 구간에 미포함. "Startup probe failed: connection refused /
  context deadline exceeded" 이벤트는 앱이 아직 리스닝 전이라 정상 — startupProbe
  (주기 10s × 임계 30 = 300s 예산)가 재시도하다 통과.
- startupProbe 는 통합 `/actuator/health`(DB/Kafka/Redis 포함) → Flyway 마이그레이션 등 포함.
- 클러스터: EKS `groovy-eks-cluster`, ARM64 Graviton `t4g.medium`, 5개 서비스 HA(replica≥2).

---

## content-service — 2026-09-07 07:51~07:56 UTC · image `bcc07ee2…`

| pod | Started (UTC) | Ready (UTC) | 소요 |
|---|---|---|---|
| 64554fb46c-247zb | 07:51:14 | 07:52:20 | **66s** |
| 64554fb46c-xgvx9 | 07:52:24 | 07:53:32 | **68s** |
| 64554fb46c-nhlz5 | 07:53:36 | 07:54:52 | **76s** |
| 64554fb46c-dpzgv | 07:54:57 | ~07:56:2x | **~85s** |

events(예시, 247zb): `07:51:13 Pulled(2.869s)` → `07:51:14 Started` →
`07:52:00 Startup probe failed: connection refused`(정상) →
`07:52:11 Startup probe failed: context deadline exceeded`(정상) → `07:52:20 Ready`.

## study-service — 2026-09-07 08:02~08:07 UTC · image `77be2ec0…`

| pod | Started | Ready | 소요 |
|---|---|---|---|
| 7f6b7bb797-72dpj | 08:02:58 | 08:04:05 | **67s** |
| 7f6b7bb797-qsqrz | 08:04:09 | 08:05:16 | **67s** |
| 7f6b7bb797-jnk4g | 08:05:20 | 08:06:27 | **67s** |
| 7f6b7bb797-8lrv9 | 08:06:31 | 08:07:38 | **67s** |

## calendar-service — 2026-09-07 08:03~08:08 UTC · image `6c3a3ae2…`

| pod | Started | Ready | 소요 |
|---|---|---|---|
| b754c6d96-p8xzp | 08:03:38 | 08:04:44 | **66s** |
| b754c6d96-ln2b4 | 08:04:49 | 08:05:46 | **57s** |
| b754c6d96-27gmt | 08:05:47 | 08:06:56 | **69s** |
| b754c6d96-vvz8m | 08:07:00 | 08:07:58 | **58s** |

## notification-service — 2026-09-07 08:04~08:09 UTC · image `62421194…`

| pod | Started | Ready | 소요 |
|---|---|---|---|
| 59b4b44b95-p5s2m | 08:04:18 | 08:05:25 | **67s** |
| 59b4b44b95-9nnps | 08:05:28 | 08:06:35 | **67s** |
| 59b4b44b95-4rlnf | 08:06:39 | 08:07:56 | **77s** |
| 59b4b44b95-t2gqp | 08:08:01 | 08:09:16 | **75s** |

## identity-service — 2026-09-07 08:10~08:11 UTC · image `3eab40b6…`

| pod | Started | Ready | 소요 |
|---|---|---|---|
| c7f8b59dd-dtb28 | 08:10:20 | 08:10:38 | **18s** |
| c7f8b59dd-vsxgj | 08:10:41 | 08:10:59 | **18s** |
| c7f8b59dd-b55hf | 08:11:03 | 08:11:20 | **17s** |

(identity 는 Flyway 스키마가 가볍고 Kafka 컨슈머가 없어 현저히 빠름.)

---

## 종합

| 서비스 | 관측 소요 (n) | 특징 |
|---|---|---|
| content | 66–85s (4) | 최댓값 |
| study | 67s (4) | 매우 일정 |
| calendar | 57–69s (4) | |
| notification | 67–77s (4) | Kafka 컨슈머 |
| identity | 17–18s (3) | 최소 |

- **관측 최대 콜드스타트: 85s** (content, 부하 없는 조건). 클러스터 전형값 ≈ 67s.
- 19개 pod, 편차 작음(±15s). 이상치 없음.

## P1c 결정

| 항목 | 기존 | P1c | 근거 |
|---|---|---|---|
| `startup.failureThreshold` | 30 (예산 300s) | **18** (예산 180s) | 관측 최대 85s의 2.1x. 안 뜨는 이미지를 3분 내 CrashLoop 로 노출 |
| `rollout.progressDeadlineSeconds` | (없음 → k8s 기본 600s) | **240** | startup 예산 180s 초과(거짓 ProgressDeadlineExceeded 방지) + 관측 최대의 2.8x. Degraded 감지 최대 4분(기본 600s 대비 단축) |

- readiness/liveness probe 경로만 분리(`/actuator/health/{readiness,liveness}`), startup 은
  통합 `/actuator/health` 유지(Flyway/DB 준비까지 기다림).
- 롤아웃: **content-service 먼저** 적용 → Healthy 확인 → 나머지 4개 batch.
