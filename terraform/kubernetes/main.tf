provider "yandex" {
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.yandex_cloud_id
  folder_id                = var.yandex_folder_id
  zone                     = "ru-central1-a"
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  
  config = {
    bucket = "diploma-terraform-state-ilya"
    key    = "infrastructure/terraform.tfstate"
    region = "ru-central1"

    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }

    access_key = var.s3_access_key
    secret_key = var.s3_secret_key

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}

# Managed Kubernetes кластер
resource "yandex_kubernetes_cluster" "k8s_cluster" {
  name        = "diploma-k8s-cluster"
  description = "Kubernetes cluster for diploma project"

  network_id = data.terraform_remote_state.infra.outputs.network_id

  master {
    zonal {
      zone      = var.zones[0]
      subnet_id = data.terraform_remote_state.infra.outputs.private_subnet_ids[0]
    }

    version   = var.k8s_version
    public_ip = true

    security_group_ids = [
      data.terraform_remote_state.infra.outputs.k8s_security_group_id
    ]
  }

  service_account_id      = yandex_iam_service_account.k8s.id
  node_service_account_id = yandex_iam_service_account.k8s-nodes.id

  depends_on = [
    yandex_resourcemanager_folder_iam_member.k8s-cluster-agent,
    yandex_resourcemanager_folder_iam_member.vpc-public-admin,
    yandex_resourcemanager_folder_iam_member.images-puller
  ]
}

# Node Group с External IP
resource "yandex_kubernetes_node_group" "k8s_nodes" {
  cluster_id = yandex_kubernetes_cluster.k8s_cluster.id
  name       = "diploma-nodes"

  instance_template {
    platform_id = "standard-v3"

    resources {
      memory = 4
      cores  = 2
    }

    boot_disk {
      type = "network-hdd"
      size = 32
    }

    scheduling_policy {
      preemptible = true
    }

    network_interface {
      subnet_ids = data.terraform_remote_state.infra.outputs.private_subnet_ids
      nat        = true
      security_group_ids = [
        data.terraform_remote_state.infra.outputs.k8s_security_group_id
      ]
    }

    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    location {
      zone = var.zones[0]
    }
    location {
      zone = var.zones[1]
    }
  }
}

# Сервисный аккаунт для кластера
resource "yandex_iam_service_account" "k8s" {
  name        = "k8s-cluster"
  description = "Service account for Kubernetes cluster"
}

# Сервисный аккаунт для нод
resource "yandex_iam_service_account" "k8s-nodes" {
  name        = "k8s-nodes"
  description = "Service account for Kubernetes nodes"
}

# Роли для сервисных аккаунтов
resource "yandex_resourcemanager_folder_iam_member" "k8s-cluster-agent" {
  folder_id = var.yandex_folder_id
  role      = "k8s.clusters.agent"
  member    = "serviceAccount:${yandex_iam_service_account.k8s.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "vpc-public-admin" {
  folder_id = var.yandex_folder_id
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "images-puller" {
  folder_id = var.yandex_folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-nodes.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-nodes" {
  folder_id = var.yandex_folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-nodes.id}"
}
