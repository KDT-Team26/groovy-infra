#!/usr/bin/env bash
# GitOps 빌드 지시서 Phase 05 — 운영 서버(mini PC)에 ArgoCD를 설치하고 최소 설정까지 마치는
# 부트스트랩 스크립트. SSH로 운영 서버에 접속해서, kubectl이 이미 대상 클러스터를 가리키고
# 있는 상태로 이 스크립트를 실행한다(레포를 clone한 뒤 argocd/bootstrap/에서 실행).
#
# 한 번에 쭉 실행해도 되고, 아래 STEP 단위로 잘라서 손으로 하나씩 실행해도 된다 — 전부
# 멱등성 있게 짰다(이미 존재하는 리소스는 그대로 두거나 최신 내용으로 갱신만 함, 삭제 없음).
#
# 미리 알아둘 것:
#   - single mini PC 전제라 비-HA(단일 인스턴스) 설치를 쓴다. 노드가 여러 개로 늘어나면 HA
#     manifest(ha/install.yaml)로 바꿔야 한다.
#   - sealed-secrets 컨트롤러(STEP 5)는 root-app.yaml 등록(STEP 6)보다 반드시 먼저 설치해야
#     한다 — platform/identity-service 등 여러 차트가 SealedSecret 리소스를 갖고 있는데, 이
#     CRD가 클러스터에 없으면 ArgoCD가 "no matches for kind SealedSecret"으로 sync 자체를
#     실패시킨다.
#   - root-app.yaml은 groovy-infra의 main 브랜치를 본다. 이 스크립트를 돌리는 시점에 아직
#     Phase 01~06 PR들이 main에 병합되기 전이라면, STEP 6 적용 직후 Application들이 실패로
#     보여도 정상이다 — main 병합이 끝나면 다음 폴링(기본 3분) 때 저절로 정상화된다. 마찬가지로
#     각 차트의 SealedSecret 값(sealedSecretData.*)을 아직 안 채웠다면 그 차트도 실패로 보이는
#     게 정상이다 — argocd/bootstrap/seal-secret-values.sh로 채운 뒤 정상화된다.
#   - Ingress는 이번 목표에서 제외됐다. 그래서 UI 접근은 port-forward로 안내한다(STEP 7).
#     운영 중인 docker-compose 스택과는 별도 네임스페이스(argocd)라 서로 간섭하지 않는다.

set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 현재 kubectl context: $(kubectl config current-context) ==="
read -r -p "이 클러스터가 맞습니까? (y/N) " confirm
[[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "중단합니다."; exit 1; }

echo
echo "[1/7] argocd 네임스페이스 생성(이미 있으면 그대로 둠)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo
echo "[2/7] ArgoCD 코어 설치 (stable 채널, non-HA)"
# --server-side 필수: applicationsets.argoproj.io CRD가 커서 기본(client-side) apply로는
# "metadata.annotations: Too long"(last-applied-configuration이 256KB 제한 초과) 에러가 난다.
# --force-conflicts는 이 명령을 재실행하거나 위 CRD들을 이미 client-side로 만들어본 적 있을 때
# 소유권 충돌 없이 서버사이드 관리로 넘어오게 한다.
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo
echo "[2/7] 전체 Pod가 Ready 될 때까지 대기 (최대 5분)"
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo
echo "[3/7] RBAC 정책 적용 (argocd-rbac-cm.yaml — 기본 role:readonly)"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/argocd-rbac-cm.yaml"
# ConfigMap은 재시작해야 argocd-server가 다시 읽는다.
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

echo
echo "[4/7] 초기 admin 비밀번호 (최초 로그인 후 반드시 변경할 것: argocd account update-password)"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo

echo
echo "[5/7] sealed-secrets 컨트롤러 설치 (root-app보다 먼저 — 위 '미리 알아둘 것' 참고)"
kubectl apply --server-side --force-conflicts -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
kubectl wait --for=condition=Ready pods -l name=sealed-secrets-controller -n kube-system --timeout=180s
echo "  → 이 클러스터의 공개키로 비밀번호를 암호화하려면: argocd/bootstrap/seal-secret-values.sh"

echo
echo "[6/7] App of Apps(root-app.yaml) 등록 — 이후로는 이 Application이 argocd/apps/를 계속 감시함"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/../root-app.yaml"

echo
echo "[7/7] 완료. UI 접근은 별도 터미널에서:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080  (admin / 위에서 출력된 초기 비밀번호)"
