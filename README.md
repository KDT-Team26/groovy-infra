# groovy-infra

## 1. Repo: groovy-infra

`groovy-infra`는 그중 **서비스 도메인 로직·DB를 소유하지 않는 공용 인프라**를 담당합니다.

## 2. 주요 기능

- **AWS 인프라 프로비저닝(Terraform)**: 
  - VPC/EKS/RDS(MySQL)/ECR/Route53+ACM/Secrets
    Manager/IAM(OIDC)까지 `terraform/`이 코드로 관리. 프론트엔드용 S3+CloudFront는
    `terraform/frontend-cdn/`으로 분리.
- **서비스별 K8s 배포 정의(Helm)**: 
  - 5개 백엔드 서비스 + `platform`(Kafka/Redis) +
    `istio-gateway` + `observability`까지 8개 독립된 Helm 차트로 구성함
- **GitOps CD(ArgoCD App of Apps)**: 
  - `argocd/apps/`의 Application 14개를 `sync-wave`
    순서(클러스터 애드온 → 데이터 플레인 → 서비스 → 게이트웨이 → 모니터링)로 자동 동기화.
- **반자동·자동 롤백 파이프라인**: 
  - 배포 직후 ArgoCD health를 자동 검증하고, 실패가 확정되면
    안전장치(킬 스위치·화이트리스트·서킷 브레이커·크로스체크)를 통과할 때만 마지막으로 정상
    확인된 이미지 태그로 자동 롤백. 사람이 직접 트리거하는 수동 break-glass 경로도 별도 유지.
- **공용 모니터링 스택 소유**: 
  - Prometheus/Grafana/Loki/Tempo/Grafana Alloy/Alertmanager와
    exporter들을 `helm/observability/`가 단일 소스로 관리.
- **시크릿 중앙 관리**: 
  - External Secrets Operator(ESO)가 AWS Secrets Manager 값을 각
    네임스페이스의 일반 Secret으로 주입

## 3. 시스템 아키텍처

```
```

### 롤백 파이프라인 흐름

```
서비스 CI: 이미지 push → groovy-infra values.yaml bump → repository_dispatch(deploy-verify)
  → deploy-verify.yml: ArgoCD sync+health 폴링(EKS/ArgoCD OIDC read-only 역할)
      ├ Healthy → last-good/<service> git tag 갱신 (Discord ✅)
      └ Degraded/timeout/inconclusive → rollback-guards.sh 판단
            ├ 킬 스위치 꺼짐 / 화이트리스트 밖 / revert 루프 / 서킷 브레이커
            │   / 배포 무관 장애(크로스체크) → abstain·circuit_break (알림만, 롤백 안 함)
            └ 전부 통과 → rollback-core: last-good 태그의 이미지로 values.yaml 되돌려
                          main에 push → ArgoCD 재동기화 → 재검증 → Discord ↩️/🚨
```

## 4. 기술 스택

- **Terraform**
- **Helm 3**
- **ArgoCD**
- **Istio** (`istio-base`/`istiod`/`istio-ingressgateway` + 자체 `Gateway`/`VirtualService`
  차트)
- **External Secrets Operator(ESO)**
- **GitHub Actions**
- **모니터링**: Prometheus, Grafana, Loki, Tempo, Grafana Alloy, Alertmanager, 각종
  exporter(node/kafka/mysqld/cadvisor) — 전부 `helm/observability/`에서 자체 배포