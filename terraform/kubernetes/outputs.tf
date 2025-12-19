# /terraform/kubernetes/outputs.tf

# Полный kubeconfig для доступа к кластеру
output "kubeconfig" {
  value = <<EOT
apiVersion: v1
clusters:
- cluster:
    server: ${yandex_kubernetes_cluster.k8s_cluster.master[0].external_v4_endpoint}
    certificate-authority-data: ${yandex_kubernetes_cluster.k8s_cluster.master[0].cluster_ca_certificate}
  name: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
contexts:
- context:
    cluster: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
    user: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
  name: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
current-context: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
kind: Config
users:
- name: yc-${yandex_kubernetes_cluster.k8s_cluster.name}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: yc
      args:
      - k8s
      - create-token
      - --folder-id=${var.yandex_folder_id}
      - --cluster-id=${yandex_kubernetes_cluster.k8s_cluster.id}
EOT
  sensitive = true
}

output "cluster_id" {
  value = yandex_kubernetes_cluster.k8s_cluster.id
}

output "cluster_external_endpoint" {
  value = yandex_kubernetes_cluster.k8s_cluster.master[0].external_v4_endpoint
}

# Дополнительные outputs для диагностики
output "network_id" {
  value = data.terraform_remote_state.infra.outputs.network_id
}

output "node_group_status" {
  value = yandex_kubernetes_node_group.k8s_nodes.status
}
# === ID ===
# ID сервисного аккаунта для нод Kubernetes
output "k8s_nodes_service_account_id" {
  value = yandex_iam_service_account.k8s-nodes.id
  description = "Service account ID for Kubernetes nodes"
}

# ID сервисного аккаунта для кластера Kubernetes
output "k8s_cluster_service_account_id" {
  value = yandex_iam_service_account.k8s.id
  description = "Service account ID for Kubernetes cluster"
}

# Имена сервисных аккаунтов для проверки
output "k8s_nodes_service_account_name" {
  value = yandex_iam_service_account.k8s-nodes.name
}

output "k8s_cluster_service_account_name" {
  value = yandex_iam_service_account.k8s.name
}