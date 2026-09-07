# 롤백 (rollback)

배포 장애 시 해당 서비스의 이미지 태그를 마지막으로 정상 확인된 값으로 되돌리는 구조.
관련 이슈: #90~#94(감지·수동 롤백 기반), 자동화 계획은 [`auto-rollback-plan.md`](./auto-rollback-plan.md).

- **감지**: 자동 (probe, ArgoCD Health, Prometheus)
- **판정·실행**: `deploy-verify.yml` 이 배포 직후 자동 검증하고, 실패가 확정되면 가드를 통과할 때
  자동 롤백한다. `rollback.yml`(수동 break-glass)은 그대로 유지된다.

---

## 1. 구성요소

| 파일 | 역할 |
|---|---|
| `helm/<svc>/values.yaml`, `*-deployment.yaml` | probe(startup=`/actuator/health`, readiness=`/actuator/health/readiness`, liveness=`/actuator/health/liveness`), `progressDeadlineSeconds: 180`, `revisionHistoryLimit`, `maxUnavailable:0`/`maxSurge:1` |
| `.github/actions/rollback-core/` | 롤백 코어 로직(대상 해석→치환→helm 렌더 검증→rebase-safe push). 수동/자동이 공유 |
| `.github/workflows/rollback.yml` | 수동(`workflow_dispatch`) 롤백. 사람이 실행한 것 = main 직접 push 승인 |
| `.github/workflows/deploy-verify.yml` | 배포 검증 + last-good 마킹 + (실패 시) 자동 롤백. `repository_dispatch`/`workflow_dispatch` |
| `.github/scripts/verify-deploy.sh` | ArgoCD sync(기대 infra_sha)+Healthy+rollout status 판정 → healthy/degraded/timeout/inconclusive |
| `.github/scripts/rollback-guards.sh` | 롤백 여부 판단(킬 스위치·화이트리스트·루프 차단·서킷 브레이커·크로스체크) |
| `terraform/github-actions-eks.tf` | 러너가 EKS/ECR 상태를 read-only 조회할 IAM Role + EKS Access Entry |
| `argocd/bootstrap/ci-readonly-rbac.yaml` | 위 역할의 클러스터 내부 RBAC(get/list/watch 만) |
| `argocd/bootstrap/argocd-notifications-cm.yaml` | sync 실패/Degraded → Discord. `oncePer: revision` 스팸 억제 |
| `helm/observability/alerts/alert.rules.yml` | `BackendPodCrashLooping`/`BackendTargetDown`/`BackendHigh5xxRate` → Discord (보조 신호) |

대상 서비스: `identity-service` `study-service` `content-service` `calendar-service`
`notification-service` (EKS 배포 대상 5개). `gateway-service` 는 Istio 로 대체되어 제외,
`frontend` 는 S3 정적 배포라 이 구조의 대상이 아니다(별도 과제).

---

## 2. 동작 흐름

```
서비스레포 main push → CI: 이미지 빌드 + ECR push
  → CI: infra/helm/<svc>/values.yaml 태그 bump 커밋 → infra main push  (infra 커밋 SHA 캡처)
  → CI: repository_dispatch(deploy-verify, {service, infra_sha}) → groovy-infra

deploy-verify.yml
  1. ArgoCD Application 이 infra_sha 로 sync(Succeeded) 될 때까지 대기 (~8분)
  2. health.status == Healthy  &&  kubectl rollout status deployment/<svc>
  3-a. Healthy → git tag -f last-good/<svc> <infra_sha> && push, Discord ✅
  3-b. 실패 → rollback-guards.sh 로 판단:
        - verify=timeout/inconclusive        → abstain (불확실은 롤백 안 함)
        - AUTO_ROLLBACK_ENABLED != true       → detect-only (알림만)
        - <svc> ∉ AUTO_ROLLBACK_SERVICES      → abstain
        - 대상 커밋이 revert(...) / 봇 bump 아님 → abstain (루프 차단)
        - 최근 6h revert 과다                  → circuit_break (중단 + page)
        - 이전 RS 도 죽음 / platform·identity 비정상 / 클러스터 알림 firing → abstain
        - 위 전부 통과                         → rollback
  4. rollback → rollback-core: last-good/<svc> 이미지 태그로 values.yaml 되돌려 main 에 push
  5. 롤백 후 재검증 → Healthy 면 Discord ↩️ 완료 / 아니면 Discord 🚨 @here
```

수동 경로: `groovy-infra → Actions → Rollback service image tag` 실행
(`service` 선택, `to_sha` 는 비우면 `last-good/<svc>` 사용, 특정 태그로 가려면 직접 입력).

---

## 3. 안전 설계 (자동 롤백이 오작동하지 않도록)

- **불확실은 롤백하지 않는다.** 러너↔EKS API 단절, ArgoCD 응답 없음, sync 정체 등 판정 불가
  상황(`inconclusive`/`timeout`)은 롤백하지 않고 사람을 호출한다.
- **새 리비전에 귀속되는 신호에서만 롤백한다.** 판정은 ArgoCD health + `kubectl rollout status`
  (새 ReplicaSet 을 지켜봄). `up==0`(서비스 전체)·노드/의존성 알림은 롤백 트리거로 쓰지 않는다.
- **배포 무관 장애 필터** (rollback-guards.sh):
  - 이전 ReplicaSet 도 available=0 → 클러스터/의존성 문제로 보고 abstain
  - `platform`(kafka/redis) 또는 `identity-service`(JWKS) Application 이 Healthy 아님 → abstain
  - Alertmanager 에 Node/Kube/APIServer/TargetDown 계열 알림 firing → abstain (best-effort)
