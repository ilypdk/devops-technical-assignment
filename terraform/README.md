# EKS + Karpenter POC

This Terraform project creates a working Amazon EKS proof of concept in a new dedicated VPC and installs Karpenter for dynamic x86_64 and AWS Graviton (ARM64) capacity.

The design keeps a small fixed EKS Managed Node Group for critical system workloads, including the Karpenter controller, while application capacity is provisioned dynamically by Karpenter.

## Architecture

```text
Dedicated VPC
|
+-- Public subnets (3 AZs)
|   |
|   +-- NAT Gateway (single NAT for this POC)
|
+-- Private subnets (3 AZs)
    |
    +-- EKS Managed Node Group
    |   |
    |   +-- 2 x t3.medium On-Demand
    |   +-- Karpenter controller
    |   +-- Kubernetes system workloads
    |
    +-- Karpenter-managed capacity
        |
        +-- x86-spot NodePool
        |   +-- amd64
        |   +-- Spot
        |   +-- c / m / r instance categories
        |
        +-- arm64-spot NodePool
            +-- arm64 / AWS Graviton
            +-- Spot
            +-- c / m / r instance categories
```

## Components

- Dedicated VPC (`10.0.0.0/16`)
- Three Availability Zones
- Three public subnets
- Three private subnets
- Single NAT Gateway for POC cost optimization
- Amazon EKS
- Private EKS API endpoint
- Two On-Demand EKS Managed Nodes for system workloads
- Amazon Linux 2023 EKS nodes
- Karpenter
- IRSA for the Karpenter controller
- Karpenter Spot interruption handling with SQS/EventBridge
- Shared `EC2NodeClass`
- x86_64 Spot `NodePool`
- ARM64 / AWS Graviton Spot `NodePool`
- KMS encryption for Kubernetes secrets
- EKS access entries

## Why a fixed Managed Node Group is used

Karpenter itself must run somewhere before it can create additional worker nodes.

For that reason, the cluster contains a small permanent EKS Managed Node Group:

```text
system
  instance type: t3.medium
  capacity:      On-Demand
  min:           2
  desired:       2
  max:           2
```

The Karpenter controller is scheduled on this stable capacity.

Application workloads can then trigger Karpenter to create additional EC2 instances.

This avoids a circular dependency where Karpenter would need to provision the node required to run Karpenter itself.

## Karpenter NodePools

Two NodePools are created.

### x86 Spot

```text
NodePool: x86-spot
Architecture: amd64
Capacity type: Spot
Instance categories: c, m, r
Label: workload-arch=x86
```

### AWS Graviton Spot

```text
NodePool: arm64-spot
Architecture: arm64
Capacity type: Spot
Instance categories: c, m, r
Label: workload-arch=graviton
```

Both NodePools use the same `EC2NodeClass`.

The `EC2NodeClass` uses:

- latest EKS-compatible Amazon Linux 2023 AMI selected by Karpenter
- private subnets discovered through `karpenter.sh/discovery`
- the EKS node Security Group discovered through `karpenter.sh/discovery`
- encrypted 30 GiB gp3 root volumes
- IMDSv2 (`httpTokens: required`)
- a dedicated Karpenter node IAM role

Karpenter consolidation is enabled with:

```text
consolidationPolicy: WhenEmptyOrUnderutilized
consolidateAfter: 1m
```

This allows unused or inefficiently allocated nodes to be consolidated.

## IRSA for Karpenter

The Karpenter controller uses IAM Roles for Service Accounts (IRSA), not EKS Pod Identity.

The ServiceAccount is annotated with the Karpenter controller IAM role:

```yaml
eks.amazonaws.com/role-arn: <karpenter-controller-role-arn>
```

The EKS OIDC provider is trusted by the IAM role for:

```text
system:serviceaccount:kube-system:karpenter
```

The runtime flow is:

