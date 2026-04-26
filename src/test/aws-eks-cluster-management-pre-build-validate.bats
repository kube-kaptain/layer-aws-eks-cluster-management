#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load helpers

# Pre-build-validate uses yq to parse cluster yaml - skip all tests if not available
setup() {
  if ! command -v yq &>/dev/null; then
    skip "yq not installed"
  fi

  local base_dir
  base_dir=$(create_test_dir "eks-pre-validate")
  # Clean stale artifacts from previous runs (create_test_dir reuses paths)
  rm -rf "$base_dir"
  mkdir -p "$base_dir"
  export TEST_BASE_DIR="$base_dir"
  export GITHUB_OUTPUT="$base_dir/github-output"
  export OUTPUT_SUB_PATH="$base_dir/target"
  export CONFIG_SUB_PATH="$base_dir/src/config"

  # Create minimal required config files
  mkdir -p "$CONFIG_SUB_PATH"
  printf 'eu-west-1' > "$CONFIG_SUB_PATH/AwsRegion"
  printf 'vpc-0123456789abcdef0' > "$CONFIG_SUB_PATH/VpcId"
  printf 't3.medium' > "$CONFIG_SUB_PATH/NodegroupInstanceType"
  printf 'subnet-aaa11111111111111' > "$CONFIG_SUB_PATH/PrivateSubnetIdA"
  printf 'subnet-bbb22222222222222' > "$CONFIG_SUB_PATH/PrivateSubnetIdB"
  printf 'subnet-ccc33333333333333' > "$CONFIG_SUB_PATH/PrivateSubnetIdC"

  # Token defaults
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"

  # Single platform by default
  export DOCKER_PLATFORM="linux/amd64"
  export IMAGE_BUILD_COMMAND="podman"

  # Create canonical values (as written by prepare step)
  mkdir -p "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "eksctl" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  printf '%s' "managed" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"

  # Create context dir with a valid cluster.yaml containing tokens
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  mkdir -p "$context_dir"

  cat > "$context_dir/cluster.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${ProjectName}
  region: ${AwsRegion}
  version: "${KubernetesVersion}"
  annotations:
    kaptain.org/eks-cluster-security-group: "${ClusterSecurityGroup}"

vpc:
  id: ${VpcId}
  subnets:
    private:
      ${AwsRegion}a:
        id: ${PrivateSubnetIdA}
      ${AwsRegion}b:
        id: ${PrivateSubnetIdB}
      ${AwsRegion}c:
        id: ${PrivateSubnetIdC}

privateCluster:
  enabled: true

managedNodeGroups:
  - name: ${NodeGroupDefaultPrefix}
    instanceType: ${NodegroupInstanceTypeKaptainDefaultNg}
    privateNetworking: true
    volumeSize: ${NodegroupVolumeSizeKaptainDefaultNg}
    volumeType: ${NodegroupVolumeTypeKaptainDefaultNg}
    volumeEncrypted: ${NodegroupVolumeEncryptedKaptainDefaultNg}
    desiredCapacity: ${NodegroupDesiredCapacityKaptainDefaultNg}
    minSize: ${NodegroupMinSizeKaptainDefaultNg}
    maxSize: ${NodegroupMaxSizeKaptainDefaultNg}

addons:
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: vpc-cni
    version: latest
YAML
}

teardown() {
  :
}

# === Valid cluster yaml passes ===

@test "passes validation with correct token placement" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "all token checks passed"
}

# === metadata.name validation ===

@test "fails when metadata.name is missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  # Remove metadata.name
  yq -i 'del(.metadata.name)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.name is missing"
}

@test "fails when metadata.name is not the PROJECT_NAME token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.name = "hardcoded-name"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${ProjectName}'
}

# === metadata.region validation ===

@test "fails when metadata.region is missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.metadata.region)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.region is missing"
}

@test "fails when metadata.region is not the AWS_REGION token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.region = "eu-west-1"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${AwsRegion}'
}

