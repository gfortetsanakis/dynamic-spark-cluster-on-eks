variable "aws_region" {
  description = "The aws region in which the infrastructure will be set up."
  default     = "eu-north-1"
}

variable "openvpn_client_cidrs" {
  description = "List of CIDR blocks that are allowed to connect to the OpenVPN server."
}

variable "openvpn_key_path" {
  description = "The path to the public ssh key file for the OpenVPN server."
}

variable "openvpn_instance_type" {
  description = "The instance type used for the openVPN server."
  default     = "t3.micro"
}

variable "openvpn_user" {
  description = "The name of the first OpenVPN user to be created during the server installation."
}

variable "nat_instance_key_path" {
  description = "The path to the public ssh key file for the NAT instance."
}

variable "nat_instance_type" {
  description = "The instance type used for the NAT instance."
  default     = "t3.micro"
}

variable "eks_worker_nodes_key_path" {
  description = "The path to the public ssh key file for the EKS worker nodes."
}

variable "kubernetes_addons_namespace" {
  description = "The namespace on which kubernetes components are installed."
  default     = "addons"
}

variable "domain" {
  description = "The domain of the Route53 private hosted zone that will be created for the EKS cluster."
}

variable "cluster_issuer_cert_path" {
  description = "The path to the file containing the certificate of the ClusterIssuer certificate authority."
}

variable "cluster_issuer_key_path" {
  description = "The path to the file containing the private key of the ClusterIssuer certificate authority."
}

variable "history_server_spark_image" {
  description = "The spark image used for deploying the spark history server."
}

variable "jupyter_notebook_image" {
  description = "The jupyter notebook image."
}

variable "docker_registry_server" {
  description = "The docker registry hosting the docker images for spark and jupyter notebook."
}

variable "docker_registry_username" {
  description = "The docker registry username."
}

variable "docker_registry_password" {
  description = "The docker registry password."
}

variable "docker_registry_email" {
  description = "The docker registry email account."
}

variable "grafana_admin_password" {
  description = "The admin password for grafana."
}