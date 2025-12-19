# /terraform/backend/main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.100.0"
    }
  }
}

provider "yandex" {
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.yandex_cloud_id
  folder_id                = var.yandex_folder_id
  zone                     = "ru-central1-a"
}

# Получаем ID сервисного аккаунта из файла ключа
data "yandex_iam_service_account" "existing" {
  service_account_id = jsondecode(file(var.service_account_key_file)).service_account_id
}

# Создаем статический ключ доступа для существующего сервисного аккаунта
resource "yandex_iam_service_account_static_access_key" "sa-key" {
  service_account_id = data.yandex_iam_service_account.existing.id
  description        = "Static access key for Terraform state"
}

# S3 бакет для хранения Terraform state
resource "yandex_storage_bucket" "terraform_state" {
  bucket = "diploma-terraform-state-ilya"

  # Используем статический ключ для аутентификации
  access_key = yandex_iam_service_account_static_access_key.sa-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-key.secret_key

  versioning {
    enabled = true
  }
}

output "s3_bucket_name" {
  value = yandex_storage_bucket.terraform_state.bucket
}

output "access_key" {
  value     = yandex_iam_service_account_static_access_key.sa-key.access_key
  sensitive = true
}

output "secret_key" {
  value     = yandex_iam_service_account_static_access_key.sa-key.secret_key
  sensitive = true
}