#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load helpers

# === Dataset infrastructure ===
#
# Instead of running the prepare script 219 times (once per test), we run it
# 5 times in setup_file() and cache the outputs. Success tests call use_dataset()
# to point at cached results. Failure and special tests still run individually.

setup_dataset_dir() {
  local name="$1"
  local base_dir
  base_dir="${DATASET_CACHE_DIR}/${name}"
  rm -rf "$base_dir"
  mkdir -p "$base_dir"

  export TEST_BASE_DIR="$base_dir"
  export GITHUB_OUTPUT="$base_dir/github-output"
  export OUTPUT_SUB_PATH="$base_dir/target"
  export CONFIG_SUB_PATH="$base_dir/src/config"
  export EKS_CLUSTER_YAML_SUB_PATH="$base_dir/src/eks"
  export SECRETS_SUB_PATH="$base_dir/src/secrets"

  mkdir -p "$CONFIG_SUB_PATH"
  printf 'eu-west-1' > "$CONFIG_SUB_PATH/AwsRegion"
  printf 'vpc-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcId"
  printf 't3.medium' > "$CONFIG_SUB_PATH/NodegroupInstanceType"
  printf 'arn:aws:kms:eu-west-1:123456789012:key/12345678-1234-1234-1234-123456789012' > "$CONFIG_SUB_PATH/SecretsEncryptionKeyArn"
  printf '123456789012' > "$CONFIG_SUB_PATH/AwsAccountId"
  printf 'sg-clusterdefault123456' > "$CONFIG_SUB_PATH/ClusterSecurityGroup"
  printf 'eksctl' > "$CONFIG_SUB_PATH/ClusterOrigin"
  printf 'managed' > "$CONFIG_SUB_PATH/NodegroupType"
  printf 'subnet-aaa11111111111111' > "$CONFIG_SUB_PATH/PrivateSubnetIdA"
  printf 'subnet-bbb22222222222222' > "$CONFIG_SUB_PATH/PrivateSubnetIdB"
  printf 'subnet-ccc33333333333333' > "$CONFIG_SUB_PATH/PrivateSubnetIdC"
  printf '32' > "$CONFIG_SUB_PATH/KubernetesMinorVersion"

  export VERSION="1.0.0"
  export PROJECT_NAME="test-cluster"
  export EKS_PRIVATE_NETWORKING="true"
  export EKS_PUBLIC_NETWORKING="false"
  export EKS_CILIUM_EBPF_NETWORKING="false"
  export DOCKER_PLATFORM="linux/amd64"
  export IMAGE_BUILD_COMMAND="podman"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"

  echo "$base_dir"
}

run_and_cache_dataset() {
  local name="$1"
  local cache_dir="${DATASET_CACHE_DIR}/.cache/${name}"
  mkdir -p "$cache_dir"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"

  printf '%s' "$status" > "$cache_dir/status"
  printf '%s' "$output" > "$cache_dir/output"
  printf '%s' "$OUTPUT_SUB_PATH" > "$cache_dir/output-sub-path"
  printf '%s' "$GITHUB_OUTPUT" > "$cache_dir/github-output-path"
  if [[ -f "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml" ]]; then
    printf '%s' "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml" > "$cache_dir/cluster-yaml"
  else
    printf '%s' "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/cluster.yaml" > "$cache_dir/cluster-yaml"
  fi
}

setup_file() {
  # Need to reload helpers in file-level scope
  load helpers

  export DATASET_CACHE_DIR
  DATASET_CACHE_DIR=$(create_test_dir "eks-datasets")
  rm -rf "$DATASET_CACHE_DIR"
  mkdir -p "$DATASET_CACHE_DIR"

  # --- Dataset 0: base (multi-platform, default config) ---
  setup_dataset_dir "base"
  export DOCKER_PLATFORM="linux/amd64,linux/arm64"
  run_and_cache_dataset "base"

  # --- Dataset 1: full (all optional features) ---
  setup_dataset_dir "full"
  export EKS_PUBLIC_NETWORKING="true"
  printf 'subnet-pub11111111111111' > "$CONFIG_SUB_PATH/PublicSubnetIdA"
  printf 'subnet-pub22222222222222' > "$CONFIG_SUB_PATH/PublicSubnetIdB"
  printf 'subnet-pub33333333333333' > "$CONFIG_SUB_PATH/PublicSubnetIdC"
  printf 'sg-aaa,sg-bbb' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"
  printf 'sg-aaa,sg-bbb' > "$CONFIG_SUB_PATH/NodegroupSecurityGroupsAttachIds"
  printf 'arn:aws:kms:eu-west-1:123456789012:key/12345678-1234-1234-1234-123456789012' > "$CONFIG_SUB_PATH/NodegroupVolumeKmsKeyId"
  printf 'true' > "$CONFIG_SUB_PATH/NodegroupPrivateNetworking"
  printf 'arn:aws:iam::123456789012:role/my-node-role' > "$CONFIG_SUB_PATH/NodegroupIamInstanceRoleArn"
  printf 'true' > "$CONFIG_SUB_PATH/PrivateClusterEnabled"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcSecurityGroup"
  # Remove VpcControlPlaneSecurityGroupIds since it's mutually exclusive with VpcSecurityGroup
  rm "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"
  printf 'false' > "$CONFIG_SUB_PATH/AutoModeConfigEnabled"
  printf '10.100.0.0/16' > "$CONFIG_SUB_PATH/NetworkConfigServiceIpV4Cidr"
  cat > "$CONFIG_SUB_PATH/MetadataTags" << 'EOF'
Environment: production
Team: "platform engineering"

kubernetes.io/cluster/${ProjectName}: owned
${ProjectName}/managed-by: kaptain
Enabled: true
Active: YES
Disabled: off
Override: null
Octal: 0777
Hex: 0x1F
Tilde: ~
QuotedBool: "true"
Other: 'false'
Normal: my-string-value
Duration: 1:30
Region: eu-west-1
EOF
  cat > "$CONFIG_SUB_PATH/NodegroupTags" << 'EOF'
CostCenter: '12345'
${ProjectName}/team: platform
Priority: 1
Weight: 3.5
Negative: -42
EOF
  cat > "$CONFIG_SUB_PATH/NodegroupLabels" << 'EOF'
role: worker
environment: production
${ProjectName}/role: worker
app.kubernetes.io/managed-by: ${ManagedBy}
gpu: false
tier: 0
EOF
  cat > "$CONFIG_SUB_PATH/NodegroupTaints" << 'YAML'
- key: workload
  value: kong
  effect: NoSchedule
- key: dedicated
  effect: NoExecute
- key: a
  effect: PreferNoSchedule
YAML
  cat > "$CONFIG_SUB_PATH/MetadataAnnotations" << 'EOF'
kaptain.org/team: platform-engineering
kaptain.org/cost-center: infrastructure
${ProjectName}/description: test cluster
kaptain.org/version: ${Version}
kaptain.org/enabled: true
kaptain.org/priority: 1
EOF
  printf 'arn:aws:iam::123456789012:role/coredns-role' > "$CONFIG_SUB_PATH/AddonsCorednsServiceAccountRoleArn"
  printf 'arn:aws:iam::123456789012:role/kube-proxy-role' > "$CONFIG_SUB_PATH/AddonsKubeProxyServiceAccountRoleArn"
  mkdir -p "$SECRETS_SUB_PATH"
  echo "encrypted-credentials" > "$SECRETS_SUB_PATH/aws-credentials.age"
  printf 'false' > "$CONFIG_SUB_PATH/IamWithOidc"
  printf 'api,audit' > "$CONFIG_SUB_PATH/CloudWatchClusterLoggingEnableTypes"
  printf '2' > "$CONFIG_SUB_PATH/KubernetesMajorVersion"
  printf 'false' > "$CONFIG_SUB_PATH/VpcClusterEndpointsPrivateAccess"
  printf 'true' > "$CONFIG_SUB_PATH/VpcClusterEndpointsPublicAccess"
  printf 'Bottlerocket' > "$CONFIG_SUB_PATH/NodegroupAmiFamily"
  printf '50' > "$CONFIG_SUB_PATH/NodegroupVolumeSize"
  printf 'io1' > "$CONFIG_SUB_PATH/NodegroupVolumeType"
  printf 'false' > "$CONFIG_SUB_PATH/NodegroupVolumeEncrypted"
  printf '2' > "$CONFIG_SUB_PATH/NodegroupUpdateConfigMaxUnavailable"
  printf '5' > "$CONFIG_SUB_PATH/NodegroupMinSize"
  printf '20' > "$CONFIG_SUB_PATH/NodegroupMaxSize"
  printf '10' > "$CONFIG_SUB_PATH/NodegroupDesiredCapacity"
  printf 'coredns,kube-proxy' > "$CONFIG_SUB_PATH/EksAddonsList"
  printf 'eu-west-1a,eu-west-1b,eu-west-1c' > "$CONFIG_SUB_PATH/NodegroupAvailabilityZones"
  printf 'true' > "$CONFIG_SUB_PATH/NodegroupSpot"
  printf 'kong,monitoring' > "$CONFIG_SUB_PATH/AdditionalNodegroups"
  printf 'g5.xlarge' > "$CONFIG_SUB_PATH/NodegroupInstanceTypeKong"
  printf 'sg-xxx' > "$CONFIG_SUB_PATH/NodegroupSecurityGroupsAttachIdsKong"
  printf 'false' > "$CONFIG_SUB_PATH/NodegroupSpotKong"
  run_and_cache_dataset "full"

  # --- Dataset 2: unmanaged (unmanaged nodegroup type + shared node SG) ---
  setup_dataset_dir "unmanaged"
  printf 'unmanaged' > "$CONFIG_SUB_PATH/NodegroupType"
  printf 'sg-0shared123456789' > "$CONFIG_SUB_PATH/VpcSharedNodeSecurityGroup"
  run_and_cache_dataset "unmanaged"

  # --- Dataset 3: adopted-mustache-upper-snake ---
  setup_dataset_dir "adopted-mustache-upper-snake"
  printf 'adopted' > "$CONFIG_SUB_PATH/ClusterOrigin"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcSecurityGroup"
  export TOKEN_DELIMITER_STYLE="mustache"
  export TOKEN_NAME_STYLE="UPPER_SNAKE"
  # Rename config files to UPPER_SNAKE style
  mv "$CONFIG_SUB_PATH/AwsRegion" "$CONFIG_SUB_PATH/AWS_REGION"
  mv "$CONFIG_SUB_PATH/VpcId" "$CONFIG_SUB_PATH/VPC_ID"
  mv "$CONFIG_SUB_PATH/NodegroupInstanceType" "$CONFIG_SUB_PATH/NODEGROUP_INSTANCE_TYPE"
  mv "$CONFIG_SUB_PATH/SecretsEncryptionKeyArn" "$CONFIG_SUB_PATH/SECRETS_ENCRYPTION_KEY_ARN"
  mv "$CONFIG_SUB_PATH/AwsAccountId" "$CONFIG_SUB_PATH/AWS_ACCOUNT_ID"
  mv "$CONFIG_SUB_PATH/ClusterSecurityGroup" "$CONFIG_SUB_PATH/CLUSTER_SECURITY_GROUP"
  mv "$CONFIG_SUB_PATH/ClusterOrigin" "$CONFIG_SUB_PATH/CLUSTER_ORIGIN"
  mv "$CONFIG_SUB_PATH/NodegroupType" "$CONFIG_SUB_PATH/NODEGROUP_TYPE"
  mv "$CONFIG_SUB_PATH/PrivateSubnetIdA" "$CONFIG_SUB_PATH/PRIVATE_SUBNET_ID_A"
  mv "$CONFIG_SUB_PATH/PrivateSubnetIdB" "$CONFIG_SUB_PATH/PRIVATE_SUBNET_ID_B"
  mv "$CONFIG_SUB_PATH/PrivateSubnetIdC" "$CONFIG_SUB_PATH/PRIVATE_SUBNET_ID_C"
  mv "$CONFIG_SUB_PATH/KubernetesMinorVersion" "$CONFIG_SUB_PATH/KUBERNETES_MINOR_VERSION"
  mv "$CONFIG_SUB_PATH/VpcSecurityGroup" "$CONFIG_SUB_PATH/VPC_SECURITY_GROUP"
  run_and_cache_dataset "adopted-mustache-upper-snake"

  # --- Dataset 4: cilium ---
  setup_dataset_dir "cilium"
  export EKS_CILIUM_EBPF_NETWORKING="true"
  run_and_cache_dataset "cilium"

}