# === metadata.version validation ===

@test "fails when metadata.version is missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.metadata.version)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.version is missing"
}

@test "fails when metadata.version is not the KUBERNETES_VERSION token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.version = "1.32"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${KubernetesVersion}'
}

# === vpc.id validation ===

@test "fails when vpc.id is missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.vpc.id)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "vpc.id is missing"
}

@test "fails when vpc.id is not the VPC_ID token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.id = "vpc-hardcoded123"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${VpcId}'
}

# === subnet token validation ===

@test "fails when subnet key is not region token + AZ letter" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  # Replace the correct key with a bad one
  yq -i '.vpc.subnets.private.badkey = .vpc.subnets.private."${AwsRegion}a"' "$context_dir/cluster.yaml"
  yq -i 'del(.vpc.subnets.private."${AwsRegion}a")' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be AWS_REGION token + single lowercase AZ letter"
}

@test "fails when private subnet id is hardcoded" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.subnets.private."${AwsRegion}a".id = "subnet-hardcoded123"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not match expected token pattern"
}

@test "passes when all subnet ids use correct token pattern" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

# === nodegroup name validation ===

@test "fails when nodegroup name does not start with prefix token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].name = "bad-nodegroup-name"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not start with NODE_GROUP_DEFAULT_PREFIX"
}

@test "passes when nodegroup name starts with prefix token" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when nodegroup name is missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.managedNodeGroups[0].name)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "name is missing"
}

# === Multiple nodegroups ===

@test "passes with multiple uniquely-named nodegroups" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups += [{"name": "${NodeGroupDefaultPrefix}-gpu", "instanceType": "g5.xlarge"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails with duplicate nodegroup names" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups += [{"name": "${NodeGroupDefaultPrefix}", "instanceType": "g5.xlarge"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicate nodegroup names"
}

# === Security group validation ===

@test "passes with vpc.securityGroup token when origin is eksctl" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "${VpcSecurityGroup}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when vpc.securityGroup is not the expected token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "sg-hardcoded123"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${VpcSecurityGroup}'
}

@test "fails when both vpc.securityGroup and vpc.controlPlaneSecurityGroupIDs present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "${VpcSecurityGroup}"' "$context_dir/cluster.yaml"
  printf '%s' "1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${VpcControlPlaneSecurityGroupId1}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "mutually exclusive"
}

@test "fails when adopted origin and no security group in yaml" {
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "adopted"
  assert_output_contains "required"
}

@test "passes when adopted origin with vpc.securityGroup token present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  yq -i '.vpc.securityGroup = "${VpcSecurityGroup}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "passes when adopted origin with vpc.controlPlaneSecurityGroupIDs present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  printf '%s' "1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${VpcControlPlaneSecurityGroupId1}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when cluster-origin canonical file missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "cluster-origin"
  assert_output_contains "not found"
}

# === Nodegroup type ===

@test "validates nodeGroups key when nodegroup-type is unmanaged" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  # Rename managedNodeGroups to nodeGroups in the test yaml
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when nodegroup-type expected-values file missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "nodegroup-type"
  assert_output_contains "not found"
}

# === controlPlaneSecurityGroupIDs token validation ===

@test "validates controlPlaneSecurityGroupIDs entries are correct tokens" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${VpcControlPlaneSecurityGroupId1}", "${VpcControlPlaneSecurityGroupId2}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when controlPlaneSecurityGroupIDs entry is wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${WrongToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${VpcControlPlaneSecurityGroupId1}'
}

@test "fails when controlPlaneSecurityGroupIDs count does not match expected" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${VpcControlPlaneSecurityGroupId1}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "1 entries but expected 2"
}

@test "fails when controlPlaneSecurityGroupIDs present but no count file" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["${SomeToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config not provided"
}

@test "fails when controlPlaneSecurityGroupIDs config provided but missing from YAML" {
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/control-plane-sg-ids-count"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config provided"
  assert_output_contains "missing from YAML"
}

