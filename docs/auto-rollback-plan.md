# 자동 롤백 구축 계획 (auto-rollback)

반자동 롤백(`docs/semi-auto-rollback.md`, 이슈 #90~#94)의 후속. "감지 → 실행" 사이의 사람 개입을
제거하되, 배포와 무관한 장애에는 자동 롤백이 개입하지 않도록 설계한다.

관련 분석: 이 문서 8절 "현재 구조 문제점 요약" 참고.

---

## 1. 배경 — 왜 지금 가능한가

반자동으로 둔 **유일한 기술적 차단 사유**는 "CI(GitHub Actions)가 ArgoCD/클러스터 배포 상태를
조회할 수 없다"였다(`semi-auto-rollback.md` 1절). 이는 해소되었다.

- EKS API 엔드포인트 공개 — `terraform/eks.tf` `endpoint_public_access = true`
- ALB Ingress 구축 — `helm/istio-gateway/templates/ingress.yaml` (AWS LB Controller, internet-facing)
- EKS Access Entry 체계 — `terraform/eks-access.tf`

→ ArgoCD 서버를 외부 노출할 필요 없이, 러너가 EKS API 로 `kubectl get application` /
`argocd app wait --health` 를 직접 호출해 배포 health 를 판정할 수 있다.

**단, 인그레스 외의 이유들은 남아 있다** (`semi-auto-rollback.md` 6절):

- DB 스키마(Flyway)는 롤백되지 않음 → 파괴적 마이그레이션 배포엔 이미지 롤백이 오히려 위험
- 배포가 원인이 아닌 장애(트래픽/노드/네트워크/외부 의존성)는 태그를 되돌려도 안 고쳐짐
- 직전 태그 자동 추출이 부정확
- `main` 직접 push 를 "사람 실행 = 승인"으로 갈음하던 설계

이 계획의 P4~P6 이 위 항목들을 각각 방어한다.

---

## 2. 목표 아키텍처

```
서비스레포 main push
  → CI: 이미지 빌드 + ECR push
  → CI: infra/helm/<svc>/values.yaml 태그 bump 커밋 → infra main push   ← infra 커밋 SHA 캡처
  → CI: repository_dispatch(type=deploy-verify, {service, infra_sha})  →  groovy-infra   [신규]
        │
        ▼
  infra/.github/workflows/deploy-verify.yml   [신규]
    1. ArgoCD Application 이 infra_sha 로 sync(Succeeded) 될 때까지 대기 (타임아웃 ~8분)
    2. health 판정:
         - app.status.health.status == Healthy
         - kubectl rollout status deployment/<svc> -n groovy-application
         - (선택) https://api.groovy-team26.com/<path>/actuator/health ALB 스모크
    3. 정상  → git tag -f last-good/<svc> <infra_sha> && push,  Discord ✅
    4. 실패  → 3절 가드 + 4절 크로스체크 통과 시  rollback 로직 호출 (last-good/<svc> 로 복귀)
    5. 롤백 후 재검증 → 정상이면 Discord ✅ / 실패면 Discord 🚨 @here (에스컬레이션)
```

- 검증·롤백 로직은 **infra 레포에 집중**. 서비스 CI 는 "배포했다"만 신호로 전송 →
  EKS 자격증명이 한 곳에만 존재.
- 전송 수단: `repository_dispatch`. 서비스 레포에 이미 있는 `INFRA_REPO_PAT` 재사용
  (`build-and-deploy.yml` 의 "Checkout groovy-infra" 스텝에서 사용 중).
- `rollback.yml` 은 워크플로로 유지(수동 break-glass 경로). 공통 스텝은 reusable workflow /
  composite action 으로 추출해 `deploy-verify.yml` 과 공유.

---

## 3. 설계 원칙

1. **불확실은 롤백하지 않는다.** 판정에 필요한 신호를 못 얻으면(러너↔API 단절, ArgoCD 응답 없음,
   API 스로틀, sync 가 `Error` 로 정체) 백오프 재시도 후 그래도 불가하면 **abstain + page**.
   `kubectl` 호출 실패를 "배포 불건강"으로 해석하지 않는다(fail-safe).
2. **새 리비전에 귀속되는 신호에서만 롤백한다.** `kubectl rollout status` 는 새 ReplicaSet 을
   지켜본다. cluster-scope 알림, `up==0`(서비스 전체), 노드/의존성 알림은 롤백 트리거로 쓰지 않는다.
3. **가드 우선.** 봇이 만든 `chore(<svc>): bump image tag` 커밋만 대상. `revert(` 로 시작하는
   커밋은 절대 트리거하지 않는다(롤백-of-롤백 루프 차단). 배포 1건당 자동 롤백 1회.
4. **서킷 브레이커.** 같은 서비스 M시간 내 N회, 또는 짧은 시간에 여러 서비스가 동시 실패 →
   전역 자동 롤백 비활성 + page. (동시 다발 실패는 코드가 아니라 인프라 문제 신호)
5. **킬 스위치.** repo variable `AUTO_ROLLBACK_ENABLED`(전역) + `AUTO_ROLLBACK_SERVICES`
   (서비스 화이트리스트). 워크플로 진입 시 확인.
6. **검증 창 한정.** 배포 후 ~10분 안의 실패만 자동 롤백 스코프. 이후 장애는 알림→온콜.

---

## 4. 배포와 무관한 장애 처리

| 상황 | verify 가 받는 것 | 처리 |
|---|---|---|
| 러너↔EKS API 블립, API 스로틀, ArgoCD 컨트롤러 느림 | 에러/타임아웃 | 백오프 재시도 → 불가 시 **abstain + page** |
| ArgoCD sync 가 `Error`/재시도 중 (git pull 실패 등) | `phase != Succeeded` | 새 버전 미기동 → 판정 불가 → **abstain + page** |
| 노드 장애 / 네트워크 파티션 / eviction | 신·구 RS 동시 불건강 | 크로스체크 4-1 에서 "배포 탓 아님" → **abstain + page** |
| RDS failover / Kafka / Redis / JWKS 다운 | readiness 실패가 신·구 Pod 에 동일 | 크로스체크 4-1·4-2 → **abstain + page** |
| ECR 일시 스로틀로 `ImagePullBackOff` 후 자체 해소 | 재확인(30s×2) 시 회복 | 디바운스 통과 못 함 → 롤백 안 함 |
| 트래픽 스파이크 / HPA 스케일 지연 → 5xx·지연 | 새 RS 는 Available, rollout 정상 | 롤백 트리거 아님 → HPA/스케일 대응(별도 영역) |

**롤백 실행 전 크로스체크** (확정 실패를 봤어도 모두 통과해야 push):

1. **신·구 ReplicaSet 비교** — 새 RS 만 불건강하고 이전 리비전 Pod 는 Ready 인가? 같이 죽으면 abstain.
2. **공유 의존성** — RDS 도달 가능? Kafka/Redis? `identity-service` 자체 Healthy? 하나라도 down → abstain.
3. **cluster-scope 알림** — Alertmanager 에 노드/네트워크/인프라 알림 firing 중이면 abstain.
4. **ECR 이미지 존재** — 롤백 타깃 이미지가 실제 있는가.

**probe 분리(P1)로 의존성 블립 원천 차단**: `livenessProbe` → `/actuator/health/liveness`
(프로세스 생존만) 라 Kafka/RDS 블립으로 컨테이너 재시작이 안 남 → 오탐 롤백 없음.
`readinessProbe` → `/actuator/health/readiness`.

**오탐이 뚫린 경우**: 이전 정상 이미지로 복귀 + 서비스 정상, 비용은 롤아웃 1회 + fix-forward 1회.
Discord 에 "무엇을·왜 롤백했는지 + 근거(신·구 RS 상태, 의존성 체크 결과)" 를 남긴다.

---

## 5. Phase 계획

| Phase | 내용 | 주요 산출물 | 위험도 |
|---|---|---|---|
| **P1** 감지 신뢰성 | probe liveness/readiness 분리, `progressDeadlineSeconds: 180` | `helm/<svc>/values.yaml`, `*-deployment.yaml` (×5) | 낮음 |
| **P2** `rollback.yml` 견고화 | 주입 제거·입력 검증·ECR 확인·HA 렌더·push 레이스 방어·실패 통보 | `.github/workflows/rollback.yml` | 낮음 |
| **P3** EKS 조회 권한 | GitHub Actions OIDC IAM Role + Access Entry + 최소 RBAC | `terraform/github-actions-eks.tf`(신규), `terraform/eks-access.tf`, `argocd/bootstrap/ci-readonly-rbac.yaml`(신규) | 중간 |
| **P4** known-good 마커 + verify 골격 | `deploy-verify.yml`(수동 dispatch) — 배포 후 Healthy 확인 시 `last-good/<svc>` 기록. `rollback.yml` 타깃 해석을 이걸로 | `.github/workflows/deploy-verify.yml`(신규), `rollback.yml` | 중간 |
| **P5** 자동 트리거 (1개 서비스 opt-in) | `deploy-verify.yml` ← `repository_dispatch`, 가드/서킷브레이커/킬스위치, 서비스 1곳 CI 연결, dry-run → 실배포 | `deploy-verify.yml`, 서비스 `build-and-deploy.yml` (1곳) | 높음 |
| **P6** 확대 + DB 게이트 | additive-only Flyway CI 체크, 통과 서비스부터 순차 활성화, 문서 개정 | 서비스 레포 CI(신규 워크플로/스텝), `docs/auto-rollback.md` | 중간 |
| **P7** (선택/후속) | ArgoCD 웹훅으로 폴링 지연 제거, VPC 내 self-hosted 러너로 API CIDR 잠금, Argo Rollouts PoC | — | — |

각 Phase = 이슈 1개, `feat(#N): ...` 커밋, 완료 후 다음 Phase (팀 GitOps 워크플로).

### P1 — 감지 신뢰성

- `livenessProbe.httpGet.path` → `/actuator/health/liveness`, `readinessProbe.httpGet.path` →
  `/actuator/health/readiness`. `startupProbe` 는 통합 `/actuator/health` 유지.
  - 전제: 각 서비스가 Spring Boot health group 을 노출해야 함
    (`management.endpoint.health.probes.enabled=true`, k8s 프로필 기본값). 미노출 서비스는
    서비스 레포 `application.yml` 에 설정 추가 (P1 하위 작업, 서비스 레포 수정).
- `rollout.progressDeadlineSeconds: 180` 값 추가 + Deployment 템플릿에 `spec.progressDeadlineSeconds`
  렌더. Degraded 전환 10분 → 3분.
- 1개 서비스 선적용 → 콜드스타트가 180s 안에 드는지 실측 후 5개 반영.

### P2 — `rollback.yml` 견고화 (트리거는 아직 수동)

- `${{ inputs.* }}` 를 `run:` 에서 `env:` 로 이동, `"$SERVICE"`/`"$TO_SHA"`/`"$REASON"` 참조 (주입 제거).
- `to_sha` 형식 검증: `^[0-9a-f]{7,40}$` 아니면 실패.
- 커밋 전 ECR 이미지 존재 확인: `aws ecr describe-images --repository-name groovy-<svc>
  --image-ids imageTag=<target>`.
- `helm template` 을 해당 `argocd/apps/<svc>.yaml` 이 쓰는 `-f values.yaml -f values-ha.yaml`
  동일 세트로 렌더.
- commit 직전 `git fetch origin main && git rebase origin/main`, 실패 시 3회 재시도, rebase 충돌 시 중단 + 알림.
- 워크플로 실패 시 Discord 통보.
- 공통 스텝 → reusable workflow / composite action 추출.

### P3 — EKS 조회 권한

- `terraform/github-actions-eks.tf`(신규): OIDC IAM Role `groovy-github-actions-eks-readonly`,
  trust `repo:KDT-Team26@*/groovy-infra@*:ref:refs/heads/main`.
- `terraform/eks-access.tf`: `aws_eks_access_entry`(해당 Role, `kubernetes_groups=["groovy-ci-readonly"]`)
  + `aws_eks_access_policy_association` `AmazonEKSViewPolicy`.
- `argocd/bootstrap/ci-readonly-rbac.yaml`(신규): `ClusterRole` — `applications.argoproj.io`
  (get/list/watch), `deployments`/`replicasets`/`pods`(get/list) → `ClusterRoleBinding` to
  group `groovy-ci-readonly`. (ClusterAdmin 금지)
- 검증: `kubectl get application -n argocd` 만 출력하는 임시 워크플로 → 확인 후 제거.
- API 엔드포인트 CIDR 는 현재 전체 개방 유지(블로커 아님). 잠금은 P7.

### P4 — known-good 마커 + verify 골격

- `git log -p` diff 스크래핑(현 `rollback.yml` 자동 추출) 폐기.
- `deploy-verify.yml`(이 단계에선 `workflow_dispatch` 수동): 배포 Healthy 확인 후
  `git tag -f last-good/<service> <infra_sha> && git push -f origin last-good/<service>`.
- `rollback.yml` 타깃 해석: `to_sha` 미지정 시 `last-good/<service>` 커밋 시점의 `values.yaml`
  태그 사용. 설정 커밋이 섞여도, 연쇄 장애여도 "마지막으로 Healthy 였던 태그" 로 정확히 복귀.
- `to_sha` 수동 지정은 break-glass 로 유지.

### P5 — 자동 트리거 (저위험 서비스 1곳 opt-in)

- `deploy-verify.yml` 을 `on: repository_dispatch: [deploy-verify]` 로 확장.
  payload `{ service, infra_sha }`.
  - 대기: `sync.revision == infra_sha && operationState.phase == Succeeded` (타임아웃 8분).
  - 판정: `health.status == Healthy` + `kubectl rollout status ... --timeout=200s`.
  - 실패 → 3절 가드 + 4절 크로스체크 후 rollback 로직 호출.
- 가드/서킷브레이커/킬스위치(3절 3~5) 구현.
- 단계적 활성화:
  1. **detect-only(dry-run)** 배포 — 감지·알림만, push 안 함. 며칠 오탐률 관찰.
  2. 저위험 서비스 1곳(예: `content-service`)만 `AUTO_ROLLBACK_SERVICES` 에 추가해 실제 on.
- 서비스 CI(`build-and-deploy.yml`, 해당 1곳): infra 체크아웃의 `git rev-parse HEAD` 캡처 →
  태그 bump push 뒤 `repository_dispatch` 전송(`INFRA_REPO_PAT`).

### P6 — 확대 + DB 마이그레이션 게이트

- 서비스 레포 CI 에 additive-only 체크: 신규 Flyway 마이그레이션에 `DROP` / `ALTER ... DROP` /
  `RENAME` 이 있고 라벨 `expand-contract` 가 없으면 실패.
- 정책 문서화: 자동 롤백은 이미지 전용. 파괴적 스키마 변경은 expand/contract 로 ≥2 릴리스 분할.
  미준수 서비스는 `AUTO_ROLLBACK_SERVICES` 에서 제외(opt-in 유지).
- 게이트 통과 서비스부터 순차 활성화.
- `docs/semi-auto-rollback.md` → `docs/auto-rollback.md` 개정 (아래 드리프트 C1~C3 현행화).

### P7 — 후속 (선택)

- ArgoCD 웹훅: infra 레포 → argocd-server `/api/webhook`, sync 폴링 3분 지연 제거
  (argocd-server 를 기존 ALB 에 경로+인증으로 노출 필요).
- VPC 내 self-hosted 러너 → `endpoint_public_access_cidrs` 를 러너 IP 로 잠금.
- Argo Rollouts PoC: 카나리 + AnalysisTemplate 자동 abort. 전 Deployment→Rollout 전환 비용.

---

## 6. 수정 영역

### groovy-infra (대부분)

| 파일 | Phase | 신규/수정 |
|---|---|---|
| `helm/<svc>/values.yaml` (identity/study/content/calendar/notification) | P1 | 수정 (probe path, progressDeadlineSeconds) |
| `helm/<svc>/templates/<svc>-deployment.yaml` (×5) | P1 | 수정 (progressDeadlineSeconds 렌더) |
| `.github/workflows/rollback.yml` | P2, P4 | 수정 |
| `.github/workflows/deploy-verify.yml` | P4, P5 | **신규** |
| `.github/actions/rollback-core/` (또는 reusable workflow) | P2 | **신규** (공통 스텝 추출) |
| `terraform/github-actions-eks.tf` | P3 | **신규** |
| `terraform/eks-access.tf` | P3 | 수정 (access entry 추가) |
| `argocd/bootstrap/ci-readonly-rbac.yaml` | P3 | **신규** |
| `argocd/bootstrap/argocd-notifications-cm.yaml` | P4 | 수정 (알림 문구: "직전 배포 revision" → last-good 태그 안내로 교정) |
| `docs/auto-rollback-plan.md` / `docs/auto-rollback.md` | P0, P6 | **신규** / 개정 |

### 백엔드 MS 레포 — **워크플로 파일만은 아님**

| 대상 | Phase | 내용 |
|---|---|---|
| `.github/workflows/build-and-deploy.yml` | P5 | infra 커밋 SHA 캡처 + `repository_dispatch` 전송 (자동 롤백 opt-in 서비스만) |
| `.github/workflows/*` (신규 Flyway lint) | P6 | additive-only 마이그레이션 체크 워크플로/스텝 |
| `src/main/resources/application*.yml` | P1 | health probe group 미노출 서비스만 `management.endpoint.health.probes.enabled` 등 설정 추가 |

대상 서비스: 실제 EKS 배포 대상 5개(identity/study/content/calendar/notification).
`groovy-gateway-service` 는 Istio 로 대체되어 chart·배포 없음 → 제외.

### 손대지 않는 영역

- `groovy-common` — 무관.
- `groovy-frontend` — S3 정적 배포라 이 계획의 자동 롤백 대상 아님. 별도 과제
  (S3 버전 관리 + CloudFront 무효화 롤백)로 분리.
- 서비스 애플리케이션 비즈니스 코드 — P1 의 `application.yml` health 설정 외에는 무변경.

### 코드가 아닌 설정 변경 (GitHub / AWS 콘솔)

- infra `main` 브랜치 보호: rollback 봇/워크플로에 "required PR 우회" 예외.
- repo variables: `AUTO_ROLLBACK_ENABLED`, `AUTO_ROLLBACK_SERVICES`.
- Secrets Manager: `groovy/prod/argocd-notifications` (`discordWebhookUrl`) 실제 등록
  — 현재 미등록이라 ArgoCD Discord 알림 경로가 죽어 있음 (`argocd-notifications-secret.yaml` 주석).

---

## 7. 남은 리스크 / 사전 결정

- **Prometheus revision 귀속 불가** — 자동 판정은 ArgoCD health + `kubectl rollout status` 에
  의존. 메트릭 기반 자동 롤백은 P7(Rollouts) 또는 per-pod 스크레이프 전환이 별도 필요.
- **감지→롤백 push 소요 ~5–8분** (ArgoCD 폴링 3분 + sync + rollout). 허용 불가 시 P7 웹훅을 앞당김.
- **"Ready 인데 5xx"** 는 ALB 스모크(선택 스텝)로만 부분 커버.
- **트리거 전송 방식**: `repository_dispatch`(기존 PAT 재사용) 권장 vs GitHub App.
- **수동 승인 게이트**: 두지 않음 권장(자동화 취지). 대신 큰 알림 + 손쉬운 fix-forward.

---

## 8. 현재 구조 문제점 요약 (계획의 근거)

### rollback.yml
- A1. 직전 태그 자동 추출(`git log -p | grep '^-    tag:'`)이 "한 칸 뒤" 를 보장 못 함 —
  태그 bump 후 설정 커밋이 쌓이면 과도 롤백. → P4 known-good 마커로 해결.
- A2. `${{ inputs.reason/to_sha }}` 를 `run:` 셸에 텍스트 치환 → 명령 주입. → P2.
- A3. `git push origin HEAD:main` 에 rebase/재시도 없음 → 배포와 레이스 시 실패. → P2.
- A5. `helm template` 이 `values.yaml` 만 렌더(실제는 +`values-ha.yaml`), 이미지 존재 미확인. → P2.
- A6. `to_sha` 형식 미검증. → P2.
- A7. 롤백 결과 확인·통보 없음. → P4/P5 폐루프 검증.

### 감지·알림
- B1. ArgoCD "직전 배포 revision" = infra 커밋 SHA ≠ 이미지 태그(서비스 커밋 SHA). 알림 문구가
  이걸 `to_sha` 로 쓰라고 오안내. → P4 에서 문구 교정 + last-good 태그 안내.
- B2. `progressDeadlineSeconds` 미설정 → Degraded 전환 최대 10분. → P1.
- B3. Prometheus 가 Service DNS 단일 타깃 스크레이프 → HA 상태에서 나쁜 Pod 1개는 `up==0` 안 뜸,
  revision 귀속 불가. → 자동 판정은 ArgoCD/rollout status 에 의존(7절).
- B4. `/actuator/health` 통합 엔드포인트를 3개 probe 모두 사용 → 의존성 블립이 liveness 를 죽여
  CrashLoop → 오탐. → P1 probe 분리.
- B5. `groovy/prod/argocd-notifications` 시크릿 미등록 → Discord 알림 경로 사망 가능. → 6절 설정.

### 문서·코드 드리프트
- C1. `semi-auto-rollback.md` "백엔드 6 + frontend = 7종", "전 서비스 replica=1" → 실제 백엔드
  5개 chart, 5개 서비스 `values-ha.yaml` 로 replica≥2 활성.
- C2. `helm/identity-service/values.yaml` "미니 PC 자원 제약으로 1 고정" 주석 stale.
- C3. `rollback.yml` 헤더 주석 "service 7종" vs `options` 5종.

---

## 부록 A. Phase별 이슈 초안

> 리포지터리: `KDT-Team26/groovy-infra` (P6 의 Flyway 체크·health 설정만 각 서비스 레포).
> 라벨 예시는 팀 컨벤션에 맞게 조정.

---

### 이슈 #A — [P1] 배포 감지 신뢰성: probe liveness/readiness 분리 + progressDeadlineSeconds

**labels**: `enhancement`, `helm`, `auto-rollback`

**배경**
자동 롤백은 "새 리비전이 건강한가" 를 빠르고 정확하게 판정할 수 있어야 한다. 현재:
- 3개 probe 모두 통합 `/actuator/health` 사용 → DB/Kafka/Redis 블립이 liveness 를 죽여
  컨테이너 재시작(CrashLoop) 유발 → 배포가 멀쩡해도 오탐.
- `progressDeadlineSeconds` 미설정(기본 600s) → 새 Pod 가 Ready 안 되는 경우 ArgoCD Degraded
  전환까지 최대 10분.

**작업 내용**
- [ ] `helm/<svc>/values.yaml` (identity/study/content/calendar/notification):
  - [ ] `probes.liveness.httpGet.path` → `/actuator/health/liveness`
  - [ ] `probes.readiness.httpGet.path` → `/actuator/health/readiness`
  - [ ] `probes.startup` 은 `/actuator/health` 유지
  - [ ] `rollout.progressDeadlineSeconds: 180` 추가
- [ ] `helm/<svc>/templates/<svc>-deployment.yaml`: `spec.progressDeadlineSeconds` 렌더 추가
- [ ] 서비스 레포 `application*.yml` 에 health probes group 미노출 시 활성화 (하위 작업, 서비스별)
- [ ] 1개 서비스 선적용 → 콜드스타트가 180s 내 기동 확인 → 나머지 반영

**완료 조건**
- `helm template` 결과에 3종 probe 가 분리 경로로 렌더되고 `progressDeadlineSeconds: 180` 포함
- 스테이징/실환경 1개 서비스에서 정상 롤아웃 확인, 의도적 bad image 시 3분 내 Degraded 확인

**의존성**: 없음 (독립 배포 가능)

---

### 이슈 #B — [P2] rollback.yml 견고화 (주입 제거 · 입력 검증 · ECR 확인 · push 레이스 방어)

**labels**: `security`, `ci`, `auto-rollback`

**배경**
현 `rollback.yml` 은 수동 실행 전제로 작성되어 자동화 시 위험한 지점이 있다 (문제점 A2/A3/A5/A6/A7).

**작업 내용**
- [ ] `${{ inputs.* }}` 를 모든 `run:` 스텝에서 `env:` 로 이동, `"$SERVICE"`/`"$TO_SHA"`/`"$REASON"` 참조
- [ ] `to_sha` 형식 검증: `^[0-9a-f]{7,40}$` 불일치 시 실패
- [ ] 커밋 전 ECR 이미지 존재 확인 (`aws ecr describe-images ... imageTag=<target>`)
- [ ] `helm template` 을 `argocd/apps/<svc>.yaml` 의 valueFiles 세트(`values.yaml` + `values-ha.yaml`)로 렌더
- [ ] commit 직전 `git fetch origin main && git rebase origin/main` + 3회 재시도, 충돌 시 중단 + Discord 알림
- [ ] 워크플로 실패(모든 경로) 시 Discord 통보
- [ ] 공통 스텝을 `.github/actions/rollback-core` composite action (또는 reusable workflow) 로 추출

**완료 조건**
- `reason` 에 `` `$(...)` `` 삽입해도 명령 실행 안 됨 (주입 테스트)
- 잘못된 `to_sha` / 존재하지 않는 이미지 태그로 실행 시 커밋 전 실패
- 롤백 도중 infra main 에 다른 커밋이 들어와도 rebase 후 성공하거나 명확히 실패+알림

**의존성**: 없음

---

### 이슈 #C — [P3] GitHub Actions 용 EKS 읽기 전용 접근 (OIDC Role + Access Entry + RBAC)

**labels**: `terraform`, `iam`, `rbac`, `auto-rollback`

**배경**
verify 워크플로가 EKS API 로 ArgoCD Application / Deployment 상태를 조회하려면 최소 권한 자격증명이 필요하다. 현재 Access Entry 는 `user/groovy_tt`(admin) 와 노드 롤만 존재.

**작업 내용**
- [ ] `terraform/github-actions-eks.tf` (신규): OIDC IAM Role `groovy-github-actions-eks-readonly`,
      trust condition `repo:KDT-Team26@*/groovy-infra@*:ref:refs/heads/main`
- [ ] `terraform/eks-access.tf`: `aws_eks_access_entry` (해당 Role, `kubernetes_groups = ["groovy-ci-readonly"]`)
      + `aws_eks_access_policy_association` (`AmazonEKSViewPolicy`, scope cluster)
- [ ] `argocd/bootstrap/ci-readonly-rbac.yaml` (신규): `ClusterRole` (applications.argoproj.io get/list/watch,
      deployments/replicasets/pods get/list) + `ClusterRoleBinding` → group `groovy-ci-readonly`
- [ ] 임시 검증 워크플로로 `kubectl get application -n argocd` / `kubectl rollout status` 동작 확인 후 제거

**완료 조건**
- 새 Role 로 assume 한 러너가 Application/Deployment 를 read 가능, write/delete 는 거부됨
- `terraform plan` 이 기존 리소스 변경 없이 신규만 추가

**의존성**: 없음 (P4 이전에 완료)

---

### 이슈 #D — [P4] known-good 태그 마커 + deploy-verify 워크플로 골격 (수동 트리거)

**labels**: `ci`, `auto-rollback`

**배경**
현 자동 태그 추출(A1)은 부정확하다. "마지막으로 Healthy 로 검증된 태그" 를 명시적으로 기록하고,
롤백 타깃을 이걸로 삼는다. 이 이슈까지는 트리거를 수동(`workflow_dispatch`)으로 둔다.

**작업 내용**
- [ ] `.github/workflows/deploy-verify.yml` (신규, `workflow_dispatch`, inputs: `service`, `infra_sha`):
  - [ ] ArgoCD Application 이 `infra_sha` 로 sync(`operationState.phase == Succeeded`) 될 때까지 폴링 (타임아웃 8분)
  - [ ] `health.status == Healthy` + `kubectl rollout status deployment/<svc> -n groovy-application --timeout=200s`
  - [ ] 정상 → `git tag -f last-good/<service> <infra_sha> && git push -f origin last-good/<service>`, Discord ✅
  - [ ] 실패/타임아웃 → Discord 경고 (이 단계에선 롤백 호출 안 함)
- [ ] `rollback.yml` 타깃 해석 수정: `to_sha` 미지정 시 `last-good/<service>` 커밋 시점의 `values.yaml` `tag:` 사용
- [ ] `git log -p | grep` 자동 추출 로직 제거
- [ ] `argocd/bootstrap/argocd-notifications-cm.yaml` 알림 문구: "직전 배포 revision" 안내를
      "`to_sha` 는 비워서 last-good 사용" 으로 교정 (B1)

**완료 조건**
- 정상 배포 후 `deploy-verify` 수동 실행 → `last-good/<svc>` 태그가 해당 infra SHA 로 갱신
- `rollback.yml` 을 `to_sha` 없이 실행 → last-good 태그 기준으로 정확히 복귀 (설정 커밋이 사이에 있어도)

**의존성**: 이슈 C (EKS 접근), 이슈 B (rollback 공통 로직)

---

### 이슈 #E — [P5] 자동 트리거 연결 + 가드/서킷브레이커/킬스위치 (1개 서비스 opt-in)

**labels**: `ci`, `auto-rollback`, `high-risk`

**배경**
verify 를 `repository_dispatch` 로 자동 호출하고, 실패 시 가드를 통과하면 롤백까지 자동 실행한다.
저위험 서비스 1곳에서 dry-run → 실배포 순으로 검증한다.

**작업 내용**
- [ ] `deploy-verify.yml` 에 `on: repository_dispatch: [deploy-verify]` 추가 (payload `{service, infra_sha}`)
- [ ] 진입 가드:
  - [ ] `AUTO_ROLLBACK_ENABLED` != true → 즉시 종료
  - [ ] `service` ∉ `AUTO_ROLLBACK_SERVICES` → 검증만, 롤백 안 함
  - [ ] 대상 커밋이 `github-actions[bot]` 의 `chore(<svc>): bump image tag` 가 아니면 롤백 안 함
  - [ ] 커밋 메시지가 `revert(` 로 시작 → 절대 롤백 안 함
- [ ] 크로스체크(문서 4절): 신·구 ReplicaSet 비교 / 공유 의존성(RDS·Kafka·Redis·identity Healthy) /
      Alertmanager cluster-scope 알림 / ECR 이미지 존재 — 하나라도 실패 시 abstain + Discord 🚨
- [ ] 서킷 브레이커: 같은 서비스 M시간 N회 초과 또는 단시간 다서비스 동시 실패 → `AUTO_ROLLBACK_ENABLED` off + page
- [ ] 롤백 후 재검증 → 정상 Discord ✅ / 실패 Discord 🚨 `@here`
- [ ] `DRY_RUN` 모드: 감지·알림만, push 안 함
- [ ] 서비스 1곳(`content-service` 등) `build-and-deploy.yml`: infra 체크아웃 `git rev-parse HEAD`
      캡처 → 태그 bump push 뒤 `repository_dispatch` 전송 (`INFRA_REPO_PAT`)
- [ ] DRY_RUN 으로 수일 운영 → 오탐률 확인 → 해당 서비스만 `AUTO_ROLLBACK_SERVICES` 에 추가

**완료 조건**
- 정상 배포: verify 통과, `last-good` 갱신, 롤백 안 일어남
- 의도적 bad image 배포: 3~8분 내 자동 롤백 → 이전 이미지로 Healthy 복귀 → Discord 리포트
- 의존성 down 상황 재현 시: 롤백하지 않고 abstain + page
- 킬 스위치 off 시: 트리거 무시

**의존성**: 이슈 D

---

### 이슈 #F — [P6] additive-only 마이그레이션 게이트 + 롤아웃 확대 + 문서 개정

**labels**: `ci`, `database`, `docs`, `auto-rollback`

**배경**
자동 롤백은 이미지 전용이다. 파괴적 Flyway 마이그레이션이 포함된 배포는 이미지 롤백으로 복구
불가하므로, 해당 위험이 없는 서비스만 자동 롤백을 켠다.

**작업 내용**
- [ ] 각 서비스 레포 CI 에 마이그레이션 lint: 신규 `db/migration/*.sql` 에 `DROP` / `ALTER ... DROP` /
      `RENAME` 포함 + PR 라벨 `expand-contract` 없음 → 실패
- [ ] 게이트 통과 + P1 probe 분리 완료된 서비스부터 `AUTO_ROLLBACK_SERVICES` 에 순차 추가
- [ ] `docs/semi-auto-rollback.md` → `docs/auto-rollback.md` 개정:
  - [ ] replica≥2 / HA 활성 현행화 (C1), 관련 주석 정리 (C2/C3)
  - [ ] 자동 흐름도, 가드·크로스체크·서킷브레이커, 킬 스위치 운영법
  - [ ] "배포 무관 장애는 자동 롤백 대상 아님 → 온콜" 명시

**완료 조건**
- 파괴적 마이그레이션 PR 이 CI 에서 차단됨 (라벨 없을 때)
- 5개 서비스 중 게이트 통과분이 `AUTO_ROLLBACK_SERVICES` 에 등록, 나머지는 반자동 유지
- 문서가 실제 동작과 일치

**의존성**: 이슈 E

---

### 이슈 #G — [P7] (선택) 폴링 지연 제거 · API CIDR 잠금 · Argo Rollouts PoC

**labels**: `enhancement`, `auto-rollback`, `later`

**작업 내용 (택일/부분)**
- [ ] ArgoCD 웹훅: infra 레포 push → argocd-server `/api/webhook` (ALB 경로 + 인증 노출)
- [ ] VPC 내 self-hosted 러너 → `endpoint_public_access_cidrs` 를 러너 IP 로 제한
- [ ] Argo Rollouts PoC: 1개 서비스 Deployment → Rollout, 카나리 + AnalysisTemplate 자동 abort

**의존성**: 이슈 E 안정화 이후
