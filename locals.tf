locals {
  vpc_cidr = "10.0.0.0/16"
  az_names = data.aws_availability_zones.available.names

  public_subnets = [
    {
      cidr_block        = cidrsubnet(local.vpc_cidr, 8, 10)
      availability_zone = local.az_names[0]
    }
  ]

  private_subnets = [
    {
      cidr_block        = cidrsubnet(local.vpc_cidr, 8, 1)
      availability_zone = local.az_names[0]
    },
    {
      cidr_block        = cidrsubnet(local.vpc_cidr, 8, 2)
      availability_zone = local.az_names[1]
    },
    {
      cidr_block        = cidrsubnet(local.vpc_cidr, 8, 3)
      availability_zone = local.az_names[2]
    }
  ]

  eks_node_groups = {
    on_demand_group = {
      min_size       = 3
      desired_size   = 3
      max_size       = 6
      instance_types = ["t3.medium"]
      disk_size      = 20
      capacity_type  = "ON_DEMAND"
    }
    spot_group = {
      min_size       = 0
      desired_size   = 0
      max_size       = 5
      instance_types = ["t3.medium"]
      disk_size      = 10
      capacity_type  = "SPOT"
    }
  }

  s3_buckets = {
    spark_logs = "example-spark-events-logs-bucket"
    spark_data = "example-spark-data-bucket"
  }

  on_demand_node_selector = {
    "eks.amazonaws.com/nodegroup" = "on_demand_group"
  }

  spot_node_selector = {
    "eks.amazonaws.com/nodegroup" = "spot_group"
  }

  docker_registry_secret = {
    server   = var.docker_registry_server
    username = var.docker_registry_username
    password = var.docker_registry_password
    email    = var.docker_registry_email
  }
}