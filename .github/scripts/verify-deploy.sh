#!/usr/bin/env bash
# 자동 롤백(auto-rollback P4) — 배포 health 판정.
#
# ArgoCD Application 이 EXPECT_SHA 로 sync(Succeeded) 되고 Healthy 인지, Deployment 롤아웃이
# 완료됐는지 폴링한다. 판정 결과를 GITHUB_OUTPUT 의 result 로 내보낸다:
#   healthy      — 기대 리비전으로 sync 됐고 Healthy + 롤아웃 완료
#   degraded     — 기대 리비전으로 sync 됐으나 Degraded + 롤아웃 실패 (배포 탓으로 확정)
#   timeout      — 제한 시간 내 healthy/degraded 어느 쪽으로도 확정되지 않음
#   inconclusive — 클러스터/ArgoCD 조회 자체가 계속 실패 (판정 불가)
#
# 필요 env: SERVICE, EXPECT_SHA
# 선택 env: APP_NAMESPACE, ARGOCD_NAMESPACE, VERIFY_TIMEOUT_SECONDS
set -uo pipefail

: "${SERVICE:?SERVICE 필요}"
: "${EXPECT_SHA:?EXPECT_SHA 필요}"
NS_APP="${APP_NAMESPACE:-groovy-application}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"
TIMEOUT="${VERIFY_TIMEOUT_SECONDS:-480}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
INTERVAL=15
consecutive_query_fail=0

emit() {
  echo "result=$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo ">>> 판정: $1"
  exit 0
}

while :; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    # 조회가 계속 실패해서 타임아웃까지 온 경우와, 그냥 Progressing 상태로 시간 초과된 경우를 구분
    [ "$consecutive_query_fail" -ge 5 ] && emit inconclusive
    emit timeout
  fi

  app_json=$(kubectl -n "$NS_ARGO" get application "$SERVICE" -o json 2>/dev/null)
  if [ -z "$app_json" ]; then
    consecutive_query_fail=$(( consecutive_query_fail + 1 ))
    echo "ArgoCD Application 조회 실패(${consecutive_query_fail}회 연속) — 재시도"
    sleep "$INTERVAL"; continue
  fi
  consecutive_query_fail=0

  sync_rev=$(printf '%s' "$app_json" | jq -r '.status.sync.revision // ""')
  phase=$(printf '%s' "$app_json"    | jq -r '.status.operationState.phase // ""')
  health=$(printf '%s' "$app_json"   | jq -r '.status.health.status // ""')
  echo "sync_rev=${sync_rev:0:12} phase=${phase:-none} health=${health:-none} (기대 ${EXPECT_SHA:0:12})"

  # 아직 기대 리비전으로 sync 되지 않았으면 계속 대기
  case "$sync_rev" in
    "$EXPECT_SHA"*) : ;;
    *) sleep "$INTERVAL"; continue ;;
  esac
  [ "$phase" = "Succeeded" ] || { sleep "$INTERVAL"; continue; }

  if [ "$health" = "Healthy" ]; then
    if kubectl -n "$NS_APP" rollout status "deployment/${SERVICE}" --timeout=60s >/dev/null 2>&1; then
      emit healthy
    fi
  elif [ "$health" = "Degraded" ]; then
    if ! kubectl -n "$NS_APP" rollout status "deployment/${SERVICE}" --timeout=20s >/dev/null 2>&1; then
      emit degraded
    fi
  fi
  # Progressing 등 그 외 상태 → 계속 폴링
  sleep "$INTERVAL"
done