- **루프 차단**: 대상 커밋이 `revert(` 로 시작하면 롤백 안 함. auto 모드는 `chore(<svc>): bump
  image tag` (github-actions 봇) 커밋만 대상.
- **서킷 브레이커**: 최근 6시간 `revert(<svc>)` ≥ 2 또는 전체 `revert(` ≥ 4 → `circuit_break`
  → 자동 롤백 중단, `AUTO_ROLLBACK_ENABLED` 를 끄고 수동 조사.
- **폐루프**: 롤백 push 후 재검증까지 하고, 실패하면 job 을 실패로 남기고 `@here` 알림.

---

## 4. 운영 (활성화 / 킬 스위치)

**GitHub repo variables** (`groovy-infra` → Settings → Secrets and variables → Actions → Variables):

| 변수 | 값 | 의미 |
|---|---|---|
| `AUTO_ROLLBACK_ENABLED` | `true` / `false` | 전역 킬 스위치. `false` 면 검증·last-good 마킹만 하고 롤백 안 함 |
| `AUTO_ROLLBACK_SERVICES` | 예: `content-service study-service` / 비활성 시 `none` | 자동 롤백을 켤 서비스(공백/쉼표 구분). 게이트(P6) 통과분만. GitHub Actions 변수는 빈 값을 못 받으므로 "없음"은 `none` 으로 둔다 |

**GitHub secret**: `DISCORD_WEBHOOK_URL` — deploy-verify/rollback 워크플로의 Discord 알림용
(ArgoCD notifications 의 ESO 시크릿과 별개).

**Secrets Manager**: `groovy/prod/argocd-notifications` 에 `discordWebhookUrl` 등록돼 있어야
ArgoCD Discord 알림이 동작한다(`argocd-notifications-secret.yaml`).

**브랜치 보호**: `main` 에 PR 필수 규칙이 있으면 rollback-bot 의 직접 push 를 우회 대상에
추가해야 한다(break-glass). 메모리 원칙 "dev/main 직접 push 금지"의 명시적 예외.

**Terraform**: `terraform/github-actions-eks.tf` 의 access entry 는 콘솔 선생성 시
`terraform import` 후 apply (eks-access.tf 와 동일 주의).

**롤아웃 순서** (계획 P5~P6):
1. `AUTO_ROLLBACK_ENABLED=false` 로 두고 detect-only 로 며칠 운영 → 오탐률 확인
2. additive-only 마이그레이션 게이트(각 서비스 레포 CI) 통과한 저위험 서비스 1곳을
   `AUTO_ROLLBACK_SERVICES` 에 추가, `AUTO_ROLLBACK_ENABLED=true`
3. 안정되면 서비스 순차 확대

---

## 5. 한계 (그대로 남는 것)

- **DB 스키마(Flyway)는 롤백되지 않는다.** 파괴적 마이그레이션이 포함된 배포는 이미지 롤백으로
  복구 불가 → 각 서비스 레포 CI 의 additive-only 게이트를 통과한 서비스만 자동 롤백을 켠다.
  파괴적 변경은 expand/contract 로 ≥2 릴리스에 나눈다.
- **배포가 원인이 아닌 장애**(트래픽 급증·노드 장애·외부 의존성 다운)는 자동 롤백 대상이 아니다.
  3절 필터로 abstain 되고, 기존 Prometheus/Alertmanager→Discord 로 온콜에 전달된다.
- **감지→롤백 소요 ~5–8분** (ArgoCD 폴링 3분 + sync + rollout). 더 빠르게 하려면 ArgoCD 웹훅
  (계획 P7).
- **Prometheus 는 Service DNS 단일 타깃 스크레이프**라 revision 단위 귀속이 안 된다. 자동 판정은
  ArgoCD health + rollout status 에만 의존하고, `alert.rules.yml` 은 보조 신호다.
- **"Ready 인데 5xx"** 는 (선택) ALB 스모크로만 부분 커버.
- replica≥2(HA) 상태에서 롤아웃/롤백 중 순단은 거의 없다. 5개 서비스 모두 `values-ha.yaml`
  활성(`argocd/apps/*.yaml`).

---

## 6. 참고 — 이전 수동 수정 내역 (#90~#94)

- **#90 probe**: 7개 차트에 startup/readiness/liveness probe + `maxUnavailable:0`/`maxSurge:1`
  + `revisionHistoryLimit:5` + `pullPolicy` 명시. (auto-rollback P1 에서 probe 를
  liveness/readiness 그룹으로 분리, `progressDeadlineSeconds:180` 추가.)
- **#91 HA**: `values-ha.yaml`(replica 2 / HPA minReplicas 2), PDB, topologySpread. 현재
  identity/study/content/calendar/notification 5개 서비스에서 활성.
- **#92 알림**: ArgoCD sync 실패/Degraded 알림에 직전 배포 커밋 + 롤백 방법, `oncePer` 중복 억제.
  (auto-rollback P4 에서 "직전 배포 revision" 이 infra 커밋 SHA 임을 명시하도록 문구 교정.)
- **#93 workflow**: `rollback.yml`. (P2 에서 견고화 + `rollback-core` 로 분리.)
- **#94 Prometheus 알림**: PodCrashLooping / TargetDown / High5xx → Discord.
