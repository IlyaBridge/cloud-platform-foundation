#!/bin/bash
set -euo pipefail

# ==========================================
# Настройка namespace
# ==========================================
echo "Создаем namespace atlantis..."
kubectl create namespace atlantis --dry-run=client -o yaml | kubectl apply -f -

# ==========================================
# Создание секрета с backend.conf
# ==========================================
echo "Создаем секрет atlantis-backend-conf..."
kubectl -n atlantis delete secret atlantis-backend-conf --ignore-not-found
kubectl -n atlantis create secret generic atlantis-backend-conf \
  --from-file=backend.conf=kubernetes-manifests/atlantis/backend.conf

# ==========================================
# Обновление Helm репозитория
# ==========================================
echo "Обновляем Helm репозиторий..."
helm repo add runatlantis https://runatlantis.github.io/helm-charts || true
helm repo update

# ==========================================
# Установка или апгрейд Atlantis
# ==========================================
echo "Устанавливаем или апгрейдим Atlantis..."
helm upgrade --install atlantis runatlantis/atlantis \
  -n atlantis \
  -f kubernetes-manifests/atlantis/atlantis-values.yaml

# ==========================================
# Проверка rollout
# ==========================================
echo "Ждем пока Atlantis развернется..."
kubectl -n atlantis rollout status statefulset/atlantis

# ==========================================
# Проверка монтирования backend.conf
# ==========================================
echo "Проверяем наличие /atlantis-backend/backend.conf..."
kubectl -n atlantis exec -it atlantis-0 -- ls -l /atlantis-backend

echo "Скрипт выполнен успешно! Atlantis готов к работе."
