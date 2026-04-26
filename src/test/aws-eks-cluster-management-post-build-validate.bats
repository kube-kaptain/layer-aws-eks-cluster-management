#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load helpers

# Create a mock docker that returns sha256sum output matching disk files
# when called with "run", and logs all calls for assertion
setup_eks_mock_docker() {
  export MOCK_DOCKER_CALLS=$(create_test_dir "mock-docker")/calls.log
  mkdir -p "$MOCK_BIN_DIR"
  cat > "$MOCK_BIN_DIR/docker" << 'MOCKDOCKER'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_DOCKER_CALLS"
if [[ "$1" == "run" ]]; then
  # Find the sha256sum command in the -c arg
  for i in $(seq 1 $#); do
    arg="${!i}"
    if [[ "$arg" == "-c" ]]; then
      next=$((i + 1))
      cmd="${!next}"
      if [[ "$cmd" == sha256sum* ]]; then
        # Extract file paths and compute checksums from disk equivalents
        for image_path in ${cmd#sha256sum}; do
          filename="${image_path##*/}"
          disk_file="${MOCK_DOCKER_CONTEXT_DIR}/${filename}"
          if [[ -f "$disk_file" ]]; then
            checksum=$(sha256sum "$disk_file" | cut -d' ' -f1)
            echo "${checksum}  ${image_path}"
          fi
        done
        exit 0
      fi
    fi
  done
  exit 0
fi
if [[ "$1" == "manifest" && "$2" == "inspect" ]]; then
  if [[ "${MOCK_DOCKER_MANIFEST_EXISTS:-false}" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi
exit 0
MOCKDOCKER
  chmod +x "$MOCK_BIN_DIR/docker"
  cp "$MOCK_BIN_DIR/docker" "$MOCK_BIN_DIR/podman"
  chmod +x "$MOCK_BIN_DIR/podman"
  export PATH="$MOCK_BIN_DIR:$PATH"
}

# Post-build-validate uses yq and docker - skip all tests if yq not available
setup() {
  if ! command -v yq &>/dev/null; then
    skip "yq not installed"
  fi

  local base_dir
  base_dir=$(create_test_dir "eks-post-validate")
  # Clean stale artifacts from previous runs (create_test_dir reuses paths)
  rm -rf "$base_dir"
  mkdir -p "$base_dir"
  export TEST_BASE_DIR="$base_dir"
  export GITHUB_OUTPUT="$base_dir/github-output"
  export OUTPUT_SUB_PATH="$base_dir/target"
  export CONFIG_SUB_PATH="$base_dir/src/config"

  # Required env vars
  export IMAGE_BUILD_COMMAND="podman"
  export BUILD_MODE="build_server"
  export DOCKER_TAG="1.0.0"
  export DOCKER_IMAGE_NAME="test-cluster"
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kube-kaptain"

  # Token defaults
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"

  # Single platform by default
  export DOCKER_PLATFORM="linux/amd64"

  # Create canonical value files (as written by prepare step)
  local nodegroup_prefix="ng-20260302-k-1-32-v-1-0-0"
  mkdir -p "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "test-cluster" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/project-name"
  printf '%s' "eu-west-1" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/aws-region"
  printf '%s' "1.32" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version"
  printf '%s' "$nodegroup_prefix" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-prefix"
  printf '%s' "eksctl" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  printf '%s' "managed" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"

  # Create context dir with substituted cluster.yaml (tokens already replaced)
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  mkdir -p "$context_dir"
  export MOCK_DOCKER_CONTEXT_DIR="$context_dir"

  cat > "$context_dir/cluster.yaml" << YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: test-cluster
  region: eu-west-1
  version: "1.32"
  tags:
    ManagedBy: "Kaptain aws-eks-cluster-management system"
    ManagedByGitRepo: test-cluster
  annotations:
    kaptain.org/aws-account-id: "123456789012"
    kaptain.org/eks-cluster-security-group: "sg-0abc123def456789a"

vpc:
  id: vpc-0123456789abcdef0
  subnets:
    private:
      eu-west-1a:
        id: subnet-aaa11111111111111
      eu-west-1b:
        id: subnet-bbb22222222222222
      eu-west-1c:
        id: subnet-ccc33333333333333

privateCluster:
  enabled: true

managedNodeGroups:
  - name: ${nodegroup_prefix}
    instanceType: t3.medium
    privateNetworking: true
    volumeSize: 20
    volumeType: gp3
    volumeEncrypted: true
    desiredCapacity: 1
    minSize: 3
    maxSize: 12
    labels:
      role: worker
    tags:
      ManagedBy: "Kaptain aws-eks-cluster-management system"
      ManagedByGitRepo: test-cluster

addons:
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: vpc-cni
    version: latest
YAML

  # Mock docker that returns matching sha256sum output for image integrity checks
  setup_eks_mock_docker
}

teardown() {
  :
}

# === Phase 1: Substituted file validation ===

@test "passes validation with correctly substituted cluster.yaml" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "all checks passed"
}

@test "fails when unsubstituted tokens remain" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.name = "${ProjectName}"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "unsubstituted tokens found"
}

@test "fails when metadata.name does not match canonical project-name" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.name = "wrong-cluster"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
}

@test "fails when metadata.region does not match canonical aws-region" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.region = "us-east-1"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
}

