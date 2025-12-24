#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG (можно переопределять переменными окружения)
# =========================
NAMESPACE="${NAMESPACE:-atlantis}"
STATEFULSET="${STATEFULSET:-atlantis}"
POD="${POD:-atlantis-0}"

# TF_VAR values
TF_VAR_yandex_cloud_id="${TF_VAR_yandex_cloud_id:-b1gpupamkrr85nd1d31m}"
TF_VAR_yandex_folder_id="${TF_VAR_yandex_folder_id:-b1grpedldfrumqsrjf62}"
TF_VAR_service_account_key_file="${TF_VAR_service_account_key_file:-/home/atlantis/service_account_key_file.json}"

# SA key file on your local machine (host)
SA_KEY_PATH="${SA_KEY_PATH:-/home/ilya/service_account_key_file.json}"

# Names of k8s objects
TFVARS_SECRET="${TFVARS_SECRET:-atlantis-tfvars}"
SAKEY_SECRET="${SAKEY_SECRET:-atlantis-yc-sa-key}"
TERRAFORMRC_CONFIGMAP="${TERRAFORMRC_CONFIGMAP:-atlantis-terraformrc}"

# Terraform mirror config path
TERRAFORMRC_TMP="/tmp/terraformrc"

# =========================
# CHECKS
# =========================
echo "🔍 Проверка зависимостей..."
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl не найден"; exit 1; }

echo "🔍 Проверка namespace/statefulset..."
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || { echo "❌ Namespace '${NAMESPACE}' не найден. Сначала запусти install-atlantis.sh"; exit 1; }
kubectl -n "${NAMESPACE}" get sts "${STATEFULSET}" >/dev/null 2>&1 || { echo "❌ StatefulSet '${STATEFULSET}' не найден в ns=${NAMESPACE}. Сначала запусти install-atlantis.sh"; exit 1; }

echo "🔍 Проверка файла ключа на хосте: ${SA_KEY_PATH}"
test -f "${SA_KEY_PATH}" || { echo "❌ Файл ключа не найден: ${SA_KEY_PATH}"; exit 1; }

# =========================
# STEP 1: quick status + logs
# =========================
echo "📌 Текущее состояние Atlantis:"
kubectl -n "${NAMESPACE}" get pods

echo "📜 Последние логи Atlantis (tail=50):"
kubectl -n "${NAMESPACE}" logs "${POD}" --tail=50 || true

# =========================
# STEP 2: secrets/configmap apply
# =========================
echo "🔐 Создаём/обновляем секрет ${TFVARS_SECRET} (TF_VAR_*)..."
kubectl -n "${NAMESPACE}" create secret generic "${TFVARS_SECRET}" \
  --from-literal=TF_VAR_yandex_cloud_id="${TF_VAR_yandex_cloud_id}" \
  --from-literal=TF_VAR_yandex_folder_id="${TF_VAR_yandex_folder_id}" \
  --from-literal=TF_VAR_service_account_key_file="${TF_VAR_service_account_key_file}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🔐 Создаём/обновляем секрет ${SAKEY_SECRET} (service account key file)..."
kubectl -n "${NAMESPACE}" create secret generic "${SAKEY_SECRET}" \
  --from-file=service_account_key_file.json="${SA_KEY_PATH}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🧩 Создаём/обновляем configmap ${TERRAFORMRC_CONFIGMAP} (terraform mirror)..."
cat > "${TERRAFORMRC_TMP}" <<'EOF'
provider_installation {
  network_mirror {
    url     = "https://terraform-mirror.yandexcloud.net/"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF

kubectl -n "${NAMESPACE}" create configmap "${TERRAFORMRC_CONFIGMAP}" \
  --from-file=terraformrc="${TERRAFORMRC_TMP}" \
  --dry-run=client -o yaml | kubectl apply -f -

# =========================
# STEP 3: detect container name + patch sts
# =========================
echo "🔎 Определяем имя контейнера в StatefulSet..."
CONTAINER_NAME="$(kubectl -n "${NAMESPACE}" get sts "${STATEFULSET}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
echo "✅ Container name: ${CONTAINER_NAME}"

echo "🩹 Патчим StatefulSet (volumes + mounts + envFrom)..."
kubectl -n "${NAMESPACE}" patch sts "${STATEFULSET}" --type='strategic' -p "
spec:
  template:
    spec:
      volumes:
      - name: yc-sa-key
        secret:
          secretName: ${SAKEY_SECRET}
      - name: terraformrc
        configMap:
          name: ${TERRAFORMRC_CONFIGMAP}
      containers:
      - name: ${CONTAINER_NAME}
        envFrom:
        - secretRef:
            name: ${TFVARS_SECRET}
        volumeMounts:
        - name: yc-sa-key
          mountPath: /home/atlantis/service_account_key_file.json
          subPath: service_account_key_file.json
          readOnly: true
        - name: terraformrc
          mountPath: /home/atlantis/.terraformrc
          subPath: terraformrc
          readOnly: true
"

# =========================
# STEP 4: rollout
# =========================
echo "🔄 Перезапуск StatefulSet и ожидание готовности..."
kubectl -n "${NAMESPACE}" rollout restart sts/"${STATEFULSET}"
kubectl -n "${NAMESPACE}" rollout status sts/"${STATEFULSET}"

echo "📌 Pods после rollout:"
kubectl -n "${NAMESPACE}" get pods -o wide

# =========================
# STEP 5: verify inside pod (exactly your commands)
# =========================
echo "✅ Проверяем terraformrc внутри pod:"
kubectl -n "${NAMESPACE}" exec -it "${POD}" -- sh -lc 'ls -la /home/atlantis/.terraformrc && cat /home/atlantis/.terraformrc'

echo "✅ Проверяем ключ SA внутри pod:"
kubectl -n "${NAMESPACE}" exec -it "${POD}" -- sh -lc 'ls -la /home/atlantis/service_account_key_file.json | cat'

echo "✅ Проверяем TF_VAR_ переменные внутри pod:"
kubectl -n "${NAMESPACE}" exec -it "${POD}" -- sh -lc 'env | grep ^TF_VAR_ | sort || echo NO_TF_VARS'

echo ""
echo "🎉 Готово! Atlantis runtime-настройки применены."
