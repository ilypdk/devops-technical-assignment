variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-karpenter-poc"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "availability_zones" {
  description = "Availability Zones used by the VPC"
  type        = list(string)

  default = [
    "eu-west-1a",
    "eu-west-1b",
    "eu-west-1c"
  ]
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR ranges allowed to access the public EKS API endpoint"
  type        = list(string)

  default = [
    "0.0.0.0/0"
  ]
}

variable "access_entries" {
  description = "Additional EKS access entries"
  type        = any
  default     = {}
}