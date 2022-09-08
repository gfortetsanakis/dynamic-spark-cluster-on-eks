terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.5.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}

locals {
  eks_endpoint        = module.eks-cluster.eks_cluster_properties["eks_endpoint"]
  eks_cluster_ca_cert = base64decode(module.eks-cluster.eks_cluster_properties["eks_cluster_ca_cert"])
  eks_cluster_name    = module.eks-cluster.eks_cluster_properties["eks_cluster_name"]
}

provider "helm" {
  kubernetes {
    host                   = local.eks_endpoint
    cluster_ca_certificate = local.eks_cluster_ca_cert
    exec {
      api_version = "client.authentication.k8s.io/v1alpha1"
      args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = local.eks_endpoint
  cluster_ca_certificate = local.eks_cluster_ca_cert
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name]
    command     = "aws"
  }
}

provider "kubectl" {
  host                   = local.eks_endpoint
  cluster_ca_certificate = local.eks_cluster_ca_cert
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name]
    command     = "aws"
  }
}