```text
Karpenter Pod
   |
   | projected ServiceAccount JWT
   v
AWS SDK
   |
   | STS AssumeRoleWithWebIdentity
   v
AWS STS
   |
   | validates EKS OIDC token and IAM trust policy
   v
Temporary AWS credentials
   |
   v
EC2 / IAM / SQS APIs required by Karpenter
```

No long-lived AWS access keys are stored in the Pod.

## Spot interruption handling

Karpenter Spot interruption handling is enabled.

Terraform creates the required SQS interruption queue and supporting AWS event configuration through the Karpenter module.

The queue name is passed to the Karpenter Helm chart:

```text
settings.interruptionQueue
```

This allows Karpenter to react to Spot interruption events and gracefully replace affected nodes where possible.

## EKS API access

The EKS API endpoint is configured as private:

```hcl
endpoint_private_access = true
endpoint_public_access  = false
```

The Kubernetes API is therefore not exposed to the public internet.

Any machine running `kubectl`, Helm, or the Terraform Kubernetes/Helm providers must have network connectivity to the VPC, for example through:

- a company VPN
- AWS Client VPN
- a bastion/management host
- a CI runner inside the VPC or connected network

This is important because Terraform installs Karpenter and its Kubernetes resources after the EKS control plane is created.

## Prerequisites

- Terraform >= 1.5.7
- AWS CLI v2
- kubectl
- AWS credentials with sufficient permissions
- network connectivity to the private EKS API endpoint for `terraform apply`

Check AWS access:

```bash
aws sts get-caller-identity
```

## Configure

Copy the example variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Example:

```hcl
aws_region = "eu-west-1"

cluster_name       = "eks-karpenter-poc"
kubernetes_version = "1.36"

availability_zones = [
  "eu-west-1a",
  "eu-west-1b",
  "eu-west-1c"
]

access_entries = {}
```

Additional EKS access entries can be supplied when required.

Example:

```hcl
access_entries = {
  admin = {
    principal_arn = "arn:aws:iam::123456789012:role/AdministratorAccess"

    policy_associations = {
      cluster_admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

        access_scope = {
          type = "cluster"
        }
      }
    }
  }
}
```

The Terraform identity creating the cluster is also granted cluster-admin access through EKS Access Entries.

## Deploy

Initialize Terraform:

```bash
terraform init
```

Format and validate:

```bash
terraform fmt -recursive
terraform validate
```

Review the plan:

```bash
terraform plan
```

Optionally save the plan:

```bash
terraform plan -out=tfplan
terraform show -no-color tfplan > plan.txt
```

Deploy:

```bash
terraform apply
```

## Resource creation flow

The important dependency order is:

```text
VPC
 |
 v
EKS + system Managed Node Group
 |
 v
OIDC / Karpenter IAM roles / interruption queue
 |
 v
Karpenter CRDs
 |
 v
Karpenter controller
 |
 v
EC2NodeClass
 |
 v
x86 and ARM64 NodePools
```

Terraform dependencies ensure that Karpenter Kubernetes resources are not created before the cluster and controller are available.


## Terraform file-by-file explanation

The Terraform configuration is intentionally split by responsibility. The following section explains what every main Terraform block or Kubernetes resource in the repository is responsible for.

### `versions.tf`

This file defines the Terraform and provider versions used by the POC.

#### `terraform.required_version`

```hcl
required_version = ">= 1.5.7"
```

Defines the minimum Terraform CLI version required to run the project.

#### AWS provider

```hcl
aws = {
  source  = "hashicorp/aws"
  version = "6.60.0"
}
```

The AWS provider is used to create and manage AWS resources such as VPC, EKS, IAM, EC2-related resources, SQS and EventBridge resources created by the modules.

#### Helm provider

```hcl
helm = {
  source  = "hashicorp/helm"
  version = "3.2.0"
}
```

The Helm provider installs the Karpenter Helm charts into the EKS cluster.

#### kubectl provider

```hcl
kubectl = {
  source  = "alekc/kubectl"
  version = "2.4.1"
}
```

