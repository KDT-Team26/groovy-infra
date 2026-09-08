#!/usr/bin/env bash
# ArgoCD 웹훅(#193 B안) — groovy-infra 레포에 GitHub push 웹훅을 등록한다.
#
# 실행 전 전제조건 (docs/argocd-webhook-setup.md 순서를 이미 끝냈다고 가정):
#   1) argocd.groovy-team26.com 이 실제로 argocd-server 로 라우팅됨 (Ingress/ALB/DNS/인증서 완료)
#   2) argocd-secret 의 webhook.github.secret 이 groovy/prod/argocd-webhook 값으로 동기화됨
#   3) 이 스크립트에 넘기는 SECRET 값이 위 2번과 정확히 같은 값이어야 서명이 맞는다
#
# 이 스크립트는 이번 작업 범위에서 실행하지 않는다 — 코드만 준비해둔다.
set -euo pipefail

REPO="KDT-Team26/groovy-infra"
WEBHOOK_URL="https://argocd.groovy-team26.com/api/webhook"

: "${GITHUB_WEBHOOK_SECRET:?groovy/prod/argocd-webhook 의 githubWebhookSecret 값을 환경변수로 넘기세요}"

echo "다음 웹훅을 ${REPO} 에 등록합니다: ${WEBHOOK_URL}"
gh api --method POST "repos/${REPO}/hooks" \
  -f name="web" \
  -f "config[url]=${WEBHOOK_URL}" \
  -f "config[content_type]=json" \
  -f "config[secret]=${GITHUB_WEBHOOK_SECRET}" \
  -f "config[insecure_ssl]=0" \
  -F active=true \
  -f "events[]=push"

echo "완료. GitHub 레포 Settings > Webhooks 에서 최근 Deliveries 로 200 응답 확인할 것."