# === Nodegroup securityGroups.attachIDs token validation ===

@test "passes when securityGroups.attachIDs has correct tokens" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["${NodegroupSecurityGroupsAttachIdKaptainDefaultNg1}", "${NodegroupSecurityGroupsAttachIdKaptainDefaultNg2}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when securityGroups.attachIDs count mismatches" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["${NodegroupSecurityGroupsAttachIdKaptainDefaultNg1}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "1 entries but expected 2"
}

@test "fails when securityGroups.attachIDs has wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["${WrongToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupSecurityGroupsAttachIdKaptainDefaultNg1}'
}

@test "fails when securityGroups.attachIDs present but no count file" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["${SomeToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config not provided"
}

@test "fails when securityGroups.attachIDs config provided but missing from YAML" {
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-sg-attach-ids-count-kaptaindefaultng"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config provided"
  assert_output_contains "missing from YAML"
}

# === VPC sharedNodeSecurityGroup token validation ===

@test "passes when sharedNodeSecurityGroup has correct token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"
  yq -i '.vpc.sharedNodeSecurityGroup = "${VpcSharedNodeSecurityGroup}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when sharedNodeSecurityGroup has wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"
  yq -i '.vpc.sharedNodeSecurityGroup = "sg-hardcoded123"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "vpc.sharedNodeSecurityGroup"
  assert_output_contains "must be exactly"
  assert_output_contains '${VpcSharedNodeSecurityGroup}'
}

# === Volume token validation ===

@test "passes when volumeType has correct token" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when volumeType token is wrong" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeType = "gp3"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeType"
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupVolumeTypeKaptainDefaultNg}'
}

@test "fails when volumeEncrypted token is wrong" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeEncrypted = "true"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeEncrypted"
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupVolumeEncryptedKaptainDefaultNg}'
}

@test "passes when volumeKmsKeyID has correct token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeKmsKeyID = "${NodegroupVolumeKmsKeyIdKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when volumeKmsKeyID has wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeKmsKeyID = "arn:aws:kms:eu-west-1:123:key/abc"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeKmsKeyID"
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupVolumeKmsKeyIdKaptainDefaultNg}'
}

# === Spot token validation ===

@test "passes when spot has correct token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].spot = "${NodegroupSpotKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when spot token is wrong" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].spot = "true"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "spot"
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupSpotKaptainDefaultNg}'
}

# === Direct-emit token blocking ===

@test "fails when NodegroupTaintsKaptainDefaultNg token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = "${NodegroupTaintsKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "NodegroupTaintsKaptainDefaultNg"
  assert_output_contains "not allowed"
}

@test "fails when NodegroupLabelsKaptainDefaultNg token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].labels = "${NodegroupLabelsKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "NodegroupLabelsKaptainDefaultNg"
  assert_output_contains "not allowed"
}

@test "fails when NodegroupTagsKaptainDefaultNg token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].tags = "${NodegroupTagsKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "NodegroupTagsKaptainDefaultNg"
  assert_output_contains "not allowed"
}

@test "fails when MetadataTags token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.tags = "${MetadataTags}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "MetadataTags"
  assert_output_contains "not allowed"
}

@test "fails when MetadataAnnotations token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.annotations = "${MetadataAnnotations}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "MetadataAnnotations"
  assert_output_contains "not allowed"
}

# === Comma-list source token blocking ===

@test "fails when CloudWatchClusterLoggingEnableTypes token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.cloudWatch.clusterLogging.enableTypes = "${CloudWatchClusterLoggingEnableTypes}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "CloudWatchClusterLoggingEnableTypes"
  assert_output_contains "numbered tokens instead"
}

@test "fails when AutoModeConfigNodePools token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.autoModeConfig.nodePools = "${AutoModeConfigNodePools}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "AutoModeConfigNodePools"
  assert_output_contains "numbered tokens instead"
}

