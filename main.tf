data "aws_availability_zones" "available" {}

module "custom-vpc" {
  source          = "gfortetsanakis/custom-vpc/aws"
  version         = "1.0.2"
  vpc_cidr        = local.vpc_cidr
  aws_region      = var.aws_region
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}

module "openvpn-server" {
  source                = "gfortetsanakis/openvpn-server/aws"
  version               = "1.0.2"
  aws_region            = var.aws_region
  vpc_id                = module.custom-vpc.vpc_id
  openvpn_key_path      = var.openvpn_key_path
  openvpn_instance_type = var.openvpn_instance_type
  openvpn_client_ips    = var.openvpn_client_ips
  openvpn_subnet_id     = module.custom-vpc.public_subnet_ids[0]
  openvpn_user          = var.openvpn_user
  openvpn_protocol      = "tcp"

  depends_on = [module.custom-vpc]
}

module "nat-instance" {
  source                      = "gfortetsanakis/nat-instance/aws"
  version                     = "1.0.4"
  vpc_id                      = module.custom-vpc.vpc_id
  vpc_private_subnet_cidrs    = local.private_subnets.*.cidr_block
  vpc_private_route_table_id  = module.custom-vpc.private_route_table_id
  nat_instance_subnet_id      = module.custom-vpc.public_subnet_ids[0]
  nat_instance_key_path       = var.nat_instance_key_path
  nat_instance_type           = var.nat_instance_type
  ssh_allowed_security_groups = [module.openvpn-server.openvpn_sg_id]

  depends_on = [module.custom-vpc]
}

module "s3-bucket" {
  for_each    = local.s3_buckets
  source      = "gfortetsanakis/s3-bucket/aws"
  version     = "1.0.4"
  bucket_tag  = each.key
  bucket_name = each.value
}

module "eks-cluster" {
  source                         = "gfortetsanakis/eks-cluster/aws"
  version                        = "1.0.4"
  subnet_ids                     = module.custom-vpc.private_subnet_ids
  eks_worker_nodes_key_path      = var.eks_worker_nodes_key_path
  eks_node_groups                = local.eks_node_groups
  ssh_allowed_security_groups    = [module.openvpn-server.openvpn_sg_id]
  kubectl_allowed_security_group = module.openvpn-server.openvpn_sg_id

  depends_on = [module.nat-instance, module.openvpn-server, module.s3-bucket]
}

module "eks-autoscaler" {
  source                 = "gfortetsanakis/eks-autoscaler/helm"
  version                = "1.0.1"
  namespace              = var.kubernetes_addons_namespace
  eks_cluster_properties = module.eks-cluster.eks_cluster_properties
  node_selector          = local.on_demand_node_selector

  depends_on = [module.eks-cluster]
}

module "external-dns" {
  source                 = "gfortetsanakis/external-dns/helm"
  version                = "1.0.4"
  namespace              = var.kubernetes_addons_namespace
  eks_cluster_properties = module.eks-cluster.eks_cluster_properties
  domain                 = var.domain
  node_selector          = local.on_demand_node_selector

  depends_on = [module.eks-cluster]
}

module "ingress-nginx" {
  source        = "gfortetsanakis/ingress-nginx/helm"
  version       = "1.0.1"
  namespace     = var.kubernetes_addons_namespace
  node_selector = local.on_demand_node_selector

  depends_on = [module.external-dns]
}

module "cert-manager" {
  source        = "gfortetsanakis/cert-manager/helm"
  version       = "1.0.1"
  namespace     = var.kubernetes_addons_namespace
  ca_key        = var.cluster_issuer_key_path
  ca_crt        = var.cluster_issuer_cert_path
  node_selector = local.on_demand_node_selector

  depends_on = [module.ingress-nginx]
}

module "spark-operator" {
  source                     = "gfortetsanakis/spark-operator/helm"
  version                    = "1.0.6"
  namespace                  = var.kubernetes_addons_namespace
  eks_cluster_properties     = module.eks-cluster.eks_cluster_properties
  domain                     = var.domain
  certificate_issuer         = module.cert-manager.cluster_issuer
  history_server_spark_image = var.history_server_spark_image
  spark_data_bucket_name     = module.s3-bucket["spark_data"].bucket_name
  spark_logs_bucket_name     = module.s3-bucket["spark_logs"].bucket_name
  node_selector              = local.on_demand_node_selector

  depends_on = [module.cert-manager]
}

module "aws-efs-csi-driver" {
  source                 = "gfortetsanakis/efs-csi-driver/helm"
  version                = "1.0.3"
  namespace              = var.kubernetes_addons_namespace
  eks_cluster_properties = module.eks-cluster.eks_cluster_properties
  node_selector          = local.on_demand_node_selector

  depends_on = [module.cert-manager]
}

module "jupyterhub" {
  source                  = "gfortetsanakis/jupyter-hub/helm"
  version                 = "1.0.3"
  namespace               = module.spark-operator.spark_namespace
  domain                  = var.domain
  certificate_issuer      = module.cert-manager.cluster_issuer
  storage_class           = module.aws-efs-csi-driver.efs_storage_class
  jupyter_service_account = module.spark-operator.spark_service_account
  jupyter_notebook_image  = var.jupyter_notebook_image
  docker_registry_secret  = local.docker_registry_secret
  node_selector           = local.on_demand_node_selector

  depends_on = [module.aws-efs-csi-driver, module.spark-operator]
}

module "kube-prometheus-stack" {
  source                 = "gfortetsanakis/kube-prometheus-stack/helm"
  version                = "1.0.1"
  namespace              = var.kubernetes_addons_namespace
  domain                 = var.domain
  certificate_issuer     = module.cert-manager.cluster_issuer
  storage_class          = module.aws-efs-csi-driver.efs_storage_class
  grafana_admin_password = var.grafana_admin_password
  node_selector          = local.on_demand_node_selector

  depends_on = [module.aws-efs-csi-driver]
}