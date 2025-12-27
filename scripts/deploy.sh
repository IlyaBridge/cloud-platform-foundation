#!/bin/bash
set -e

echo "=== ПОЛНОЕ РАЗВЕРТЫВАНИЕ ИНФРАСТРУКТУРЫ ==="

# Создаем common-vars.sh
COMMON_VARS_FILE="/home/ilya/cloud-platform-foundation/terraform/common-vars.sh"
if [ ! -f "$COMMON_VARS_FILE" ]; then
    echo "Создаем $COMMON_VARS_FILE"
    cat > "$COMMON_VARS_FILE" << EOF
#!/bin/bash
# Общие переменные для проекта

export YC_CLOUD_ID="$YC_CLOUD_ID"
export YC_FOLDER_ID="$YC_FOLDER_ID"
export SERVICE_ACCOUNT_KEY_FILE="$SERVICE_ACCOUNT_KEY_FILE"
export S3_ACCESS_KEY="$S3_ACCESS_KEY"
export S3_SECRET_KEY="$S3_SECRET_KEY"
EOF
    chmod +x "$COMMON_VARS_FILE"
    echo "Файл common-vars.sh создан"
fi

# Проверка бакета
echo "Проверка S3 бакета..."
if ! yc storage bucket get diploma-terraform-state-ilya &>/dev/null; then
    echo "S3 бакет не найден! Сначала запустите: ./scripts/deploy-s3-bucket.sh"
    exit 1
fi
echo "S3 бакет найден"

# Функция для безопасного получения значения из Terraform output
safe_terraform_output() {
    local output_name=$1
    local module_path=$2
    
    cd "$module_path" 2>/dev/null || return 1
    # Получаем только значение без предупреждений
    terraform output -raw "$output_name" 2>/dev/null | grep -v "Warning:" | head -1
}

# Функция для развертывания модуля
deploy_module() {
    local module=$1
    local extra_vars=$2
    
    echo ""
    echo "=== РАЗВЕРТЫВАНИЕ: $module ==="
    cd /home/ilya/cloud-platform-foundation/terraform/$module
    
    # Очищаем предыдущие конфигурации
    rm -f terraform.tfvars 2>/dev/null || true
    
    # Создаем базовый terraform.tfvars
    cat > terraform.tfvars << EOF
yandex_cloud_id = "${YC_CLOUD_ID}"
yandex_folder_id = "${YC_FOLDER_ID}"
service_account_key_file = "${SERVICE_ACCOUNT_KEY_FILE}"
EOF
    
    # Добавляем S3 ключи для всех модулей
    echo "s3_access_key = \"${S3_ACCESS_KEY}\"" >> terraform.tfvars
    echo "s3_secret_key = \"${S3_SECRET_KEY}\"" >> terraform.tfvars
    
    # Добавляем дополнительные переменные если есть
    if [ ! -z "$extra_vars" ]; then
        echo "$extra_vars" >> terraform.tfvars
    fi
    
    echo "terraform.tfvars создан для модуля $module"
    echo "--- Начало terraform.tfvars ---"
    cat terraform.tfvars | sed 's/secret_key = .*/secret_key = "***Скрыто***"/' | \
                         sed 's/access_key = .*/access_key = "***Скрыто***"/'
    echo "--- Конец terraform.tfvars ---"
    
    # Инициализация и применение
    echo "Инициализация Terraform..."
    terraform init -backend-config=backend.conf -reconfigure
    
    echo "Применение конфигурации..."
    terraform apply -auto-approve
}

# 1. Infrastructure
deploy_module "infrastructure"

# 2. Kubernetes кластер
deploy_module "kubernetes"

# 3. Получаем SA ID для registry
echo ""
echo "=== ПОЛУЧЕНИЕ SERVICE ACCOUNT ID ==="

cd /home/ilya/cloud-platform-foundation/terraform/kubernetes
K8S_NODES_SA_ID=$(terraform output -raw k8s_nodes_service_account_id 2>/dev/null || echo "")

if [ -z "$K8S_NODES_SA_ID" ]; then
    # Альтернативный способ получения SA ID
    K8S_NODES_SA_ID=$(yc iam service-account get --name k8s-nodes --format=json 2>/dev/null | jq -r '.id' 2>/dev/null || echo "")
