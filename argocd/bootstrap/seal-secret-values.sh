#!/usr/bin/env bash
# GitOps 빌드 지시서 Phase 05 부속 — 9개 차트의 시크릿 값을 이 클러스터의 sealed-secrets
# 공개키로 암호화해서, 각 차트 values.yaml의 sealedSecretData.* 에 붙여넣을 YAML 조각을
# 출력해준다. install-argocd.sh의 STEP 5(sealed-secrets 컨트롤러 설치)가 끝난 뒤에만 동작한다
# — kubeseal이 기본적으로 현재 kubectl context의 컨트롤러에서 공개키를 직접 가져오기 때문이다.
#
# 이 스크립트는 클러스터에 아무것도 적용(apply)하지 않는다 — 순수하게 "평문 -> 암호문" 변환만
# 하고 결과를 화면에 출력한다. 그 출력을 사람이 직접 확인하고 values.yaml에 붙여넣는 방식이다.
#
# 실제로 필요한 값은 20개다(서비스 DB 비밀번호 5 + grafana 1 +
# alertmanager discord webhook 설정 전체(#65) 1 +
# argocd-notifications discord webhook(#61) 1 +
# 서비스별 MySQL 관리자 비밀번호 10(root/provisioner 각 5) + kafka 2).
# 실제로 필요한 값은 12개다(서비스 DB 비밀번호 5 + grafana 1 + alertmanager discord webhook
# 설정 전체(#65) 1 + mysql 2 + kafka 2 + argocd-notifications discord webhook(#61) 1).

# db-init용 SQL에도 같은 서비스 비밀번호가 또 들어가지만, 이 스크립트는 한 번 입력받은 값을
# 재사용만 하지 다시 묻지 않는다(재입력을 시키면 오히려 오타로 두 곳 값이 달라질 위험만 커짐).
#
# 사용법 — 대화형(하나씩 프롬프트):
#   ./seal-secret-values.sh
#
# 사용법 — 비대화형(전부 환경변수로 한 번에, 반복 설치·CI 등에 유용):
#   SVC_IDENTITY_DB_PW=... SVC_STUDY_DB_PW=... SVC_CONTENT_DB_PW=... \
#   SVC_CALENDAR_DB_PW=... SVC_NOTIFICATION_DB_PW=... GRAFANA_ADMIN_PW=... \
#   ALERTMANAGER_DISCORD_WEBHOOK_URL=... ARGOCD_DISCORD_WEBHOOK_URL=... \
#   MYSQL_IDENTITY_ROOT_PW=... MYSQL_IDENTITY_PROVISIONER_PW=... \
#   MYSQL_STUDY_ROOT_PW=... MYSQL_STUDY_PROVISIONER_PW=... \
#   MYSQL_CONTENT_ROOT_PW=... MYSQL_CONTENT_PROVISIONER_PW=... \
#   MYSQL_CALENDAR_ROOT_PW=... MYSQL_CALENDAR_PROVISIONER_PW=... \
#   MYSQL_NOTIFICATION_ROOT_PW=... MYSQL_NOTIFICATION_PROVISIONER_PW=... \
#   KAFKA_BROKER_PW=... KAFKA_APP_PW=... \
#   ./seal-secret-values.sh
#   (일부만 환경변수로 주고 나머진 프롬프트로 받는 것도 가능 — 값이 없는 것만 물어봄)
#
# NAMESPACE=other-ns ./seal-secret-values.sh  로 대상 네임스페이스도 바꿀 수 있다(기본 groovy-kubernates).

set -euo pipefail

NAMESPACE="${NAMESPACE:-groovy-kubernates}"
SEALED_SECRETS_CERT="${SEALED_SECRETS_CERT:-}"

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${BOOTSTRAP_DIR}/.." && cd .. && pwd)"

command -v kubeseal >/dev/null || {
  echo "kubeseal CLI가 필요합니다."
  exit 1
}

if [[ -n "${SEALED_SECRETS_CERT}" && ! -f "${SEALED_SECRETS_CERT}" ]]; then
  echo "Sealed Secrets 공개 인증서를 찾을 수 없습니다: ${SEALED_SECRETS_CERT}"
  exit 1
fi

