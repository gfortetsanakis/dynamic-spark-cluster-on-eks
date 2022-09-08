# A dynamic Big Data processing environment on EKS based on Spark

This project implements a dynamic big data processing environment on the AWS cloud based on apache spark. In this environment, large volumes of data stored on S3 buckets can be processed by spark applications executed on a fleet of EC2 spot instances. These instances are created dynamically when needed and are managed by an EKS kubernetes cluster. Administration of computational resources in the cluster is completely dynamic. When there is a need of cpu and memory for scheduling applications, new instances are launched, while when these instances remain idle for a certain amount of time, they are automatically terminated by the EKS cluster. This approach ensures that resources are always available when needed while at the same time minimizing the overall computational costs. 

This solution has been based on various open-source technologies and tools, including, external DNS for publishing DNS records on a managed Route53 domain, ingress nginx for routing https traffic in the kubernetes infrastructure, certificate manager for automatically issuing certificates for services and applications deployed on EKS, and kube prometheus stack for implementing monitoring and alerting mechanisms. All individual components have been implemented using Terraform modules, while the entire infrastructure can be deployed by executing the Terraform script provided in this repository. The following sections describe the architecture of the proposed solution and the various components in more detail. 

## Networking

![](C:\Users\gfort\OneDrive\Εικόνες\network_architecture_1.png)

The entire solution is implemented on a custom VPC in AWS. This VPC is composed of one public subnet and three private subnets, each deployed on a different availability zone (AZ). For security reasons, the EKS cluster is installed on the private subnets and is not accessible from the public Internet. Users can only access the cluster by connecting to an OpenVPN server deployed on the public subnet of the infrastructure. Additionally, for being able to install packages and updates on the nodes of the cluster, a NAT instance is also deployed. 

#### OpenVPN server

The OpenVPN server is installed on an Amazon Linux 2 EC2 instance and can support connections with either the "tcp" or the "udp" protocol. An Elastic IP address is assigned to the instance, such that, the address of the server would not change in case of restarts or maintenance.  For strengthening the security of the infrastructure, the  security group of the OpenVPN server can be customized to allow connections from specific source CIDR blocks.  

