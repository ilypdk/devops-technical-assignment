output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "karpenter_controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "karpenter_node_role_arn" {
  value = module.karpenter.node_iam_role_arn
}

output "karpenter_interruption_queue" {
  value = module.karpenter.queue_name
}