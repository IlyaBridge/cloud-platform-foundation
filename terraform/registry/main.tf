# /terraform/registry/main.tf
provider "yandex" {
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.yandex_cloud_id
  folder_id                = var.yandex_folder_id
  zone                     = "ru-central1-a"
}

# Yandex Container Registry
resource "yandex_container_registry" "diploma_registry" {
  name = "diploma-registry"
  
  # Добавляем labels для публичного доступа
  labels = {
    environment = "diploma"
  }
}

# IAM binding для сервисного аккаунта Kubernetes нод (pull)
resource "yandex_container_registry_iam_binding" "puller" {
  registry_id = yandex_container_registry.diploma_registry.id
  role        = "container-registry.images.puller"
  
  members = [
    "serviceAccount:${var.k8s_nodes_service_account_id}"
  ]
}

# IAM binding для push прав (для CI/CD)
resource "yandex_container_registry_iam_binding" "pusher" {
  registry_id = yandex_container_registry.diploma_registry.id
  role        = "container-registry.images.pusher"
  
  members = [
    "serviceAccount:${var.k8s_nodes_service_account_id}"
  ]
}

# Добавляем правило для публичного pull - разрешаем pull всем аутентифицированным пользователям
resource "yandex_container_registry_iam_binding" "public_puller" {
  registry_id = yandex_container_registry.diploma_registry.id
  role        = "container-registry.images.puller"
  
  members = [
    "system:allAuthenticatedUsers"  # Все аутентифицированные пользователи Yandex Cloud
  ]
}

output "registry_id" {
  value = yandex_container_registry.diploma_registry.id
}

output "registry_name" {
  value = yandex_container_registry.diploma_registry.name
}