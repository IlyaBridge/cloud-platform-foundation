# terraform/infrastructure/variables.tf
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

variable "network_cidr" {
  type        = string
  description = "Network CIDR"
  default     = "10.0.0.0/16"
}

# ============================
variable "s3_access_key" {
  type        = string
  description = "S3 Access Key"
  default     = ""
}

variable "s3_secret_key" {
  type        = string
  description = "S3 Secret Key"
  sensitive   = true
  default     = ""
}
# ============================