The kubectl provider applies Kubernetes manifests that are not managed directly by the Helm chart, specifically the Karpenter `EC2NodeClass` and `NodePool` resources.

---

### `providers.tf`

This file configures how Terraform connects to AWS and to the Kubernetes API.

#### `provider "aws"`

```hcl
provider "aws" {
  region = var.aws_region
}
```

All AWS resources are created in the region selected by `var.aws_region`.

#### `provider "helm"`

The Helm provider connects directly to the EKS Kubernetes API using:

- the EKS API endpoint;
- the EKS cluster CA certificate;
- a temporary Kubernetes authentication token obtained with `aws eks get-token`.

Authentication flow:

```text
Terraform Helm Provider
        |
        | aws eks get-token
        v
AWS CLI / EKS authentication
        |
        v
EKS Kubernetes API
```

The provider does not store a static Kubernetes password or token.

#### `provider "kubectl"`

The kubectl provider uses the same EKS endpoint and AWS token-based authentication.

It is used for resources such as:

```text
EC2NodeClass
NodePool x86
NodePool ARM64
```

`apply_retry_count = 15` allows retries while the newly-created Kubernetes API and Karpenter CRDs become available.

Because the EKS public endpoint is disabled, the machine running Terraform must have network connectivity to the private EKS endpoint.

---

### `variables.tf`

This file defines the input parameters of the Terraform project.

#### `aws_region`

Defines the AWS region where the infrastructure is created.

Default:

```text
eu-west-1
```

#### `cluster_name`

Defines the EKS cluster name and is also reused in resource names and Karpenter discovery tags.

Default:

```text
eks-karpenter-poc
```

#### `kubernetes_version`

Defines the Kubernetes version used by EKS.

Default:

```text
1.36
```

#### `availability_zones`

Defines the three Availability Zones used by the VPC.

The VPC module creates corresponding private and public subnets across these AZs.

#### `access_entries`

Allows additional IAM principals to be granted Kubernetes API access through the EKS Access Entry API.

This is the modern EKS-native method for granting IAM users or roles access to the cluster.

#### Public endpoint CIDR variable

The repository currently contains:

```hcl
cluster_endpoint_public_access_cidrs
```

However, the EKS public endpoint is disabled:

```hcl
endpoint_public_access = false
```

Therefore this variable is currently not required by the POC and can be removed from `variables.tf`, `terraform.tfvars.example`, and the EKS module configuration to avoid confusion.

---

### `terraform.tfvars.example`

This file is an example set of values for the input variables.

A developer copies it before running Terraform:

```bash
cp terraform.tfvars.example terraform.tfvars
```

The real `terraform.tfvars` can then be customized without changing the reusable Terraform configuration.

It defines:

- AWS region;
- EKS cluster name;
- Kubernetes version;
- Availability Zones;
- optional EKS access entries.

The example file should not contain credentials or secrets.

---

### `vpc.tf`

This file creates the dedicated VPC used by the EKS cluster.

#### `module "vpc"`

Uses:

```text
terraform-aws-modules/vpc/aws
```

instead of implementing every VPC resource individually.

The module creates the VPC and its supporting networking resources.

#### VPC CIDR

```hcl
cidr = "10.0.0.0/16"
```

Provides the private address space for the POC.

#### Private subnets

```text
10.0.1.0/24
10.0.2.0/24
10.0.3.0/24
```

One private subnet is created in each Availability Zone.

The EKS Managed Node Group and Karpenter-created worker nodes use these subnets.

The nodes do not require public IP addresses.

#### Public subnets

```text
10.0.101.0/24
10.0.102.0/24
10.0.103.0/24
```

One public subnet is created in each Availability Zone.

The public subnets provide the network location for internet-facing AWS resources and the NAT Gateway.

#### NAT Gateway

```hcl
enable_nat_gateway = true
single_nat_gateway = true
```

A single NAT Gateway is used for the POC.

