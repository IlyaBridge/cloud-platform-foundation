provider "yandex" {
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.yandex_cloud_id
  folder_id                = var.yandex_folder_id
  zone                     = "ru-central1-a"
}

# VPC сеть
resource "yandex_vpc_network" "network" {
  name = "main-network"
}

# Публичные подсети в 2 зонах
resource "yandex_vpc_subnet" "public" {
  count = length(var.zones)

  name           = "public-${var.zones[count.index]}"
  zone           = var.zones[count.index]
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [cidrsubnet(var.network_cidr, 8, count.index + 10)]
}

# Приватные подсети в 2 зонах
resource "yandex_vpc_subnet" "private" {
  count = length(var.zones)

  name           = "private-${var.zones[count.index]}"
  zone           = var.zones[count.index]
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [cidrsubnet(var.network_cidr, 8, count.index + 20)]
  route_table_id = yandex_vpc_route_table.private_rt.id
}

# NAT Gateway для приватных подсетей
resource "yandex_vpc_gateway" "nat_gateway" {
  name = "nat-gateway"
  shared_egress_gateway {}
}

# Таблица маршрутизации для приватных подсетей
resource "yandex_vpc_route_table" "private_rt" {
  name       = "private-route-table"
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# Security Group для Kubernetes
resource "yandex_vpc_security_group" "k8s" {
  name       = "k8s-security-group"
  network_id = yandex_vpc_network.network.id

  # 1. Полный трафик между компонентами кластера
  ingress {
    protocol       = "ANY"
    description    = "Allow all traffic between cluster components"
    v4_cidr_blocks = [var.network_cidr]
    from_port      = 0
    to_port        = 65535
  }

  # 2. Внутренний трафик VPC (Ingress → Pods)
  ingress {
    protocol       = "ANY"
    description    = "Allow internal VPC traffic (critical for Ingress)"
    v4_cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
    from_port      = 0
    to_port        = 65535
  }

  # 3. Load Balancer health checks
  ingress {
    protocol       = "TCP"
    description    = "Load Balancer health checks"
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
    port           = 10256
  }

  # 4. Kubernetes API
  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 6443
  }

  # 5. HTTPS
  ingress {
    protocol       = "TCP"
    description    = "HTTPS"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  # 6. HTTP
  ingress {
    protocol       = "TCP"
    description    = "HTTP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  # 7. Kubelet API
  ingress {
    protocol       = "TCP"
    description    = "Kubelet API"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 10250
  }

  # 8. NodePort services
  ingress {
    protocol       = "TCP"
    description    = "NodePort services"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 30000
    to_port        = 32767
  }

  # Разрешить весь исходящий трафик
  egress {
    protocol       = "ANY"
    description    = "Allow all outbound traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