@test "fails when VpcControlPlaneSecurityGroupIds token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = "${VpcControlPlaneSecurityGroupIds}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "VpcControlPlaneSecurityGroupIds"
  assert_output_contains "numbered tokens instead"
}

@test "fails when NodegroupSecurityGroupsAttachIdsKaptainDefaultNg token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = "${NodegroupSecurityGroupsAttachIdsKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "NodegroupSecurityGroupsAttachIdsKaptainDefaultNg"
  assert_output_contains "numbered tokens instead"
}

@test "fails when NodegroupAvailabilityZonesKaptainDefaultNg token found in template" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].availabilityZones = "${NodegroupAvailabilityZonesKaptainDefaultNg}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "NodegroupAvailabilityZonesKaptainDefaultNg"
  assert_output_contains "numbered tokens instead"
}

# === Nodegroup availabilityZones token validation ===

@test "passes when availabilityZones has correct tokens" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].availabilityZones = ["${NodegroupAvailabilityZoneKaptainDefaultNg1}", "${NodegroupAvailabilityZoneKaptainDefaultNg2}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when availabilityZones count mismatches" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].availabilityZones = ["${NodegroupAvailabilityZoneKaptainDefaultNg1}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "1 entries but expected 2"
}

@test "fails when availabilityZones has wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng"
  yq -i '.managedNodeGroups[0].availabilityZones = ["${WrongToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${NodegroupAvailabilityZoneKaptainDefaultNg1}'
}

@test "fails when availabilityZones present but no count file" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].availabilityZones = ["${SomeToken}"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config not provided"
}

@test "fails when availabilityZones config provided but missing from YAML" {
  printf '%s' "2" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-az-count-kaptaindefaultng"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "config provided"
  assert_output_contains "missing from YAML"
}

# === Cluster security group annotation validation ===

@test "fails when cluster-security-group annotation missing" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.metadata.annotations["kaptain.org/eks-cluster-security-group"])' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "kaptain.org/eks-cluster-security-group"
  assert_output_contains "missing"
}

@test "fails when cluster-security-group annotation is wrong token" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.annotations["kaptain.org/eks-cluster-security-group"] = "sg-hardcoded123"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
  assert_output_contains '${ClusterSecurityGroup}'
}

@test "passes when cluster-security-group annotation has correct token" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "all token checks passed"
}

# === Missing cluster.yaml ===

@test "fails when cluster.yaml not found in context dir" {
  rm "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "file not found"
}

# === Controlplane-only yaml validation ===

@test "validates controlplane-only yaml when present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  cat > "$context_dir/cluster-controlplane-only.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${ProjectName}
  region: ${AwsRegion}
  version: "${KubernetesVersion}"
  annotations:
    kaptain.org/eks-cluster-security-group: "${ClusterSecurityGroup}"

vpc:
  id: ${VpcId}

privateCluster:
  enabled: true

addons:
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: vpc-cni
    version: latest
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when controlplane-only yaml has wrong metadata.name" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  cat > "$context_dir/cluster-controlplane-only.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: wrong-name
  region: ${AwsRegion}
  version: "${KubernetesVersion}"
  annotations:
    kaptain.org/eks-cluster-security-group: "${ClusterSecurityGroup}"

vpc:
  id: ${VpcId}

addons:
  - name: coredns
    version: latest
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
}

# === Multi-platform validation ===

@test "validates both platform context dirs when multi-platform" {
  export DOCKER_PLATFORM="linux/amd64,linux/arm64"

  # Copy the valid cluster.yaml to both context dirs
  local amd_dir="$OUTPUT_SUB_PATH/docker-linux-amd64/substituted"
  local arm_dir="$OUTPUT_SUB_PATH/docker-linux-arm64/substituted"
  mkdir -p "$amd_dir" "$arm_dir"
  cp "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml" "$amd_dir/cluster.yaml"
  cp "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml" "$arm_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

# === Output messages ===

@test "outputs pre-build validate header" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "EKS Cluster Management Pre-Build Validate"
}

