# groovy-infra

## 1. Repo: groovy-infra

**Groovy** 원본 `Groovy` 레포(`feat/poly_repo_transfer` 브랜치)에서 DB 초기화, 메시지 브로커 설정, k8s/Helm 배포
매니페스트, 모니터링 스택 등 **서비스 도메인 로직·DB를 소유하지 않는 공용 인프라**만 분리해둠

## !!주의!!
- 백엔드 모듈 6개 + 프론트엔드 영역을 제외한 부분들을 분리한 것이라 추가 수정이 필요합니다.
- 아마 작업하던 내용을 새로운 폴리 레포 구조에 맞추어 추가 수정이 필요할 것 같습니다.
- 일단 분리한 파일들과 그 이유는 아래 적어 놓긴 했는데 확인하시고 작업 이어서 해주시면 될 것 같습니다.

## 분리 이유 및 수정해야할 영역 내용은 모두 지켜야 되는 것이 아닙니다
- 제가 임시로 작성한 내용이므로 그냥 참고만 해주세요

> 작업 위치: `poly/groovy-infra/` (아직 별도 GitHub 레포로 push하지 않은 로컬 스테이징 상태)
> 관련 문서: [`docs/Groovy_폴리레포_전환_계획서.md`](./docs/Groovy_폴리레포_전환_계획서.md)

## 2. 이 레포에 포함한 것과 이유

| 대상 | 이유 |
|---|---|
| `helm/` | 6개 백엔드 서비스(`api-gateway`/`identity`/`study`/`content`/`calendar`/`notification`) + `frontend` + `mysql`/`redis`/`kafka`(`platform`) + 모니터링 스택(`observability`: `prometheus`/`grafana`/`tempo`/`loki`/`alloy`/exporter들)까지 전부 서비스 단위 템플릿으로 완비된 **k8s 배포의 단일 소스**. 서비스 간 통신도 k8s Service DNS(`http://identity-service:8081` 등) 기준이라 소스 경로 결합이 없어 그대로 이관 가능. **(GitOps 빌드 지시서 Phase 03 완료: 원래 단일 통합 차트였던 `helm/groovy/`를 9개 독립 차트(`helm/<chart>/Chart.yaml`+`values.yaml`+`templates/`)로 분리함 — ArgoCD의 서비스 단위 Application 분리를 위한 전제조건.)** |
| `mysql-init/` | 서비스별(`identity`/`study`/`content`/`calendar`/`notification`) 스키마 + 전용 계정 생성 스크립트. 테이블 스키마 자체는 각 서비스가 Flyway로 소유하지만, **컨테이너 최초 프로비저닝(DB+계정 생성)** 은 공유 인프라 소관이라는 계획서 4장 방침에 따름. |
| `kafka-init/` | Kafka SASL 클라이언트 인증 설정(`adminclient.conf`). 특정 서비스 소유가 아닌 공용 브로커 설정. |
| `monitoring-msa/` | Prometheus/Grafana/Tempo/Loki/Alloy 로컬 스택 설정. 스크레이프 job이 이미 서비스명 기준으로 분리돼 있어(`job_name: calendar-service` 등) 레포 분리와 무관하게 동작. |
| `alertmanager/` | 알림 규칙 라우팅 설정. 공용 인프라. |
| `docs/Groovy_폴리레포_전환_계획서.md` | 전체 폴리레포 전환 방침(레포 목록, 공통 lib 처리, DB 배치, CI/CD 구조, 단계별 순서)을 정의한 원본 계획서. 인프라 레포의 존재 이유·설계 근거 자체라 포함. |
| `docs/Groovy_MSA_저장소_구조.md`, `docs/Groovy_MSA_구조와실행.md` | 현재 MSA 구조와 실행 방식(포트 노출 정책, 네트워크 구성 등)을 설명하는 문서. 인프라 매니페스트가 왜 이렇게 구성됐는지의 근거 자료라 포함. |
| `docs/Groovy_MSA_DB_관계도.md` | 서비스별 DB 분리 구조/FK 없는 논리적 참조 관계를 담은 문서. `mysql-init/`이 왜 이렇게 스키마를 나누는지의 근거라 포함. |
| `docs/Groovy_MSA_도메인경계_재검토.md` | 서비스 도메인 경계 정의. `helm/`의 서비스별 매니페스트 구성·`monitoring-msa/`의 서비스별 라벨링이 이 경계를 그대로 따르므로 참고 자료로 포함. |

## 3. 제외한 것과 이유

