#!/usr/bin/env bash
set -euo pipefail

# identity-service의 JWT 서명키(RSA)를 모든 replica가 공유하도록 고정 키쌍을 생성하고 봉인한다.
#
# 배경(#116): JwtKeyProvider가 pod 기동 시 메모리에서 키를 매번 새로 생성했다 — replica가 2개
# 이상이면 pod마다 다른 키를 쓰게 되어, study/content-service가 JWKS를 어느 pod에서 받느냐에
# 따라 다른 pod가 발급한 토큰의 서명 검증이 실패했다(kube-proxy가 요청마다 다른 pod로 로드밸런싱
# 하므로 ~50% 확률로 401). 이 스크립트로 만든 고정 키를 JWT_PRIVATE_KEY_PEM 환경변수(Secret)로
# 모든 replica에 공유하면 해결된다.
#
# 이 스크립트는 클러스터에 아무것도 적용(apply)하지 않는다 — seal-secret-values.sh와 동일하게
# 순수 "평문 -> 암호문" 변환만 하고 결과를 화면에 출력한다. 그 출력을 helm/identity-service/
# values.yaml의 sealedSecretData.identityService 아래에 붙여넣는다.
#
# 주의(키 로테이션 관련): 이미 발급된 로그인 토큰은 키가 바뀌면 전부 무효화된다(사용자 재로그인
# 필요). 최초 1회 고정용으로 실행하고, 이후 재실행해서 values.yaml을 덮어쓰는 건 곧 전체 로그아웃을
# 의미하니 의도한 로테이션이 아니면 하지 말 것.
#
# 사용법:
#   ./generate-identity-jwt-key.sh
# (kubeseal이 현재 kubectl context의 sealed-secrets 컨트롤러 공개키를 자동으로 사용한다 —
# seal-secret-values.sh와 동일한 전제.)

NAMESPACE=groovy-kubernates
SECRET_NAME=identity-service-secret

TMP_KEY="$(mktemp)"
trap 'rm -f "${TMP_KEY}"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${TMP_KEY}" 2>/dev/null

PEM="$(cat "${TMP_KEY}")"

sealed="$(
  kubectl create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
    --dry-run=client \
    --from-literal=JWT_PRIVATE_KEY_PEM="${PEM}" \
    -o yaml \
    | kubeseal --format yaml -n "${NAMESPACE}" \
    | grep -F "    JWT_PRIVATE_KEY_PEM:" \
    | head -1 \
    | sed -E 's/^    [^:]+: *//'
)"

echo "--- helm/identity-service/values.yaml (sealedSecretData.identityService) 아래에 추가 ---"
echo "    jwtPrivateKeyPem: ${sealed}"
