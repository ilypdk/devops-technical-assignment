resource "kubectl_manifest" "karpenter_node_pool_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: x86-spot

    spec:
      template:
        metadata:
          labels:
            workload-arch: x86

        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            - key: kubernetes.io/arch
              operator: In
              values:
                - amd64

            - key: kubernetes.io/os
              operator: In
              values:
                - linux

            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - spot

            - key: karpenter.k8s.aws/instance-category
              operator: In
              values:
                - c
                - m
                - r

      limits:
        cpu: "100"

      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

resource "kubectl_manifest" "karpenter_node_pool_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: arm64-spot

    spec:
      template:
        metadata:
          labels:
            workload-arch: graviton

        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            - key: kubernetes.io/arch
              operator: In
              values:
                - arm64

            - key: kubernetes.io/os
              operator: In
              values:
                - linux

            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - spot

            - key: karpenter.k8s.aws/instance-category
              operator: In
              values:
                - c
                - m
                - r

      limits:
        cpu: "100"

      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}