# Restore cached dataset results for a success test
use_dataset() {
  local name="$1"
  local cache_dir="${DATASET_CACHE_DIR}/.cache/${name}"

  if [[ ! -d "$cache_dir" ]]; then
    echo "Unknown or uncached dataset: $name" >&2
    return 1
  fi

  status=$(< "$cache_dir/status")
  output=$(< "$cache_dir/output")
  OUTPUT_SUB_PATH=$(< "$cache_dir/output-sub-path")
  CLUSTER_YAML=$(< "$cache_dir/cluster-yaml")
  GITHUB_OUTPUT=$(< "$cache_dir/github-output-path")
}

setup() {
  # For failure/special tests that need fresh dirs
  local base_dir
  base_dir=$(create_test_dir "eks-prepare")
  rm -rf "$base_dir"
  mkdir -p "$base_dir"
  export TEST_BASE_DIR="$base_dir"
  export GITHUB_OUTPUT="$base_dir/github-output"
  export OUTPUT_SUB_PATH="$base_dir/target"
  export CONFIG_SUB_PATH="$base_dir/src/config"
  export EKS_CLUSTER_YAML_SUB_PATH="$base_dir/src/eks"
  export SECRETS_SUB_PATH="$base_dir/src/secrets"

  mkdir -p "$CONFIG_SUB_PATH"
  printf 'eu-west-1' > "$CONFIG_SUB_PATH/AwsRegion"
  printf 'vpc-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcId"
  printf 't3.medium' > "$CONFIG_SUB_PATH/NodegroupInstanceType"
  printf 'arn:aws:kms:eu-west-1:123456789012:key/12345678-1234-1234-1234-123456789012' > "$CONFIG_SUB_PATH/SecretsEncryptionKeyArn"
  printf '123456789012' > "$CONFIG_SUB_PATH/AwsAccountId"
  printf 'sg-clusterdefault123456' > "$CONFIG_SUB_PATH/ClusterSecurityGroup"
  printf 'eksctl' > "$CONFIG_SUB_PATH/ClusterOrigin"
  printf 'managed' > "$CONFIG_SUB_PATH/NodegroupType"
  printf 'subnet-aaa11111111111111' > "$CONFIG_SUB_PATH/PrivateSubnetIdA"
  printf 'subnet-bbb22222222222222' > "$CONFIG_SUB_PATH/PrivateSubnetIdB"
  printf 'subnet-ccc33333333333333' > "$CONFIG_SUB_PATH/PrivateSubnetIdC"
  printf '32' > "$CONFIG_SUB_PATH/KubernetesMinorVersion"

  export VERSION="1.0.0"
  export PROJECT_NAME="test-cluster"
  export EKS_PRIVATE_NETWORKING="true"
  export EKS_PUBLIC_NETWORKING="false"
  export EKS_CILIUM_EBPF_NETWORKING="false"
  export DOCKER_PLATFORM="linux/amd64"
  export IMAGE_BUILD_COMMAND="podman"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
}

teardown() {
  :
}

# === Required input validation (failure tests - individual runs) ===

@test "fails when VERSION is not set" {
  unset VERSION

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "VERSION is required"
}

@test "fails when PROJECT_NAME is not set" {
  unset PROJECT_NAME

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "PROJECT_NAME is required"
}

# === Config resolution (mixed) ===

@test "reads KUBERNETES_MINOR_VERSION from config file" {
  use_dataset "base"
  [ "$status" -eq 0 ]
  assert_output_contains "Kubernetes version: 1.32"
}

@test "fails when KubernetesMinorVersion config file missing" {
  rm "$CONFIG_SUB_PATH/KubernetesMinorVersion"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "KUBERNETES_MINOR_VERSION is required"
}

# === Required config file validation (failure tests) ===

@test "fails when AwsRegion config file missing" {
  rm "$CONFIG_SUB_PATH/AwsRegion"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "AWS_REGION"
  assert_output_contains "is required"
}

@test "fails when VpcId config file missing" {
  rm "$CONFIG_SUB_PATH/VpcId"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "VPC_ID"
  assert_output_contains "is required"
}

@test "fails when NodegroupInstanceType config file missing" {
  rm "$CONFIG_SUB_PATH/NodegroupInstanceType"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_INSTANCE_TYPE"
  assert_output_contains "is required"
}

@test "fails when SecretsEncryptionKeyArn config file missing" {
  rm "$CONFIG_SUB_PATH/SecretsEncryptionKeyArn"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "SECRETS_ENCRYPTION_KEY_ARN"
  assert_output_contains "is required"
}

@test "reports all missing config files before exiting" {
  rm "$CONFIG_SUB_PATH/AwsRegion"
  rm "$CONFIG_SUB_PATH/VpcId"
  rm "$CONFIG_SUB_PATH/NodegroupInstanceType"
  rm "$CONFIG_SUB_PATH/SecretsEncryptionKeyArn"
  rm "$CONFIG_SUB_PATH/AwsAccountId"
  rm "$CONFIG_SUB_PATH/ClusterOrigin"
  rm "$CONFIG_SUB_PATH/NodegroupType"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "AWS_REGION"
  assert_output_contains "VPC_ID"
  assert_output_contains "NODEGROUP_INSTANCE_TYPE"
  assert_output_contains "SECRETS_ENCRYPTION_KEY_ARN"
  assert_output_contains "AWS_ACCOUNT_ID"
  assert_output_contains "CLUSTER_ORIGIN"
  assert_output_contains "NODEGROUP_TYPE"
  assert_output_contains "7 error(s)"
}

