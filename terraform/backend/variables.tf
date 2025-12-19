# /terraform/backend/variables.tf
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