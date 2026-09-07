#!/usr/bin/env bash
# 자동 롤백(auto-rollback P4) — 배포 health 판정.
#
# EXPECT_SHA(= infra 태그 bump 커밋)가 설정한 이미지 태그로 Deployment 가 실제 굴러가고,
# ArgoCD Application 이 Healthy 이며, 롤아웃이 완료됐는지 폴링한다.
#
#   판정 결과를 GITHUB_OUTPUT 의 result 로 내보낸다:
#   healthy      — 기대 이미지로 배포됐고 Healthy + 롤아웃 완료
#   degraded     — 기대 이미지로 배포됐으나 Degraded + 롤아웃 실패 (배포 탓으로 확정)
#   timeout      — 제한 시간 내 어느 쪽으로도 확정되지 않음 (아직 Progressing 등)
#   inconclusive — 클러스터/ArgoCD 조회 실패, 또는 기대 태그를 해석 못 함 (판정 불가)
#
# 주의: ArgoCD Application 의 status.sync.revision 은 "이 앱 경로를 바꾼 커밋"이 아니라
#       tracking 브랜치(main)의 현재 HEAD 다. 다중 서비스 환경에서는 bump 커밋 직후에도
#       다른 커밋이 쌓여 어긋나므로, revision 대신 "배포된 이미지 태그"로 판정한다.
#
# 필요 env: SERVICE, EXPECT_SHA
# 선택 env: APP_NAMESPACE, ARGOCD_NAMESPACE, VERIFY_TIMEOUT_SECONDS
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