# === Private networking config ===

@test "requires private subnet files when EKS_PRIVATE_NETWORKING=true" {
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdA"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdB"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdC"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "PRIVATE_SUBNET_ID_A"
  assert_output_contains "PRIVATE_SUBNET_ID_B"
  assert_output_contains "PRIVATE_SUBNET_ID_C"
}

@test "does not require private subnet files when EKS_PRIVATE_NETWORKING=false" {
  export EKS_PRIVATE_NETWORKING="false"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdA"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdB"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdC"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]
}

# === Public networking config ===

@test "requires public subnet files when EKS_PUBLIC_NETWORKING=true" {
  export EKS_PUBLIC_NETWORKING="true"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "PUBLIC_SUBNET_ID_A"
  assert_output_contains "PUBLIC_SUBNET_ID_B"
  assert_output_contains "PUBLIC_SUBNET_ID_C"
}

@test "succeeds with public subnet files when EKS_PUBLIC_NETWORKING=true" {
  use_dataset "full"
  [ "$status" -eq 0 ]
}

# === VPC security group config ===

@test "does not generate securityGroup by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"securityGroup"* ]]
}

# === Cluster origin ===

@test "fails when ClusterOrigin config file missing" {
  rm "$CONFIG_SUB_PATH/ClusterOrigin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "CLUSTER_ORIGIN"
  assert_output_contains "is required"
}

@test "fails when ClusterOrigin has invalid value" {
  printf 'terraform' > "$CONFIG_SUB_PATH/ClusterOrigin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "CLUSTER_ORIGIN"
  assert_output_contains "must be 'eksctl' or 'adopted'"
}

@test "succeeds with ClusterOrigin=eksctl without security group config" {
  use_dataset "base"
  [ "$status" -eq 0 ]
  assert_output_contains "Cluster origin: eksctl"
}

@test "succeeds with ClusterOrigin=adopted and VpcSecurityGroup present" {
  use_dataset "adopted-mustache-upper-snake"
  [ "$status" -eq 0 ]
  assert_output_contains "Cluster origin: adopted"
}

@test "succeeds with ClusterOrigin=adopted and VpcControlPlaneSecurityGroupIds present" {
  # This needs its own run - adopted + VpcControlPlaneSecurityGroupIds (not VpcSecurityGroup)
  printf 'adopted' > "$CONFIG_SUB_PATH/ClusterOrigin"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]
}

@test "fails with ClusterOrigin=adopted and no security group config" {
  printf 'adopted' > "$CONFIG_SUB_PATH/ClusterOrigin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "CLUSTER_ORIGIN=adopted"
  assert_output_contains "VPC_SECURITY_GROUP"
}

@test "fails when both VpcSecurityGroup and VpcControlPlaneSecurityGroupIds present" {
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcSecurityGroup"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "mutually exclusive"
}

@test "fails when both SG configs present even with adopted origin" {
  printf 'adopted' > "$CONFIG_SUB_PATH/ClusterOrigin"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcSecurityGroup"
  printf 'sg-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "mutually exclusive"
}

# === Nodegroup type ===

@test "fails when NodegroupType config file missing" {
  rm "$CONFIG_SUB_PATH/NodegroupType"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TYPE"
  assert_output_contains "is required"
}

@test "fails when NodegroupType has invalid value" {
  printf 'fargate' > "$CONFIG_SUB_PATH/NodegroupType"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TYPE"
  assert_output_contains "must be 'managed' or 'unmanaged'"
}

@test "generates managedNodeGroups when NodegroupType is managed" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "managedNodeGroups:" "cluster.yaml"
  [[ "$content" != *"nodeGroups:"* ]]
}

@test "generates nodeGroups when NodegroupType is unmanaged" {
  use_dataset "unmanaged"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "nodeGroups:" "cluster.yaml"
  [[ "$content" != *"managedNodeGroups:"* ]]
}

@test "generates updateConfig when NodegroupType is managed" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "updateConfig:" "cluster.yaml"
  assert_contains "$content" "maxUnavailable:" "cluster.yaml"
}

@test "does not generate updateConfig when NodegroupType is unmanaged" {
  use_dataset "unmanaged"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"updateConfig:"* ]]
  [[ "$content" != *"maxUnavailable:"* ]]
}

@test "does not write updateConfig default when NodegroupType is unmanaged" {
  use_dataset "unmanaged"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/docker/config/NodegroupUpdateConfigMaxUnavailable" ]
}

@test "fails when updateConfig config present with unmanaged NodegroupType" {
  printf 'unmanaged' > "$CONFIG_SUB_PATH/NodegroupType"
  printf '2' > "$CONFIG_SUB_PATH/NodegroupUpdateConfigMaxUnavailable"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE"
  assert_output_contains "not supported for unmanaged"
}

@test "writes nodegroup-type to expected-values" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type")" = "managed" ]
}

# === Control plane security group IDs generation ===

@test "generates controlPlaneSecurityGroupIDs with numbered tokens when config present" {
  # full dataset doesn't have VpcControlPlaneSecurityGroupIds (mutually exclusive with VpcSecurityGroup)
  # Need individual run
  printf 'sg-aaa,sg-bbb' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" "controlPlaneSecurityGroupIDs:" "cluster.yaml"
  assert_contains "$content" '- ${VpcControlPlaneSecurityGroupId1}' "cluster.yaml"
  assert_contains "$content" '- ${VpcControlPlaneSecurityGroupId2}' "cluster.yaml"
}

@test "expands VPC_CONTROL_PLANE_SECURITY_GROUP_IDS to numbered token files" {
  printf 'sg-aaa,sg-bbb,sg-ccc' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/docker/config/VpcControlPlaneSecurityGroupId1")" = "sg-aaa" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/VpcControlPlaneSecurityGroupId2")" = "sg-bbb" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/VpcControlPlaneSecurityGroupId3")" = "sg-ccc" ]
}

@test "writes control-plane-sg-ids-count to expected-values" {
  printf 'sg-aaa,sg-bbb' > "$CONFIG_SUB_PATH/VpcControlPlaneSecurityGroupIds"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count")" = "2" ]
}

@test "does not generate controlPlaneSecurityGroupIDs by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"controlPlaneSecurityGroupIDs"* ]]
}

@test "generates securityGroups.attachIDs with numbered tokens when config present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "securityGroups:" "cluster.yaml"
  assert_contains "$content" "attachIDs:" "cluster.yaml"
  assert_contains "$content" '- ${NodegroupSecurityGroupsAttachIdKaptainDefaultNg1}' "cluster.yaml"
  assert_contains "$content" '- ${NodegroupSecurityGroupsAttachIdKaptainDefaultNg2}' "cluster.yaml"
}

@test "expands NODEGROUP_SECURITY_GROUPS_ATTACH_IDS to numbered token files" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupSecurityGroupsAttachIdKaptainDefaultNg1")" = "sg-aaa" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupSecurityGroupsAttachIdKaptainDefaultNg2")" = "sg-bbb" ]
}

@test "writes nodegroup-sg-attach-ids-count to expected-values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng")" = "2" ]
}

@test "generates sharedNodeSecurityGroup when config present and unmanaged" {
  use_dataset "unmanaged"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'sharedNodeSecurityGroup: ${VpcSharedNodeSecurityGroup}' "cluster.yaml"
}

@test "does not generate sharedNodeSecurityGroup by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"sharedNodeSecurityGroup"* ]]
}

@test "fails when sharedNodeSecurityGroup config present with managed NodegroupType" {
  printf 'sg-0shared123456789' > "$CONFIG_SUB_PATH/VpcSharedNodeSecurityGroup"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "VPC_SHARED_NODE_SECURITY_GROUP"
  assert_output_contains "not supported for managed"
}

# === Volume config ===

@test "generates volumeType and volumeEncrypted in cluster.yaml" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'volumeType: ${NodegroupVolumeTypeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" 'volumeEncrypted: ${NodegroupVolumeEncryptedKaptainDefaultNg}' "cluster.yaml"
}

@test "generates volumeKmsKeyID when config present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'volumeKmsKeyID: ${NodegroupVolumeKmsKeyIdKaptainDefaultNg}' "cluster.yaml"
}

@test "does not generate volumeKmsKeyID by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"volumeKmsKeyID"* ]]
}

@test "fails when NODEGROUP_VOLUME_TYPE is invalid" {
  printf 'ssd' > "$CONFIG_SUB_PATH/NodegroupVolumeType"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_VOLUME_TYPE"
  assert_output_contains "must be one of"
}

