# ArgoCD 웹훅 + 그라파나/ArgoCD UI 외부 노출 (#193 B안) — 적용 순서

**상태: 코드만 준비됨. 커밋·terraform apply·kubectl apply·GitHub 웹훅 등록 전부 미실행.**

목적:
1. 서비스 CI가 infra `main`에 bump 커밋을 push한 뒤, ArgoCD가 그걸 인지하는 데 걸리는
   폴링 지연(기본 ~3분)을 제거한다. `trouble/04_fail-fast-복구시간단축-검증.md`에서
   확인했듯, A안(fail-fast) 적용 후 이 폴링 지연이 전체 복구 시간의 약 79%를 차지하는
   가장 큰 병목이 됐다.
2. (겸사겸사) 원래 계획돼 있던 Grafana/ArgoCD UI 외부 브라우저 접속도 같은 작업으로 해결한다
   — ArgoCD 웹훅 노출에 필요한 인프라(ALB 그룹핑/서브도메인/인증서)가 UI 노출에 필요한 것과
   동일해서, 웹훅용 Ingress에 `/` 경로만 같이 열면 ArgoCD UI는 자동으로 되고, 그라파나는
   같은 패턴의 Ingress를 하나 더 추가했다.

셋 다(`api.`/`argocd.`/`grafana.`) **기존 ALB(istio-ingressgateway 것)에 병합**해서 노출한다
— 전용 새 ALB를 만들지 않는다(AWS Load Balancer Controller의 IngressGroup 기능, 세 Ingress가
같은 `group.name`을 가지면 자동으로 하나의 ALB로 묶인다).

## 관련 파일

| 파일 | 역할 |
|---|---|
| `helm/istio-gateway/values.yaml` | `istioGateway.albGroupName` 필드 추가(기본값 `""` — 값 없으면 기존 동작 그대로) |
| `helm/istio-gateway/templates/ingress.yaml` | `albGroupName`이 설정되면 `alb.ingress.kubernetes.io/group.name` 주석 추가 |
| `argocd/bootstrap/argocd-ingress.yaml` | argocd-server용 신규 Ingress(웹훅 `/api/webhook` + UI `/`). 위와 같은 `group.name`으로 같은 ALB에 합류 |
| `argocd/bootstrap/argocd-webhook-secret.yaml` | `argocd-secret`에 `webhook.github.secret` 키를 **Merge**(기존 키 보존)로 주입하는 ExternalSecret |
| `argocd/bootstrap/argocd-cmd-params-cm.yaml` | `server.insecure: "true"` — ALB가 TLS 종료 후 평문으로 넘기는 구조에 필요. ⚠️ `argocd-cm`이 아니라 서버 기동 파라미터 전용 ConfigMap에 넣어야 실제 적용됨(실수로 `argocd-cm`에 넣었다가 ALB 헬스체크가 307로 실패한 적 있음) |
| `helm/observability/values.yaml` | `grafana.ingress.{albGroupName,domain,certificateArn}` 필드 추가(기본 비활성) |
| `helm/observability/templates/grafana-ingress.yaml` | 그라파나용 신규 Ingress. `albGroupName` 설정 전엔 렌더링 자체가 안 됨 |
| `terraform/dns.tf` | `argocd.`/`grafana.groovy-team26.com`용 ACM 인증서 + 검증 레코드 각 1쌍. 실제 A 레코드 둘 다 순서상 뒤에 주석 해제 |
| `argocd/bootstrap/register-github-webhook.sh` | 마지막에 실행할 GitHub 웹훅 등록 스크립트(미실행) |

## 적용 순서 (실제 진행 시)

1. **AWS Secrets Manager에 웹훅 시크릿 등록**
   ```
   aws secretsmanager create-secret --name groovy/prod/argocd-webhook \
     --secret-string "{\"githubWebhookSecret\":\"$(openssl rand -hex 32)\"}"
   ```
2. **terraform apply** — `aws_acm_certificate.argocd` + DNS 검증 레코드만 먼저 적용(A 레코드는 아직 주석 상태라 안전). ACM 콘솔에서 `ISSUED` 상태 될 때까지 대기.
3. `argocd-ingress.yaml`의 `certificate-arn`을 2번에서 발급된 실제 ARN으로 채움.
4. `helm/istio-gateway/values.yaml`의 `albGroupName`에 실제 값(예: `groovy-shared-alb`) 채움 + `argocd-ingress.yaml`의 `group.name`을 동일 값으로 채움.
5. **먼저 dev/스테이징 없이 바로 프로덕션 ALB를 건드리는 변경**이므로, 가능하면 트래픽이 적은 시간대에 진행:
   - `kubectl apply -f argocd/bootstrap/argocd-cmd-params-cm.yaml` → `argocd-server` 재시작, 로그에서 `tls: false` 확인(파일 상단 주석 참고)
   - `kubectl apply -f argocd/bootstrap/argocd-webhook-secret.yaml`
   - `kubectl apply -f argocd/bootstrap/argocd-ingress.yaml`
   - `helm/istio-gateway`의 `values.yaml` 변경을 **ArgoCD를 통해(GitOps)** 반영 — 즉 이 브랜치를 dev→main으로 병합해야 `argocd-gateway-config` Application이 albGroupName 변경을 집어감
6. **AWS Load Balancer Controller 로그/콘솔에서 ALB가 그룹으로 재구성됐는지 확인**:
   ```
   aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'istiosys')]"
   aws elbv2 describe-tags --resource-arns <위 ALB ARN> --query "TagDescriptions[].Tags[?Key=='ingress.k8s.aws/stack']"
   ```
   태그 값이 `albGroupName`으로 바뀌었는지, 기존 `api.groovy-team26.com` 트래픽이 여전히 정상인지(회귀 확인) 반드시 검증.
7. `terraform/dns.tf`의 `data.aws_lb.api_gateway` 태그 필터 값을 `albGroupName`으로 갱신 + 주석 처리된 `aws_route53_record.argocd` 활성화 → `terraform apply`.
8. `curl -I https://argocd.groovy-team26.com`로 ArgoCD UI 응답 확인(로그인 화면 200).
9. `GITHUB_WEBHOOK_SECRET=<1번 값> bash argocd/bootstrap/register-github-webhook.sh` 실행.
10. GitHub 레포 Settings → Webhooks → 방금 등록된 웹훅의 "Recent Deliveries"에서 테스트 ping이 200인지 확인.
11. `trouble/03`/`04`와 동일한 방법(content-service, 존재하지 않는 이미지 태그)으로 재검증 → `trouble/05_...md`에 A+B 적용 후 복구 시간 기록, baseline·A만·A+B 3단 비교.

## 롤백 방법(문제 생길 경우)

- `albGroupName`을 다시 `""`로 되돌리고 GitOps 반영 → istio-ingressgateway Ingress가 원래의
  단독(암묵적) 그룹으로 복귀 → ALB 태그도 원래 값(`istio-system/istio-ingressgateway`)으로
  복귀할 것으로 예상되나, **AWS Load Balancer Controller가 그룹 분리 시 ALB를 재생성하는지
  아니면 태그만 갱신하는지는 실제로 적용해보기 전까지 100% 확신할 수 없다** — 5번 적용
  직후 6번 검증을 반드시 건너뛰지 말 것.
- `argocd-ingress.yaml`만 삭제하면 argocd-server 노출은 즉시 사라지고 기존 `api.` 트래픽 경로는
  영향 없음(같은 그룹의 다른 멤버 삭제는 나머지 멤버에 영향 없음).