fi

if [ -z "$K8S_NODES_SA_ID" ]; then
    echo "Не удалось получить SA ID для registry, продолжаем с пустым значением"
else
    echo "SA ID для registry: $K8S_NODES_SA_ID"
fi

# 4. Registry с передачей SA ID
if [ ! -z "$K8S_NODES_SA_ID" ]; then
    deploy_module "registry" "k8s_nodes_service_account_id = \"$K8S_NODES_SA_ID\""
else
    deploy_module "registry"
fi

# 5. ДОБАВЛЕНИЕ РОЛЕЙ ДЛЯ k8s-nodes
echo ""
echo "=== ДОБАВЛЕНИЕ РОЛЕЙ ДЛЯ k8s-nodes ==="

SA_NAME="k8s-nodes"
FOLDER_ID="b1grpedldfrumqsrjf62"

# Получаем ID сервисного аккаунта
echo "Получаем ID сервисного аккаунта $SA_NAME..."
SA_ID=$(yc iam service-account get --name $SA_NAME --format=json 2>/dev/null | jq -r '.id' 2>/dev/null || echo "")

if [ -z "$SA_ID" ]; then
    echo "Сервисный аккаунт $SA_NAME не найден, пропускаем добавление ролей"
else
    echo "ID сервисного аккаунта: $SA_ID"
    echo ""
    echo "Добавляем необходимые роли (команды идемпотентны):"
    
    # Роли для Load Balancer и Kubernetes
    ROLES=(
        "load-balancer.admin"
        "vpc.user" 
        "k8s.clusters.agent"
        "compute.admin"
        "iam.serviceAccounts.user"
        "container-registry.images.puller"
    )
    
    for ROLE in "${ROLES[@]}"; do
        echo "  Добавляем: $ROLE"
        # Правильный синтаксис для новой версии yc
        yc resource-manager folder add-access-binding $FOLDER_ID \
            --subject serviceAccount:$SA_ID \
            --role $ROLE 2>&1 | grep -v "already has" | grep -v "уже имеет" || true
        sleep 1
    done
    
    echo ""
    echo "Проверяем добавленные роли:"
    yc resource-manager folder list-access-bindings $FOLDER_ID --format=json 2>/dev/null | \
      jq -r --arg sa "$SA_ID" '.accessBindings[] | select(.subject.id == $sa) | "  • \(.roleId)"' 2>/dev/null || \
      echo "  (не удалось получить список ролей)"
fi

# 6. Сборка и push приложения
echo ""
echo "=== СБОРКА И PUSH ПРИЛОЖЕНИЯ ==="
cd /home/ilya/cloud-platform-foundation/app

# Получаем registry ID
REGISTRY_ID=$(yc container registry list --format=json 2>/dev/null | jq -r '.[0].id' 2>/dev/null || echo "")

if [ -z "$REGISTRY_ID" ]; then
    # Или получаем из terraform state
    cd /home/ilya/cloud-platform-foundation/terraform/registry
    REGISTRY_ID=$(terraform output -raw registry_id 2>/dev/null || echo "")
fi

if [ -z "$REGISTRY_ID" ]; then
    echo "Не удалось получить Registry ID"
    echo "Пробуем продолжить без registry..."
else
    echo "Registry ID: $REGISTRY_ID"
    
    # Настраиваем Docker и собираем образ
    yc container registry configure-docker
    docker build -t cr.yandex/${REGISTRY_ID}/cloud-demo-app:1.0.0 .
    docker push cr.yandex/${REGISTRY_ID}/cloud-demo-app:1.0.0
fi

# 7. Настройка доступа к K8s
echo ""
echo "=== НАСТРОЙКА ДОСТУПА К KUBERNETES ==="
CLUSTER_ID=$(yc managed-kubernetes cluster list --format=json | jq -r '.[0].id' 2>/dev/null || echo "")

