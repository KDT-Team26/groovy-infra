# EKS 노드 OOM 장애 분석 및 리소스 리밋 런북 (Troubleshooting & Runbook)

**문서 상태**: 운영 런북 및 장애 사후 분석 보고서 (Post-Mortem)  
**최초 발생 일시**: 2026-09-10 11:12 KST  
**영향 범위**: `ip-10-0-11-67` 노드 사망(`NotReady`), Grafana 504 Gateway Timeout, 동일 노드 파드 정체  
**조치 결과**: 긴급 파드 강제 재배치 및 ASG 인스턴스 재생성 완료, Platform/Observability 전수 Requests & Limits 적용 완료  

---

## 1. 장애 요약 (Executive Summary)

EKS 워커 노드(`t4g.medium`, vCPU 2, RAM 4GiB) 환경에서 Grafana 웹 접속 시 `504 Gateway Timeout`이 발생하며 워커 노드가 `NotReady` 상태로 다운되었다.  

원인 조사 결과, HPA(Horizontal Pod Autoscaler)에 의해 `study-service` 및 `identity-service` 자바 파드 4대가 급증했으나, 동일 노드에 실행 중이던 공용 인프라/모니터링 파드(`kafka`, `tempo`, `loki`, `grafana`)에 **Requests/Limits가 전혀 설정되어 있지 않아(`<none>`)**, 쿠버네티스 스케줄러가 이들의 메모리 사용량을 `0MB`로 오인하고 자바 파드들을 한 노드에 과도하게 밀어 넣었다.  
이로 인해 노드의 물리 메모리(4GiB)를 초과(실제 사용량 4.3GiB+)하여 **리눅스 커널 OOM Killer에 의해 Kubelet이 강제 종료**되면서 노드가 사망하였다.

---

## 2. 근본 원인 분석 (Root Cause Analysis)

### 2.1 스케줄러의 '장부 조작' 착각
쿠버네티스 스케줄러는 노드에 파드를 배치할 때 실시간 메모리 사용량을 보지 않고, 오직 파드 스펙의 **`Requests(요청량)` 합계**만 보고 빈 공간을 계산한다.
$$\text{노드 가용 메모리} = \text{노드 Allocatable (약 3.3GiB)} - \sum \text{파드 Requests}$$

- `kafka-0`, `tempo`, `loki-0`, `grafana`의 `Requests`가 `<none>`으로 되어 있어, 스케줄러는 이들이 **자원을 0MB 쓴다고 판단**.
- 실제로는 실측 결과 **Tempo(819MB), Kafka(700MB~1GB), Loki(145MB), Grafana(130MB) 등 약 1.9GB의 메모리를 이미 점유**하고 있었음.
- 스케줄러는 장부상 여유가 있다고 착각하여 HPA로 생성된 자바 파드 4대(개당 512MB, 총 2.0GB+)를 이 노드에 모두 배정함.

### 2.2 노드 오버커밋(Overcommit) 폭발
사망 직전 노드의 `Allocated resources` 현황:
```text
Resource           Requests      Limits
--------           --------      ------
cpu                1580m (81%)   4 (207%)
memory             3176Mi (96%)  6464Mi (196%)
```
- **파드 슬롯**: 17개 물리적 한계 100% 꽉 참
- **메모리 Requests**: 3176Mi (96%) - 장부상으로도 이미 턱밑까지 참
- **메모리 Limits**: 6464Mi (196%) - 물리 메모리의 2배 수준으로 오버커밋
- **결과**: 신규 자바 파드 4대가 동시에 JVM 힙을 할당받는 순간 물리 RAM 4GiB가 즉각 고갈되어 Kubelet 데몬 통신 마비(`net/http: TLS handshake timeout to 10.0.11.67:10250`) 발생.

---

## 3. 긴급 대응 트러블슈팅 절차 (Emergency Response)

유사한 노드 마비 및 504 타임아웃 발생 시 아래 3단계로 3분 내 긴급 복구한다.

### Step 1. 노드 및 Kubelet 통신 상태 확인
```bash
# 1. 노드 상태 확인 (NotReady 여부 파악)
kubectl get nodes -o wide

# 2. 특정 파드 로그 호출 시 Kubelet 핸드셰이크 에러 확인
kubectl logs -n <네임스페이스> <파드명> --tail=20
# 출력 에러: net/http: TLS handshake timeout (노드 통신 두절 확인)
```

