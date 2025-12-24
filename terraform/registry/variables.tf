# /terraform/registry/variables.tf
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

variable "k8s_nodes_service_account_id" {
  type        = string
  description = "Kubernetes nodes service account ID"
  sensitive   = true
}
# Test