#!/usr/bin/env bash
# 자동 롤백(auto-rollback P5) — 롤백 실행 여부 판단.
#
# "불확실은 롤백하지 않는다 / 새 리비전에 귀속되는 신호에서만 롤백한다" 원칙을 코드로.
# 결과를 GITHUB_OUTPUT 의 decision / reason 으로 내보낸다:
#   decision = rollback       — 배포 실패 확정 + 모든 가드·크로스체크 통과
#   decision = abstain        — 롤백하지 않음 (사유는 reason). 알림만.
#   decision = circuit_break  — 최근 롤백 과다 → 자동 롤백 중단, 수동 개입 필요
#
# 필요 env: SERVICE, INFRA_SHA, MODE(manual|auto), RESULT(verify-deploy.sh 결과)
# 선택 env: AUTO_ENABLED, AUTO_SERVICES, APP_NAMESPACE, ARGOCD_NAMESPACE
set -uo pipefail

: "${SERVICE:?}"; : "${INFRA_SHA:?}"; : "${MODE:?}"; : "${RESULT:?}"
AUTO_ENABLED="${AUTO_ENABLED:-false}"
AUTO_SERVICES="${AUTO_SERVICES:-}"
NS_APP="${APP_NAMESPACE:-groovy-application}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"

DECISION="abstain"; REASON=""
finish() {
  {
    echo "decision=${DECISION}"
    echo "reason=${REASON}"
  } >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo ">>> decision=${DECISION} :: ${REASON}"
  exit 0
}

# 1) verify 결과가 "배포 실패 확정"이 아니면 롤백 안 함
case "$RESULT" in
  degraded) : ;;
  timeout)      REASON="verify=timeout — 판정 불확실, 롤백 안 함(수동 확인)"; finish ;;
  inconclusive) REASON="verify=inconclusive — 클러스터/ArgoCD 조회 실패, 롤백 안 함(수동 확인)"; finish ;;
  healthy)      REASON="verify=healthy — 롤백 불필요"; finish ;;
  *)            REASON="verify=${RESULT} — 알 수 없는 상태, 롤백 안 함"; finish ;;
esac

# 2) 킬 스위치 / 화이트리스트 (auto 모드에서만)
# GitHub Actions 변수는 빈 값을 허용하지 않으므로, "활성 서비스 없음"은 'none' 으로 표기한다.
[ "$AUTO_SERVICES" = "none" ] && AUTO_SERVICES=""
if [ "$MODE" = "auto" ]; then
  if [ "$AUTO_ENABLED" != "true" ]; then
    REASON="AUTO_ROLLBACK_ENABLED != true — detect-only 모드"; finish
  fi
  if ! printf '%s' "$AUTO_SERVICES" | tr ', ' '\n' | grep -qx "$SERVICE"; then
    REASON="${SERVICE} 가 AUTO_ROLLBACK_SERVICES 화이트리스트에 없음"; finish
  fi
fi

# 3) last-good 기준선 존재 확인
git fetch origin "refs/tags/last-good/${SERVICE}:refs/tags/last-good/${SERVICE}" --force >/dev/null 2>&1 || true
if ! git rev-parse -q --verify "refs/tags/last-good/${SERVICE}" >/dev/null; then
  REASON="last-good/${SERVICE} 기준선 태그가 없음 — 안전하게 롤백 불가(수동 확인)"; finish
fi

# 4) 커밋 형태 가드 (루프 차단 + "봇 배포 커밋만")
SUBJ=$(git log -1 --format='%s' "$INFRA_SHA" 2>/dev/null || echo "")
AUTHOR=$(git log -1 --format='%an' "$INFRA_SHA" 2>/dev/null || echo "")
case "$SUBJ" in
  "revert("*) REASON="대상 커밋이 이미 revert — 롤백-of-롤백 루프 차단 (subj=${SUBJ})"; finish ;;