| 대상 | 이유 |
|---|---|
| `docker-compose.local.yml`, `docker-compose.example.yml`, `.env.example` | 모놀리식 레포 기준 로컬 통합 개발용 스택. 6개 서비스가 `build: context: ./backend`로 원본 소스를 직접 빌드하는 구조라 poly 전환 이후엔 성립하지 않고, 폴리 레포 체제에서 로컬 개발도 `helm/`(k8s) 기준으로 가기로 함에 따라 무의미해져 제거. |
| `backend/`, `front/` | 서비스 도메인 소스. 이미 `poly/groovy-*-service/`, `poly/groovy-frontend/`로 각각 추출되어 별도 GitHub 레포(`team26/*`)에 반영 완료됨. 인프라 레포가 다시 담을 이유가 없음. |
| `k8s/`, `k8s-local/` | 단일 `backend` 이미지 기준의 레거시 raw manifest. `helm/`이 이미 서비스 단위로 완전히 대체했고(`refactor(helm): remove legacy backend` 커밋 등), 최신화도 멈춰 있어 죽은 코드에 가까움. `k8s-local/nginx-deployment.yaml`도 실제 프록시/TLS 설정이 아니라 `nginx:alpine` 데모용 연습 매니페스트라 이관 가치 없음. |
| `nginx/` | 활성 설정이 전부 `proxy_pass http://backend:8080`(단일 backend 컨테이너) 기준. `docker-compose.local.yml`/`helm/` 어디에도 nginx 서비스가 없어 MSA/k8s 트랙과 무관. 현재 운영 중인 `docker-compose.prod.yml`(레포 밖, 운영 서버 소유) 전용이며, 팀 방침상 운영은 당분간 원본 `Groovy` `main`으로 유지하므로 그대로 원본 레포에 남겨둠. 목표 아키텍처에서도 이 역할은 Ingress+cert-manager(또는 Istio Gateway+cert-manager)로 대체될 예정이라 그대로 옮길 대상이 아님. |
| `.github/workflows/docker-build-push-frontend.yml` | `front/**` 경로 트리거 + 운영 서버 `docker-compose.prod.yml` 배포까지 담당하는 **현재 운영 중인 파이프라인**. 모놀리식 프론트 전용이라 인프라 레포 소관이 아니고, `poly/groovy-frontend`가 이미 자체 CI(현재 비활성)를 별도로 보유 중. |
| `docs/순서1/*`(Phase0~13), `docs/순서2(코드_결함_수정_기록)/*`, `docs/troubles/*` | 백엔드 모놀리식 → MSA 전환 **과정 기록**(설계/실행 히스토리, 결함 수정 이력, 공통 lib 처리 고민 과정). 인프라 운영 문서가 아니라 전환 프로젝트의 히스토리 아카이브 성격이라 제외. |
| `docs/transfer/*.md` | poly 레포 "전환 작업 그 자체"의 격리 판단·검증 기록(서비스별). 이미 각 서비스 poly 레포 README에 핵심 내용이 반영됐고, 인프라가 아니라 전환 프로젝트 메타기록이라 제외. |
| `docs/원본 레포 통합 시 주의점.md` | 로컬 개발용 저장소 설정을 운영 서버로 "역통합"할 때의 체크리스트. 지금 하는 작업(운영과 무관한 인프라 분리)과 반대 방향의 문서라 제외. |
| `docs/images/*.png` | 루트 `README.md`의 아키텍처 다이어그램 첨부 이미지. 이관 대상 문서 어디에서도 참조되지 않아 제외. |
| `helm/<chart>/values-secret.yaml` (실존하지 않음) | `.gitignore`에 의해 애초에 커밋되지 않는 실제 시크릿 파일. 차트별 예시 파일(`values-secret.example.yaml`)만 포함. |

## 4. "MSA + k8s + poly" 운영을 위해 수정해야 할 영역

| 영역 | 무엇을, 어떻게 |
|---|---|
| **이미지 레지스트리 네임스페이스 통일** | 각 서비스 차트의 `helm/<service>/values.yaml`·`values.amd64.yaml`이 보는 이미지가 `khg1115/groovy-*`(수동 빌드 스냅샷)인데, poly 서비스 레포들의 (현재 비활성화된) CI는 `bebeghi/groovy-*`로 push하도록 되어 있음. 둘 중 하나로 정하고 `values*.yaml`의 `repository` 필드를 그 값으로 갱신해야 함. |
| **poly 서비스/프론트 레포의 로컬 개발 문서 갱신** | 각 서비스 README가 "전체 스택은 원본 `Groovy` 레포의 `docker-compose.local.yml` 사용 권장"이라고 되어 있는데, docker-compose가 제거됐으므로 `helm/`(이 레포) 기준 k8s 로컬 실행 방법을 안내하도록 바꿔야 함(이 레포 자체가 아니라 poly 서비스 레포 쪽 수정 사항). |
| **서비스 CI 활성화** | poly 7개 레포(`groovy-frontend` + 6개 서비스)의 `.github/workflows/docker-build-push.yml.disabled`를 활성화하고, 각 GitHub 레포에 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` 시크릿을 새로 등록해야 함(모놀리식 레포 시크릿은 자동 상속 안 됨). 활성화 시 워크플로우 상단에 이미 박혀 있는 TODO(`@SpringBootTest` 통합 테스트를 CI에서 어떻게 돌릴지 미정)도 함께 정책 결정 필요. |
| **ArgoCD 기반 CD 신설** | 지금 이 레포엔 ArgoCD `Application`/`AppProject` 매니페스트가 전혀 없음. 서비스 CI가 이미지를 푸시하면 이 레포의 이미지 태그를 갱신하고, ArgoCD가 그 변경을 감지해 클러스터에 동기화하는 GitOps 파이프라인(계획서 5장)을 이 레포 안에 새로 구성해야 함. |
| **외부 진입점(Ingress) + 인증서 자동화 신설** | `helm/api-gateway/templates/`·`helm/frontend/templates/`에 `Ingress`/TLS 관련 리소스가 전혀 없고, `api-gateway-service`/`frontend-service` 모두 `ClusterIP`라 클러스터 밖에서 접근할 방법이 아예 없음. `Ingress`(또는 추후 Istio `Gateway`) + `cert-manager`(Let's Encrypt ACME 자동 발급/갱신)를 새로 추가해야 함. |
| **레거시 raw manifest 최종 정리** | `helm/`이 사실상 유일한 활성 배포 경로이므로, 원본 레포의 `k8s/`, `k8s-local/`는 이 레포로 옮기지 않기로 확정한 만큼 원본 쪽에서 삭제할지 보류할지 별도로 결정. |