### Step 2. 갇힌 파드 강제 이주 (서비스 즉시 정상화)
죽은 노드에 스케줄링되어 멈춰있는 파드를 강제 종료하면, 쿠버네티스가 건강한 다른 노드에 파드를 즉시 재생성한다:
```bash
kubectl delete pod -n <네임스페이스> <파드명> --force --grace-period=0
# 예: kubectl delete pod -n groovy-monitoring -l app=grafana --force --grace-period=0
```

### Step 3. 사망한 EC2 인스턴스 종료 (ASG 자동 복구 유도)
NotReady 상태로 복구 불능인 EC2 인스턴스를 강제 종료하여, Auto Scaling Group이 건강한 새 노드를 즉시 프로비저닝하도록 한다:
```bash
# 1. 노드의 EC2 인스턴스 ID 추출
INSTANCE_ID=$(kubectl get node <죽은노드이름> -o jsonpath='{.spec.providerID}' | awk -F'/' '{print $NF}')

# 2. 인스턴스 종료
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
```

---

## 4. 실측 기반 영구 해결책 (Permanent Fixes)

재발 방지를 위해 프로메테우스 실측 피크 데이터를 기반으로 모든 인프라/모니터링 파드에 Requests & Limits를 영구 부여했다.

### 4.1 프로메테우스 실측 데이터 및 설정값
| 컴포넌트 | 실측 Peak RAM | CPU (Req / Limit) | Memory (Req / Limit) | 조치 사유 |
| :--- | :---: | :---: | :---: | :--- |
| **`kafka`** | ~800 MiB | `200m` / `500m` | **`700Mi` / `1000Mi`** | JVM 힙 메모리 폭주 방지 |
| **`redis`** | ~40 MiB | `50m` / `200m` | **`48Mi` / `96Mi`** | 경량 인메모리 캐시 보호 |
| **`tempo`** | **819 MiB** | `50m` / `200m` | **`600Mi` / `1Gi`** | **최대 메모리 하마**. 실측 819M 고려 1Gi 한도 |
| **`prometheus`** | **522 MiB** | `100m` / `300m` | **`400Mi` / `768Mi`** | 시계열 데이터 청크 캐시 고려 |
| **`loki`** | 145 MiB | `20m` / `100m` | **`128Mi` / `256Mi`** | 로그 인덱스 버퍼링 수용 |
| **`grafana`** | 130 MiB | `30m` / `150m` | **`100Mi` / `256Mi`** | 대시보드 쿼리 스파이크 수용 |
| **`alloy`** | 105 MiB | `20m` / `100m` | **`96Mi` / `192Mi`** | 로그/트레이스 수집 에이전트 |
| **`alertmanager`** | 15.1 MiB | `10m` / `50m` | **`24Mi` / `64Mi`** | 경량 알림 발송 |
| **`kafka-exporter`**| 22.0 MiB | `10m` / `50m` | **`24Mi` / `64Mi`** | 경량 메트릭 수집기 |

### 4.2 Helm 템플릿 연동 주의사항
`values.yaml`에만 값을 작성하면 Helm이 매니페스트를 렌더링할 때 무시된다. 반드시 `templates/*-deployment.yaml` 또는 `*-statefulset.yaml`에 아래 주입 코드가 포함되어 있어야 한다:
```yaml
          {{- if .Values.<컴포넌트>.resources }}
          resources:
            {{- toYaml .Values.<컴포넌트>.resources | nindent 12 }}
          {{- end }}
```

---

## 5. 일상 운영 점검 런북 (Daily Operations Runbook)

### 5.1 전체 실행 중인 파드의 리퀘스트/리밋 점검
클러스터 내에 리소스 제한 없이 실행 중인 위험 파드(`<none>`)가 있는지 모니터링:
```bash
kubectl get pods -A --field-selector=status.phase=Running -o custom-columns=\
"NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
CPU_REQ:.spec.containers[*].resources.requests.cpu,\
CPU_LIM:.spec.containers[*].resources.limits.cpu,\
MEM_REQ:.spec.containers[*].resources.requests.memory,\
MEM_LIM:.spec.containers[*].resources.limits.memory"
```

### 5.2 노드별 실시간 메모리/CPU 압박 상태 점검
```bash
# 1. 노드 실제 물리 사용률 확인
kubectl top nodes

# 2. 노드별 장부상 예약률(Requests %) 확인 (80% 초과 시 주의)
kubectl describe nodes | grep -E "(Name:|Allocated resources:)" -A 7
```

### 5.3 Cluster Autoscaler 동작 상태 확인
스케줄러가 Requests 한계로 인해 파드를 `Pending` 시켰을 때, CA가 노드를 정상 증설하고 있는지 점검:
```bash
kubectl -n kube-system get cm cluster-autoscaler-status -o yaml
```