if [ ! -z "$CLUSTER_ID" ]; then
    echo "Настраиваем доступ к кластеру $CLUSTER_ID..."
    yc managed-kubernetes cluster get-credentials $CLUSTER_ID --external 2>/dev/null && echo "Kubeconfig настроен" || echo "Не удалось настроить доступ"
    
    # Проверяем доступ
    echo "Проверка доступа к кластеру..."
    kubectl cluster-info 2>/dev/null && echo "Доступ к кластеру работает" || echo "Проблемы с доступом к кластеру"
else
    echo "Не удалось получить ID кластера"
fi


echo ""
echo "ЭТАП <<< РАЗВЕРТЫВАНИЕ ИНФРАСТРУКТУРЫ >>> ЗАВЕРШЁН!"
echo "Теперь переходим к запуску Этапа <<< МОНИТОРИНГ И ДОСТУП >>>:"
echo ""


echo "=== <<< МОНИТОРИНГ И ДОСТУП >>> ==="

# ========================================
# Переменные окружения
# ========================================
YC_FOLDER_ID="b1grpedldfrumqsrjf62"
YC_CLOUD_ID="b1gpupamkrr85nd1d31m"
SERVICE_ACCOUNT_KEY_FILE="/home/ilya/service_account_key_file.json"

export YC_FOLDER_ID YC_CLOUD_ID SERVICE_ACCOUNT_KEY_FILE

# ========================================
# 0. НАЗНАЧЕНИЕ РОЛЕЙ ДЛЯ k8s-cluster
# ========================================
echo ""
echo "Проверка и назначение ролей для k8s-cluster..."

# Получаем ID существующего SA
K8S_CLUSTER_SA_ID=$(yc iam service-account get --name k8s-cluster --format=json 2>/dev/null | jq -r '.id' || echo "")

if [ -z "$K8S_CLUSTER_SA_ID" ]; then
    echo "Сервисный аккаунт k8s-cluster не найден! Роли назначать нельзя."
else
    echo "ID SA k8s-cluster: $K8S_CLUSTER_SA_ID"

    # Роли для LoadBalancer
    CLUSTER_ROLES=("load-balancer.admin" "vpc.publicAdmin")

    for ROLE in "${CLUSTER_ROLES[@]}"; do
        echo "  Добавляем роль: $ROLE"
        yc resource-manager folder add-access-binding "$YC_FOLDER_ID" \
            --subject serviceAccount:"$K8S_CLUSTER_SA_ID" \
            --role "$ROLE" 2>&1 | grep -v "already has" || true
        sleep 1
    done

    echo ""

fi

# --------------------------------
# 0.1 Получаем REGISTRY_ID динамически
# --------------------------------
# Автоматизируем процесс при каждом новом деплое
# находим новый REGISTRY_ID и подставляем его в файл deployment.yaml 
#
REGISTRY_ID=$(yc container registry list --format json | jq -r '.[0].id')

if [[ -z "$REGISTRY_ID" || "$REGISTRY_ID" == "null" ]]; then
  echo "REGISTRY_ID не найден. Проверьте Yandex Container Registry."
  exit 1
fi

echo "Найден REGISTRY_ID: $REGISTRY_ID"
echo ""
echo "Развертывание тестового приложения (с динамическим REGISTRY_ID)..."

DEPLOYMENT_FILE="../kubernetes-manifests/application/deployment.yaml"

# Перезаписываем deployment.yaml с REGISTRY_ID
cat > "$DEPLOYMENT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloud-demo-app
  labels:
    app: cloud-demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloud-demo-app
  template:
    metadata:
      labels:
        app: cloud-demo-app
    spec:
      containers:
        - name: nginx
          image: cr.yandex/${REGISTRY_ID}/cloud-demo-app:1.0.0
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "64Mi"
              cpu: "250m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /health
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
EOF

echo "deployment.yaml сгенерирован"

# ========================================
# 1. INGRESS CONTROLLER
# ========================================
echo ""
echo "Установка Ingress Controller для Managed K8s с нашей группой безопасности..."

# Создаем namespace
kubectl create namespace nginx-system 2>/dev/null || true

# Добавляем репозиторий
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

# ID нужной группы безопасности
SECURITY_GROUP_ID="enpdii2gt6cocqdb7eob"

# Устанавливаем Ingress Controller с LoadBalancer и нужной группой безопасности
echo "Установка с service.type=LoadBalancer и security group $SECURITY_GROUP_ID..."

helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace nginx-system \
  --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.replicaCount=3 \
    --set controller.admissionWebhooks.enabled=false \
    --wait

# Ждем выделения IP
# Динамическое получение имени сервиса Ingress
SVC_NAME=$(kubectl get svc -n nginx-system -l app.kubernetes.io/name=ingress-nginx \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$SVC_NAME" ]; then
    echo "Сервис Ingress не найден!"
    EXTERNAL_IP=""
else
    echo "Найден сервис Ingress: $SVC_NAME"

    # Ждем выделения внешнего IP
    EXTERNAL_IP=""
    for i in {1..20}; do
        EXTERNAL_IP=$(kubectl get svc -n nginx-system "$SVC_NAME" \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

        if [ -n "$EXTERNAL_IP" ]; then
            echo "Внешний IP получен: $EXTERNAL_IP"
            break
        fi
        echo "   Попытка $i/20..."
        sleep 10
    done

    if [ -z "$EXTERNAL_IP" ]; then
        echo "Внешний IP пока не готов. Продолжаем развертывание..."
    fi
fi

# Можно получить позже через: 
# kubectl get svc -n nginx-system

# ========================================
# 1.1 Автоматическое обновление /etc/hosts
# ========================================
if [ -n "$EXTERNAL_IP" ]; then
    echo "Обновляем /etc/hosts с IP: $EXTERNAL_IP"
    # Удаляем старые записи *.diploma.local
    sudo sed -i '/\.diploma\.local$/d' /etc/hosts 2>/dev/null || true
    # Добавляем новые записи
    echo "$EXTERNAL_IP app.diploma.local grafana.diploma.local prometheus.diploma.local" | sudo tee -a /etc/hosts
    echo "Hosts обновлен"
else
    echo "Внешний IP так и не получен. Обновите /etc/hosts вручную позже."
fi

# ========================================
# 2. ТЕСТОВОЕ ПРИЛОЖЕНИЕ
# ========================================
echo ""
echo "Развертывание тестового приложения..."

# Применяем манифесты
kubectl apply -f "$DEPLOYMENT_FILE"
kubectl apply -f ../kubernetes-manifests/application/service.yaml
kubectl apply -f ../kubernetes-manifests/application/ingress.yaml
# kubectl apply -f /home/ilya/cloud-platform-foundation/kubernetes-manifests/application/

# ========================================
# 3. СИСТЕМА МОНИТОРИНГА
# ========================================
echo ""
echo "Установка kube-prometheus-stack..."

kubectl create namespace monitoring 2>/dev/null || true

# Добавляем репозиторий prometheus-community (НЕ bitnami!)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# Устанавливаем stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword="admin123" \
  --set grafana.service.type=ClusterIP \
  --set prometheus.service.type=ClusterIP \
  --set alertmanager.service.type=ClusterIP \
  --wait

echo "kube-prometheus-stack установлен (не bitnami!)"

# ========================================
# 4. INGRESS ДЛЯ СЕРВИСОВ
# ========================================
echo ""
echo "Настройка Ingress правил..."

# Обновляем манифесты приложения (убираем устаревшую аннотацию)
cat > /tmp/app-ingress-fixed.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloud-demo-app-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: app.diploma.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cloud-demo-app-service
            port:
              number: 80
EOF

kubectl apply -f /tmp/app-ingress-fixed.yaml

# Ingress для Grafana
cat > /tmp/grafana-ingress-fixed.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
  - host: grafana.diploma.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-stack-grafana
            port:
              number: 80
EOF

kubectl apply -f /tmp/grafana-ingress-fixed.yaml

# Ingress для Prometheus
cat > /tmp/prometheus-ingress-fixed.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
  - host: prometheus.diploma.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-stack-prometheus
            port:
              number: 9090
EOF

kubectl apply -f /tmp/prometheus-ingress-fixed.yaml

echo "Ingress правила настроены (используется ingressClassName)"

# ========================================
# 5. НАСТРОЙКА ДОСТУПА
# ========================================
echo ""
echo "Настройка доступа..."

if [ -n "$EXTERNAL_IP" ]; then
    # Обновляем /etc/hosts
    echo "Обновление /etc/hosts с IP: $EXTERNAL_IP"
    sudo sed -i '/\.diploma\.local$/d' /etc/hosts 2>/dev/null || true
    echo "$EXTERNAL_IP app.diploma.local grafana.diploma.local prometheus.diploma.local atlantis.diploma.local" | sudo tee -a /etc/hosts
    echo "Hosts обновлен"
else
    echo "IP не получен. Обновите /etc/hosts позже вручную"
fi

# ========================================
# 6. ПРОВЕРКА
# ========================================
echo "Состояние подов и сервисов:"

# --- Ingress Controller ---
echo ""
echo "Ingress Controller (nginx-system namespace):"
kubectl get pods -n nginx-system
kubectl get svc -n nginx-system nginx-ingress-ingress-nginx-controller

# --- Приложение ---
echo ""
echo "Приложение (default namespace):"
kubectl get pods -l app=cloud-demo-app
kubectl get svc -l app=cloud-demo-app

# --- Мониторинг ---
echo ""
echo "Мониторинг (monitoring namespace):"
kubectl get pods -n monitoring | grep -E "(grafana|prometheus|alertmanager)"
kubectl get svc -n monitoring | grep -E "(grafana|prometheus|alertmanager)"

# --- Ingress ---
echo ""
echo "Ingress (все namespace):"
kubectl get ingress -A

# ====================
# ИНСТРУКЦИЯ
# ====================
echo ""
echo "==============================================="
echo " ЭТАП <<< МОНИТОРИНГ И ДОСТУП >>> ЗАВЕРШЕН"
echo "==============================================="
echo ""
echo " !!!! Что сделано !!!!:"
echo "   - Ingress Controller с service.type=LoadBalancer"
echo "   - Yandex Cloud автоматически создал Load Balancer"
echo "   - Тестовое приложение развернуто"
echo "   - kube-prometheus-stack установлен (НЕ bitnami)"
echo "   - Ingress правила через ingressClassName"
echo ""

if [ -n "$EXTERNAL_IP" ]; then
    echo ""
    echo "1. Доступ через Ingress:"
    echo "   Приложение:    curl -H 'Host: app.diploma.local' http://$EXTERNAL_IP"
    echo "   Grafana:       http://grafana.diploma.local"
    echo "   Prometheus:    http://prometheus.diploma.local"
    echo ""
    echo "   Логин Grafana: admin / admin123"
fi

echo ""
echo "2. Доступ через port-forward:"
echo "   kubectl port-forward svc/cloud-demo-app-service 8080:80"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:3000"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
echo "3. Проверка компонентов:"
echo "   kubectl get pods -A"
echo "   kubectl get svc -A"
echo "   kubectl get ingress -A"
echo ""
echo "4. Проверка Load Balancer в Yandex Cloud:"
echo "   yc load-balancer network-load-balancer list"
echo ""
echo " Ключевые моменты:"
echo "   - НЕ использовались helm-чарты bitnami"
echo "   - НЕ создавался Load Balancer вручную через yc"
echo "   - НЕ использовались NodePort для Ingress"
echo "   - Используется Managed Kubernetes подход"


echo "=========================================================="
echo "=== <<< INSTALL ATLANTIS >>> ==="
echo "=========================================================="

# ========================================
# CONFIG
# ========================================
NAMESPACE="atlantis"
RELEASE_NAME="atlantis"
HELM_REPO_NAME="runatlantis"
HELM_REPO_URL="https://runatlantis.github.io/helm-charts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALUES_FILE="$SCRIPT_DIR/atlantis-values.yaml"
INGRESS_FILE="$PROJECT_ROOT/kubernetes-manifests/atlantis/ingress.yaml"
NODEPORT_FILE="$PROJECT_ROOT/kubernetes-manifests/atlantis/service-nodeport.yaml"
BACKEND_SECRET="atlantis-backend-conf"
BACKEND_FILE="$PROJECT_ROOT/kubernetes-manifests/atlantis/backend.conf"

# ========================================
# CHECKS
# ========================================
echo "Проверка зависимостей..."
command -v kubectl >/dev/null 2>&1 || { echo "kubectl не найден"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm не найден"; exit 1; }
[ -z "$GITHUB_TOKEN" ] && { echo "Переменная GITHUB_TOKEN не задана"; exit 1; }

echo "Всё готово"

# ========================================
# NAMESPACE
# ========================================
echo "Создание namespace $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl get ns $NAMESPACE

# ========================================
# GITHUB SECRET
# ========================================
echo "Создание GitHub token secret"
kubectl -n $NAMESPACE delete secret atlantis-github-token --ignore-not-found
kubectl -n $NAMESPACE create secret generic atlantis-github-token --from-literal=token=$GITHUB_TOKEN
kubectl -n $NAMESPACE get secret atlantis-github-token

# ========================================
# BACKEND SECRET
# ========================================
echo "Создание секретов для backend.conf"
kubectl -n $NAMESPACE delete secret $BACKEND_SECRET --ignore-not-found
kubectl -n $NAMESPACE create secret generic $BACKEND_SECRET --from-file=backend.conf="$BACKEND_FILE"
kubectl -n $NAMESPACE get secret $BACKEND_SECRET

# ========================================
# HELM REPO
# ========================================
echo "Добавление Helm repo Atlantis"
helm repo add $HELM_REPO_NAME $HELM_REPO_URL || true
helm repo update

# ========================================
# VALUES.YAML
# ========================================
echo "Генерация $VALUES_FILE"
cat <<EOF > $VALUES_FILE
orgAllowlist: github.com/IlyaBridge/*

github:
  user: IlyaBridge
  token: ${GITHUB_TOKEN}
  secret: atlantis-webhook-secret-123

repoConfig: |
  repos:
    - id: /.*/
      workflow: terraform
  workflows:
    terraform:
      plan:
        steps:
          - init:
              extra_args:
                - "-backend-config=/atlantis-backend/backend.conf"
          - plan
      apply:
        steps:
          - apply

service:
  type: LoadBalancer

extraVolumes:
  - name: backend-conf
    secret:
      secretName: $BACKEND_SECRET

extraVolumeMounts:
  - name: backend-conf
    mountPath: /atlantis-backend
    readOnly: true
EOF

# ========================================
# INSTALL / UPGRADE HELM
# ========================================
echo "Установка Atlantis"
helm upgrade --install $RELEASE_NAME $HELM_REPO_NAME/atlantis \
  -n $NAMESPACE \
  -f $VALUES_FILE

# ========================================
# CHECK PODS
# ========================================
echo "Ожидание запуска Atlantis..."
kubectl rollout status statefulset/$RELEASE_NAME -n $NAMESPACE
kubectl get pods -n $NAMESPACE

# ========================================
# APPLY INGRESS & NODEPORT
# ========================================
echo "Применение Ingress и NodePort"
kubectl apply -f $INGRESS_FILE
kubectl apply -f $NODEPORT_FILE
kubectl get ingress -n $NAMESPACE
kubectl get svc -n $NAMESPACE

# ========================================
# LOGS
# ========================================
echo "Логи Atlantis (первые строки):"
kubectl logs -n $NAMESPACE -l app=atlantis --tail=20

# ========================================
# EXTERNAL IP & PORT
# ========================================
echo "Ожидание внешнего IP..."
EXTERNAL_IP=""
while [ -z "$EXTERNAL_IP" ]; do
  EXTERNAL_IP=$(kubectl get svc atlantis -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -z "$EXTERNAL_IP" ] && sleep 2
done
PORT=$(kubectl get svc atlantis -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}')
echo "Atlantis доступен по адресу: http://$EXTERNAL_IP:$PORT"

# ========================================
# Проверка монтирования backend.conf
# ========================================
echo "Проверяем наличие файла /atlantis-backend/backend.conf в контейнере..."
kubectl -n $NAMESPACE exec -it atlantis-0 -- test -f /atlantis-backend/backend.conf && echo "Файл backend.conf найден." || echo "Файл backend.conf НЕ найден."

# ========================================
# DONE
# ========================================
echo ""
echo "Atlantis полностью установлен и готов к работе!"
echo "URL через Ingress: http://atlantis.diploma.local"