@test "fails when NODEGROUP_VOLUME_ENCRYPTED is not true or false" {
  printf 'yes' > "$CONFIG_SUB_PATH/NodegroupVolumeEncrypted"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_VOLUME_ENCRYPTED"
  assert_output_contains "true"
  assert_output_contains "false"
}

@test "does not generate securityGroups.attachIDs by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"attachIDs"* ]]
}

# === Generated cluster.yaml content ===

@test "generates cluster.yaml with metadata tokens" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$CLUSTER_YAML" ]
  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'name: ${ProjectName}' "cluster.yaml"
  assert_contains "$content" 'region: ${AwsRegion}' "cluster.yaml"
  assert_contains "$content" 'version: "${KubernetesVersion}"' "cluster.yaml"
}

@test "generates cluster.yaml with vpc section" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'id: ${VpcId}' "cluster.yaml"
}

@test "generates cluster.yaml with clusterEndpoints section" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "clusterEndpoints:" "cluster.yaml"
  assert_contains "$content" 'privateAccess: ${VpcClusterEndpointsPrivateAccess}' "cluster.yaml"
  assert_contains "$content" 'publicAccess: ${VpcClusterEndpointsPublicAccess}' "cluster.yaml"
}

@test "generates cluster.yaml with private subnets when EKS_PRIVATE_NETWORKING=true" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "private:" "cluster.yaml"
  assert_contains "$content" '${PrivateSubnetIdA}' "cluster.yaml"
  assert_contains "$content" '${PrivateSubnetIdB}' "cluster.yaml"
  assert_contains "$content" '${PrivateSubnetIdC}' "cluster.yaml"
}

@test "generates cluster.yaml without private subnets when EKS_PRIVATE_NETWORKING=false" {
  export EKS_PRIVATE_NETWORKING="false"
  rm "$CONFIG_SUB_PATH/PrivateSubnetIdA" "$CONFIG_SUB_PATH/PrivateSubnetIdB" "$CONFIG_SUB_PATH/PrivateSubnetIdC"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  [[ "$content" != *"PrivateSubnet"* ]]
}

@test "generates cluster.yaml with public subnets when EKS_PUBLIC_NETWORKING=true" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "public:" "cluster.yaml"
  assert_contains "$content" '${PublicSubnetIdA}' "cluster.yaml"
  assert_contains "$content" '${PublicSubnetIdB}' "cluster.yaml"
  assert_contains "$content" '${PublicSubnetIdC}' "cluster.yaml"
}

@test "generates cluster.yaml with securityGroup token when config present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'securityGroup: ${VpcSecurityGroup}' "cluster.yaml"
}

# === Auto Mode config ===

@test "does not generate autoModeConfig by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"autoModeConfig"* ]]
}

@test "generates autoModeConfig when config file exists with false" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "autoModeConfig:" "cluster.yaml"
  assert_contains "$content" 'enabled: ${AutoModeConfigEnabled}' "cluster.yaml"
  [[ "$content" != *"nodePools"* ]]
}

@test "generates autoModeConfig with nodePools when enabled=true" {
  printf 'true' > "$CONFIG_SUB_PATH/AutoModeConfigEnabled"
  printf 'general-purpose,system' > "$CONFIG_SUB_PATH/AutoModeConfigNodePools"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" "autoModeConfig:" "cluster.yaml"
  assert_contains "$content" 'enabled: ${AutoModeConfigEnabled}' "cluster.yaml"
  assert_contains "$content" '- ${AutoModeConfigNodePool1}' "cluster.yaml"
  assert_contains "$content" '- ${AutoModeConfigNodePool2}' "cluster.yaml"

  [ "$(< "$OUTPUT_SUB_PATH/docker/config/AutoModeConfigNodePool1")" = "general-purpose" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/AutoModeConfigNodePool2")" = "system" ]
}

@test "fails when AutoModeConfigEnabled=true but AutoModeConfigNodePools missing" {
  printf 'true' > "$CONFIG_SUB_PATH/AutoModeConfigEnabled"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "AUTO_MODE_CONFIG_NODE_POOLS"
  assert_output_contains "is required"
}

# === Network config ===

@test "does not generate kubernetesNetworkConfig by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"kubernetesNetworkConfig"* ]]
}

@test "generates kubernetesNetworkConfig when config file exists" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "kubernetesNetworkConfig:" "cluster.yaml"
  assert_contains "$content" 'serviceIPv4CIDR: ${NetworkConfigServiceIpV4Cidr}' "cluster.yaml"
}

@test "generates cluster.yaml with managedNodeGroups section" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "managedNodeGroups:" "cluster.yaml"
  assert_contains "$content" '${NodeGroupDefaultPrefix}' "cluster.yaml"
  assert_contains "$content" '${NodegroupInstanceTypeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupAmiFamilyKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupVolumeSizeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupVolumeTypeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupVolumeEncryptedKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupDesiredCapacityKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupMinSizeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupMaxSizeKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" "updateConfig:" "cluster.yaml"
  assert_contains "$content" '${NodegroupUpdateConfigMaxUnavailableKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" "subnets:" "cluster.yaml nodegroup"
  assert_contains "$content" '${PrivateSubnetIdA}' "cluster.yaml nodegroup subnets"
  assert_contains "$content" '${PrivateSubnetIdB}' "cluster.yaml nodegroup subnets"
  assert_contains "$content" '${PrivateSubnetIdC}' "cluster.yaml nodegroup subnets"
  [[ "$content" != *"privateNetworking"* ]]
}

@test "generates privateNetworking in nodegroup when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'privateNetworking: ${NodegroupPrivateNetworkingKaptainDefaultNg}' "cluster.yaml"
}

@test "generates nodegroup subnets with public subnets when EKS_PUBLIC_NETWORKING=true" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${PublicSubnetIdA}' "cluster.yaml nodegroup subnets"
}

@test "does not generate nodegroup subnets when no networking subnets" {
  export EKS_PRIVATE_NETWORKING="false"
  export EKS_PUBLIC_NETWORKING="false"
  rm -f "$CONFIG_SUB_PATH/PrivateSubnetIdA" "$CONFIG_SUB_PATH/PrivateSubnetIdB" "$CONFIG_SUB_PATH/PrivateSubnetIdC"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  [[ "$content" != *"subnets:"* ]]
}

@test "generates iam.instanceRoleARN in nodegroup when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "iam:" "cluster.yaml nodegroup"
  assert_contains "$content" 'instanceRoleARN: ${NodegroupIamInstanceRoleArnKaptainDefaultNg}' "cluster.yaml"
}

@test "does not generate instanceRoleARN by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"instanceRoleARN"* ]]
}

@test "generates cluster.yaml with iam section" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "iam:" "cluster.yaml"
  assert_contains "$content" 'withOIDC: ${IamWithOidc}' "cluster.yaml"
}

@test "does not generate privateCluster section by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"privateCluster"* ]]
}

@test "generates privateCluster section when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "privateCluster:" "cluster.yaml"
  assert_contains "$content" 'enabled: ${PrivateClusterEnabled}' "cluster.yaml"
}

@test "generates cluster.yaml with cloudWatch section as block sequence" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "cloudWatch:" "cluster.yaml"
  assert_contains "$content" "clusterLogging:" "cluster.yaml"
  assert_contains "$content" "enableTypes:" "cluster.yaml"
  assert_contains "$content" '- ${CloudWatchClusterLoggingEnableType1}' "cluster.yaml"
  assert_contains "$content" '- ${CloudWatchClusterLoggingEnableType5}' "cluster.yaml"
}

@test "generates cluster.yaml with secretsEncryption section" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "secretsEncryption:" "cluster.yaml"
  assert_contains "$content" 'keyARN: ${SecretsEncryptionKeyArn}' "cluster.yaml"
}

# === Tags and labels ===

@test "generates fixed metadata tags by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'ManagedBy: "Kaptain aws-eks-cluster-management system"' "cluster.yaml"
  assert_contains "$content" 'ManagedByGitRepo: ${ProjectName}' "cluster.yaml"
}

@test "generates fixed nodegroup tags by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local count
  count=$(grep -c 'ManagedBy: "Kaptain aws-eks-cluster-management system"' "$CLUSTER_YAML")
  [ "$count" -eq 2 ]
}

@test "appends user metadata tags from config file" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "Environment: production" "cluster.yaml"
  assert_contains "$content" 'Team: "platform engineering"' "cluster.yaml"
  assert_contains "$content" 'ManagedBy: "Kaptain aws-eks-cluster-management system"' "cluster.yaml"
}

@test "fails when metadata tags contain reserved Name key" {
  cat > "$CONFIG_SUB_PATH/MetadataTags" << 'EOF'
Name: my-cluster-name
Environment: production
EOF

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "METADATA_TAGS"
  assert_output_contains "Name"
  assert_output_contains "reserved"
}