# 값 하나를 암호화해서 암호문(값만, key: 접두어 없이)을 출력한다.
# kubeseal --format yaml 출력은 spec.encryptedData 아래 4-space 들여쓰기로 "KEY: 암호문"이 나온다.
# 4번째 인자(ns)는 선택 — 대부분 시크릿은 기본 NAMESPACE(groovy-kubernates)를 쓰지만,
# argocd-notifications-secret처럼 argocd 네임스페이스에 떠야 하는 예외가 있어서 넣었다.
seal_literal() {
  local secret_name="$1" key="$2" value="$3" ns="${4:-$NAMESPACE}"

  local kubeseal_args=(
    --format yaml
    -n "${ns}"
  )

  if [[ -n "${SEALED_SECRETS_CERT}" ]]; then
    kubeseal_args+=(--cert "${SEALED_SECRETS_CERT}")
  fi

  kubectl create secret generic "${secret_name}" -n "${ns}" \
    --dry-run=client \
    --from-literal="${key}=${value}" \
    -o yaml \
    | kubeseal "${kubeseal_args[@]}" \
    | grep -F "    ${key}:" \
    | head -1 \
    | sed -E "s/^    [^:]+: *//"
}

# 환경변수(envname)가 이미 설정돼 있으면 그 값을 그대로 쓰고, 없을 때만 프롬프트로 물어본다.
read_secret() {
  local prompt="$1" varname="$2" envname="$3"
  if [[ -n "${!envname:-}" ]]; then
    printf -v "${varname}" '%s' "${!envname}"
    echo "${prompt}: (환경변수 \$${envname}에서 읽음)"
  else
    read -r -s -p "${prompt}: " "${varname}"
    echo
  fi
}

echo "=== 대상 네임스페이스: ${NAMESPACE} (다르면 NAMESPACE=xxx로 다시 실행) ==="
echo

# ── 1) 서비스 DB 비밀번호 5개 — 이 값을 배열에 저장해서 dbInit 섹션에서 재사용한다. ──
declare -A svc_pw
declare -A db_names=( [identity]=identity_db [study]=study_db [content]=content_db [calendar]=calendar_db [notification]=notification_db )
declare -A env_names=( [identity]=SVC_IDENTITY_DB_PW [study]=SVC_STUDY_DB_PW [content]=SVC_CONTENT_DB_PW [calendar]=SVC_CALENDAR_DB_PW [notification]=SVC_NOTIFICATION_DB_PW )

for svc in identity study content calendar notification; do
  read_secret "${svc}-service DB 비밀번호" pw "${env_names[${svc}]}"
  svc_pw[${svc}]="${pw}"
  echo "--- helm/${svc}-service/values.yaml ---"
  echo "sealedSecretData:"
  echo "  ${svc}Service:"
  echo "    dbPassword: $(seal_literal "${svc}-service-secret" SPRING_DEV_DB_PASSWORD "${pw}")"
  echo
done

read_secret "Grafana admin 비밀번호" grafana_pw GRAFANA_ADMIN_PW
echo "--- helm/observability/values.yaml (grafana) ---"
echo "sealedSecretData:"
echo "  grafanaAdminPassword: $(seal_literal grafana-secret GF_SECURITY_ADMIN_PASSWORD "${grafana_pw}")"
echo

# ── 1-1) helm/observability/templates/alertmanager-secret.yaml (#65, Slack -> Discord 전환) ──
# discord_configs가 slack_configs의 api_url_file(파일 경로 참조)을 지원하지 않아(alertmanager-
# secret.yaml 주석 참고) URL 한 줄이 아니라 alertmanager.yml 전체를 여기서 조립해서 통째로
# 봉인한다 — mysql-secret.yaml의 provisionerInitSql과 같은 방식.
read_secret "Alertmanager Discord Webhook URL" alertmanager_discord_webhook ALERTMANAGER_DISCORD_WEBHOOK_URL
alertmanager_config=$(cat <<YAML
global:
  resolve_timeout: 5m

route:
  receiver: "discord-notifications"

receivers:
  - name: "discord-notifications"
    discord_configs:
      - webhook_url: "${alertmanager_discord_webhook}"
        send_resolved: true
YAML
)
echo "--- helm/observability/values.yaml (alertmanager) ---"
echo "sealedSecretData:"
echo "  alertmanagerConfig: $(seal_literal alertmanager-secret alertmanager.yml "${alertmanager_config}")"
echo

# ── 1-2) argocd/bootstrap/argocd-notifications-secret.yaml — argocd 네임스페이스라
#         seal_literal에 ns를 명시로 넘긴다(#61, ArgoCD sync 알림 Discord 연동). ──
read_secret "ArgoCD Notifications Discord Webhook URL" argocd_discord_webhook ARGOCD_DISCORD_WEBHOOK_URL
echo "--- argocd/bootstrap/argocd-notifications-secret.yaml (encryptedData.discord-webhook-url) ---"
echo "  discord-webhook-url: $(seal_literal argocd-notifications-secret discord-webhook-url "${argocd_discord_webhook}" argocd)"
echo