It allows instances in the private subnets to make outbound internet connections without exposing those instances directly to inbound internet traffic.

Example:

```text
Private EKS node
      |
      v
Private route table
      |
      v
NAT Gateway
      |
      v
Internet Gateway
      |
      v
Internet
```

A production environment would normally use one NAT Gateway per AZ for higher availability.

#### DNS support

```hcl
enable_dns_support   = true
enable_dns_hostnames = true
```

Enables VPC DNS functionality required by EKS and normal AWS service name resolution.

#### Public subnet ELB tag

```hcl
"kubernetes.io/role/elb" = "1"
```

Marks the public subnets as suitable for internet-facing Kubernetes/AWS load balancers.

#### Private subnet internal ELB tag

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

Marks the private subnets as suitable for internal load balancers.

#### Karpenter discovery subnet tag

```hcl
"karpenter.sh/discovery" = var.cluster_name
```

Karpenter uses this tag to discover which subnets it is allowed to use when launching EC2 worker nodes.

---

### `eks.tf`

This file creates the EKS control plane and the permanent system Managed Node Group.

#### `module "eks"`

Uses:

```text
terraform-aws-modules/eks/aws
```

The module creates the EKS cluster and its supporting AWS resources such as IAM roles and Security Groups.

#### EKS cluster name and version

```hcl
name               = var.cluster_name
kubernetes_version = var.kubernetes_version
```

Creates the cluster using the configured name and Kubernetes version.

#### Private EKS API endpoint

```hcl
endpoint_private_access = true
endpoint_public_access  = false
```

The Kubernetes API is available only through the VPC/private network path.

This prevents direct access to the EKS API from the public internet.

#### Cluster creator admin permission

```hcl
enable_cluster_creator_admin_permissions = true
```

Creates an EKS Access Entry for the IAM identity that creates the cluster and grants that identity cluster administrator permissions.

#### IRSA support

```hcl
enable_irsa = true
```

Creates the EKS OIDC provider required for IAM Roles for Service Accounts.

The Karpenter controller later uses this OIDC provider to assume its IAM role through STS.

#### EKS add-ons

```hcl
addons = {
  coredns    = {}
  kube-proxy = {}
  vpc-cni    = {}
}
```

`coredns`

Provides Kubernetes DNS service discovery inside the cluster.

`kube-proxy`

Implements Kubernetes Service networking rules on worker nodes.

`vpc-cni`

Provides pod networking using AWS VPC networking and assigns VPC-routable IP addresses to Pods.

#### VPC placement

```hcl
vpc_id     = module.vpc.vpc_id
subnet_ids = module.vpc.private_subnets
```

Connects EKS to the dedicated VPC and places worker capacity in private subnets.

#### `system` EKS Managed Node Group

The permanent Managed Node Group contains:

```text
2 x t3.medium
Amazon Linux 2023
x86_64
On-Demand
```

Its main purpose is to provide stable capacity for system components, especially the Karpenter controller.

Configuration:

```hcl
min_size     = 2
desired_size = 2
max_size     = 2
```

The node group is intentionally fixed at two nodes in this POC.

#### Karpenter controller node label

```hcl
labels = {
  "karpenter.sh/controller" = "true"
}
```

Adds a label to the system nodes.

The Karpenter Helm deployment uses this label as its `nodeSelector`, ensuring the controller runs on stable Managed Node Group capacity instead of capacity managed by Karpenter itself.

#### Karpenter Security Group discovery tag

```hcl
node_security_group_tags = {
  "karpenter.sh/discovery" = var.cluster_name
}
```

Tags the EKS node Security Group so that the Karpenter `EC2NodeClass` can discover and attach it to dynamically-created nodes.

#### Additional access entries

```hcl
access_entries = var.access_entries
```

Allows extra IAM identities to receive Kubernetes API permissions without editing the Terraform module.

---

### `karpenter.tf`

This file creates the AWS permissions required by Karpenter and installs the Karpenter controller.

