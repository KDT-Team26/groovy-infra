#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 현재 kubectl context: $(kubectl config current-context) ==="
read -r -p "이 클러스터가 맞습니까? (y/N) " confirm
[[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "중단합니다."; exit 1; }

echo
echo "[1/6] argocd 네임스페이스 생성(이미 있으면 그대로 둠)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo
echo "[2/6] ArgoCD 코어 설치 (stable 채널, non-HA)"

kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo
echo "[2/6] 전체 Pod가 Ready 될 때까지 대기 (최대 5분)"
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo
echo "[3/6] RBAC 정책 적용 (argocd-rbac-cm.yaml — 기본 role:readonly)"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/argocd-rbac-cm.yaml"
# ConfigMap은 재시작해야 argocd-server가 다시 읽는다.
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

echo
echo "[3.5/6] 전역 설정 적용 (argocd-cm.yaml — Istio webhook caBundle 등 ignoreDifferences, #157)"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/argocd-cm.yaml"
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout restart statefulset argocd-application-controller -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

echo
echo "[4/6] 초기 admin 비밀번호 (최초 로그인 후 반드시 변경할 것: argocd account update-password)"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo

echo
echo "[4.5/6] ArgoCD Notifications(Discord) 설정 적용 (#61)"
# notifications-controller는 core install.yaml(STEP 2)에 이미 포함되어 있어 별도 설치가
# 필요 없다 — ConfigMap/ExternalSecret만 적용하면 된다. argocd-notifications-secret.yaml은
# ExternalSecret이라 groovy/prod/argocd-notifications(Discord Webhook URL)가 Secrets Manager에
# 없으면 이 스텝도 정상적으로 실패로 보인다 — 값 채운 뒤 재적용하면 된다(root-app과 마찬가지로
# 이 두 리소스도 GitOps 관리 대상이 아니라 여기서 kubectl apply로 직접 적용한다).
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/argocd-notifications-cm.yaml"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/argocd-notifications-secret.yaml"

echo
echo "[5/6] App of Apps(root-app.yaml) 등록 — 이후로는 이 Application이 argocd/apps/를 계속 감시함"
kubectl apply -n argocd -f "${BOOTSTRAP_DIR}/../root-app.yaml"

echo
echo "[6/6] 완료. UI 접근은 별도 터미널에서:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080  (admin / 위에서 출력된 초기 비밀번호)"
