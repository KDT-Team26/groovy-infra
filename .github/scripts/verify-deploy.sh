#!/usr/bin/env bash
#
# fail-fast(#193): ImagePullBackOff 류는 progressDeadlineSeconds(기본 240s) 전체를
# 기다리지 않아도 재시도로 회복되지 않는다는 게 이미 확정된 상태다. 매 폴링(INTERVAL)마다
# 새 이미지(EXPECT_TAG)로 뜬 Pod의 컨테이너 상태를 같이 확인해서, 그런 상태가 연속
# FAILFAST_CONFIRM 회 관측되면 progressDeadlineSeconds 를 기다리지 않고 즉시 degraded 로
# 확정한다. "healthy 확정"에는 관여하지 않는다 — degraded 확정만 앞당길 뿐, 불확실한
# 쪽으로는 안전장치를 건너뛰지 않는다.

set -uo pipefail

: "${SERVICE:?SERVICE 필요}"
: "${EXPECT_SHA:?EXPECT_SHA 필요}"
NS_APP="${APP_NAMESPACE:-groovy-application}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"
TIMEOUT="${VERIFY_TIMEOUT_SECONDS:-900}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
INTERVAL=15
consecutive_query_fail=0

# 재시도해도 회복 불가능하다고 kubelet 이 이미 결론 낸 컨테이너 상태들.
#   ImagePullBackOff/ErrImagePull/InvalidImageName : 이미지가 없거나 참조 자체가 잘못됨
#   CreateContainerConfigError                     : envFrom(ConfigMap/Secret) 키 참조가 깨짐
#   CrashLoopBackOff                                : 기동은 되지만 반복적으로 죽어서 백오프 중
# 전부 "Back(Loop)"/"Err"/"Invalid"/"ConfigError" 이름대로, kubelet 이 이미 여러 번
# 재시도한 뒤에만 붙는 상태라 확정적 실패로 취급해도 안전하다.
FAILFAST_REGEX='^(ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CrashLoopBackOff)$'
FAILFAST_CONFIRM="${FAILFAST_CONFIRM:-2}"
failfast_streak=0

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

  # ---- fail-fast(#193): progressDeadlineSeconds 를 기다리지 않고 확정적 실패 조기 감지 ----
  # 새 이미지(EXPECT_TAG)로 뜬 pod 의 컨테이너 중에 FAILFAST_REGEX 상태가 있는지 확인.
  # 라벨 selector 는 app=<service> 라 구버전 이미지로 계속 떠 있는 pod(maxUnavailable:0 이라
  # 살아있음)도 걸리지만, image 태그가 EXPECT_TAG 로 끝나는 컨테이너만 걸러서 신버전만 본다.
  bad_reason=$(kubectl -n "$NS_APP" get pods -l "app=${SERVICE}" -o json 2>/dev/null \
    | jq -r --arg tag "$EXPECT_TAG" --arg re "$FAILFAST_REGEX" '
        [.items[].status.containerStatuses[]?
          | select((.image // "") | endswith(":" + $tag))
          | (.state.waiting.reason // empty)
        ]
        | map(select(test($re)))
        | first // empty
      ' 2>/dev/null)

  if [ -n "$bad_reason" ]; then
    failfast_streak=$(( failfast_streak + 1 ))
    echo "fail-fast 후보: ${bad_reason} (연속 ${failfast_streak}/${FAILFAST_CONFIRM}회)"
    if [ "$failfast_streak" -ge "$FAILFAST_CONFIRM" ]; then
      echo "::warning::확정적 실패 상태(${bad_reason})가 연속 ${FAILFAST_CONFIRM}회 관측됨 — progressDeadlineSeconds 대기 없이 degraded 판정"
      emit degraded
    fi
  else
    failfast_streak=0
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