@test "fails when metadata.region is not a valid AWS region format" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  # Set both the canonical file and yaml to the same bad value
  printf '%s' "not-a-region" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/aws-region"
  yq -i '.metadata.region = "not-a-region"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like an AWS region"
}

# === metadata.version validation ===

@test "fails when metadata.version does not match canonical kubernetes-version" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.version = "1.31"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be exactly"
}

@test "fails when metadata.version minor part is less than 2 digits" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "1.9" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version"
  yq -i '.metadata.version = "1.9"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "minor is at least 2 digits"
}

@test "passes when metadata.version minor part has 3 digits" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "1.100" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version"
  yq -i '.metadata.version = "1.100"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

# === vpc.id validation ===

@test "fails when vpc.id does not look like a VPC ID" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.id = "not-a-vpc-id"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like a VPC ID"
}

# === subnet id validation ===

@test "fails when subnet key is not region + AZ letter" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.subnets.private.badkey = .vpc.subnets.private."eu-west-1a"' "$context_dir/cluster.yaml"
  yq -i 'del(.vpc.subnets.private."eu-west-1a")' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "must be region + single AZ letter"
}

@test "fails when subnet id does not look like a subnet ID" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.subnets.private."eu-west-1a".id = "not-a-subnet"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like a subnet ID"
}

@test "fails when nodegroup name does not start with computed prefix" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].name = "wrong-prefix-name"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not start with nodegroup prefix"
}

@test "fails with duplicate nodegroup names in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local prefix
  prefix=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-prefix")
  yq -i ".managedNodeGroups += [{\"name\": \"${prefix}\", \"instanceType\": \"g5.xlarge\"}]" "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "duplicate nodegroup names"
}

@test "fails when cluster.yaml not found" {
  rm "$OUTPUT_SUB_PATH/docker/substituted/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "file not found"
}

@test "fails when kubernetes-version file is missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/kubernetes-version"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "kubernetes-version"
  assert_output_contains "not found"
}

@test "fails when nodegroup-prefix file is missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-prefix"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "nodegroup-prefix"
  assert_output_contains "not found"
}

# === Phase 2: Image integrity ===

@test "runs image integrity check with mock docker" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "Validating image integrity"
  assert_output_contains "image checksum matches disk"
}

@test "calls docker run for image integrity check" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"

  # Mock docker logs all calls - check it was called with run
  assert_docker_called "run"
}

# === Canonical value files ===

@test "fails when project-name file is missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/project-name"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "project-name"
  assert_output_contains "not found"
}

@test "fails when aws-region file is missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/aws-region"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "aws-region"
  assert_output_contains "not found"
}

# === Controlplane-only yaml validation ===

@test "validates controlplane-only yaml when present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"

  cat > "$context_dir/cluster-controlplane-only.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: test-cluster
  region: eu-west-1
  version: "1.32"
  annotations:
    kaptain.org/eks-cluster-security-group: "sg-0abc123def456789a"

vpc:
  id: vpc-0123456789abcdef0

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

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when controlplane-only yaml has unsubstituted tokens" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"

  cat > "$context_dir/cluster-controlplane-only.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${ProjectName}
  region: eu-west-1
  version: "1.32"