@test "outputs expected token strings" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains 'Expected PROJECT_NAME token: ${ProjectName}'
  assert_output_contains 'Expected AWS_REGION token: ${AwsRegion}'
  assert_output_contains 'Expected KUBERNETES_VERSION token: ${KubernetesVersion}'
  assert_output_contains 'Expected VPC_ID token: ${VpcId}'
  assert_output_contains 'Private subnet pattern: ${PrivateSubnetId?}'
}

# === Fail-complete behavior ===

@test "reports multiple validation errors before exiting" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.name = "wrong"' "$context_dir/cluster.yaml"
  yq -i '.metadata.region = "wrong"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.name"
  assert_output_contains "metadata.region"
  assert_output_contains "2 error(s)"
}

# === Additional nodegroup validation ===

@test "passes with valid base and additional nodegroup tokens" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"
  printf '%s' "KONG" > "$ev_dir/additional-nodegroup-suffixes"

  yq -i '.managedNodeGroups += [{"name": "${NodeGroupDefaultPrefixKong}", "instanceType": "${NodegroupInstanceTypeKong}", "volumeSize": "${NodegroupVolumeSizeKong}", "volumeType": "${NodegroupVolumeTypeKong}", "volumeEncrypted": "${NodegroupVolumeEncryptedKong}", "desiredCapacity": "${NodegroupDesiredCapacityKong}", "minSize": "${NodegroupMinSizeKong}", "maxSize": "${NodegroupMaxSizeKong}"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when additional nodegroup has wrong token suffix" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"
  printf '%s' "KONG" > "$ev_dir/additional-nodegroup-suffixes"

  yq -i '.managedNodeGroups += [{"name": "${NodeGroupDefaultPrefixWrong}", "instanceType": "${NodegroupInstanceTypeKong}", "volumeSize": "${NodegroupVolumeSizeKong}", "volumeType": "${NodegroupVolumeTypeKong}", "volumeEncrypted": "${NodegroupVolumeEncryptedKong}", "desiredCapacity": "${NodegroupDesiredCapacityKong}", "minSize": "${NodegroupMinSizeKong}", "maxSize": "${NodegroupMaxSizeKong}"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not start with NODE_GROUP_DEFAULT_PREFIX"
}

@test "fails when nodegroup count mismatches additional-nodegroup-count" {
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"
  printf '%s' "KONG" > "$ev_dir/additional-nodegroup-suffixes"

  # Only 1 nodegroup in YAML but expected 2 (1 base + 1 additional)
  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "entries but expected 2"
}

@test "fails when AdditionalNodegroups source token in YAML" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].additionalGroups = "${AdditionalNodegroups}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "AdditionalNodegroups"
  assert_output_contains "comma-separated source token"
}

@test "validates per-nodegroup sg-attach tokens on additional nodegroup" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"
  printf '%s' "KONG" > "$ev_dir/additional-nodegroup-suffixes"
  printf '%s' "2" > "$ev_dir/nodegroup-sg-attach-ids-count-kong"

  yq -i '.managedNodeGroups += [{"name": "${NodeGroupDefaultPrefixKong}", "instanceType": "${NodegroupInstanceTypeKong}", "volumeSize": "${NodegroupVolumeSizeKong}", "volumeType": "${NodegroupVolumeTypeKong}", "volumeEncrypted": "${NodegroupVolumeEncryptedKong}", "desiredCapacity": "${NodegroupDesiredCapacityKong}", "minSize": "${NodegroupMinSizeKong}", "maxSize": "${NodegroupMaxSizeKong}", "securityGroups": {"attachIDs": ["${NodegroupSecurityGroupsAttachIdKong1}", "${NodegroupSecurityGroupsAttachIdKong2}"]}}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-pre-build-validate"
  [ "$status" -eq 0 ]
}
