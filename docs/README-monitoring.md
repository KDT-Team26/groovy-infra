# Loki / Alloy Helm 통합 및 로그 영속성 구성

Groovy Kubernetes 환경에서 Loki / Alloy 로그 수집 구성을 `helm/groovy` Chart에 통합하고, Loki 로그 영속성을 적용한 작업을 정리합니다.
기존에는 Loki / Alloy를 standalone Kubernetes manifest로 별도 배포했지만, 현재는 `helm/groovy/`에 통합되어 Helm 배포 시 애플리케이션과 로그 모니터링 환경이 함께 구성됩니다.

최종 수정일: 2026-08-25
관련 PR: #6, #11

## 1. 작업 목적

기존 배포 구조:

```text
Helm
 └─ Groovy Application

kubectl apply
 └─ Loki / Alloy
```

현재 배포 구조:

```text
helm upgrade --install
        │
        ├── Groovy Application
        ├── MySQL / Redis / Kafka
        ├── Prometheus / Grafana / Tempo
        ├── Alloy
        └── Loki
             │
             └── PVC
```

주요 작업:

* Loki / Alloy Helm Chart 통합
* Kubernetes API 기반 Pod 로그 수집
* Alloy RBAC 구성
* Grafana Loki datasource 및 로그 Dashboard 연동
* Loki StatefulSet + PVC 기반 로그 영속성 적용
* Loki 로그 72시간 보관 정책 적용

## 2. 로그 수집 구조

```text
Groovy MSA Pods
       │
       │ Pod Logs
       ▼
     Alloy
       │
       ▼
      Loki
       │
       ├── PVC 저장
       │
       ▼
    Grafana
```

Alloy가 Kubernetes API를 통해 Pod를 탐색하고 로그를 수집하여 Loki로 전달합니다.
Loki에 저장된 로그는 Grafana에서 서비스별로 조회할 수 있습니다.

## 3. Helm 통합

PR #6 — Loki / Alloy Helm 통합

기존에 별도로 배포하던 Loki / Alloy를 `helm/groovy` Chart에 포함했습니다.
Helm 배포 시 Loki / Alloy가 함께 생성되며, 이미지·포트·replica 등은 `values.yaml`을 통해 관리합니다.

### Alloy RBAC 추가

Alloy가 Kubernetes Pod를 탐색하고 로그를 수집하기 위해 다음 RBAC 구성을 추가했습니다.

```text
ServiceAccount
      │
      ▼
ClusterRole
      │
      ▼
ClusterRoleBinding
```

조회 대상:

```text
pods
nodes
namespaces
```

관련 파일:

```text
helm/groovy/templates/alloy-rbac.yaml
```

Helm Release가 설치된 namespace를 기준으로 동작하도록 구성되어 있습니다.

## 4. Grafana 로그 Dashboard

Groovy MSA 로그 Dashboard는 다음 위치에서 관리합니다.

```text
helm/groovy/dashboards/
└── backend-app-logs-dashboard.json
```

Loki datasource를 사용하여 다음 MSA 서비스의 로그를 조회합니다.

```text
api-gateway
identity-service
study-service
content-service
calendar-service
notification-service
```

Dashboard에서 `INFO`, `WARN`, `ERROR` 로그를 구분하여 확인할 수 있습니다.

## 5. Loki 로그 영속성

PR #11 — Loki StatefulSet + PVC 적용

초기 Helm 통합 시 Loki는 `emptyDir`을 사용했기 때문에 Pod가 재생성되면 기존 로그가 삭제되는 문제가 있었습니다.
이를 다음 구조로 변경했습니다.

```text
Loki StatefulSet
       │
       ▼
groovy-loki-data PVC
       │
       ▼
     /loki
```

### Loki PVC 추가

Loki 로그 저장을 위한 PVC를 추가했습니다.
관련 파일:

```text
helm/groovy/templates/loki-pvc.yaml
```

기본 설정:

```text
Name        : groovy-loki-data
Access Mode : ReadWriteOnce
Size        : 10Gi
```

현재 Loki는 StatefulSet에서 해당 PVC를 `/loki` 경로에 연결하여 사용합니다.

```text
helm/groovy/templates/loki-statefulset.yaml
```

이를 통해 Loki Pod가 재생성되더라도 기존 로그를 유지할 수 있습니다.

## 6. 로그 보관 정책

PVC에 로그가 계속 누적되지 않도록 Loki 로그 보관 기간을 72시간으로 설정했습니다.

```yaml
limits_config:
  retention_period: 72h
```

또한 Compactor를 활성화하여 보관 기간을 초과한 로그를 주기적으로 정리하도록 구성했습니다.

```yaml
compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  delete_request_store: filesystem
```

## 7. 최종 구성

```text
helm/groovy/
├── values.yaml
│
├── templates/
│   ├── alloy-configmap.yaml
│   ├── alloy-deployment.yaml
│   ├── alloy-rbac.yaml
│   │
│   ├── loki-configmap.yaml
│   ├── loki-service.yaml
│   ├── loki-statefulset.yaml
│   └── loki-pvc.yaml
│
└── dashboards/
    └── backend-app-logs-dashboard.json
```

현재는 별도의 Loki / Alloy manifest 적용 없이 Groovy Helm Chart 배포만으로 로그 모니터링 환경까지 함께 구성됩니다.

```text
helm upgrade --install
        │
        ▼
   Groovy Helm Chart
        │
        ├── Application
        ├── Infrastructure
        ├── Monitoring
        ├── Alloy
        │     └── Kubernetes Pod 로그 수집
        │
        └── Loki
              └── PVC 기반 로그 저장
```
