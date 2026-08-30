# 반자동 롤백 (semi-auto rollback)

배포 장애 시 해당 서비스의 이미지 태그를 이전 값으로 되돌리는 구조. 관련 이슈: #90 #91 #92 #93 #94.

---

## 1. 왜 자동이 아니라 반자동인가

- 완전 자동 = "배포 후 헬스 확인이 실패하면 자동으로 롤백을 트리거"하는 고리가 필요하다.
- 이 고리는 CI(GitHub Actions)가 ArgoCD/클러스터의 배포 상태를 조회할 수 있어야 성립한다.
- 현재 ArgoCD는 외부 노출이 없다(Ingress 미구축, port-forward 전용) → 러너가 배포 상태를 물어볼 수 없다.
- 그래서 "감지 → 실행" 사이를 사람이 잇는 반자동으로 구축했다.

## 2. 자동 롤백 구축 예정 시점

- **EKS 이관 + Ingress(ALB) 구축 이후.**
- 그때 서비스 배포 CI 끝에 `argocd app wait --health` 를 붙이고, 실패 시 롤백 워크플로를 자동 호출한다.
- 워크플로(`rollback.yml`) 자체는 그대로 두고, 트리거만 "수동 실행 → 자동 호출"로 바꾸면 된다.

## 3. 주요 수정 사항

### 3-1. probe 추가 (#90)

- 7개 배포 차트(백엔드 6 + frontend) Deployment에 startup / readiness / liveness probe 추가.
  - 백엔드: `GET /actuator/health` (api-gateway는 관리포트 8090), frontend: `GET /`.
- 함께 추가: `strategy.rollingUpdate(maxUnavailable:0, maxSurge:1)`, `revisionHistoryLimit:5`, `image.pullPolicy` 명시.
- 효과: readiness 실패 시 롤아웃이 멈추고 ArgoCD가 Degraded로 바뀐다. (기존엔 probe가 없어 앱이 깨져도 Healthy로 보였다.)

### 3-2. infra repo에 workflow 추가 (#93)

- `.github/workflows/rollback.yml` — 수동 실행(`workflow_dispatch`).
  - 입력: `service`(7종), `to_sha`(비우면 직전 태그 자동 추출), `reason`, `dry_run`.
  - 동작: `helm/<svc>/values.yaml` 의 `tag:` 한 줄만 치환 → `helm template` 검증 → main에 커밋·push.
  - `.github/` 는 ArgoCD 감시 대상 밖이라 배포에 영향 없음.
- 함께: ArgoCD 알림 강화(#92) — sync 실패/Degraded 알림에 직전 revision + 롤백 방법 문구, 중복 억제(`oncePer`).
- 함께: Prometheus 알림(#94) — PodCrashLooping / TargetDown / High5xx 3종 → Discord.

### 3-3. HA 수정 내역 (#91)

- 현재 전 서비스 replica=1 (미니 PC 자원 제약, JVM 메모리 테스트용 임시 상태).
- replica≥2용 코드를 미리 작성하되 **비활성** 상태로 둠:
  - `helm/<svc>/values-ha.yaml` 신규 — replicaCount 2 (또는 hpa.minReplicas 2), PDB, topologySpread.
  - `<svc>-pdb.yaml` 신규 — `pdb.enabled` 게이트. (replica=1에서 PDB를 켜면 노드 drain이 막히므로 기본 false.)
  - Deployment에 `topologySpreadConstraints` 조건부 블록. (값이 비면 렌더되지 않음.)
- 활성화 방법: `argocd/apps/<svc>.yaml` 의 `helm.valueFiles` 에 `- values-ha.yaml` 한 줄 추가.
- 기본값 그대로면 현재 동작은 바뀌지 않는다.

## 4. 현재 반자동 롤백 작동 흐름

1. 배포/리소스 문제로 Pod가 probe 실패 → NotReady·재시작, 롤아웃 정지  *(자동)*
2. ArgoCD Application이 Degraded로 전환  *(자동)*
3. Discord 알림: 현재 revision + 직전 revision + 롤백 방법  *(자동)*
4. (병행) Prometheus 알림 → Discord  *(자동)*
5. **사람이 알림 확인, 롤백 여부 판단**
6. **사람이 GitHub Actions에서 `rollback.yml` 실행** (service 지정)
7. 워크플로가 직전 태그로 `values.yaml` 수정 → main push  *(자동)*
8. ArgoCD가 커밋 감지 → 이전 이미지로 재배포  *(자동)*
9. 이전 이미지 Pod가 probe 통과 → 트래픽 복구, Healthy 복귀  *(자동)*
10. **사람이 복구 확인 + 근본 원인 수정(fix-forward)**

## 5. 사람이 하는 일 / 자동으로 되는 일

| 자동 | 사람 |
|---|---|
| 장애 감지 (probe, ArgoCD Health) | 알림 확인 |
| Discord 알림 발송 (ArgoCD / Prometheus) | 롤백이 맞는 처방인지 판단 |
| 직전 태그 산출, `values.yaml` 수정, main push | 롤백 워크플로 실행(트리거) |
| ArgoCD 재배포, 트래픽 복구 | 대상 서비스 / 태그 선택 |
| 복구 후 성공 알림 | 복구 확인, 근본 원인 수정 |

## 6. 현재 롤백의 한계점

- **완전 자동이 아님** — 감지는 자동이나 실행은 사람이 트리거해야 한다. 알림을 봐야 시작되므로 야간·휴일 대응이 느리다.
- **이미지 태그만 되돌림** — DB 스키마(Flyway)는 롤백되지 않는다. 파괴적 마이그레이션이 포함된 배포는 이미지 롤백으로 복구 불가 → "additive-only 마이그레이션" 규칙 병행 필요.
- **배포가 원인이 아닌 장애엔 무력** — 트래픽 급증·노드 장애·외부 의존성 다운 등은 태그를 되돌려도 그대로다. 스케일업 / HPA / 리밋으로 대응(별도 영역).
- **replica=1** — 롤백·롤아웃 중 순단이 발생한다. 무중단은 HA 프로파일(#91) 활성화가 필요.
- **직전 태그 자동 추출의 한계** — 과거 수동 태그가 섞인 경우(예: frontend) 자동값이 부정확할 수 있어 `to_sha` 를 직접 지정해야 한다.
- **main 직접 push (break-glass)** — 롤백 워크플로는 PR 없이 main에 직접 커밋한다.
