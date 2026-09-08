#!/usr/bin/env bash

set -uo pipefail

: "${SERVICE:?SERVICE 필요}"
: "${EXPECT_SHA:?EXPECT_SHA 필요}"
NS_APP="${APP_NAMESPACE:-groovy-application}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"
TIMEOUT="${VERIFY_TIMEOUT_SECONDS:-900}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
INTERVAL=15
consecutive_query_fail=0

emit() {
  echo "result=$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo ">>> 판정: $1"
  exit 0
}

# EXPECT_SHA 시점의 helm/<svc>/values.yaml 에 박힌 이미지 태그 = 이 배포가 의도한 태그
EXPECT_TAG=$(git show "${EXPECT_SHA}:helm/${SERVICE}/values.yaml" 2>/dev/null \
             | grep -E '^    tag: ' | head -1 | sed -E 's/^    tag: "?([^"]*)"?.*/\1/')
if [ -z "$EXPECT_TAG" ]; then
  echo "::warning::${EXPECT_SHA} 에서 helm/${SERVICE}/values.yaml 의 tag 를 읽지 못했습니다."
  emit inconclusive
fi
echo "기대 이미지 태그: ${EXPECT_TAG}  (infra 커밋 ${EXPECT_SHA:0:12})"

while :; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    [ "$consecutive_query_fail" -ge 5 ] && emit inconclusive
    emit timeout
  fi

  running_img=$(kubectl -n "$NS_APP" get deploy "$SERVICE" \
                -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  app_json=$(kubectl -n "$NS_ARGO" get application "$SERVICE" -o json 2>/dev/null)
  if [ -z "$running_img" ] || [ -z "$app_json" ]; then
    consecutive_query_fail=$(( consecutive_query_fail + 1 ))
    echo "클러스터/ArgoCD 조회 실패(${consecutive_query_fail}회 연속) — 재시도"
    sleep "$INTERVAL"; continue
  fi
  consecutive_query_fail=0

  running_tag="${running_img##*:}"
  phase=$(printf '%s' "$app_json"  | jq -r '.status.operationState.phase // ""')
  health=$(printf '%s' "$app_json" | jq -r '.status.health.status // ""')
  echo "running_tag=${running_tag} phase=${phase:-none} health=${health:-none} (기대 ${EXPECT_TAG})"

  # 아직 기대 이미지로 안 넘어왔으면 계속 대기 (ArgoCD sync 전 / 롤아웃 전)
  if [ "$running_tag" != "$EXPECT_TAG" ]; then
    sleep "$INTERVAL"; continue
  fi

  if [ "$health" = "Healthy" ]; then
    if kubectl -n "$NS_APP" rollout status "deployment/${SERVICE}" --timeout=60s >/dev/null 2>&1; then
      emit healthy
    fi
  elif [ "$health" = "Degraded" ]; then
    if ! kubectl -n "$NS_APP" rollout status "deployment/${SERVICE}" --timeout=20s >/dev/null 2>&1; then
      emit degraded
    fi
  fi
  # Progressing 등 그 외 → 계속 폴링
  sleep "$INTERVAL"
done