# ── 2) platform/mysql-secret.yaml — 서비스별 MySQL 관리자 credential 분리 ──
echo "--- helm/platform/values.yaml (mysql) ---"
echo "sealedSecretData:"
echo "  mysql:"

for svc in identity study content calendar notification; do
  svc_upper=$(printf '%s' "${svc}" | tr '[:lower:]' '[:upper:]')

  root_env="MYSQL_${svc_upper}_ROOT_PW"
  prov_env="MYSQL_${svc_upper}_PROVISIONER_PW"

  read_secret "${svc} MySQL root 비밀번호" mysql_root_pw "${root_env}"
  read_secret "${svc} MySQL provisioner 비밀번호" mysql_prov_pw "${prov_env}"

  provisioner_sql=$(cat <<SQL
CREATE USER IF NOT EXISTS 'provisioner'@'%'
  IDENTIFIED BY '${mysql_prov_pw}';

GRANT ALL PRIVILEGES ON *.* TO 'provisioner'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL
)

  secret_name="${svc}-mysql-secret"

  echo "    ${svc}:"
  echo "      rootPassword: $(seal_literal "${secret_name}" MYSQL_ROOT_PASSWORD "${mysql_root_pw}")"
  echo "      provisionerPassword: $(seal_literal "${secret_name}" MYSQL_PROVISIONER_PASSWORD "${mysql_prov_pw}")"
  echo "      provisionerInitSql: $(seal_literal "${secret_name}" 00-provisioner-init.sql "${provisioner_sql}")"
done
echo

# ── 3) platform/db-init-secret.yaml — 위 1)에서 이미 입력받은 서비스별 비밀번호를 그대로
#       재사용한다(다시 묻지 않음 — 두 SealedSecret이 같은 원본 값을 각자 암호화하는 것뿐). ──
echo "--- helm/platform/values.yaml (dbInit) ---"
echo "sealedSecretData:"
echo "  dbInit:"
for svc in identity study content calendar notification; do
  db="${db_names[${svc}]}"
  sql=$(cat <<SQL
CREATE DATABASE IF NOT EXISTS ${db}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS '${svc}_service'@'%'
  IDENTIFIED BY '${svc_pw[${svc}]}';

GRANT ALL PRIVILEGES ON ${db}.* TO '${svc}_service'@'%';

FLUSH PRIVILEGES;
SQL
)
  echo "    ${svc}Service: $(seal_literal db-init-sql "${svc}-service.sql" "${sql}")"
done
echo

# ── 4) platform/kafka-secret.yaml — 사용자명은 비밀이 아니라 values.yaml에서 그대로 읽는다. ──
# kafka.security 블록이 kafka: 바로 아래가 아니라 한참 뒤에 있어서, 앞뒤 문맥에 기대지 않고
# 파일 전체에서 키 이름으로 직접 찾는다(이 세 키는 파일 안에 각각 한 번씩만 등장한다).
# 따옴표 사이 값만 뽑는다 — \s는 BSD sed(macOS)에서 리터럴로 취급돼 위험하므로 안 쓴다.
broker_user=$(grep "brokerUsername:" "${INFRA_ROOT}/helm/platform/values.yaml" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
app_user=$(grep "applicationUsername:" "${INFRA_ROOT}/helm/platform/values.yaml" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
sasl_mech=$(grep "saslEnabledMechanisms:" "${INFRA_ROOT}/helm/platform/values.yaml" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
echo "(values.yaml에서 읽음: brokerUsername=${broker_user}, applicationUsername=${app_user}, saslEnabledMechanisms=${sasl_mech})"
read_secret "Kafka broker 비밀번호" kafka_broker_pw KAFKA_BROKER_PW
read_secret "Kafka application 비밀번호" kafka_app_pw KAFKA_APP_PW

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

# ── 5) observability/kafka-exporter-secret.yaml ──
# 기존 Kafka application 계정 비밀번호를 Kafka Exporter에서도 재사용한다.
echo "--- helm/observability/values.yaml (kafka-exporter) ---"
echo "sealedSecretData:"
echo "  kafkaExporterPassword: $(seal_literal kafka-exporter-secret KAFKA_PASSWORD "${kafka_app_pw}")"
echo

echo "=== 완료. 위 sealedSecretData 블록들을 각 차트의 values.yaml에 병합해 넣으세요. ==="