#### `data "aws_iam_policy_document" "karpenter_irsa_assume_role"`

This generates the IAM trust policy used by the Karpenter controller role.

The allowed STS action is:

```text
sts:AssumeRoleWithWebIdentity
```

The trusted principal is the EKS OIDC provider.

The trust policy also validates:

```text
aud = sts.amazonaws.com
sub = system:serviceaccount:kube-system:karpenter
```

Therefore only the `karpenter` ServiceAccount in the `kube-system` namespace can use this IRSA trust relationship.

Runtime flow:

```text
Karpenter Pod
   |
ServiceAccount JWT
   |
   v
STS AssumeRoleWithWebIdentity
   |
   v
IAM trust policy validates OIDC claims
   |
   v
temporary AWS credentials
```

#### `module "karpenter"`

Uses the Karpenter submodule of:

```text
terraform-aws-modules/eks/aws
```

This module creates the AWS-side resources required by the Karpenter controller.

#### Disable EKS Pod Identity

```hcl
create_pod_identity_association = false
```

The POC intentionally uses IRSA instead of EKS Pod Identity.

#### Karpenter controller IAM role

```hcl
iam_role_name = "${var.cluster_name}-karpenter-controller"
```

This IAM role is assumed by the Karpenter controller Pod.

The module attaches the permissions Karpenter requires to discover and provision EC2 infrastructure.

Examples include:

```text
ec2:RunInstances
ec2:CreateFleet
ec2:CreateLaunchTemplate
ec2:TerminateInstances
ec2:Describe*
pricing:GetProducts
ssm:GetParameter
eks:DescribeCluster
iam:PassRole
```

#### Override controller trust policy

```hcl
iam_role_override_assume_policy_documents = [
  data.aws_iam_policy_document.karpenter_irsa_assume_role.json
]
```

Replaces the module's Pod Identity trust behavior with the custom IRSA trust policy.

#### Karpenter node IAM role

```hcl
create_node_iam_role = true
```

Creates a separate IAM role for EC2 instances launched by Karpenter.

The controller role and node role have different responsibilities:

```text
Karpenter controller IAM role
    -> allows the controller to create/manage infrastructure

Karpenter node IAM role
    -> permissions used by the EC2 worker node itself
```

#### EKS access entry for Karpenter nodes

```hcl
create_access_entry = true
```

Allows EC2 nodes created by Karpenter to authenticate and join the EKS cluster.

#### Spot interruption handling

```hcl
enable_spot_termination = true
queue_name = "${var.cluster_name}-karpenter"
```

Creates the Karpenter interruption queue and related AWS event resources.

Spot-related AWS events are delivered to the queue, and the Karpenter controller consumes them to react before interrupted nodes disappear.

#### `helm_release "karpenter_crd"`

Installs the Karpenter Custom Resource Definitions before installing the controller.

The CRDs define Kubernetes resource types such as:

```text
NodePool
NodeClaim
EC2NodeClass
```

Installing them first ensures Kubernetes understands those resource kinds before Terraform creates them.

#### `helm_release "karpenter"`

Installs the actual Karpenter controller into the `kube-system` namespace.

Important configuration:

`skip_crds = true`

The CRDs are installed separately by `karpenter_crd`, so the main chart does not install them again.

`atomic = true`

If the Helm installation fails, Helm rolls the release back instead of leaving a partially-installed release.

`cleanup_on_fail = true`

Removes newly-created resources if the Helm upgrade/install fails.

#### Karpenter ServiceAccount annotation

```yaml
eks.amazonaws.com/role-arn: <controller-role-arn>
```

Connects the Kubernetes ServiceAccount to the Karpenter IAM role for IRSA.

The EKS IRSA admission mechanism injects the role ARN and projected web identity token information into the Karpenter Pod, and the AWS SDK uses them to call STS.

#### Karpenter `nodeSelector`

```yaml
nodeSelector:
  karpenter.sh/controller: "true"
```

