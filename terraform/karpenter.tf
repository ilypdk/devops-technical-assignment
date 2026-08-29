data "aws_iam_policy_document" "karpenter_irsa_assume_role" {
  statement {
    sid    = "PodIdentity"
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        module.eks.oidc_provider_arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"

      values = [
        "system:serviceaccount:kube-system:karpenter"
      ]
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = false

  iam_role_name            = "${var.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix = false

  iam_policy_name            = "${var.cluster_name}-karpenter-controller"
  iam_policy_use_name_prefix = false

  iam_role_override_assume_policy_documents = [
    data.aws_iam_policy_document.karpenter_irsa_assume_role.json
  ]

  create_node_iam_role = true

  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  create_access_entry = true

  enable_spot_termination = true
  queue_name              = "${var.cluster_name}-karpenter"

  tags = {
    Project   = "eks-karpenter-poc"
    ManagedBy = "Terraform"
  }

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = "1.14.1"

  wait    = true
  timeout = 600

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.14.1"

  skip_crds = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [
    <<-EOT
    serviceAccount:
      name: karpenter
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}

    nodeSelector:
      karpenter.sh/controller: "true"

    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}

    controller:
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
        limits:
          cpu: 1
          memory: 1Gi
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd
  ]
}