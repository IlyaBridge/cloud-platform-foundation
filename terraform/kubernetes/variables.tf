variable "yandex_cloud_id" {
  type        = string
  description = "Yandex Cloud ID"
  sensitive   = true
}

variable "yandex_folder_id" {
  type        = string
  description = "Yandex Folder ID"
  sensitive   = true
}

variable "service_account_key_file" {
  type        = string
  description = "Path to service account key file"
  sensitive   = true
}

variable "zones" {
  type        = list(string)
  description = "Yandex Cloud zones"
  default     = ["ru-central1-a", "ru-central1-b"]
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes version"
  default     = "1.30"  # Актуальная версия
}

variable "s3_access_key" {
  type        = string
  description = "S3 access key for remote state"
  sensitive   = true
  default     = ""
}

variable "s3_secret_key" {
  type        = string
  description = "S3 secret key for remote state"
  sensitive   = true
  default     = ""
}