Forces the controller onto the fixed system Managed Node Group.

#### `settings.clusterName`

Tells Karpenter which EKS cluster it manages.

#### `settings.clusterEndpoint`

Provides the Kubernetes API endpoint required by the controller.

#### `settings.interruptionQueue`

Provides the SQS queue used for Spot interruption handling.

#### Controller resource requests and limits

```yaml
requests:
  cpu: 500m
  memory: 512Mi

limits:
  cpu: 1
  memory: 1Gi
```

Reserves predictable CPU/memory for the Karpenter controller and prevents unbounded resource usage.

---

### `karpenter_node_class.tf`

This file defines how Karpenter-created EC2 instances should be configured.

#### `kubectl_manifest "karpenter_node_class"`

Creates an AWS-specific Karpenter `EC2NodeClass` named:

```text
default
```

A NodePool describes what type of capacity is wanted, while the EC2NodeClass describes how the underlying AWS EC2 node should be created.

Conceptually:

```text
NodePool
   |
   | architecture / Spot / instance category
   v
EC2NodeClass
   |
   | subnet / SG / AMI / disk / IAM role
   v
EC2 instance
```

#### Node IAM role

```yaml
role: ${module.karpenter.node_iam_role_name}
```

Associates dynamically-created EC2 worker nodes with the dedicated Karpenter node IAM role.

#### AMI selector

```yaml
amiSelectorTerms:
  - alias: al2023@latest
```

Tells Karpenter to select the latest compatible Amazon Linux 2023 AMI.

#### Subnet selector

```yaml
subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: ${var.cluster_name}
```

Karpenter discovers the private subnets created in `vpc.tf` by matching their discovery tag.

#### Security Group selector

```yaml
securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: ${var.cluster_name}
```

Discovers the EKS node Security Group tagged in `eks.tf`.

#### EBS root volume

Each Karpenter node receives:

```text
30 GiB
gp3
encrypted
delete on termination
```

`deleteOnTermination: true` prevents unused root volumes from remaining after Karpenter terminates a node.

#### EC2 Instance Metadata Service settings

```yaml
httpTokens: required
```

Requires IMDSv2.

This protects the EC2 metadata endpoint by requiring a session token instead of allowing unrestricted IMDSv1 requests.

`httpPutResponseHopLimit: 1` restricts the metadata response hop limit.

#### `depends_on`

```hcl
depends_on = [
  helm_release.karpenter
]
```

Ensures Terraform does not try to create the `EC2NodeClass` before the Karpenter controller and its CRDs are installed.

---

### `karpenter_node_pool.tf`

This file creates the two Karpenter capacity pools requested by the assignment.

#### `kubectl_manifest "karpenter_node_pool_x86"`

Creates:

```text
NodePool: x86-spot
```

The NodePool references the shared `EC2NodeClass`:

```yaml
nodeClassRef:
  group: karpenter.k8s.aws
  kind: EC2NodeClass
  name: default
```

#### x86 architecture requirement

```yaml
- key: kubernetes.io/arch
  operator: In
  values:
    - amd64
```

Only x86_64 instances can satisfy this NodePool.

#### Linux requirement

```yaml
kubernetes.io/os = linux
```

Restricts nodes to Linux.

#### Spot requirement

```yaml
karpenter.sh/capacity-type = spot
```

Only EC2 Spot capacity is selected.

#### Instance category requirement

```yaml
karpenter.k8s.aws/instance-category = c, m, r
```

Allows Karpenter to choose from:

```text
c = compute optimized
m = general purpose
r = memory optimized
```

Giving Karpenter several instance families improves its ability to find available Spot capacity and select cost-effective instances.

#### Custom x86 label

```yaml
workload-arch: x86
```

Makes it easy for application manifests to explicitly target this NodePool.

Example:

```yaml
nodeSelector:
  workload-arch: x86
```

#### CPU limit

```yaml
limits:
  cpu: "100"
```

Limits the total CPU capacity that this NodePool is allowed to provision to 100 vCPUs.

