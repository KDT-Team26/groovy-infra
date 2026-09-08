# 롤백 (rollback)

배포 장애 시 해당 서비스의 이미지 태그를 마지막으로 정상 확인된 값으로 되돌리는 구조.

- **감지**: 자동 (probe, ArgoCD Health, Prometheus)
- **판정·실행**: `deploy-verify.yml` 이 배포 직후 자동 검증하고, 실패가 확정되면 가드를 통과할 때
  자동 롤백한다. `rollback.yml`(수동 break-glass)은 그대로 유지된다.

---

## 1. 구성요소

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

- **불확실은 롤백하지 않는다.** 
  - 러너↔EKS API 단절, ArgoCD 응답 없음, sync 정체 등 판정 불가
    상황은 롤백하지 않고 사람을 호출한다.
- **루프 차단**: 
  - 대상 커밋이 `revert(` 로 시작하면 롤백 안 함. auto 모드는 `chore(<svc>): bump
    image tag` (github-actions 봇) 커밋만 대상.
---

## 4. 한계 (그대로 남는 것)

- **DB 스키마(Flyway)는 롤백되지 않는다.** 테이블 스키마가 변경되는 마이그레이션이 포함된 배포는 이미지 롤백으로
  복구 불가 → 각 서비스 레포 CI 의 additive-only 게이트를 통과한 서비스만 자동 롤백을 켠다.
 
- **배포가 원인이 아닌 장애**(트래픽 급증·노드 장애·외부 의존성 다운)는 자동 롤백 대상이 아니다.