@test "appends user nodegroup tags from config file" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "CostCenter: '12345'" "cluster.yaml"
}

@test "fails when nodegroup tags contain reserved Name key" {
  cat > "$CONFIG_SUB_PATH/NodegroupTags" << 'EOF'
Name: my-custom-name
CostCenter: '12345'
EOF

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Name"
  assert_output_contains "reserved"
}

@test "generates nodegroup labels from config file" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "labels:" "cluster.yaml"
  assert_contains "$content" "role: worker" "cluster.yaml"
  assert_contains "$content" "environment: production" "cluster.yaml"
}

@test "does not generate nodegroup labels section when config absent" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"labels:"* ]]
}

# === Nodegroup taints ===

@test "generates taints when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "taints:" "cluster.yaml"
  assert_contains "$content" "key: workload" "cluster.yaml taints"
  assert_contains "$content" "value: kong" "cluster.yaml taints"
  assert_contains "$content" "effect: NoSchedule" "cluster.yaml taints"
}

@test "generates taints with multiple entries" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "key: workload" "cluster.yaml taints"
  assert_contains "$content" "key: dedicated" "cluster.yaml taints"
  assert_contains "$content" "effect: NoExecute" "cluster.yaml taints"
}

@test "does not generate taints when config absent" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"taints:"* ]]
}

@test "fails when taint missing key" {
  cat > "$CONFIG_SUB_PATH/NodegroupTaints" << 'YAML'
- value: kong
  effect: NoSchedule
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TAINTS"
  assert_output_contains "missing 'key'"
}

@test "fails when taint missing effect" {
  cat > "$CONFIG_SUB_PATH/NodegroupTaints" << 'YAML'
- key: workload
  value: kong
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TAINTS"
  assert_output_contains "missing 'effect'"
}

@test "fails when taint has invalid effect" {
  cat > "$CONFIG_SUB_PATH/NodegroupTaints" << 'YAML'
- key: workload
  value: kong
  effect: InvalidEffect
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TAINTS"
  assert_output_contains "must be one of"
}

@test "fails when taints have duplicate key+effect" {
  cat > "$CONFIG_SUB_PATH/NodegroupTaints" << 'YAML'
- key: workload
  value: kong
  effect: NoSchedule
- key: workload
  value: different
  effect: NoSchedule
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TAINTS"
  assert_output_contains "duplicate"
}

@test "passes with taint without value (key-only)" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "key: dedicated" "cluster.yaml taints"
  assert_contains "$content" "effect: NoExecute" "cluster.yaml taints"
}

@test "passes with all three valid taint effects" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "effect: NoSchedule" "cluster.yaml taints"
  assert_contains "$content" "effect: PreferNoSchedule" "cluster.yaml taints"
  assert_contains "$content" "effect: NoExecute" "cluster.yaml taints"
}

@test "fails with invalid YAML in taints file" {
  printf 'not: valid: yaml: [' > "$CONFIG_SUB_PATH/NodegroupTaints"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_TAINTS"
}

@test "fails with invalid metadata tag format" {
  printf 'bad tag format no colon' > "$CONFIG_SUB_PATH/MetadataTags"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "invalid tag at line 1"
}

@test "fails with invalid nodegroup tag format" {
  printf 'also bad' > "$CONFIG_SUB_PATH/NodegroupTags"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "invalid tag at line 1"
}

@test "accepts token placeholders in metadata tag keys" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'kubernetes.io/cluster/${ProjectName}: owned' "cluster.yaml"
}

@test "accepts token placeholders in nodegroup tag keys" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${ProjectName}/team: platform' "cluster.yaml"
}

@test "accepts token placeholders in nodegroup label keys" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${ProjectName}/role: worker' "cluster.yaml"
}

@test "accepts token placeholders in metadata annotation keys" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${ProjectName}/description: test cluster' "cluster.yaml"
}

@test "still rejects completely invalid tag format with tokens" {
  printf '${broken' > "$CONFIG_SUB_PATH/MetadataTags"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "invalid tag at line 1"
}

@test "skips blank lines in tag config files" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "Environment: production" "cluster.yaml"
  assert_contains "$content" 'Team: "platform engineering"' "cluster.yaml"
}

# === YAML auto-quoting ===

@test "auto-quotes boolean values in metadata tags" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'Enabled: "true"' "cluster.yaml"
  assert_contains "$content" 'Active: "YES"' "cluster.yaml"
  assert_contains "$content" 'Disabled: "off"' "cluster.yaml"
  assert_output_contains "auto-quoted YAML-unsafe value"
}

@test "auto-quotes numeric values in nodegroup tags" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'Priority: "1"' "cluster.yaml"
  assert_contains "$content" 'Weight: "3.5"' "cluster.yaml"
  assert_contains "$content" 'Negative: "-42"' "cluster.yaml"
}

@test "auto-quotes null and special values in metadata tags" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'Override: "null"' "cluster.yaml"
  assert_contains "$content" 'Octal: "0777"' "cluster.yaml"
  assert_contains "$content" 'Hex: "0x1F"' "cluster.yaml"
  assert_contains "$content" 'Tilde: "~"' "cluster.yaml"
}

@test "does not double-quote already-quoted values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'QuotedBool: "true"' "cluster.yaml"
  assert_contains "$content" "Other: 'false'" "cluster.yaml"
  assert_contains "$content" "Normal: my-string-value" "cluster.yaml"
}

@test "auto-quotes in nodegroup labels" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'gpu: "false"' "cluster.yaml"
  assert_contains "$content" 'tier: "0"' "cluster.yaml"
}

@test "auto-quotes sexagesimal values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'Duration: "1:30"' "cluster.yaml"
}

@test "does not quote safe string values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "Region: eu-west-1" "cluster.yaml"
}

# === Required AwsAccountId ===

@test "fails when AwsAccountId config file missing" {
  rm "$CONFIG_SUB_PATH/AwsAccountId"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "AWS_ACCOUNT_ID"
  assert_output_contains "is required"
}

@test "fails when ClusterSecurityGroup config file missing" {
  rm "$CONFIG_SUB_PATH/ClusterSecurityGroup"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "CLUSTER_SECURITY_GROUP"
  assert_output_contains "is required"
}

# === Annotations ===

@test "generates fixed annotation with AwsAccountId token" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "annotations:" "cluster.yaml"
  assert_contains "$content" 'kaptain.org/aws-account-id: "${AwsAccountId}"' "cluster.yaml"
}

@test "generates fixed annotation with ClusterSecurityGroup token" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'kaptain.org/eks-cluster-security-group: "${ClusterSecurityGroup}"' "cluster.yaml"
}

@test "appends user metadata annotations from config file" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "kaptain.org/team: platform-engineering" "cluster.yaml"
  assert_contains "$content" "kaptain.org/cost-center: infrastructure" "cluster.yaml"
  assert_contains "$content" 'kaptain.org/aws-account-id: "${AwsAccountId}"' "cluster.yaml"
}

@test "auto-quotes in metadata annotations" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'kaptain.org/enabled: "true"' "cluster.yaml"
  assert_contains "$content" 'kaptain.org/priority: "1"' "cluster.yaml"
  assert_output_contains "auto-quoted YAML-unsafe value"
}

@test "does not generate user annotations when config absent" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'kaptain.org/aws-account-id: "${AwsAccountId}"' "cluster.yaml"
  [[ "$content" != *"kaptain.org/team"* ]]
}

@test "generates cluster.yaml with addons" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "addons:" "cluster.yaml"
  assert_contains "$content" "name: coredns" "cluster.yaml"
  assert_contains "$content" "name: kube-proxy" "cluster.yaml"
  assert_contains "$content" "name: vpc-cni" "cluster.yaml"
  assert_contains "$content" "name: aws-ebs-csi-driver" "cluster.yaml"
  assert_contains "$content" "name: aws-efs-csi-driver" "cluster.yaml"
  assert_contains "$content" "version: latest" "cluster.yaml"
}

@test "adds serviceAccountRoleARN to addon when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'serviceAccountRoleARN: ${AddonsCorednsServiceAccountRoleArn}' "cluster.yaml"
}

@test "does not add serviceAccountRoleARN when config file absent" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"serviceAccountRoleARN"* ]]
}

@test "adds serviceAccountRoleARN only to matching addon" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  # kube-proxy has it
  assert_contains "$content" 'serviceAccountRoleARN: ${AddonsKubeProxyServiceAccountRoleArn}' "cluster.yaml"
  # Both addons have ARNs, so count should be 2
  local count
  count=$(echo "$content" | grep -c "serviceAccountRoleARN" || true)
  [ "$count" -eq 2 ]
}

# === Cilium eBPF networking ===