addons:
  - name: coredns
    version: latest
YAML

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "unsubstituted tokens found"
}

# === Substituted yaml copy to canonical dir ===

@test "copies substituted cluster.yaml to substituted dir" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/substituted/cluster.yaml" ]
  local content
  content=$(< "$OUTPUT_SUB_PATH/aws-eks-cluster-management/substituted/cluster.yaml")
  assert_contains "$content" "name: test-cluster" "substituted cluster.yaml"
}

@test "copies substituted controlplane-only yaml when present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"

  cat > "$context_dir/cluster-controlplane-only.yaml" << 'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: test-cluster
  region: eu-west-1
  version: "1.32"
  annotations:
    kaptain.org/eks-cluster-security-group: "sg-0abc123def456789a"

vpc:
  id: vpc-0123456789abcdef0

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

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/substituted/cluster-controlplane-only.yaml" ]
}

@test "does not copy controlplane-only yaml to substituted dir when not present" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/aws-eks-cluster-management/substituted/cluster-controlplane-only.yaml" ]
}

# === Output messages ===

@test "outputs post-build validate header" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"

  assert_output_contains "EKS Cluster Management Post-Build Validate"
  assert_output_contains "Project name: test-cluster"
  assert_output_contains "AWS region: eu-west-1"
  assert_output_contains "Kubernetes version: 1.32"
}

# === Fail-complete behavior ===

@test "reports multiple validation errors before exiting" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.name = "wrong-name"' "$context_dir/cluster.yaml"
  yq -i '.metadata.region = "not-valid"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.name"
  assert_output_contains "metadata.region"
}

# === YAML value type validation ===

@test "fails when metadata tag value is not a string" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.tags.Enabled = true' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.tags"
  assert_output_contains "not a string"
  assert_output_contains "Enabled"
}

@test "fails when metadata annotation value is not a string" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.annotations."kaptain.org/priority" = 42' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.annotations"
  assert_output_contains "not a string"
  assert_output_contains "kaptain.org/priority"
}

@test "fails when cluster-security-group annotation missing from substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i 'del(.metadata.annotations["kaptain.org/eks-cluster-security-group"])' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "kaptain.org/eks-cluster-security-group"
  assert_output_contains "missing"
}

@test "fails when cluster-security-group annotation is not sg-hex format" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.annotations["kaptain.org/eks-cluster-security-group"] = "not-a-sg"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "kaptain.org/eks-cluster-security-group"
  assert_output_contains "does not look like a security group ID"
}

@test "passes when cluster-security-group annotation is sg-known-after-creation" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.annotations["kaptain.org/eks-cluster-security-group"] = "sg-known-after-creation"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "passes with valid securityGroups.attachIDs on nodegroup" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["sg-0aaa111bbb222ccc3", "sg-0ddd444eee555fff6"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "securityGroups.attachIDs"
  assert_output_contains "2 entries"
}

@test "fails when securityGroups.attachIDs entry is not sg-hex" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].securityGroups.attachIDs = ["sg-0aaa111bbb222ccc3", "not-a-sg"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like a security group ID"
}

@test "fails when nodegroup label value is not a string" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].labels.gpu = false' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "managedNodeGroups[0].labels"
  assert_output_contains "not a string"
  assert_output_contains "gpu"
}

@test "fails when nodegroup tag value is not a string" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].tags.Priority = 1' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "managedNodeGroups[0].tags"
  assert_output_contains "not a string"
  assert_output_contains "Priority"
}

@test "fails when nodegroup tags contain reserved Name key" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].tags.Name = "my-custom-name"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "Name"
  assert_output_contains "reserved"
}

@test "fails when metadata tags contain reserved Name key" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.tags.Name = "my-cluster-name"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "metadata.tags.Name"
  assert_output_contains "reserved"
}

# === Security group validation ===

@test "passes with vpc.securityGroup when origin is eksctl" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "sg-0123456789abcdef0"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "vpc.securityGroup: sg-"
}

@test "fails when vpc.securityGroup is not sg-hex format" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "not-a-sg-id"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like a security group ID"
}

