# /terraform/registry/backend.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.100.0"
    }
  }

  backend "s3" {
    # Конфигурация в отдельном файле backend.conf
  }
}