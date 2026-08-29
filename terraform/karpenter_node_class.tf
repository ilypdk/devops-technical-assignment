resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default

    spec:
      role: ${module.karpenter.node_iam_role_name}

      amiSelectorTerms:
        - alias: al2023@latest

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 30Gi
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true

      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 1
        httpTokens: required

      tags:
        Project: eks-karpenter-poc
        ManagedBy: Karpenter
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}