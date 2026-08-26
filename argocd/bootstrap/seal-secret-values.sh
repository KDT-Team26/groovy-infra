#!/usr/bin/env bash
# GitOps 빌드 지시서 Phase 05 부속 — 9개 차트의 시크릿 값을 이 클러스터의 sealed-secrets
# 공개키로 암호화해서, 각 차트 values.yaml의 sealedSecretData.* 에 붙여넣을 YAML 조각을
# 출력해준다. install-argocd.sh의 STEP 5(sealed-secrets 컨트롤러 설치)가 끝난 뒤에만 동작한다
# — kubeseal이 기본적으로 현재 kubectl context의 컨트롤러에서 공개키를 직접 가져오기 때문이다.
#
# 이 스크립트는 클러스터에 아무것도 적용(apply)하지 않는다 — 순수하게 "평문 -> 암호문" 변환만
# 하고 결과를 화면에 출력한다. 그 출력을 사람이 직접 확인하고 values.yaml에 붙여넣는 방식이다
# (자동으로 파일을 고치지 않는 이유: 실제 비밀번호가 이 스크립트를 거쳐가는 민감한 작업이라,
# 사람이 최종 결과를 눈으로 한 번 보고 넣는 편이 안전하다).
#
# 사용법:
#   ./seal-secret-values.sh                    # groovy-kubernates 네임스페이스 기준(기본값)
#   NAMESPACE=other-ns ./seal-secret-values.sh  # 다른 네임스페이스로 테스트할 때

set -euo pipefail

NAMESPACE="${NAMESPACE:-groovy-kubernates}"
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${BOOTSTRAP_DIR}/.." && cd .. && pwd)"

command -v kubeseal >/dev/null || { echo "kubeseal CLI가 필요합니다. https://github.com/bitnami-labs/sealed-secrets#installation 참고"; exit 1; }

# 값 하나를 암호화해서 암호문(값만, key: 접두어 없이)을 출력한다.
# kubeseal --format yaml 출력은 spec.encryptedData 아래 4-space 들여쓰기로 "KEY: 암호문"이 나온다.
seal_literal() {
  local secret_name="$1" key="$2" value="$3"
  kubectl create secret generic "${secret_name}" -n "${NAMESPACE}" \
    --dry-run=client --from-literal="${key}=${value}" -o yaml \
    | kubeseal --format yaml -n "${NAMESPACE}" \
    | grep -F "    ${key}:" | head -1 | sed -E "s/^    [^:]+: *//"
}

read_secret() {
  local prompt="$1" varname="$2"
  read -r -s -p "${prompt}: " "${varname}"
  echo
}

echo "=== 대상 네임스페이스: ${NAMESPACE} (다르면 NAMESPACE=xxx로 다시 실행) ==="
echo

# ── 1) 단순 서비스 시크릿 6개 (identity/study/content/calendar/notification-service, grafana) ──
for svc in identity study content calendar notification; do
  read_secret "${svc}-service DB 비밀번호" pw
  echo "--- helm/${svc}-service/values.yaml ---"
  echo "sealedSecretData:"
  echo "  ${svc}Service:"
  echo "    dbPassword: $(seal_literal "${svc}-service-secret" SPRING_DEV_DB_PASSWORD "${pw}")"
  echo
done

read_secret "Grafana admin 비밀번호" grafana_pw
echo "--- helm/observability/values.yaml ---"
echo "sealedSecretData:"
echo "  grafanaAdminPassword: $(seal_literal grafana-secret GF_SECURITY_ADMIN_PASSWORD "${grafana_pw}")"
echo