@test "generates controlplane-only yaml when EKS_CILIUM_EBPF_NETWORKING=true" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  [ -f "$CLUSTER_YAML" ]
  [ -f "$OUTPUT_SUB_PATH/docker/substituted/cluster-controlplane-only.yaml" ]
}

@test "cilium mode excludes kube-proxy and vpc-cni from cluster.yaml addons" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"name: kube-proxy"* ]]
  [[ "$content" != *"name: vpc-cni"* ]]
  assert_contains "$content" "name: coredns" "cluster.yaml"
}

@test "cilium mode includes all addons in controlplane-only yaml" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster-controlplane-only.yaml")
  assert_contains "$content" "name: coredns" "controlplane-only"
  assert_contains "$content" "name: kube-proxy" "controlplane-only"
  assert_contains "$content" "name: vpc-cni" "controlplane-only"
}

@test "cilium controlplane-only yaml has no managedNodeGroups" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster-controlplane-only.yaml")
  [[ "$content" != *"managedNodeGroups"* ]]
}

@test "does not generate controlplane-only yaml when EKS_CILIUM_EBPF_NETWORKING=false" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/docker/substituted/cluster-controlplane-only.yaml" ]
}

# === Three-tier file resolution (special tests - individual runs) ===

@test "uses cluster.yaml from context dir if already present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  mkdir -p "$context_dir"
  echo "pre-existing content" > "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$context_dir/cluster.yaml")
  assert_contains "$content" "pre-existing content" "cluster.yaml"
  assert_output_contains "already in context dir"
}

@test "copies cluster.yaml from EKS_CLUSTER_YAML_SUB_PATH when present" {
  mkdir -p "$EKS_CLUSTER_YAML_SUB_PATH"
  echo "custom cluster config" > "$EKS_CLUSTER_YAML_SUB_PATH/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" "custom cluster config" "cluster.yaml"
  assert_output_contains "copied from"
}

@test "generates cluster.yaml when not in context dir or source dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "generating from template"
  [ -f "$CLUSTER_YAML" ]
}

@test "copies controlplane-only yaml from source dir when present" {
  mkdir -p "$EKS_CLUSTER_YAML_SUB_PATH"
  echo "custom controlplane config" > "$EKS_CLUSTER_YAML_SUB_PATH/cluster-controlplane-only.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster-controlplane-only.yaml")
  assert_contains "$content" "custom controlplane config" "controlplane-only"
}

# === Secrets file handling ===

@test "copies aws-credentials.age when present in secrets dir" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker/substituted/aws-credentials.age" ]
}

@test "does not fail when aws-credentials.age is absent" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/docker/substituted/aws-credentials.age" ]
}

# === Dockerfile generation ===

@test "generates Dockerfile with correct FROM line" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/Dockerfile")
  assert_contains "$content" "FROM ghcr.io/kube-kaptain/aws/aws-eks-cluster-management:" "Dockerfile"
}

@test "generated Dockerfile copies cluster.yaml" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/Dockerfile")
  assert_contains "$content" "COPY cluster.yaml /kd/eks/" "Dockerfile"
}

@test "generated Dockerfile copies controlplane-only yaml when present" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/Dockerfile")
  assert_contains "$content" "COPY cluster-controlplane-only.yaml /kd/eks/" "Dockerfile"
}

@test "generated Dockerfile copies credentials when present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/Dockerfile")
  assert_contains "$content" "COPY aws-credentials.age /kd/secrets/" "Dockerfile"
}

@test "generated Dockerfile ends with USER kaptain" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/Dockerfile")
  assert_contains "$content" "USER kaptain" "Dockerfile"
}

@test "does not overwrite existing Dockerfile in context dir" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  mkdir -p "$context_dir"
  echo "FROM custom-image:latest" > "$context_dir/Dockerfile"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$context_dir/Dockerfile")
  assert_contains "$content" "FROM custom-image:latest" "Dockerfile"
}

@test "uses custom base image parts from env vars" {
  export EKS_BASE_IMAGE_REGISTRY="docker.io"
  export EKS_BASE_IMAGE_NAMESPACE="myorg"
  export EKS_BASE_IMAGE_NAME="custom-eks"
  export EKS_BASE_IMAGE_TAG="2.0"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/Dockerfile")
  assert_contains "$content" "FROM docker.io/myorg/custom-eks:2.0" "Dockerfile"
}

# === Nodegroup prefix ===

@test "nodegroup prefix contains k8s version components" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "k-1-32"
}

@test "nodegroup prefix contains version with dashes" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "v-1-0-0"
}

@test "nodegroup prefix starts with ng-" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "ng-"
}

@test "writes nodegroup prefix to output dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-prefix" ]
  local prefix
  prefix=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-prefix")
  [[ "$prefix" == ng-* ]]
  [[ "$prefix" == *-k-1-32-v-1-0-0 ]]
}

@test "writes kubernetes-version to output dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version" ]
  local version
  version=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version")
  [ "$version" = "1.32" ]
}

@test "copies cluster.yaml to with-tokens dir for inspection" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/with-tokens/cluster.yaml" ]
  local content
  content=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/with-tokens/cluster.yaml")
  assert_contains "$content" 'name: ${ProjectName}' "with-tokens cluster.yaml"
}

@test "copies controlplane-only yaml to with-tokens dir when generated" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/with-tokens/cluster-controlplane-only.yaml" ]
}

@test "does not copy controlplane-only yaml to with-tokens dir when not generated" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/with-tokens/cluster-controlplane-only.yaml" ]
}

@test "copies user-provided cluster.yaml to with-tokens dir" {
  mkdir -p "$EKS_CLUSTER_YAML_SUB_PATH"
  echo "custom user cluster config" > "$EKS_CLUSTER_YAML_SUB_PATH/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/with-tokens/cluster.yaml")
  assert_contains "$content" "custom user cluster config" "with-tokens cluster.yaml"
}

@test "writes KubernetesVersion to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/KubernetesVersion" ]
  local version
  version=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/KubernetesVersion")
  [ "$version" = "1.32" ]
}

@test "writes nodegroup prefix to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodeGroupDefaultPrefix" ]
  local prefix
  prefix=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodeGroupDefaultPrefix")
  [[ "$prefix" == ng-* ]]
}

# === Default token handling ===

@test "writes default IAM_WITH_OIDC to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/IamWithOidc" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/IamWithOidc")
  [ "$value" = "true" ]
}

@test "writes default VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/VpcClusterEndpointsPrivateAccess" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/VpcClusterEndpointsPrivateAccess")
  [ "$value" = "true" ]
}

@test "writes default VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/VpcClusterEndpointsPublicAccess" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/VpcClusterEndpointsPublicAccess")
  [ "$value" = "false" ]
}

@test "expands default CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES to numbered tokens" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType1" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType2" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType3" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType4" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType5" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType1")" = "api" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType2")" = "audit" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType3")" = "authenticator" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType4")" = "controllerManager" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/CloudWatchClusterLoggingEnableType5")" = "scheduler" ]
}

@test "does not overwrite user-provided IamWithOidc in CONFIG_SUB_PATH" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  assert_output_contains "IAM_WITH_OIDC: read from"
}

@test "expands user-provided CloudWatchClusterLoggingEnableTypes to numbered tokens" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  assert_output_contains "CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES: user config found"
  [ -f "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType1" ]
  [ -f "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType2" ]
  [ ! -f "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType3" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType1")" = "api" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType2")" = "audit" ]
}

@test "writes default NODEGROUP_AMI_FAMILY to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupAmiFamily" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupAmiFamily")
  [ "$value" = "AmazonLinux2023" ]
}

@test "writes default NODEGROUP_VOLUME_SIZE to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeSize" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeSize")
  [ "$value" = "20" ]
}

@test "writes default NODEGROUP_VOLUME_TYPE to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeType" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeType")
  [ "$value" = "gp3" ]
}

@test "writes default NODEGROUP_VOLUME_ENCRYPTED to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeEncrypted" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupVolumeEncrypted")
  [ "$value" = "true" ]
}

@test "writes default NODEGROUP_DESIRED_CAPACITY to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupDesiredCapacity" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupDesiredCapacity")
  [ "$value" = "3" ]
}

@test "writes default NODEGROUP_MIN_SIZE to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupMinSize" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupMinSize")
  [ "$value" = "3" ]
}

@test "writes default NODEGROUP_MAX_SIZE to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupMaxSize" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupMaxSize")
  [ "$value" = "12" ]
}

@test "writes default NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE to platform config dir" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupUpdateConfigMaxUnavailable" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupUpdateConfigMaxUnavailable")
  [ "$value" = "1" ]
}

@test "fails when NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE is zero" {
  printf '0' > "$CONFIG_SUB_PATH/NodegroupUpdateConfigMaxUnavailable"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "must be greater than 0"
}