When a client authenticates and connects to the OpenVPN server, he gains access to the VPC private network. Specifically, he can connect to the various services and infrastructure components deployed within the VPC using their private IP addresses. Additionally, he can translate DNS records by querying a Route53 private hosted zone deployed within the VPC (see [External DNS](#external-dns)). That way he can access services like the Kubernetes API of the EKS cluster.

#### NAT instance

The EC2 instances deployed in the private subnets of the infrastructure will need to access the Internet for downloading packages and security updates. To allow this while keeping the EKS cluster not publicly accessible and secure, a NAT instance is deployed in the public subnet of the infrastructure. The routing tables of the private subnets are modified to route all Internet traffic via this NAT instance. 

#### VPC gateway endpoint

Another important networking aspect of the infrastructure is the routing of S3 traffic. For reducing the overall networking costs, a VPC private gateway endpoint is deployed for connecting to the Amazon S3 service. Appropriate entries are added in the routing tables of all private subnets for routing S3-related traffic through this gateway. This will significantly reduce the networking costs when reading and writing data to S3 buckets during the execution of spark applications.

#### High availability considerations

![](C:\Users\gfort\OneDrive\Εικόνες\network_architecture_2.png)

The network infrastructure described in the previous paragraphs is more suitable for a development or testing environment given that there is only one OpenVPN server instance and one NAT instance. An alternative architecture that would be more suitable for a production environment would consist of three public subnets, each deployed on a different AZ. On each public subnet, a separate OpenVPN server and NAT instance would be deployed. Each private subnet would then forward traffic to the NAT instance deployed within its own AZ. Additionally, a network load balancer would be deployed in front of all OpenVPN server instances. That way, the infrastructure would be able to withstand the loss of up to two availability zones within the AWS region in which the infrastructure is deployed.  For the sake of simplicity and for reducing costs, in this project, we will adopt the simple approach with one public subnet.

## EKS cluster

The EKS cluster hosting the infrastructure is deployed on the three private subnets of the custom VPC described in the previous section. Worker nodes of the cluster are evenly distributed  among these subnets. 

#### IAM permissions

For the proper functioning of the cluster components, two IAM roles are created, one for the controlplane and one for the worker nodes. The AWS managed "AmazonEKSClusterPolicy" is attached to the controlplane role assigning all necessary permissions for managing the EKS cluster. Similarly, the "AmazonEKSWorkerNodePolicy", the "AmazonEKS_CNI_Policy", and the "AmazonEC2ContainerRegistryReadOnly" are assigned to the worker node role providing appropriate access rights to worker node ec2 instances, network interfaces, and elastic container registry for downloading docker images.  

#### Cluster nodegroups

The worker nodes of the cluster are divided into two distinct node groups, the "on_demand_group" and the "spot_group". The "on_demand_group" consists of a set of on demand EC2 instances that are dedicated for hosting the fixed part of the infrastructure. In this part, all critical kubernetes services are deployed (e.g., external dns, ingress nginx, certificate manager, prometheus and grafana). These services should always run uninterrupted for the cluster to function properly, and therefore, they should be deployed on on demand instances that are more reliable. On the other hand, the "spot_group" is dedicated for hosting the spark applications. Given these  applications are relatively short lived and can withstand failures, spot instances are ideal for their deployment due to their low cost.

For being able to dynamically adjust the size of the above node groups based on varying levels of demand for resources, the EKS cluster creates two autoscaling groups (ASGs),  one for on demand instances and one for the spot instances. When additional resources are required for deploying new pods, the EKS cluster autoscaler triggers a scale up event on the corresponding autoscaling group for launching additional instances to match the demand, while when the resources remain idle, it triggers a scale down event terminating unneeded instances (see [EKS cluster autoscaler](#eks-cluster-autoscaler)).

The parameters of the EKS cluster node groups are provided in the following input map variable:

```
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
      disk_size      = 20
      capacity_type  = "SPOT"
    }
  }
```

This variable defines, the min, desired, and max size of each node group along with the respective instance type and EBS disk capacity in GBs. Please note that the desired and min size for the spot group has been set equal to 0. This is because initially there are no spot instances in the cluster. They are only created when spark applications are submitted to the cluster. 

#### OpenID connect provider

In applications deployed on the EKS cluster, it is often necessary to provide access to various AWS services. For example, spark applications should have read and write access to the S3 buckets on which data reside. This can be performed by attaching appropriate IAM roles to the kubernetes service accounts that are assigned to application pods. For being able to do this, an OpenID connect provider should first be installed on the EKS cluster. The Terraform module which deploys the cluster, automatically creates the OpenID connect provider.

## Kubernetes components

For the kubernetes cluster to be fully functional, several additional components should be installed over EKS. In this project, the installation of such components is performed using the helm provider of Terraform. All those components are installed in a separate kubernetes namespace named "addons".

#### EKS cluster autoscaler

The EKS cluster autoscaler is responsible for continuously monitoring the available computing resources in the cluster and the current demand placed by deployed applications. In case the demand exceeds the available computing capacity, it scales up the appropriate EKS node group(s) by launching additional EC2 instances. Specifically, each time, it  takes into consideration the total requested resources in cpu and memory placed by all pods currently in pending state. Then, it launches the minimum required number of EC2 instances that will result in those pods to be scheduled. On the other hand, if there is a low demand in the cluster resulting in several EC2 instances to be underutilized for a certain amount of time (default 10 minutes), it terminates those instances. That way, the scheduling of computing resources is completely dynamic and is adjusted appropriately to match the current levels of demand in the cluster.

For being able to change the size of the autoscaling groups, the EKS autoscaler is assigned with an appropriate IAM role. This role provides the required permissions for reading and modifying autoscaling groups. Additionally, for being able to determine which autoscaling group to adjust each time, appropriate tags have been added to the groups during the creation of the eks cluster:  

| ASG                 | Tag                                                                       | Value           |
| ------------------- | ------------------------------------------------------------------------- | --------------- |
| On demand instances | k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/nodegroup | on_demand_group |
| Spot instances      | k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/nodegroup | spot_group      |

 When deploying a new application on the cluster, a nodeSelector property is set: "eks.amazonaws.com/nodegroup=on_demand_group" for applications deployed on on demand instances and "eks.amazonaws.com/nodegroup=spot_group" for applications deployed on spot instances (i.e., spark applications). Based on this nodeSelector property, the EKS autoscaler knows which autoscaling group to adjust each time. 

#### EFS CSI driver

Given that the EKS cluster is deployed over multiple AZs, the most appropriate storage system for creating persistent volumes would be EFS. In contrast to EBS volumes which are bound to a specific AZ, EFS volumes can be attached to pods that reside in different AZs. For example, in case of an AZ failure, pods can be rescheduled to worker nodes in other AZs and the corresponding EFS volumes can be reattached to them. On the other hand, for EBS volumes to be available to different AZs, EBS snapshots of the volumes should be created regularly in other AZs making such a solution more complex and less resilient to failures. 

For being able to create EFS persistent volumes on the EKS cluster, an EFS CSI driver should be installed. The Terraform module of the driver first creates a new EFS file system to be used by the cluster. Then, an EFS mount point is created at all subnets of the cluster. Through these mount points, the EFS file system will be accessible by the EKS worker nodes. Additionally, appropriate service accounts are created for the efs csi driver controller and the efs csi driver node pods, respectively. These service accounts are assigned with an IAM role for being able to create an EFS access point to be used by the EKS cluster. For strengthening security, a security group is defined for the EFS CSI driver allowing access to the EFS file system only to the EKS cluster worker nodes. Finally, a new storage class is created in the EKS cluster that can be used to request persistent volume claims from EFS. 

#### External DNS

For being able to assign DNS hostnames to services that are deployed in the EKS cluster, a Route53 private hosted zone is created within the cluster VPC. Kubernetes services that should be accessible from outside the cluster (e.g., component UIs) are assigned a DNS hostname. The component that is responsible to create DNS records in Route53 for newly deployed services is external DNS. This service monitors the cluster at regular time intervals and when a new ingress is created (see [Ingress nginx](#ingress-nginx)), it publishes a corresponding DNS record in Route53. Similarly, when an ingress is deleted from the cluster, the external dns deletes the corresponding DNS record from Route53. For being able to add and delete DNS records, the service account of external dns is assigned with an IAM role that provides permissions to modify Route53 records. 

After the DNS record corresponding to a new service (e.g., a UI) is published in Route53, users will be able to access the service from their browser using the corresponding DNS hostname. 

#### Ingress nginx

The routing of https traffic within the EKS cluster is performed using an nginx ingress controller. When the ingress controller is deployed, a corresponding classic load balancer is created in AWS. This load balancer is responsible to route https request to the appropriate services within the cluster, based on the requested hostname and path. For each new service that should be exposed via https from the EKS cluster, a new ingress rule is created defining the correspond hostname and path. An example of  such an ingress rule corresponding to the spark history server UI is the following:

```

```

Based on the above rule, when the nginx ingress controller receives an https request on the hostname "spark.<Route53_domain>", it forwards the request to the spark history server service. All https services (e.g., component UIs) in the EKS cluster are exposed in a similar manner. For being able to forward requests to pods that are deployed in different AZs, cross zone load balancing is enabled in the classic load balancer corresponding to the nginx ingress controller. 

#### Certificate Manager

To enable encryption in transit for the various services that are exposed by the EKS cluster, there should be a way to automatically issue TLS certificates for these services. This is performed by the cert manager component. Specifically, first, a new root or intermediate certificate authority should be created that will be responsible for signing the certificates of newly deployed services. The private key and certificate of this authority is stored as a kubernetes secret and passed to cert manager. Then, a custom resource definition (CRD) is defined for creating a ClusterIssuer entity as follows:

```
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: <cluster_issuer_name>
spec:
  ca:
    secretName: <certificate_authority_secret_name>
```

This entity will be used by the cert manager to sign the TLS certificates of new services using the private key of the certificate authority. After importing the certificate of the above mentioned certificate authority in their browser, users will be able to securely connect via HTTPS to the various services and UIs exposed by the EKS cluster.

#### Kube prometheus stack

One important component of the infrastructure is the cluster monitoring and alerting. In this solution, we adopt the kube prometheus stack. The stack installs prometheus for collecting and storing performance metrics in the cluster and grafana for creating dashboards and visualizations. The storage backed for prometheus and alert manager is based on EFS volumes requested using the storage class created by the EFS CSI driver (see [EFS CSI driver](#efs-csi-driver)). 

The stack also installs a daemonset of node exporter pods in the cluster that collect system-level metrics from each worker node and exposes them to prometheus. Grafana is also deployed with a set of pre-configured dashboards which provide visualizations for various metrics related to the kubernetes infrastructure and deployed services. Those dashboards are organized based on various dimensions, such as, the kubernetes namespaces, worker nodes, and pods. These dashboards can be very useful when troubleshooting issues related to the kubernetes infrastructure or the deployed applications (e.g., spark applications).

Additionally, the stack deploys the prometheus operator with which custom CRDs can be defined for deploying prometheus exporters which can expose metrics to prometheus from newly deployed applications in the cluster. Based on these metrics, custom dashboards and alerts can be defined on grafana for continuously monitoring important application performance KPIs.  

## Spark components

In this solution, several tools have been installed to aid in the development, testing, and deployment of spark applications on the EKS cluster. Developers can have their own isolated environments in JupyterHub for developing the spark applications. Through interactive notebooks, they can access datasets that reside on S3 buckets, process them and produce outputs and visualizations. After a spark application has been developed and thoroughly tested, it can be deployed to the cluster using the spark operator. 

#### Data storage on S3

For spark applications, two dedicated S3 buckets are created on AWS, one for storing the data to be processed, and one for keeping the history of event logs of all executed applications. For being able to access these S3 buckets, application pods should be executed with a service account that has been assigned a role with the appropriate IAM permissions for reading and writing objects to these buckets.  

#### JupyterHub

The JupyterHub can be used to create isolated environments in the cluster for spark application developers. These environments are deployed as separate pods each with its own dedicated resources (cpu and memory). The user workspaces are persisted in EFS volumes that are mounted to the corresponding Jupyter notebook pods. Even after restarts and redeployments of a notebook, the status of its workspace remains intact. Through the Jupyter notebooks, developers can access data from S3, they can process them in spark, and produce outputs and visualizations. After an application has been developed and tested in the Jupyter notebook, it can be deployed in the cluster using the spark operator.

#### Spark operator

With the spark operator, spark applications can be submitted to the kubernetes API using CRD files. These files define all required spark parameters, such as, the mode of execution, application image, spark configuration options, spark UI options, and specifications for the driver and executors. An example of a CRD file for executing a pyspark application on the EKS cluster is the following:

```
apiVersion: "sparkoperator.k8s.io/v1beta2"
kind: SparkApplication
metadata:
  name: <pyspark_application_name>
  namespace: spark
spec:
  type: Python
  pythonVersion: "3"
  mode: cluster
  image: <spark_image>
  imagePullPolicy: Always
  mainApplicationFile: local:///<path_to_python_application>
  sparkVersion: 3.2.1"
  sparkConf:
    "spark.eventLog.enabled": "true"
    "spark.eventLog.dir": "s3a://<spark_event_logs_bucket>/logs/"
    "spark.hadoop.fs.s3a.aws.credentials.provider": "com.amazonaws.auth.WebIdentityTokenCredentialsProvider"
  sparkUIOptions:
    ingressAnnotations:
      cert-manager.io/cluster-issuer: <cluster_issuer_name>
      kubernetes.io/ingress.class: nginx
    ingressTLS:
      - secretName: <spark_ui_tls_certificate_secret>
        hosts:
          - <pyspark_application_name>.<route53_domain>
  restartPolicy:
    type: Never
  driver:
    cores: 1
    memory: "512m"
    nodeSelector:
      eks.amazonaws.com/nodegroup: spot_group
    labels:
      version: 3.2.1
    serviceAccount: <spark_application_service_account>
  executor:
    cores: 1
    instances: 1
    memory: "512m"
    nodeSelector:
      eks.amazonaws.com/nodegroup: spot_group
    labels:
      version: 3.2.1
```

In the above file, in the "spec" block, the docker image of the spark application is defined (image) along with the path to the pyspark application executable file within the image (mainApplicationFile). The "sparkConf" block defines the required  configuration options for exporting the event logs of the application to S3. For monitoring and troubleshooting the application during its execution, the spark UI is exposed through an ingress. The CRD file contains a dedicated block for the spark UI (sparkUIOptions). This block defines the cluster issuer that is responsible for signing the TLS certificate of the spark UI (see [Certificate manager](#certificate-manager)), the name of the kubernetes secret holding the certificate, and the hostname that will be assigned to the spark UI.

In the file, there are also blocks dedicated to the driver and executor pods in which properties such as the requested resources (cpu cores and memory), node selector (eks.amazonaws.com/nodegroup: spot_group), and service account are defined. The node selector label ensures that the application will be deployed on the EKS node group with the spot instances. 

#### Spark history server

The history of executed spark applications and their logs are accessible from the spark history server UI. The spark operator module deploys the spark history server and exposes its UI using an ingress. This server accesses the logs of past executed applications from the corresponding spark event logs S3 bucket.

## Terraform modules

The source code of this repository depends on the Terraform modules defined in the following table:

| Module                                                                                                         | Description                                                                                                                                  |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| [terraform-aws-custom-vpc](https://github.com/gfortetsanakis/terraform-aws-custom-vpc)                         | Creates the VPC of the infrastructure                                                                                                        |
| [terraform-aws-openvpn-server](https://github.com/gfortetsanakis/terraform-aws-openvpn-server)                 | Deploys on OpenVPN server                                                                                                                    |
| [terraform-aws-nat-instance](https://github.com/gfortetsanakis/terraform-aws-nat-instance)                     | Deploys a NAT instance                                                                                                                       |
| [terraform-aws-eks-cluster](https://github.com/gfortetsanakis/terraform-aws-eks-cluster)                       | Creates the EKS cluster                                                                                                                      |
| [terraform-helm-eks-autoscaler](https://github.com/gfortetsanakis/terraform-helm-eks-autoscaler)               | Installs the [cluster-autoscaler chart](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)                      |
| [terraform-helm-efs-csi-driver](https://github.com/gfortetsanakis/terraform-helm-efs-csi-driver)               | Installs the [efs-csi-driver chart](https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/charts/aws-efs-csi-driver/values.yaml) |
| [terraform-helm-external-dns](https://github.com/gfortetsanakis/terraform-helm-external-dns)                   | Install the [external-dns chart](https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/charts/aws-efs-csi-driver/values.yaml)    |
| [terraform-helm-ingress-nginx](https://github.com/gfortetsanakis/terraform-helm-ingress-nginx)                 | Installs the [ingress-nginx chart](https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx)                               |
| [terraform-helm-cert-manager](https://github.com/gfortetsanakis/terraform-helm-cert-manager)                   | Installs the [cert-manager chart](https://github.com/cert-manager/cert-manager/tree/master/deploy/charts/cert-manager)                       |
| [terraform-helm-kube-prometheus-stack](https://github.com/gfortetsanakis/terraform-helm-kube-prometheus-stack) | Installs the [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)       |
| [terraform-aws-s3-bucket](https://github.com/gfortetsanakis/terraform-helm-eks-autoscaler)                     | Creates S3 buckets on AWS                                                                                                                    |
| [terraform-helm-jupyter-hub](https://github.com/gfortetsanakis/terraform-helm-jupyter-hub)                     | Installs the [jupyterHub chart](https://github.com/jupyterhub/helm-chart)                                                                    |
| [terraform-helm-spark-operator](https://github.com/gfortetsanakis/terraform-helm-spark-operator)               | Installs the [spark-operator chart](https://github.com/GoogleCloudPlatform/spark-on-k8s-operator/tree/master/charts/spark-operator-chart)    |

## Installation instructions

Before proceeding with the installation of the infrastructure, the following software components should be first installed on the local machine:

- Terraform

- AWS CLI

- Kubectl

- OpenVPN client

The Terraform script of this repository requires a set of input parameters described in the following table:

| Parameter                   | Module                | Description                                                                                | Default    |
| --------------------------- | --------------------- | ------------------------------------------------------------------------------------------ | ---------- |
| aws_region                  | custom-vpc            | The aws region at which the infrastructure will be set up                                  | eu-north-1 |
| openvpn_client_cidrs        | OpenVPN server        | List of CIDR blocks that are allowed to connect to the OpenVPN server                      |            |
| openvpn_key_path            | OpenVPN server        | The path to the public ssh key file for the OpenVPN server                                 |            |
| openvpn_instance_type       | OpenVPN server        | The instance type used for the openVPN server                                              | t3.micro   |
| openvpn_user                | OpenVPN server        | The name of the first OpenVPN user to be created during the server installation            |            |
| nat_instance_key_path       | NAT instance          | The path to the public ssh key file for the NAT instance                                   |            |
| nat_instance_type           | NAT instance          | The instance type used for the NAT instance                                                | t3.micro   |
| eks_worker_nodes_key_path   | EKS cluster           | The path to the public ssh key file for the EKS worker nodes                               |            |
| kubernetes_addons_namespace | EKS cluster           | The namespace on which kubernetes components are installed                                 | addons     |
| domain                      | External DNS          | The domain of the Route53 private hosted zone that will be created for the EKS cluster     |            |
| cluster_issuer_cert_path    | Certificate manager   | The path to the file containing the certificate of the ClusterIssuer certificate authority |            |
| cluster_issuer_key_path     | Certificate manager   | The path to the file containing the private key of the ClusterIssuer certificate authority |            |
| history_server_spark_image  | Spark operator        | The spark image used for deploying the spark history server                                |            |
| jupyter_notebook_image      | JupyterHub            | The Jupyter notebook image                                                                 |            |
| docker_registry_server      | JupyterHub            | The docker registry hosting the docker image for Jupyter notebook                          |            |
| docker_registry_username    | JupyterHub            | The docker registry username                                                               |            |
| docker_registry_password    | JupyterHub            | The docker registry password                                                               |            |
| docker_registry_email       | JupyterHub            | The docker registry email account                                                          |            |
| grafana_admin_password      | Kube prometheus stack | The admin password for grafana                                                             |            |

Regarding the spark and Jupyter notebook images, it is necessary to support the latest s3a connector. That way spark applications will be able to read and write data to S3 buckets with the best possible performance. A pre-build docker image that could be used for the spark history server which supports the S3a connector is "datamechanics/spark:3.2-latest" that is available on [DockerHub](https://hub.docker.com/r/datamechanics/spark). For building an image with s3a support for the Jupyter notebook, a Dockerfile is provided in the Docker folder of this repository. After building the image, it can be uploaded on a docker registry (e.g., DockerHub, Amazon ECR) from which it will be pulled during the deployment of the JupyterHub chart. 

#### Installation steps

1. Clone the repository to your machine
   
   ```
   git clone https://github.com/gfortetsanakis/dynamic-spark-environment-on-eks.git
   ```

2. cd to the repository directory:
   
   ```
   cd dynamic-spark-environment-on-eks
   ```

3. Create a "terraform.tfvars" file and define values for all input parameters described in the previous section.

4. Edit the locals.tf file, modify the "eks_node_groups" variable according to you needs and define the names of S3 buckets to be created for spark in "s3_buckets" variable:
   
   ```
   eks_node_groups = {
     on_demand_group = {
       min_size       = 3
       desired_size   = 3
       max_size       = 6
       instance_types = ["t3.medium"]
       disk_size      = 20
       capacity_type  = "SPOT"
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
     spark_logs = "example-spark-logs-bucket"
     spark_data = "example-spark-data-bucket"
   }
   ```

5. Initialize terraform:
   
   ```
   terraform init
   ```

6. After the successful initialization of Terraform, proceed with the deployment of the custom vpc and OpenVPN server modules:
   
   ```
   terraform apply --target=module.custom-vpc --target=module.openvpn-server
   ```

7. Wait until the OpenVPN server EC2 instance is successfully initialized. Then connect  to the instance via ssh and download the .ovpn file that has been created inside the home directory of the "ec2-user".

8. Import the .ovpn file in the OpenVPN client software on your machine and connect to the OpenVPN server.

9. Install the remaining components of the infrastructure:
   
   ```
   terraform apply
   ```

10. Test accessing the UIs of the kubernetes components (spark history server, grafana, prometheus, alert manager). The URLs of these UIs are provided in the output of the Terraform script. Please note that for establishing secure connections to these UIs, the certificate of the ClusterIssuer certificate authority should first be imported on the web browser (see [Certificate manager](#certificate-manager)). 

11. Use the aws cli to download the kubeconfig file for the eks cluster:
    
    ```
    aws eks --region <eks_cluster_region> update-kubeconfig --name <eks_cluster_name>
    ```

12. Test executing kubectl commands:
    
    ```
    kubectl get nodes
    ```

#### Examples