esac
if [ "$MODE" = "auto" ]; then
  case "$SUBJ" in
    "chore(${SERVICE}): bump image tag"*) : ;;
    *) REASON="대상 커밋이 봇 이미지 bump 가 아님 — 자동 롤백 안 함 (subj=${SUBJ})"; finish ;;
  esac
  case "$AUTHOR" in
    *github-actions*) : ;;
    *) REASON="대상 커밋 작성자가 github-actions 봇이 아님 (${AUTHOR})"; finish ;;
  esac
fi

# 5) 서킷 브레이커 — 최근 6시간 revert 과다
git fetch origin main --quiet 2>/dev/null || true
RECENT_ALL=$(git log origin/main --since='6 hours ago' --grep='^revert(' --format='%h' 2>/dev/null | wc -l | tr -d ' ')
RECENT_SVC=$(git log origin/main --since='6 hours ago' --grep="^revert(${SERVICE})" --format='%h' 2>/dev/null | wc -l | tr -d ' ')
if [ "${RECENT_SVC:-0}" -ge 2 ] || [ "${RECENT_ALL:-0}" -ge 4 ]; then
  DECISION="circuit_break"
  REASON="최근 6h revert: ${SERVICE}=${RECENT_SVC}, 전체=${RECENT_ALL} — 자동 롤백 중단. AUTO_ROLLBACK_ENABLED 를 끄고 수동 조사하세요."
  finish
fi

# 6) 크로스체크 — 배포와 무관한 장애 걸러내기 (kubeconfig 필요)
#   6-1) 이전 ReplicaSet 도 죽어 있으면 배포 탓 아님
OLD_READY=$(kubectl -n "$NS_APP" get rs -l "app=${SERVICE}" -o json 2>/dev/null \
  | jq '[.items[] | select((.status.availableReplicas // 0) > 0)] | length' 2>/dev/null || echo "unknown")
if [ "$OLD_READY" = "unknown" ]; then
  REASON="ReplicaSet 조회 실패 — 크로스체크 불가, 롤백 안 함(수동 확인)"; finish
fi
if [ "${OLD_READY:-0}" -eq 0 ]; then
  REASON="이전 ReplicaSet 도 available=0 — 배포가 아니라 클러스터/의존성 문제로 보임"; finish
fi

#   6-2) 공유 의존성 health (platform=kafka/redis, identity=JWKS 발급자)
PLAT=$(kubectl -n "$NS_ARGO" get application platform -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
IDH=$(kubectl  -n "$NS_ARGO" get application identity-service -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
if [ "$PLAT" != "Healthy" ]; then
  REASON="공유 의존성 platform=${PLAT} — 롤백 안 함(먼저 인프라 확인)"; finish
fi
if [ "$SERVICE" != "identity-service" ] && [ "$IDH" != "Healthy" ]; then
  REASON="공유 의존성 identity-service=${IDH} — 롤백 안 함(먼저 인프라 확인)"; finish
fi

#   6-3) 클러스터 범위 알림 (best-effort — RBAC 상 proxy 불가하면 skip)
AM=$(kubectl get --raw \
  "/api/v1/namespaces/groovy-monitoring/services/http:alertmanager:9093/proxy/api/v2/alerts?active=true" 2>/dev/null || echo "")
if [ -n "$AM" ]; then
  INFRA_ALERTS=$(printf '%s' "$AM" \
    | jq '[.[] | select(.labels.alertname | test("Node|Kube|Etcd|APIServer|TargetDown|Disk|Memory"))] | length' 2>/dev/null || echo 0)
  if [ "${INFRA_ALERTS:-0}" -gt 0 ]; then
    REASON="클러스터 범위 알림 ${INFRA_ALERTS}건 firing — 배포 무관 장애 가능, 롤백 안 함"; finish
  fi
fi

DECISION="rollback"
REASON="배포 실패 확정(verify=degraded) + 가드/크로스체크 통과 (이전 RS available=${OLD_READY})"
finish