@test "does not overwrite user-provided nodegroup sizing in CONFIG_SUB_PATH" {
  printf '5' > "$CONFIG_SUB_PATH/NodegroupDesiredCapacity"
  printf '2' > "$CONFIG_SUB_PATH/NodegroupMinSize"
  printf '20' > "$CONFIG_SUB_PATH/NodegroupMaxSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  assert_output_contains "NODEGROUP_DESIRED_CAPACITY: read from"
  assert_output_contains "NODEGROUP_MIN_SIZE: read from"
  assert_output_contains "NODEGROUP_MAX_SIZE: read from"
}

@test "config file overrides all defaultable tokens" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  assert_output_contains "KUBERNETES_MAJOR_VERSION: read from"
  assert_output_contains "IAM_WITH_OIDC: read from"
  assert_output_contains "VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS: read from"
  assert_output_contains "VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS: read from"
  assert_output_contains "CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES: user config found"
  assert_output_contains "NODEGROUP_AMI_FAMILY: read from"
  assert_output_contains "NODEGROUP_VOLUME_SIZE: read from"
  assert_output_contains "NODEGROUP_VOLUME_TYPE: read from"
  assert_output_contains "NODEGROUP_VOLUME_ENCRYPTED: read from"
  assert_output_contains "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE: read from"
  assert_output_contains "NODEGROUP_MIN_SIZE: read from"
  assert_output_contains "NODEGROUP_MAX_SIZE: read from"
  assert_output_contains "NODEGROUP_DESIRED_CAPACITY: read from"
  assert_output_contains "EKS_ADDONS_LIST: read from"

  [ "$(< "$OUTPUT_SUB_PATH/docker/config/KubernetesVersion")" = "2.32" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType1")" = "api" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType2")" = "audit" ]
  [ ! -f "$OUTPUT_SUB_PATH/docker/config/CloudWatchClusterLoggingEnableType3" ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "name: coredns" "cluster.yaml"
  assert_contains "$content" "name: kube-proxy" "cluster.yaml"
  [[ "$content" != *"name: vpc-cni"* ]]
}

@test "uses custom nodegroup sizing from env vars" {
  export NODEGROUP_DESIRED_CAPACITY="4"
  export NODEGROUP_MIN_SIZE="2"
  export NODEGROUP_MAX_SIZE="24"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker/config/NodegroupDesiredCapacity" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupDesiredCapacity")
  [ "$value" = "4" ]
}

@test "defaults NODEGROUP_DESIRED_CAPACITY to user-provided NODEGROUP_MIN_SIZE" {
  printf '5' > "$CONFIG_SUB_PATH/NodegroupMinSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker/config/NodegroupDesiredCapacity" ]
  local value
  value=$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupDesiredCapacity")
  [ "$value" = "5" ]
}

@test "fails when NODEGROUP_DESIRED_CAPACITY less than NODEGROUP_MIN_SIZE" {
  printf '1' > "$CONFIG_SUB_PATH/NodegroupDesiredCapacity"
  printf '3' > "$CONFIG_SUB_PATH/NodegroupMinSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_DESIRED_CAPACITY"
  assert_output_contains "must be >= NODEGROUP_MIN_SIZE"
}

@test "fails when NODEGROUP_DESIRED_CAPACITY greater than NODEGROUP_MAX_SIZE" {
  printf '20' > "$CONFIG_SUB_PATH/NodegroupDesiredCapacity"
  printf '12' > "$CONFIG_SUB_PATH/NodegroupMaxSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_DESIRED_CAPACITY"
  assert_output_contains "must be <= NODEGROUP_MAX_SIZE"
}

@test "fails when NODEGROUP_MIN_SIZE greater than NODEGROUP_MAX_SIZE" {
  printf '15' > "$CONFIG_SUB_PATH/NodegroupMinSize"
  printf '12' > "$CONFIG_SUB_PATH/NodegroupMaxSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_MIN_SIZE"
  assert_output_contains "must be <= NODEGROUP_MAX_SIZE"
}

@test "passes when desired equals min" {
  use_dataset "base"
  [ "$status" -eq 0 ]
}

@test "passes when desired equals max" {
  printf '12' > "$CONFIG_SUB_PATH/NodegroupDesiredCapacity"
  printf '12' > "$CONFIG_SUB_PATH/NodegroupMaxSize"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]
}

# === DOCKERFILE_SUBSTITUTION_FILES output ===

@test "outputs DOCKERFILE_SUBSTITUTION_FILES with cluster.yaml appended" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "DOCKERFILE_SUBSTITUTION_FILES=Dockerfile,cluster.yaml"
}

@test "outputs DOCKERFILE_SUBSTITUTION_FILES with both yamls when cilium enabled" {
  use_dataset "cilium"
  [ "$status" -eq 0 ]

  assert_output_contains "DOCKERFILE_SUBSTITUTION_FILES=Dockerfile,cluster.yaml,cluster-controlplane-only.yaml"
}

@test "writes DOCKERFILE_SUBSTITUTION_FILES to GITHUB_OUTPUT" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$GITHUB_OUTPUT" ]
  local gh_output
  gh_output=$(< "$GITHUB_OUTPUT")
  assert_contains "$gh_output" "DOCKERFILE_SUBSTITUTION_FILES=Dockerfile,cluster.yaml" "GITHUB_OUTPUT"
}

# === Multi-platform support (base dataset is multi-platform) ===

@test "creates context dirs for both platforms when multi-platform" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/cluster.yaml" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-arm64/substituted/cluster.yaml" ]
}

@test "creates config dirs for both platforms when multi-platform" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/KubernetesVersion" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-arm64/config/KubernetesVersion" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodeGroupDefaultPrefix" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-arm64/config/NodeGroupDefaultPrefix" ]
}

@test "generates Dockerfile for both platforms" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/substituted/Dockerfile" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-arm64/substituted/Dockerfile" ]
}

@test "writes defaults to both platform config dirs" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/docker-linux-amd64/config/NodegroupDesiredCapacity" ]
  [ -f "$OUTPUT_SUB_PATH/docker-linux-arm64/config/NodegroupDesiredCapacity" ]
}

# === Token style handling ===

@test "generates tokens with shell delimiter style by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${ProjectName}' "cluster.yaml"
  assert_contains "$content" '${AwsRegion}' "cluster.yaml"
  assert_contains "$content" '${KubernetesVersion}' "cluster.yaml"
  assert_contains "$content" '${IamWithOidc}' "cluster.yaml"
  assert_contains "$content" '${CloudWatchClusterLoggingEnableType1}' "cluster.yaml"
  assert_contains "$content" '${CloudWatchClusterLoggingEnableType5}' "cluster.yaml"
  assert_contains "$content" '${SecretsEncryptionKeyArn}' "cluster.yaml"
}

@test "generates tokens with mustache delimiter style" {
  use_dataset "adopted-mustache-upper-snake"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '{{ PROJECT_NAME }}' "cluster.yaml"
  assert_contains "$content" '{{ AWS_REGION }}' "cluster.yaml"
  assert_contains "$content" '{{ KUBERNETES_VERSION }}' "cluster.yaml"
  assert_contains "$content" '{{ IAM_WITH_OIDC }}' "cluster.yaml"
  assert_contains "$content" '{{ CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPE_1 }}' "cluster.yaml"
  assert_contains "$content" '{{ CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPE_5 }}' "cluster.yaml"
  assert_contains "$content" '{{ SECRETS_ENCRYPTION_KEY_ARN }}' "cluster.yaml"
}

@test "generates tokens with UPPER_SNAKE name style" {
  use_dataset "adopted-mustache-upper-snake"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '{{ PROJECT_NAME }}' "cluster.yaml"
  assert_contains "$content" '{{ AWS_REGION }}' "cluster.yaml"
  assert_contains "$content" '{{ KUBERNETES_VERSION }}' "cluster.yaml"

  [ -f "$OUTPUT_SUB_PATH/docker/config/KUBERNETES_VERSION" ]
  [ -f "$OUTPUT_SUB_PATH/docker/config/NODE_GROUP_DEFAULT_PREFIX" ]
}

@test "fails with invalid TOKEN_DELIMITER_STYLE" {
  export TOKEN_DELIMITER_STYLE="invalid"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Unknown substitution token style"
}

@test "fails with invalid TOKEN_NAME_STYLE" {
  export TOKEN_NAME_STYLE="invalid"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Unknown token name style"
}

# === Output messages ===

@test "outputs EKS prepare header" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "EKS Cluster Management Prepare"
}

@test "outputs base image info" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "Base image: ghcr.io/kube-kaptain/aws/aws-eks-cluster-management:"
}

@test "outputs completion message" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "EKS Cluster Management Prepare complete"
}

@test "outputs substitution files list" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  assert_output_contains "Substitution files: Dockerfile,cluster.yaml"
}

# === Custom addon list ===