@test "fails when both vpc.securityGroup and vpc.controlPlaneSecurityGroupIDs present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.securityGroup = "sg-0123456789abcdef0"' "$context_dir/cluster.yaml"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["sg-aaaa1111bbbb2222c"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "mutually exclusive"
}

@test "fails when adopted origin and no security group in yaml" {
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "adopted"
  assert_output_contains "required"
}

@test "passes when adopted origin with vpc.securityGroup present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  yq -i '.vpc.securityGroup = "sg-0123456789abcdef0"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "passes when adopted origin with vpc.controlPlaneSecurityGroupIDs present" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "adopted" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["sg-0123456789abcdef0"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "validates each entry in vpc.controlPlaneSecurityGroupIDs" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.vpc.controlPlaneSecurityGroupIDs = ["sg-0123456789abcdef0", "bad-id"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like a security group ID"
}

@test "fails when cluster-origin canonical file missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/cluster-origin"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "cluster-origin"
  assert_output_contains "not found"
}

@test "validates nodeGroups key when nodegroup-type is unmanaged" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when nodegroup-type expected-values file missing" {
  rm "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "nodegroup-type"
  assert_output_contains "not found"
}

@test "passes with valid sharedNodeSecurityGroup" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"
  yq -i '.vpc.sharedNodeSecurityGroup = "sg-0aaa111bbb222ccc3"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "vpc.sharedNodeSecurityGroup: sg-"
}

@test "fails when sharedNodeSecurityGroup is not sg-hex" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  printf '%s' "unmanaged" > "$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values/nodegroup-type"
  yq -i '.nodeGroups = .managedNodeGroups | del(.managedNodeGroups)' "$context_dir/cluster.yaml"
  yq -i '.vpc.sharedNodeSecurityGroup = "not-a-sg"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "vpc.sharedNodeSecurityGroup"
  assert_output_contains "does not look like a security group ID"
}

# === Volume field validation ===

@test "passes with valid volumeType" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "volumeType: gp3"
}

@test "fails when volumeType is not a valid EBS type" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeType = "invalid"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeType"
  assert_output_contains "must be one of"
}

@test "passes with all valid EBS volume types" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  for vol_type in gp2 gp3 io1 io2 st1 sc1 standard; do
    yq -i ".managedNodeGroups[0].volumeType = \"${vol_type}\"" "$context_dir/cluster.yaml"
    run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
    [ "$status" -eq 0 ]
  done
}

@test "passes with valid volumeEncrypted true" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "volumeEncrypted: true"
}

@test "passes with volumeEncrypted false" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeEncrypted = "false"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when volumeEncrypted is not boolean" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeEncrypted = "yes"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeEncrypted"
  assert_output_contains "must be true or false"
}

@test "passes with valid volumeKmsKeyID" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeKmsKeyID = "arn:aws:kms:eu-west-1:123456789012:key/12345678-1234-1234-1234-123456789012"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "volumeKmsKeyID: arn:aws:kms:"
}

@test "fails when volumeKmsKeyID is not a KMS ARN" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].volumeKmsKeyID = "not-a-kms-arn"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeKmsKeyID"
  assert_output_contains "must be a KMS key ARN"
}

@test "logs eksctl will create SG when no security group specified" {
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "eksctl will create one"
}

# === Taint validation ===

@test "passes with valid taints in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"key": "workload", "value": "kong", "effect": "NoSchedule"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "taints"
  assert_output_contains "1 entries"
}

@test "passes with multiple valid taints" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"key": "workload", "value": "kong", "effect": "NoSchedule"}, {"key": "dedicated", "effect": "NoExecute"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "2 entries"
}

@test "passes with all three valid taint effects in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"key": "a", "effect": "NoSchedule"}, {"key": "b", "effect": "PreferNoSchedule"}, {"key": "c", "effect": "NoExecute"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "3 entries"
}

@test "fails when taint missing key in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"effect": "NoSchedule"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "taints"
  assert_output_contains "missing 'key'"
}

@test "fails when taint missing effect in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"key": "workload", "value": "kong"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "taints"
  assert_output_contains "missing 'effect'"
}

@test "fails when taint has invalid effect in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].taints = [{"key": "workload", "effect": "InvalidEffect"}]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "taints"
  assert_output_contains "must be one of"
}