It is a NodePool-wide capacity guardrail, not a limit for one Pod or one EC2 instance.

#### Consolidation

```yaml
consolidationPolicy: WhenEmptyOrUnderutilized
consolidateAfter: 1m
```

Allows Karpenter to remove or replace empty/underutilized nodes after they have been eligible for consolidation for one minute.

#### `kubectl_manifest "karpenter_node_pool_arm64"`

Creates:

```text
NodePool: arm64-spot
```

It is equivalent to the x86 NodePool except for the architecture and custom label.

Architecture:

```yaml
kubernetes.io/arch: arm64
```

This selects AWS Graviton-compatible EC2 capacity.

Custom label:

```yaml
workload-arch: graviton
```

A developer can therefore explicitly target Graviton:

```yaml
nodeSelector:
  kubernetes.io/arch: arm64
  workload-arch: graviton
```

The ARM64 NodePool also uses Spot capacity and the `c`, `m`, and `r` instance categories.

#### NodePool dependencies

Both NodePools depend on:

```text
EC2NodeClass
```

This ensures the shared AWS node configuration exists before the NodePools reference it.

---

### `outputs.tf`

This file exposes useful values after `terraform apply`.

#### `cluster_name`

Returns the EKS cluster name.

Useful for commands such as:

```bash
aws eks update-kubeconfig --name <cluster_name>
```

#### `cluster_endpoint`

Returns the Kubernetes API endpoint.

This is also consumed internally by the Helm and kubectl providers.

#### `vpc_id`

Returns the ID of the dedicated VPC.

Useful for troubleshooting and validation.

#### `private_subnets`

Returns the IDs of the private subnets where EKS/Karpenter capacity can run.

#### `karpenter_controller_role_arn`

Returns the IAM role ARN used by the Karpenter controller through IRSA.

#### `karpenter_node_role_arn`

Returns the IAM role ARN used by EC2 worker nodes created by Karpenter.

#### `karpenter_interruption_queue`

Returns the SQS queue name used by Karpenter for interruption handling.

---

## End-to-end relationship between the resources

The complete resource relationship can be summarized as:

```text
versions.tf
   |
   +--> provider versions

providers.tf
   |
   +--> AWS API
   +--> EKS Kubernetes API

vpc.tf
   |
   +--> VPC
   +--> public/private subnets
   +--> NAT Gateway
   +--> Karpenter discovery tags
          |
          v
eks.tf
   |
   +--> EKS control plane
   +--> OIDC provider
   +--> EKS add-ons
   +--> system Managed Node Group
   +--> node Security Group discovery tag
          |
          v
karpenter.tf
   |
   +--> controller IAM role (IRSA)
   +--> node IAM role
   +--> EKS node access entry
   +--> SQS interruption queue
   +--> EventBridge interruption events
   +--> Karpenter CRDs
   +--> Karpenter controller
          |
          v
karpenter_node_class.tf
   |
   +--> EC2NodeClass
          |
          +--> private subnet discovery
          +--> Security Group discovery
          +--> AL2023 AMI
          +--> gp3 EBS
          +--> node IAM role
          |
          v
karpenter_node_pool.tf
   |
   +--> x86-spot
   |
   +--> arm64-spot
          |
          v
Unschedulable application Pod
          |
          v
Karpenter provisions matching EC2 worker node
```


## Configure kubectl

```bash
aws eks update-kubeconfig \
  --region eu-west-1 \
  --name eks-karpenter-poc
```

Check access:

```bash
kubectl get nodes
```

Initially, the two fixed system nodes should be visible.

Check Karpenter:

```bash
kubectl get pods \
  -n kube-system \
  -l app.kubernetes.io/name=karpenter
```

Check Karpenter resources:

```bash
kubectl get ec2nodeclass
kubectl get nodepool
kubectl get nodeclaims
```

Expected NodePools:

```text
x86-spot
arm64-spot
```

