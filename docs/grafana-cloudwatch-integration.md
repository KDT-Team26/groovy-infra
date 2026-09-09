# Grafana — AWS CloudWatch(RDS 모니터링) 연동 아키텍처 의사결정 및 연동 가이드

**상태: 코드 준비 완료 (Terraform, Helm, 대시보드 반영 완료)**

---

## 1. 배경 및 목적

심화 프로젝트 대시보드(`advanced-project-dashboard.json`)에 기존 인클러스터 메트릭(Prometheus/Cadvisor) 외에, AWS 완전관리형 데이터베이스인 **RDS MySQL (`groovy-rds-mysql`)**의 4대 핵심 지표(CPU 사용률, 활성 DB 연결 수, 여유 메모리, 여유 스토리지)를 표출할 수 있도록 **Grafana CloudWatch 데이터소스 연동**이 필요했다.

Grafana 파드가 AWS CloudWatch API(`GetMetricData`, `ListMetrics` 등)를 호출하여 메트릭을 수집하려면 적절한 AWS IAM 권한이 부여되어야 한다.

---

## 2. 권한 연동 방안 검토 및 비교

EKS 환경에서 Grafana 파드에 AWS CloudWatch 조회 권한을 제공하기 위해 다음 2가지 방안을 검토했다.

| 구분 | 방안 1: EKS Worker Node 공용 역할에 권한 부여 | 방안 2: EKS Pod Identity 전용 역할 격리 (최종 선택) |
|---|---|---|
| **권한 부여 대상** | EC2 Worker Node IAM 역할 (`groovy-eks-node-role`) | Grafana 파드 전용 ServiceAccount (`groovy-monitoring/grafana`) |
| **인증 메커니즘** | EC2 인스턴스 메타데이터 서비스 (IMDSv2) | EKS Pod Identity 에이전트 (`pods.eks.amazonaws.com`) |
| **최소 권한 원칙** | ❌ **위배** (동일 노드 내 모든 파드가 권한 공유) | ✅ **준수** (오직 Grafana 파드에만 엄격히 격리) |
| **자격증명 관리** | 노드 레벨 자격증명 사용 | 단기 임시 자격증명 자동 주입 (토큰 주기적 갱신) |
| **작업 복잡도** | 낮음 (`terraform/iam.tf`에 정책 연결 1줄) | 중간 (IAM 역할 + Pod Identity 바인딩 + k8s SA 생성) |
| **기존 아키텍처 일관성** | 별도 패턴 없음 | ✅ `eso.tf`(External Secrets Operator)와 동일 패턴 |

---

### 방안 1 상세: EKS Worker Node 공용 역할에 정책 부여
- **동작 방식**:
  - `terraform/iam.tf`의 `groovy-eks-node-role`에 `CloudWatchReadOnlyAccess` 정책을 연결.
  - 노드에서 동작하는 모든 파드는 IMDS를 통해 추가 설정 없이 AWS SDK 기본 인증으로 CloudWatch 조회가 가능해짐.
- **장점**:
  - 구성이 매우 간단하며, k8s ServiceAccount나 추가 매핑 설정 없이 `terraform apply` 즉시 동작.
- **한계 및 문제점**:
  - **최소 권한 원칙(Principle of Least Privilege) 위배**: 같은 워커 노드에 배포된 비즈니스 애플리케이션 파드(identity, study, content 등)도 노드 메타데이터를 통해 CloudWatch 메트릭을 임의로 조회할 수 있게 됨.
  - 읽기 전용 권한이라도 불필요한 인프라 메트릭 노출은 보안 감사 및 멀티 테넌시 관점에서 지양해야 하는 안티 패턴.

---

### 방안 2 상세: EKS Pod Identity 기반 전용 역할 격리 (선택)
- **동작 방식**:
  - `pods.eks.amazonaws.com`을 신뢰 관계(Trust Relationship)로 갖는 Grafana 전용 IAM 역할(`groovy-grafana-cloudwatch-role`)을 생성.
  - EKS Pod Identity Association을 통해 `groovy-monitoring` 네임스페이스의 `grafana` ServiceAccount와 매핑.
  - Grafana 파드 기동 시 EKS Pod Identity 에이전트가 단기 세션 자격증명을 파드 환경에 주입.