# ── 2) platform/mysql-secret.yaml ──
read_secret "MySQL root 비밀번호" mysql_root_pw
read_secret "MySQL provisioner 비밀번호" mysql_prov_pw
provisioner_sql=$(cat <<SQL
CREATE USER IF NOT EXISTS 'provisioner'@'%'
  IDENTIFIED BY '${mysql_prov_pw}';

GRANT ALL PRIVILEGES ON *.* TO 'provisioner'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL
)
echo "--- helm/platform/values.yaml (mysql) ---"
echo "sealedSecretData:"
echo "  mysql:"
echo "    rootPassword: $(seal_literal mysql-secret MYSQL_ROOT_PASSWORD "${mysql_root_pw}")"
echo "    provisionerPassword: $(seal_literal mysql-secret MYSQL_PROVISIONER_PASSWORD "${mysql_prov_pw}")"
echo "    provisionerInitSql: $(seal_literal mysql-secret 00-provisioner-init.sql "${provisioner_sql}")"
echo

# ── 3) platform/db-init-secret.yaml — 각 서비스 dbPassword는 위에서 이미 입력받은 값과
#       반드시 같아야 한다(같은 원본 비밀번호, 서로 다른 SealedSecret으로 각각 암호화됨). ──
echo "--- helm/platform/values.yaml (dbInit) — 위에서 입력한 서비스별 DB 비밀번호를 그대로 재사용합니다 ---"
declare -A db_names=( [identity]=identity_db [study]=study_db [content]=content_db [calendar]=calendar_db [notification]=notification_db )
echo "sealedSecretData:"
echo "  dbInit:"
for svc in identity study content calendar notification; do
  var="pw_${svc}"
  # 위 루프에서 read_secret pw로 매번 덮어썼으므로, 여기선 다시 입력받는다(재입력 = 실수 방지).
  read_secret "[dbInit용] ${svc}-service DB 비밀번호 재입력(위와 동일한 값)" pw2
  db="${db_names[${svc}]}"
  sql=$(cat <<SQL
CREATE DATABASE IF NOT EXISTS ${db}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS '${svc}_service'@'%'
  IDENTIFIED BY '${pw2}';

GRANT ALL PRIVILEGES ON ${db}.* TO '${svc}_service'@'%';

FLUSH PRIVILEGES;
SQL
)
  echo "    ${svc}Service: $(seal_literal db-init-sql "${svc}-service.sql" "${sql}")"
done
echo

# ── 4) platform/kafka-secret.yaml — 사용자명은 비밀이 아니라 values.yaml에서 그대로 읽는다. ──
broker_user=$(grep -A2 "^kafka:" "${INFRA_ROOT}/helm/platform/values.yaml" | grep "brokerUsername:" | sed -E 's/.*brokerUsername:\s*"?([^"]*)"?/\1/')
app_user=$(grep "applicationUsername:" "${INFRA_ROOT}/helm/platform/values.yaml" | sed -E 's/.*applicationUsername:\s*"?([^"]*)"?/\1/')
sasl_mech=$(grep "saslEnabledMechanisms:" "${INFRA_ROOT}/helm/platform/values.yaml" | sed -E 's/.*saslEnabledMechanisms:\s*"?([^"]*)"?/\1/')
echo "(values.yaml에서 읽음: brokerUsername=${broker_user}, applicationUsername=${app_user}, saslEnabledMechanisms=${sasl_mech})"
read_secret "Kafka broker 비밀번호" kafka_broker_pw
read_secret "Kafka application 비밀번호" kafka_app_pw

broker_jaas="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${broker_user}\" password=\"${kafka_broker_pw}\" user_${broker_user}=\"${kafka_broker_pw}\" user_${app_user}=\"${kafka_app_pw}\";"
app_jaas="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${app_user}\" password=\"${kafka_app_pw}\";"
adminclient_conf=$(cat <<CONF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=${sasl_mech}
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${broker_user}" password="${kafka_broker_pw}";
CONF
)

echo "--- helm/platform/values.yaml (kafka) ---"
echo "sealedSecretData:"
echo "  kafka:"
echo "    brokerJaasConfig: $(seal_literal kafka-secret broker-jaas-config "${broker_jaas}")"
echo "    appJaasConfig: $(seal_literal kafka-secret app-jaas-config "${app_jaas}")"
echo "    adminclientConf: $(seal_literal kafka-secret adminclient.conf "${adminclient_conf}")"
echo

echo "=== 완료. 위 sealedSecretData 블록들을 각 차트의 values.yaml에 병합해 넣으세요. ==="
