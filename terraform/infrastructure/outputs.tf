# terraform/infrastructure/outputs.tf
output "network_id" {
  value = yandex_vpc_network.network.id
}

output "public_subnet_ids" {
  value = yandex_vpc_subnet.public[*].id
}

output "private_subnet_ids" {
  value = yandex_vpc_subnet.private[*].id
}

output "k8s_security_group_id" {
  value = yandex_vpc_security_group.k8s.id
}

output "zones" {
  value = var.zones
}