- **장점**:
  - **완벽한 권한 격리**: Grafana ServiceAccount를 사용하는 파드 외에는 그 어떤 파드도 해당 CloudWatch 권한을 사용할 수 없음.
  - **안전성**: AccessKey/SecretKey 같은 영구 자격증명을 노출하거나 주입할 필요가 전혀 없음.
  - **아키텍처 일관성**: 프로젝트 내 External Secrets Operator(`terraform/eso.tf`)가 채택한 표준 인증 방식과 동일하여 운영 및 관리 일관성 확보.

---

## 3. 최종 의사결정 (ADR)

> **결정**: **방안 2(EKS Pod Identity 기반 전용 역할 격리)**를 최종 채택한다.

**선정 사유**:
1. **보안성(최소 권한 준수)**: 데이터 시각화 도구인 Grafana의 읽기 권한이 비즈니스 서비스 파드들로 전파되는 보안 리스크를 원천 차단한다.
2. **AWS 최신 표준 부합**: 기존 IRSA(OIDC Provider + WebIdentityToken 주입)보다 구성이 간결하고 성능이 우수한 EKS Pod Identity 방식을 사용한다.
3. **기존 프로젝트 규칙과의 통일성**: `eso.tf`에서 이미 검증된 Pod Identity 패턴을 그대로 활용하여 인프라 팀의 유지보수 부담을 최소화한다.

---

## 4. 코드 변경 내역

### 1) Terraform 인프라 (`terraform/grafana-cloudwatch.tf`) [신규]
- Grafana 전용 IAM Role 생성 (`groovy-grafana-cloudwatch-role`)
- AWS 관리형 정책 `arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess` 연결
- `aws_eks_pod_identity_association` 리소스로 `groovy-monitoring/grafana`와 역할 바인딩

### 2) Helm Observability 차트
- **`templates/grafana-serviceaccount.yaml`** [신규]: `grafana` ServiceAccount 리소스 정의
- **`templates/grafana-deployment.yaml`** [수정]: `spec.template.spec.serviceAccountName: grafana` 명시
- **`templates/grafana-datasources-configmap.yaml`** [수정]: CloudWatch 데이터소스 프로비저닝 추가
  ```yaml
        - name: CloudWatch
          uid: cloudwatch
          type: cloudwatch
          editable: true
          jsonData:
            authType: default
            defaultRegion: ap-northeast-2
  ```

### 3) 대시보드 (`helm/observability/dashboards/advanced-project-dashboard.json`) [수정]
- **`AWS RDS [ CloudWatch ]`** Row (ID: 65) 신설
- 4대 핵심 패널 추가 (인스턴스: `groovy-rds-mysql`, 리전: `ap-northeast-2`):
  - ID 66: `RDS CPU 사용률 (%)` (`CPUUtilization`)
  - ID 67: `RDS 데이터베이스 연결 수` (`DatabaseConnections`)
  - ID 68: `RDS 여유 메모리 (Freeable Memory)` (`FreeableMemory`)
  - ID 69: `RDS 여유 스토리지 (Free Storage)` (`FreeStorageSpace`)

---

## 5. 실제 배포 및 적용 절차

1. **Terraform 적용 (IAM & Pod Identity Association 생성)**
   ```bash
   cd groovy-infra/terraform
   terraform plan -target=aws_iam_role.grafana_cloudwatch -target=aws_iam_role_policy_attachment.grafana_cloudwatch -target=aws_eks_pod_identity_association.grafana_cloudwatch
   terraform apply
   ```

2. **ArgoCD Sync 또는 Helm 배포**
   - 변경 사항 Git 커밋 및 Push ➔ ArgoCD가 `observability` 앱 동기화
   - ServiceAccount `grafana` 생성 및 Grafana Deployment 업데이트

3. **Grafana 파드 재기동 및 자격증명 확인**
   - Pod Identity는 파드가 기동될 때 자격증명을 주입하므로 배포 후 롤링 업데이트로 새 파드가 뜨는지 확인:
   ```bash
   kubectl get pods -n groovy-monitoring -l app=grafana
   ```
   - Grafana UI ➔ 대시보드 ➔ `AWS RDS [ CloudWatch ]` 행에서 메트릭이 정상 조회되는지 확인.
