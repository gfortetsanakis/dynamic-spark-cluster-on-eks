output "spark_history_server_url" {
  value = module.spark-operator.spark_history_server_url
}

output "jupyterhub_server_url" {
  value = module.jupyterhub.jupyterhub_server_url
}

output "prometheus_url" {
  value = module.kube-prometheus-stack.prometheus_url
}

output "grafana_url" {
  value = module.kube-prometheus-stack.grafana_url
}

output "alert_manager_url" {
  value = module.kube-prometheus-stack.alert_manager_url
}