@test "uses custom addon list from config file" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "name: coredns" "cluster.yaml"
  assert_contains "$content" "name: kube-proxy" "cluster.yaml"
  [[ "$content" != *"name: vpc-cni"* ]]
}

# === eksctl format ===

@test "generated yaml has correct eksctl apiVersion" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "apiVersion: eksctl.io/v1alpha5" "cluster.yaml"
  assert_contains "$content" "kind: ClusterConfig" "cluster.yaml"
}

# === Nodegroup availabilityZones ===

@test "generates availabilityZones when config file present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" "availabilityZones:" "cluster.yaml"
  assert_contains "$content" '- ${NodegroupAvailabilityZoneKaptainDefaultNg1}' "cluster.yaml"
  assert_contains "$content" '- ${NodegroupAvailabilityZoneKaptainDefaultNg2}' "cluster.yaml"
}

@test "does not generate availabilityZones by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"availabilityZones:"* ]]
}

@test "writes nodegroup-az-count to expected-values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng")" = "3" ]
}

@test "expands NODEGROUP_AVAILABILITY_ZONES to numbered token files" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupAvailabilityZoneKaptainDefaultNg1")" = "eu-west-1a" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupAvailabilityZoneKaptainDefaultNg2")" = "eu-west-1b" ]
  [ "$(< "$OUTPUT_SUB_PATH/docker/config/NodegroupAvailabilityZoneKaptainDefaultNg3")" = "eu-west-1c" ]
}

# === Nodegroup spot ===

@test "generates spot when config file present with true" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" 'spot: ${NodegroupSpotKaptainDefaultNg}' "cluster.yaml"
}

@test "generates spot when config file present with false" {
  # full dataset has spot=true, need individual run for spot=false
  printf 'false' > "$CONFIG_SUB_PATH/NodegroupSpot"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" 'spot: ${NodegroupSpotKaptainDefaultNg}' "cluster.yaml"
}

@test "does not generate spot by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  [[ "$content" != *"spot:"* ]]
}

@test "fails when NodegroupSpot is not true or false" {
  printf 'yes' > "$CONFIG_SUB_PATH/NodegroupSpot"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_SPOT must be 'true' or 'false'"
}

@test "fails when NodegroupSpot present with unmanaged nodegroup type" {
  printf 'unmanaged' > "$CONFIG_SUB_PATH/NodegroupType"
  printf 'true' > "$CONFIG_SUB_PATH/NodegroupSpot"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "NODEGROUP_SPOT is not supported for unmanaged nodegroups"
}

# === Additional nodegroups ===

@test "does not generate additional nodegroups by default" {
  use_dataset "base"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-count")" = "0" ]

  local ng_count
  # base is multi-platform, use first platform's cluster.yaml
  ng_count=$(yq '.managedNodeGroups | length' "$CLUSTER_YAML")
  [ "$ng_count" -eq 1 ]
}

@test "generates additional nodegroups when AdditionalNodegroups config present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-count")" = "2" ]

  local ng_count
  ng_count=$(yq '.managedNodeGroups | length' "$CLUSTER_YAML")
  [ "$ng_count" -eq 3 ]
}

@test "additional nodegroup inherits base instanceType when no override" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodegroupInstanceTypeMonitoring}' "cluster.yaml"
}

@test "additional nodegroup uses suffixed config when present" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodegroupInstanceTypeKong}' "cluster.yaml"
}

@test "additional nodegroup inherits base volumeSize default" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodegroupVolumeSizeKong}' "cluster.yaml"
}

@test "additional nodegroup name has correct suffix" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodeGroupDefaultPrefixKong}' "cluster.yaml"
}

@test "writes additional-nodegroup-count to expected-values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-count" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-count")" = "2" ]
}

@test "writes additional-nodegroup-suffixes to expected-values" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-suffixes" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/additional-nodegroup-suffixes")" = "KONG,MONITORING" ]
}

@test "writes per-nodegroup expected-values with suffix" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  [ -f "$ev_dir/has-volume-kms-key-id-kaptaindefaultng" ]
  [ -f "$ev_dir/has-volume-kms-key-id-kong" ]
  [ -f "$ev_dir/has-spot-kong" ]
  [ -f "$ev_dir/has-sg-attach-ids-kong" ]
  [ -f "$ev_dir/has-availability-zones-kong" ]
}

@test "accepts hyphenated suffix like kong-1" {
  printf 'kong-1' > "$CONFIG_SUB_PATH/AdditionalNodegroups"
  printf 't3.large' > "$CONFIG_SUB_PATH/NodegroupInstanceTypeKong1"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" '${NodegroupInstanceTypeKong1}' "cluster.yaml"
  assert_contains "$content" '${NodeGroupDefaultPrefixKong1}' "cluster.yaml"
  local prefix_val
  prefix_val=$(< "$OUTPUT_SUB_PATH/docker/config/NodeGroupDefaultPrefixKong1")
  [[ "$prefix_val" == *"-kong-1" ]]
}

@test "accepts digit-starting suffix like 1-kong" {
  printf '1-kong' > "$CONFIG_SUB_PATH/AdditionalNodegroups"
  printf 't3.large' > "$CONFIG_SUB_PATH/NodegroupInstanceType1Kong"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  assert_contains "$content" '${NodegroupInstanceType1Kong}' "cluster.yaml"
  assert_contains "$content" '${NodeGroupDefaultPrefix1Kong}' "cluster.yaml"
  local prefix_val
  prefix_val=$(< "$OUTPUT_SUB_PATH/docker/config/NodeGroupDefaultPrefix1Kong")
  [[ "$prefix_val" == *"-1-kong" ]]
}

@test "rejects suffix starting with hyphen" {
  printf '%s' '-kong' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "rejects suffix ending with hyphen" {
  printf 'kong-' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "rejects suffix with consecutive hyphens" {
  printf 'kong--gpu' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "rejects suffix with special characters" {
  printf 'kong.gpu' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "rejects suffix with uppercase" {
  printf 'Kong' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "rejects suffix with underscore" {
  printf 'kong_gpu' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "lowercase alphanumeric"
}

@test "fails with duplicate additional nodegroup suffixes" {
  printf 'kong,kong' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicate suffixes"
}

@test "additional nodegroup inherits optional sg-attach from base" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodegroupSecurityGroupsAttachIdKaptainDefaultNg1}' "cluster.yaml"
  assert_contains "$content" '${NodegroupSecurityGroupsAttachIdKong1}' "cluster.yaml"
  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kong" ]
}

@test "additional nodegroup gets own suffixed comma-list when overridden" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng")" = "2" ]
  [ "$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kong")" = "1" ]
}

@test "additional nodegroup inherits labels from base" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  [ "$(< "$ev_dir/has-labels-kaptaindefaultng")" = "true" ]
  [ "$(< "$ev_dir/has-labels-kong")" = "true" ]
}

@test "additional nodegroup spot inherits from base when managed" {
  use_dataset "full"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$CLUSTER_YAML")
  assert_contains "$content" '${NodegroupSpotKaptainDefaultNg}' "cluster.yaml"
  assert_contains "$content" '${NodegroupSpotKong}' "cluster.yaml"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  [ "$(< "$ev_dir/has-spot-kaptaindefaultng")" = "true" ]
  [ "$(< "$ev_dir/has-spot-kong")" = "true" ]
}

@test "additional nodegroup spot override with own value" {
  printf 'kong' > "$CONFIG_SUB_PATH/AdditionalNodegroups"
  printf 'false' > "$CONFIG_SUB_PATH/NodegroupSpotKong"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -eq 0 ]

  local content
  content=$(< "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml")
  # Base has no spot, kong has spot
  [[ "$content" != *'spot: ${NodegroupSpotKaptainDefaultNg}'* ]]
  assert_contains "$content" '${NodegroupSpotKong}' "cluster.yaml"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  [ "$(< "$ev_dir/has-spot-kaptaindefaultng")" = "false" ]
  [ "$(< "$ev_dir/has-spot-kong")" = "true" ]
}

# === Kaptain prefix rejection ===

@test "fails with additional nodegroup suffix starting with kaptain" {
  printf 'kaptainspecial' > "$CONFIG_SUB_PATH/AdditionalNodegroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "must not start with 'kaptain'"
}

# === Unrecognised config file detection ===

@test "fails when unrecognised config file exists" {
  printf 'something' > "$CONFIG_SUB_PATH/NodeGrupTypo"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Unrecognised config file"
  assert_output_contains "NodeGrupTypo"
}

@test "fails when multiple unrecognised config files exist" {
  printf 'something' > "$CONFIG_SUB_PATH/NodeGrupTypo"
  printf 'something' > "$CONFIG_SUB_PATH/AdditionalNodeGroups"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Unrecognised config file"
  assert_output_contains "NodeGrupTypo"
  assert_output_contains "AdditionalNodeGroups"
  assert_output_contains "2 unrecognised config file(s)"
}