## Run a workload on x86

A developer can request x86 capacity using Kubernetes scheduling constraints.

Create `x86-demo.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x86-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: x86-demo
  template:
    metadata:
      labels:
        app: x86-demo
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
        workload-arch: x86
      containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
```

Deploy:

```bash
kubectl apply -f x86-demo.yaml
```

Because the workload requires:

```text
kubernetes.io/arch=amd64
workload-arch=x86
```

it matches the `x86-spot` NodePool.

If no existing node has sufficient matching capacity, the Pod remains temporarily Pending and Karpenter provisions an appropriate x86 Spot EC2 instance.

Check the Pod and selected node:

```bash
kubectl get pods -o wide
```

Check node architecture and Karpenter labels:

```bash
kubectl get nodes \
  -L kubernetes.io/arch,karpenter.sh/capacity-type,karpenter.sh/nodepool,workload-arch
```

## Run a workload on AWS Graviton

Create `graviton-demo.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graviton-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: graviton-demo
  template:
    metadata:
      labels:
        app: graviton-demo
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
        workload-arch: graviton
      containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
```

Deploy:

```bash
kubectl apply -f graviton-demo.yaml
```

The workload requires:

```text
kubernetes.io/arch=arm64
workload-arch=graviton
```

and therefore matches the `arm64-spot` NodePool.

If matching capacity does not already exist, Karpenter provisions an ARM64/Graviton Spot EC2 instance.

Check the result:

```bash
kubectl get pods -o wide

kubectl get nodes \
  -L kubernetes.io/arch,karpenter.sh/capacity-type,karpenter.sh/nodepool,workload-arch
```

## Important container image requirement for Graviton

A workload scheduled on ARM64 requires an ARM64-compatible container image.

For applications built by the company, container images should therefore be built as multi-architecture images, for example:

```text
linux/amd64
linux/arm64
```

A multi-architecture image allows the same image tag to be used on both x86 and Graviton nodes.

Example with Docker Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <registry>/<image>:<tag> \
  --push .
```

## How Karpenter scaling works in this POC

Karpenter is driven by unschedulable Pods.

Example:

```text
Developer creates ARM64 Deployment
            |
            v
Kubernetes scheduler cannot find
an ARM64 node with free capacity
            |
            v
Pod becomes Pending
            |
            v
Karpenter sees the unschedulable Pod
            |
            v
arm64-spot NodePool matches
            |
            v
Karpenter selects an appropriate
Graviton Spot instance
            |
            v
EC2 instance joins EKS
            |
            v
Pod is scheduled
```

The same flow applies to x86 workloads through the `x86-spot` NodePool.

When application capacity becomes empty or underutilized, Karpenter can consolidate nodes according to the configured disruption policy.

## Verify Spot capacity

```bash
kubectl get nodes \
  -L kubernetes.io/arch,karpenter.sh/capacity-type,karpenter.sh/nodepool
```

Expected examples:

```text
amd64   spot   x86-spot
arm64   spot   arm64-spot
```

## Remove test workloads

```bash
kubectl delete deployment x86-demo graviton-demo
```

After the workloads are removed, Karpenter can consolidate and terminate unnecessary dynamically provisioned nodes.

The two fixed system Managed Node Group instances remain running.

## Destroy

Destroy the environment when testing is complete:

```bash
terraform destroy
```

Because the POC contains chargeable AWS resources such as EKS, EC2, and a NAT Gateway, the environment should not be left running unnecessarily.

## Notes

- The single NAT Gateway is a POC cost optimization. A production design would normally use one NAT Gateway per Availability Zone for higher availability.
- Karpenter application capacity is Spot-only in this POC to demonstrate the requested Spot and Graviton capabilities.
- A production design may combine Spot and On-Demand capacity based on workload criticality.
- The fixed EKS Managed Node Group provides reliable capacity for system components and the Karpenter controller.
- The EKS control plane is private and is intended to be accessed through a VPN or another trusted network path.