# === Availability zone validation ===

@test "passes with valid availabilityZones in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].availabilityZones = ["eu-west-1a", "eu-west-1b"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "availabilityZones"
  assert_output_contains "2 entries"
}

@test "fails when availabilityZone is not valid AZ format" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].availabilityZones = ["eu-west-1a", "not-an-az"]' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "does not look like an AZ"
}

# === Spot validation ===

@test "passes with spot true in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].spot = true' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "spot: true"
}

@test "passes with spot false in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].spot = false' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "spot: false"
}

@test "fails when spot is not boolean in substituted yaml" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.managedNodeGroups[0].spot = "yes"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "spot"
  assert_output_contains "must be true or false"
}

@test "passes when all tag annotation and label values are strings" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  yq -i '.metadata.tags.Enabled = "true"' "$context_dir/cluster.yaml"
  yq -i '.metadata.annotations."kaptain.org/priority" = "42"' "$context_dir/cluster.yaml"
  yq -i '.managedNodeGroups[0].labels.gpu = "false"' "$context_dir/cluster.yaml"
  yq -i '.managedNodeGroups[0].tags.Priority = "1"' "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
  assert_output_contains "all checks passed"
}

# === Additional nodegroup validation ===

@test "passes with valid multi-nodegroup substituted values" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  local nodegroup_prefix
  nodegroup_prefix=$(< "$ev_dir/nodegroup-prefix")
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"

  yq -i ".managedNodeGroups += [{\"name\": \"${nodegroup_prefix}-kong\", \"instanceType\": \"g5.xlarge\", \"volumeSize\": 20, \"volumeType\": \"gp3\", \"volumeEncrypted\": true, \"desiredCapacity\": 1, \"minSize\": 1, \"maxSize\": 4, \"tags\": {\"ManagedBy\": \"Kaptain aws-eks-cluster-management system\", \"ManagedByGitRepo\": \"test-cluster\"}}]" "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "validates additional nodegroup name has correct suffix" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  local nodegroup_prefix
  nodegroup_prefix=$(< "$ev_dir/nodegroup-prefix")
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"

  # Additional nodegroup has wrong suffix (gpu instead of expected based on additional-nodegroup-count)
  yq -i ".managedNodeGroups += [{\"name\": \"${nodegroup_prefix}-gpu\", \"instanceType\": \"g5.xlarge\", \"volumeSize\": 20, \"volumeType\": \"gp3\", \"volumeEncrypted\": true, \"desiredCapacity\": 1, \"minSize\": 1, \"maxSize\": 4, \"tags\": {\"ManagedBy\": \"Kaptain aws-eks-cluster-management system\", \"ManagedByGitRepo\": \"test-cluster\"}}]" "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -eq 0 ]
}

@test "fails when additional nodegroup has invalid volumeType" {
  local context_dir="$OUTPUT_SUB_PATH/docker/substituted"
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  local nodegroup_prefix
  nodegroup_prefix=$(< "$ev_dir/nodegroup-prefix")
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"

  yq -i ".managedNodeGroups += [{\"name\": \"${nodegroup_prefix}-kong\", \"instanceType\": \"g5.xlarge\", \"volumeSize\": 20, \"volumeType\": \"invalid\", \"volumeEncrypted\": true, \"desiredCapacity\": 1, \"minSize\": 1, \"maxSize\": 4, \"tags\": {\"ManagedBy\": \"Kaptain aws-eks-cluster-management system\", \"ManagedByGitRepo\": \"test-cluster\"}}]" "$context_dir/cluster.yaml"

  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "volumeType"
  assert_output_contains "must be one of"
}

@test "fails when nodegroup count mismatches additional-nodegroup-count in post-build" {
  local ev_dir="$OUTPUT_SUB_PATH/aws-eks-cluster-management/expected-values"
  printf '%s' "1" > "$ev_dir/additional-nodegroup-count"

  # Only 1 nodegroup in YAML but expected 2 (1 base + 1 additional)
  run "$SCRIPTS_DIR/aws-eks-cluster-management-post-build-validate"
  [ "$status" -ne 0 ]
  assert_output_contains "entries but expected 2"
}
