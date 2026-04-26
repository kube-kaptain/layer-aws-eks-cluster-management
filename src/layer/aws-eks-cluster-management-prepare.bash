#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management-prepare - Generate EKS cluster config and Dockerfile
#
# Runs as a pre-docker hook. Generates cluster.yaml (and optionally
# cluster-controlplane-only.yaml) with token placeholders, plus a thin
# Dockerfile that layers them onto the base management image.
#
# Three-tier file resolution for each generated file:
#   1. Already in docker context dir → skip (user's pre-docker hook put it there)
#   2. Exists in src/eks/ → copy to context dir
#   3. Neither → generate from template
#
# Required config (file in CONFIG_SUB_PATH only, used as tokens):
#   KUBERNETES_MINOR_VERSION    - K8s minor version
#   AWS_REGION                  - AWS region (e.g., eu-west-1)
#   VPC_ID                      - VPC identifier
#   NODEGROUP_INSTANCE_TYPE     - Node instance type (e.g., t3.medium)
#   SECRETS_ENCRYPTION_KEY_ARN  - KMS key ARN for envelope encryption of Kubernetes secrets
#   AWS_ACCOUNT_ID              - AWS account ID (e.g., 123456789012)
#   CLUSTER_SECURITY_GROUP      - EKS cluster default security group ID (from EKS console Networking tab)
#   CLUSTER_ORIGIN              - Cluster origin: 'eksctl' (created by eksctl) or 'adopted' (existing cluster)
#   NODEGROUP_TYPE              - Nodegroup type: 'managed' (EKS managed) or 'unmanaged' (self-managed)
#   PRIVATE_SUBNET_ID_A/B/C     - Private subnet IDs (if EKS_PRIVATE_NETWORKING=true)
#   PUBLIC_SUBNET_ID_A/B/C      - Public subnet IDs (if EKS_PUBLIC_NETWORKING=true)
#   AUTO_MODE_CONFIG_NODE_POOLS - Node pool names, comma-separated (if AUTO_MODE_CONFIG_ENABLED=true)
#     (expanded to numbered tokens: AUTO_MODE_CONFIG_NODE_POOL_1, ...POOL_2, etc.)
#
# Optional config (file in CONFIG_SUB_PATH, generates section when present):
#   VPC_SECURITY_GROUP                     - VPC security group ID (generates securityGroup in vpc block)
#   VPC_CONTROL_PLANE_SECURITY_GROUP_IDS   - Control plane SG IDs, comma-separated, mutually exclusive with VPC_SECURITY_GROUP
#     (expanded to numbered tokens: VPC_CONTROL_PLANE_SECURITY_GROUP_ID_1, ...ID_2, etc.)
#   PRIVATE_CLUSTER_ENABLED                - Generate privateCluster block (e.g., true)
#   NODEGROUP_PRIVATE_NETWORKING           - Generate privateNetworking in nodegroup (e.g., true)
#   AUTO_MODE_CONFIG_ENABLED               - Enable EKS Auto Mode (generates autoModeConfig block)
#   NETWORK_CONFIG_SERVICE_IP_V4_CIDR      - Custom service CIDR (generates kubernetesNetworkConfig block)
#   METADATA_TAGS                          - Additional metadata tags (flat yaml: key: value per line)
#   METADATA_ANNOTATIONS                   - Additional metadata annotations (flat yaml: key: value per line)
#   NODEGROUP_TAGS                         - Additional nodegroup tags (flat yaml: key: value per line)
#   NODEGROUP_LABELS                       - Additional nodegroup labels (flat yaml: key: value per line)
#   NODEGROUP_TAINTS                       - Nodegroup taints (raw yaml list: - key/value/effect per entry)
#   NODEGROUP_SECURITY_GROUPS_ATTACH_IDS   - Additional SG IDs for nodegroup instances, comma-separated
#     (expanded to numbered tokens: NODEGROUP_SECURITY_GROUPS_ATTACH_ID_1, ...ID_2, etc.)
#   NODEGROUP_AVAILABILITY_ZONES           - Pin nodegroup to specific AZs, comma-separated (e.g., eu-west-1a,eu-west-1b)
#     (expanded to numbered tokens: NODEGROUP_AVAILABILITY_ZONE_1, ...ZONE_2, etc.)
#   VPC_SHARED_NODE_SECURITY_GROUP         - Shared node SG ID, unmanaged nodegroups only (generates sharedNodeSecurityGroup in vpc block)
#   NODEGROUP_SPOT                         - Use Spot instances (true or false), managed nodegroups only
#   NODEGROUP_VOLUME_KMS_KEY_ID            - KMS key ARN for EBS volume encryption
#   NODEGROUP_IAM_INSTANCE_ROLE_ARN        - Custom IAM instance role ARN for nodegroup
#   ADDITIONAL_NODEGROUPS                 - Additional nodegroups, comma-separated (e.g., kong,monitoring)
#     Each per-nodegroup field is shared unless overridden with a suffixed config file
#     (e.g., NODEGROUP_INSTANCE_TYPE_KONG to NodegroupInstanceTypeKong overrides instanceType for kong)
#     Suffix must be lowercase alphanumeric with optional hyphens (no leading/trailing/consecutive hyphens)
#   ADDONS_<NAME>_SERVICE_ACCOUNT_ROLE_ARN - Per-addon service account role ARN
#     (e.g., ADDONS_VPC_CNI_SERVICE_ACCOUNT_ROLE_ARN to AddonsVpcCniServiceAccountRoleArn)
#
# Tokens with defaults (checked in CONFIG_SUB_PATH, default written to platform config dir if absent and needed):
#   KUBERNETES_MAJOR_VERSION                   - default: 1
#   IAM_WITH_OIDC                              - default: true
#   VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS       - default: true
#   VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS        - default: false
#   CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES   - default: api,audit,authenticator,controllerManager,scheduler - expanded to numbered tokens likeCLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPE_1 etc
#   NODEGROUP_AMI_FAMILY                       - default: AmazonLinux2023
#   NODEGROUP_VOLUME_SIZE                      - default: 20
#   NODEGROUP_VOLUME_TYPE                      - default: gp3 (gp2, gp3, io1, io2, st1, sc1, standard)
#   NODEGROUP_VOLUME_ENCRYPTED                 - default: true (true or false)
#   NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE    - default: 1 (must be > 0)
#   NODEGROUP_MIN_SIZE                         - default: 3
#   NODEGROUP_MAX_SIZE                         - default: 12
#   NODEGROUP_DESIRED_CAPACITY                 - default: same as NODEGROUP_MIN_SIZE
#   EKS_ADDONS_LIST                            - default: coredns,kube-proxy,vpc-cni,aws-ebs-csi-driver,aws-efs-csi-driver
#
# Inputs (environment variables / switches):
#   EKS_BASE_IMAGE_REGISTRY    - Base image registry (default: ghcr.io)
#   EKS_BASE_IMAGE_NAMESPACE   - Base image namespace (default: kube-kaptain)
#   EKS_BASE_IMAGE_NAME        - Base image name (default: aws/aws-eks-cluster-management)
#   EKS_BASE_IMAGE_TAG         - Base image tag (default: <see defaults script for current>)
#   EKS_PRIVATE_NETWORKING     - Include private subnets section (default: true)
#   EKS_PUBLIC_NETWORKING      - Include public subnets section (default: false)
#   EKS_CILIUM_EBPF_NETWORKING - Generate controlplane-only yaml (default: false)
#   SECRETS_SUB_PATH           - Source dir for encrypted secrets (default: src/secrets)
#   DOCKER_PLATFORM            - Target platform(s) (default: linux/amd64)
#   TOKEN_DELIMITER_STYLE      - Token delimiter syntax (default: shell)
#   TOKEN_NAME_STYLE           - Case style for token names (default: PascalCase)
#   CONFIG_SUB_PATH            - Token config dir (default: src/config)
#   VERSION                    - Build version (from versions-and-naming)
#   PROJECT_NAME               - Project name (from versions-and-naming)
#
# Outputs:
#   DOCKERFILE_SUBSTITUTION_FILES - Extended with cluster yaml filenames
#   Writes NODE_GROUP_DEFAULT_PREFIX to platform config dir(s) and OUTPUT_SUB_PATH/aws-eks-cluster-management/nodegroup-prefix
#   Writes defaultable token values to platform config dir(s) when not in CONFIG_SUB_PATH
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Source defaults ===

# shellcheck source=src/scripts/defaults/platform.bash
source "${SCRIPT_DIR}/../defaults/platform.bash"
# shellcheck source=src/scripts/lib/log.bash
source "${SCRIPT_DIR}/../lib/log.bash"
# shellcheck source=src/scripts/defaults/output-sub-path.bash
source "${SCRIPT_DIR}/../defaults/output-sub-path.bash"
# shellcheck source=src/scripts/defaults/docker-dockerfile.bash
source "${SCRIPT_DIR}/../defaults/docker-dockerfile.bash"
# shellcheck source=src/scripts/defaults/docker-common.bash
source "${SCRIPT_DIR}/../defaults/docker-common.bash"
# shellcheck source=src/scripts/defaults/tokens.bash
source "${SCRIPT_DIR}/../defaults/tokens.bash"
# shellcheck source=src/scripts/defaults/aws-eks-cluster-management.bash
source "${SCRIPT_DIR}/../defaults/aws-eks-cluster-management.bash"

# === Source libs ===

# shellcheck source=src/scripts/lib/token-format.bash
source "${SCRIPT_DIR}/../lib/token-format.bash"
# shellcheck source=src/scripts/lib/output-var.bash
source "${SCRIPT_DIR}/../lib/output-var.bash"

# === Helper functions ===

validation_errors=0
declare -a platform_config_dirs=()
valid_config_list=$(mktemp)
trap 'rm -f "${valid_config_list}"' EXIT

# has_config_file - Check if a config file exists and track it
#
# Converts the canonical UPPER_SNAKE name to the configured token name style,
# checks if the file exists in CONFIG_SUB_PATH, and records it to valid_config_list
# if present. Sets checked_name in caller scope for subsequent reads.
#
# Args:
#   $1 - UPPER_SNAKE canonical name
#
# Sets in caller scope:
#   checked_name - the converted config file name (always set)
#
# Returns: 0 if file exists, 1 if not
has_config_file() {
  local canonical="$1"
  checked_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "${canonical}")
  if [[ -f "${CONFIG_SUB_PATH}/${checked_name}" ]]; then
    echo "${checked_name}" >> "${valid_config_list}"
    return 0
  fi
  return 1
}

# resolve_token - Resolve a token value from config file or default
#
# Checks CONFIG_SUB_PATH for a user-provided file. If found, reads the value
# and sets the shell variable. If not found and a default is provided, uses
# the default and writes it to platform config dir(s). If not found and no
# default, logs an error and increments validation_errors.
#
# Args:
#   $1 - UPPER_SNAKE variable name
#   $2 - default value (optional — omit for required tokens)
#
# Sets the named variable in caller's scope via eval.
resolve_token() {
  local var_name="$1"
  local has_default="false"
  local default_value=""
  if [[ $# -ge 2 ]]; then
    has_default="true"
    default_value="$2"
  fi

  local config_file_name
  config_file_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "${var_name}")

  # Config file in CONFIG_SUB_PATH always wins
  if [[ -f "${CONFIG_SUB_PATH}/${config_file_name}" ]]; then
    echo "${config_file_name}" >> "${valid_config_list}"
    local value
    value=$(< "${CONFIG_SUB_PATH}/${config_file_name}")
    value="${value%$'\n'}"
    eval "${var_name}=\"\${value}\""
    log "  ${var_name}: read from ${CONFIG_SUB_PATH}/"
    return 0
  fi

  # Check if already present in platform config dir(s) (hook may have written it)
  if [[ ${#platform_config_dirs[@]} -gt 0 ]]; then
    local all_present=true
    for config_dir in "${platform_config_dirs[@]}"; do
      if [[ ! -f "${config_dir}/${config_file_name}" ]]; then
        all_present=false
        break
      fi
    done
    if [[ "${all_present}" == "true" ]]; then
      local value
      value=$(< "${platform_config_dirs[0]}/${config_file_name}")
      value="${value%$'\n'}"
      eval "${var_name}=\"\${value}\""
      log "  ${var_name}: already present in platform config dir(s)"
      return 0
    fi
  fi

  # No config file — use default if provided
  if [[ "${has_default}" == "true" ]]; then
    eval "${var_name}=\"\${default_value}\""
    if [[ ${#platform_config_dirs[@]} -gt 0 ]]; then
      for config_dir in "${platform_config_dirs[@]}"; do
        mkdir -p "${config_dir}"
        printf '%s' "${default_value}" > "${config_dir}/${config_file_name}"
      done
      log "  ${var_name}: default '${default_value}' written to platform config dir(s)"
    else
      log "  ${var_name}: using default '${default_value}'"
    fi
    return 0
  fi

  # Required and missing
  eval "${var_name}=''"
  log_error "${var_name} is required - add ${config_file_name} to ${CONFIG_SUB_PATH}/"
  validation_errors=$((validation_errors + 1))
}

# is_yaml_unsafe_value - Check if a value would be coerced by YAML 1.1
#
# Returns 0 (true) if the value needs quoting to remain a string in YAML.
# Covers: booleans, null, integers, octal, hex, floats, sexagesimal.
#
# Args:
#   $1 - the value to check
is_yaml_unsafe_value() {
  local val="$1"

  # Case-insensitive exact matches: booleans and null
  local lower
  lower=$(echo "${val}" | tr '[:upper:]' '[:lower:]')
  case "${lower}" in
    true|false|yes|no|on|off|null) return 0 ;;
  esac

  # Tilde (YAML null)
  [[ "${val}" == "~" ]] && return 0

  # Integers (positive and negative)
  [[ "${val}" =~ ^-?[0-9]+$ ]] && return 0

  # Octal: 0777 or 0o777
  [[ "${val}" =~ ^0[0-7]+$ ]] && return 0
  [[ "${val}" =~ ^0o[0-7]+$ ]] && return 0

  # Hex: 0x1F
  [[ "${val}" =~ ^0x[0-9a-fA-F]+$ ]] && return 0

  # Floats: 1.0, .5, -1.0, 1e10, 1.5e-3
  [[ "${val}" =~ ^-?[0-9]*\.[0-9]+([eE][-+]?[0-9]+)?$ ]] && return 0
  [[ "${val}" =~ ^-?[0-9]+[eE][-+]?[0-9]+$ ]] && return 0

  # Special floats
  case "${lower}" in
    .inf|-.inf|+.inf|.nan) return 0 ;;
  esac

  # Sexagesimal: digits:digits (YAML 1.1 base-60)
  [[ "${val}" =~ ^[0-9]+:[0-9]+(:[0-9]+)*$ ]] && return 0

  return 1
}

# validate_flat_yaml_tags - Validate a flat yaml tags config file (pre-substitution)
#
# Each non-empty line must be: key: value (with optional single or double quotes)
# Blank lines and lines containing only whitespace are skipped.
# Token placeholders are allowed anywhere (validated strictly in post-build-validate).
#
# Args:
#   $1 - UPPER_SNAKE token name (for error messages)
#   $2 - path to the config file
#
# Returns: 0 if valid, 1 if invalid (increments validation_errors)
validate_flat_yaml_tags() {
  local token_name="$1"
  local file_path="$2"
  local line_num=0
  local tag_errors=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_num=$((line_num + 1))

    # Skip blank lines
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue

    # Loose check: key: value format allowing token placeholders ($, {, }, spaces in keys)
    # Strict format validation happens in post-build-validate after substitution
    if [[ ! "${line}" =~ ^[A-Za-z$\{][A-Za-z0-9_./\ \}\$\{-]*:[[:space:]]+.+$ ]]; then
      log_error "${token_name}: invalid tag at line ${line_num}: ${line}"
      log_error "  Expected format: TagName: value  or  TagName: \"value\""
      tag_errors=$((tag_errors + 1))
    fi
  done < "${file_path}"

  if [[ "${tag_errors}" -gt 0 ]]; then
    validation_errors=$((validation_errors + tag_errors))
    return 1
  fi
  return 0
}

# inject_flat_yaml - Inject flat yaml lines with auto-quoting of YAML-unsafe values
#
# Reads a flat yaml file and echoes each line with the given indentation.
# Values that would be coerced by YAML 1.1 are wrapped in double quotes
# and a warning is emitted. Already-quoted values are left alone.
#
# Args:
#   $1 - UPPER_SNAKE token name (for warning messages)
#   $2 - path to the config file
#   $3 - indentation string (e.g. "    " for 4 spaces)
inject_flat_yaml() {
  local token_name="$1"
  local file_path="$2"
  local indent="$3"
  local line_num=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_num=$((line_num + 1))

    # Skip blank lines
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue

    # Extract key and value portions
    local key="${line%%:*}"
    local after_key="${line#*:}"
    local spaces="${after_key%%[! ]*}"
    local value="${after_key#"${spaces}"}"

    # Check if already quoted (single or double)
    if [[ "${value}" =~ ^\".*\"$ ]] || [[ "${value}" =~ ^\'.*\'$ ]]; then
      echo "${indent}${line}"
      continue
    fi

    # Check if value is YAML-unsafe and quote it
    if is_yaml_unsafe_value "${value}"; then
      local quoted="${key}:${spaces}\"${value}\""
      log_warning "${token_name}: auto-quoted YAML-unsafe value at line ${line_num}: ${line} -> ${quoted}" >&2
      echo "${indent}${quoted}"
    else
      echo "${indent}${line}"
    fi
  done < "${file_path}"
}

# expand_comma_list_token - Expand comma-separated value into individually numbered tokens
#
# User writes comma-separated values in CONFIG_SUB_PATH (e.g., api,audit,authenticator).
# This function reads the source, splits on commas, and writes individually numbered
# token files to the platform config dir (e.g., CloudWatchClusterLoggingEnableType1,
# ...Type2, ...Type3). The generated YAML references these numbered tokens as a
# block sequence. The source plural file is NOT used in the template.
#
# This avoids YAML flow sequence syntax ([${token}]) which breaks yq parsing
# because ${} contains flow indicators.
#
# Args:
#   $1 - UPPER_SNAKE token name (plural source, e.g., CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES)
#   $2 - UPPER_SNAKE singular base name (e.g., CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPE)
#   $3 - default comma-separated value
#
# Sets in caller scope:
#   expanded_count - number of items expanded
#   expanded_tokens - array of formatted token references for YAML generation
expand_comma_list_token() {
  local source_name="$1"
  local singular_base="$2"
  local default_value="$3"
  local source_config_name
  source_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "${source_name}")

  local raw_value="${default_value}"

  # User override in CONFIG_SUB_PATH
  if [[ -f "${CONFIG_SUB_PATH}/${source_config_name}" ]]; then
    echo "${source_config_name}" >> "${valid_config_list}"
    raw_value=$(< "${CONFIG_SUB_PATH}/${source_config_name}")
    raw_value="${raw_value%$'\n'}"
    log "  ${source_name}: user config found in ${CONFIG_SUB_PATH}/"
  else
    log "  ${source_name}: using default: ${default_value}"
  fi

  # Split on commas
  IFS=',' read -ra items <<< "${raw_value}"
  expanded_count=${#items[@]}
  expanded_tokens=()

  for idx in $(seq 1 "${expanded_count}"); do
    local item="${items[$((idx - 1))]}"
    local numbered_name="${singular_base}_${idx}"
    local numbered_config_name
    numbered_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "${numbered_name}")

    # Write to each platform config dir
    for config_dir in "${platform_config_dirs[@]}"; do
      mkdir -p "${config_dir}"
      printf '%s' "${item}" > "${config_dir}/${numbered_config_name}"
    done

    # Build token reference for YAML generation
    local token_ref
    token_ref=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${numbered_name}")
    expanded_tokens+=("${token_ref}")
  done

  log "  ${source_name}: expanded ${expanded_count} item(s) to numbered tokens"
}

# === Validate required inputs ===

# Explicit checks — ${:?} exit status is swallowed by EXIT traps in bash 3.2
if [[ -z "${VERSION:-}" ]]; then
  log_error "VERSION is required"
  exit 1
fi
if [[ -z "${PROJECT_NAME:-}" ]]; then
  log_error "PROJECT_NAME is required"
  exit 1
fi

validate_token_styles

# === Resolve config tokens ===

resolve_token "KUBERNETES_MAJOR_VERSION" "${KUBERNETES_MAJOR_VERSION}"
resolve_token "KUBERNETES_MINOR_VERSION"
resolve_token "EKS_ADDONS_LIST" "${EKS_ADDONS_LIST}"
resolve_token "AWS_REGION"
resolve_token "VPC_ID"
resolve_token "NODEGROUP_INSTANCE_TYPE"
resolve_token "SECRETS_ENCRYPTION_KEY_ARN"
resolve_token "AWS_ACCOUNT_ID"
resolve_token "CLUSTER_SECURITY_GROUP"
resolve_token "CLUSTER_ORIGIN"
resolve_token "NODEGROUP_TYPE"

if [[ "${EKS_PRIVATE_NETWORKING}" == "true" ]]; then
  resolve_token "PRIVATE_SUBNET_ID_A"
  resolve_token "PRIVATE_SUBNET_ID_B"
  resolve_token "PRIVATE_SUBNET_ID_C"
fi

if [[ "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
  resolve_token "PUBLIC_SUBNET_ID_A"
  resolve_token "PUBLIC_SUBNET_ID_B"
  resolve_token "PUBLIC_SUBNET_ID_C"
fi

# Validate cluster origin value
# shellcheck disable=SC2154,SC2153 # CLUSTER_ORIGIN set dynamically by resolve_token via eval
cluster_origin="${CLUSTER_ORIGIN}"
if [[ -n "${cluster_origin}" && "${cluster_origin}" != "eksctl" && "${cluster_origin}" != "adopted" ]]; then
  log_error "CLUSTER_ORIGIN: invalid value '${cluster_origin}' - must be 'eksctl' or 'adopted'"
  validation_errors=$((validation_errors + 1))
fi

# Validate nodegroup type value
# shellcheck disable=SC2154,SC2153 # NODEGROUP_TYPE set dynamically by resolve_token via eval
nodegroup_type="${NODEGROUP_TYPE}"
if [[ -n "${nodegroup_type}" && "${nodegroup_type}" != "managed" && "${nodegroup_type}" != "unmanaged" ]]; then
  log_error "NODEGROUP_TYPE: invalid value '${nodegroup_type}' - must be 'managed' or 'unmanaged'"
  validation_errors=$((validation_errors + 1))
fi

# VPC security group - optional: if config file exists, include securityGroup line
has_vpc_security_group="false"
if has_config_file "VPC_SECURITY_GROUP"; then
  has_vpc_security_group="true"
fi

# VPC control plane security group IDs - optional alternative to VPC_SECURITY_GROUP
has_vpc_control_plane_sg_ids="false"
if has_config_file "VPC_CONTROL_PLANE_SECURITY_GROUP_IDS"; then
  has_vpc_control_plane_sg_ids="true"
fi

# VPC shared node security group - optional: unmanaged-only, generates sharedNodeSecurityGroup in vpc block
has_vpc_shared_node_sg="false"
if has_config_file "VPC_SHARED_NODE_SECURITY_GROUP"; then
  has_vpc_shared_node_sg="true"
fi

# VPC security group mutual exclusion: cannot have both securityGroup and controlPlaneSecurityGroupIDs
if [[ "${has_vpc_security_group}" == "true" && "${has_vpc_control_plane_sg_ids}" == "true" ]]; then
  log_error "VPC_SECURITY_GROUP and VPC_CONTROL_PLANE_SECURITY_GROUP_IDS are mutually exclusive and have the same purpose - provide one or the other"
  validation_errors=$((validation_errors + 1))
fi

# Adopted clusters require a control plane security group (eksctl can't resolve from CloudFormation)
if [[ "${cluster_origin}" == "adopted" && "${has_vpc_security_group}" == "false" && "${has_vpc_control_plane_sg_ids}" == "false" ]]; then
  log_error "CLUSTER_ORIGIN=adopted requires either VPC_SECURITY_GROUP or VPC_CONTROL_PLANE_SECURITY_GROUP_IDS"
  validation_errors=$((validation_errors + 1))
fi

# sharedNodeSecurityGroup is unmanaged-only - reject when managed
if [[ "${has_vpc_shared_node_sg}" == "true" && "${nodegroup_type}" == "managed" ]]; then
  log_error "VPC_SHARED_NODE_SECURITY_GROUP is not supported for managed nodegroups - managed nodegroups use the EKS cluster default security group, sharedNodeSecurityGroup only applies to unmanaged (self-managed) nodegroups"
  validation_errors=$((validation_errors + 1))
fi

# Private cluster - conditional: if config file exists, generate privateCluster block
has_private_cluster_config="false"
if has_config_file "PRIVATE_CLUSTER_ENABLED"; then
  has_private_cluster_config="true"
fi

# Global nodegroup private networking - if config file exists, all nodegroups inherit unless overridden
has_global_private_networking="false"
NODEGROUP_PRIVATE_NETWORKING=""
if has_config_file "NODEGROUP_PRIVATE_NETWORKING"; then
  NODEGROUP_PRIVATE_NETWORKING=$(< "${CONFIG_SUB_PATH}/${checked_name}")
  NODEGROUP_PRIVATE_NETWORKING="${NODEGROUP_PRIVATE_NETWORKING%$'\n'}"
  has_global_private_networking="true"
fi

# Global nodegroup IAM instance role ARN - if config file exists, all nodegroups inherit unless overridden
has_global_iam_instance_role_arn="false"
NODEGROUP_IAM_INSTANCE_ROLE_ARN=""
if has_config_file "NODEGROUP_IAM_INSTANCE_ROLE_ARN"; then
  NODEGROUP_IAM_INSTANCE_ROLE_ARN=$(< "${CONFIG_SUB_PATH}/${checked_name}")
  NODEGROUP_IAM_INSTANCE_ROLE_ARN="${NODEGROUP_IAM_INSTANCE_ROLE_ARN%$'\n'}"
  has_global_iam_instance_role_arn="true"
fi

# Auto Mode - conditional: if config file exists, generate block; if true, require node pools
has_auto_mode_config="false"
auto_mode_needs_node_pools="false"
if has_config_file "AUTO_MODE_CONFIG_ENABLED"; then
  has_auto_mode_config="true"
  auto_mode_value=$(< "${CONFIG_SUB_PATH}/${checked_name}")
  auto_mode_value="${auto_mode_value%$'\n'}"
  if [[ "${auto_mode_value}" == "true" ]]; then
    auto_mode_needs_node_pools="true"
    resolve_token "AUTO_MODE_CONFIG_NODE_POOLS"
  fi
fi

# Network config - conditional: if config file exists, generate block
has_network_config="false"
if has_config_file "NETWORK_CONFIG_SERVICE_IP_V4_CIDR"; then
  has_network_config="true"
fi

# Tags - optional flat yaml config files (key: value per line)
has_metadata_tags="false"
metadata_tags_file=""
if has_config_file "METADATA_TAGS"; then
  metadata_tags_file="${CONFIG_SUB_PATH}/${checked_name}"
  if validate_flat_yaml_tags "METADATA_TAGS" "${metadata_tags_file}"; then
    has_metadata_tags="true"
  fi
  if grep -qE '^Name:' "${metadata_tags_file}"; then
    log_error "METADATA_TAGS: 'Name' tag is reserved - eksctl sets it from the nodegroup name"
    validation_errors=$((validation_errors + 1))
  fi
fi

has_global_tags="false"
global_tags_file=""
if has_config_file "NODEGROUP_TAGS"; then
  global_tags_file="${CONFIG_SUB_PATH}/${checked_name}"
  if validate_flat_yaml_tags "NODEGROUP_TAGS" "${global_tags_file}"; then
    has_global_tags="true"
  fi
  # eksctl auto-sets the Name tag on nodegroup EC2 instances from the nodegroup name.
  # A user-supplied Name tag conflicts and causes intermittent behaviour on upgrades.
  if grep -qE '^Name:' "${global_tags_file}"; then
    log_error "NODEGROUP_TAGS: 'Name' tag is reserved - eksctl sets it from the nodegroup name"
    validation_errors=$((validation_errors + 1))
  fi
fi

has_global_labels="false"
global_labels_file=""
if has_config_file "NODEGROUP_LABELS"; then
  global_labels_file="${CONFIG_SUB_PATH}/${checked_name}"
  if validate_flat_yaml_tags "NODEGROUP_LABELS" "${global_labels_file}"; then
    has_global_labels="true"
  fi
fi

has_global_taints="false"
global_taints_file=""
if has_config_file "NODEGROUP_TAINTS"; then
  global_taints_file="${CONFIG_SUB_PATH}/${checked_name}"
  # Validate taints structure using yq
  if ! yq -e '.' "${global_taints_file}" &>/dev/null; then
    log_error "NODEGROUP_TAINTS: file is not valid YAML"
    validation_errors=$((validation_errors + 1))
  else
    taint_count=$(yq '. | length' "${global_taints_file}" 2>/dev/null || echo "0")
    if [[ "${taint_count}" -eq 0 ]]; then
      log_error "NODEGROUP_TAINTS: file is empty or not a YAML list"
      validation_errors=$((validation_errors + 1))
    else
      taint_errors=0
      for idx in $(seq 0 $((taint_count - 1))); do
        taint_key=$(yq ".[${idx}].key" "${global_taints_file}" 2>/dev/null || echo "")
        if [[ -z "${taint_key}" || "${taint_key}" == "null" ]]; then
          log_error "NODEGROUP_TAINTS: entry ${idx} missing 'key'"
          taint_errors=$((taint_errors + 1))
        fi

        taint_effect=$(yq ".[${idx}].effect" "${global_taints_file}" 2>/dev/null || echo "")
        if [[ -z "${taint_effect}" || "${taint_effect}" == "null" ]]; then
          log_error "NODEGROUP_TAINTS: entry ${idx} missing 'effect'"
          taint_errors=$((taint_errors + 1))
        else
          case "${taint_effect}" in
            NoSchedule|PreferNoSchedule|NoExecute) ;;
            *)
              log_error "NODEGROUP_TAINTS: entry ${idx} effect '${taint_effect}' must be one of: NoSchedule, PreferNoSchedule, NoExecute"
              taint_errors=$((taint_errors + 1))
              ;;
          esac
        fi
      done

      # Check for duplicate key+effect combinations
      unique_pairs=$(yq '.[] | .key + ":" + .effect' "${global_taints_file}" 2>/dev/null | sort -u | wc -l | tr -d ' ')
      if [[ "${unique_pairs}" -ne "${taint_count}" ]]; then
        log_error "NODEGROUP_TAINTS: duplicate key+effect combinations found"
        taint_errors=$((taint_errors + 1))
      fi

      if [[ "${taint_errors}" -gt 0 ]]; then
        validation_errors=$((validation_errors + taint_errors))
      else
        has_global_taints="true"
      fi
    fi
  fi
fi

has_global_sg_attach_ids="false"
if has_config_file "NODEGROUP_SECURITY_GROUPS_ATTACH_IDS"; then
  has_global_sg_attach_ids="true"
fi

has_global_availability_zones="false"
if has_config_file "NODEGROUP_AVAILABILITY_ZONES"; then
  has_global_availability_zones="true"
fi

# Global volume KMS key ID - if config file exists, all nodegroups inherit unless overridden
has_global_volume_kms_key_id="false"
NODEGROUP_VOLUME_KMS_KEY_ID=""
if has_config_file "NODEGROUP_VOLUME_KMS_KEY_ID"; then
  NODEGROUP_VOLUME_KMS_KEY_ID=$(< "${CONFIG_SUB_PATH}/${checked_name}")
  NODEGROUP_VOLUME_KMS_KEY_ID="${NODEGROUP_VOLUME_KMS_KEY_ID%$'\n'}"
  has_global_volume_kms_key_id="true"
fi

# Additional nodegroups - optional: comma-separated list of nodegroup suffixes
additional_ng_count=0
declare -a additional_ng_suffixes=()
declare -a additional_ng_suffixes_upper=()
if has_config_file "ADDITIONAL_NODEGROUPS"; then
  additional_ng_raw=$(< "${CONFIG_SUB_PATH}/${checked_name}")
  additional_ng_raw="${additional_ng_raw%$'\n'}"
  IFS=',' read -ra additional_ng_suffixes <<< "${additional_ng_raw}"
  additional_ng_count=${#additional_ng_suffixes[@]}

  for i in "${!additional_ng_suffixes[@]}"; do
    suffix="${additional_ng_suffixes[${i}]}"

    if [[ ! "${suffix}" =~ ^[a-z0-9](-?[a-z0-9])*$ ]]; then
      log_error "ADDITIONAL_NODEGROUPS: suffix '${suffix}' must be lowercase alphanumeric with optional hyphens (no leading/trailing/consecutive hyphens)"
      validation_errors=$((validation_errors + 1))
    elif [[ "${suffix}" == kaptain* ]]; then
      log_error "ADDITIONAL_NODEGROUPS: suffix '${suffix}' must not start with 'kaptain' - this prefix is reserved"
      validation_errors=$((validation_errors + 1))
    fi

    suffix_upper=$(echo "${suffix}" | tr '[:lower:]-' '[:upper:]_')
    additional_ng_suffixes_upper+=("${suffix_upper}")
  done

  # Check for duplicate suffixes
  if [[ ${additional_ng_count} -gt 1 ]]; then
    unique_count=$(printf '%s\n' "${additional_ng_suffixes[@]}" | sort -u | wc -l | tr -d ' ')
    if [[ "${unique_count}" -ne "${additional_ng_count}" ]]; then
      log_error "ADDITIONAL_NODEGROUPS: duplicate suffixes found"
      validation_errors=$((validation_errors + 1))
    fi
  fi
fi

has_metadata_annotations="false"
metadata_annotations_file=""
if has_config_file "METADATA_ANNOTATIONS"; then
  metadata_annotations_file="${CONFIG_SUB_PATH}/${checked_name}"
  if validate_flat_yaml_tags "METADATA_ANNOTATIONS" "${metadata_annotations_file}"; then
    has_metadata_annotations="true"
  fi
fi

if [[ ${validation_errors} -gt 0 ]]; then
  log_error "Validation failed with ${validation_errors} error(s)"
  exit 1
fi

# === Compute values ===

# shellcheck disable=SC2154,SC2153 # KUBERNETES_MINOR_VERSION set dynamically by resolve_token via eval
k8s_version="${KUBERNETES_MAJOR_VERSION}.${KUBERNETES_MINOR_VERSION}"
version_dashes=$(echo "${VERSION}" | tr '.' '-')
timestamp=$(date +%Y%m%d)
nodegroup_prefix="ng-${timestamp}-k-${KUBERNETES_MAJOR_VERSION}-${KUBERNETES_MINOR_VERSION}-v-${version_dashes}"

# Persist canonical values for post-build-validate (before platform dirs are set up)
canonical_dir="${OUTPUT_SUB_PATH}/aws-eks-cluster-management"
expected_values_dir="${canonical_dir}/expected-values"
mkdir -p "${expected_values_dir}"
printf '%s' "${PROJECT_NAME}" > "${expected_values_dir}/project-name"
# shellcheck disable=SC2154 # AWS_REGION set dynamically by resolve_token via eval
printf '%s' "${AWS_REGION}" > "${expected_values_dir}/aws-region"
printf '%s' "${k8s_version}" > "${expected_values_dir}/kubernetes-version"
printf '%s' "${nodegroup_prefix}" > "${expected_values_dir}/nodegroup-prefix"
printf '%s' "${cluster_origin}" > "${expected_values_dir}/cluster-origin"
printf '%s' "${nodegroup_type}" > "${expected_values_dir}/nodegroup-type"
printf '%s' "${additional_ng_count}" > "${expected_values_dir}/additional-nodegroup-count"
if [[ ${additional_ng_count} -gt 0 ]]; then
  printf '%s' "$(IFS=','; echo "${additional_ng_suffixes_upper[*]}")" > "${expected_values_dir}/additional-nodegroup-suffixes"
fi

# === Determine platforms, context dirs, and config dirs ===

declare -a platforms=()
declare -a context_dirs=()

if [[ "${DOCKER_PLATFORM}" == *,* ]]; then
  IFS=',' read -ra platforms <<< "${DOCKER_PLATFORM}"
  for platform in "${platforms[@]}"; do
    case "${platform}" in
      linux/amd64)
        context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_AMD64}")
        platform_config_dirs+=("${OUTPUT_SUB_PATH}/docker-linux-amd64/config")
        ;;
      linux/arm64)
        context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_ARM64}")
        platform_config_dirs+=("${OUTPUT_SUB_PATH}/docker-linux-arm64/config")
        ;;
      *)
        log_error "Unsupported platform: ${platform}"
        exit 1
        ;;
    esac
  done
else
  platforms=("${DOCKER_PLATFORM}")
  context_dirs=("${DOCKER_CONTEXT_SUB_PATH}")
  platform_config_dirs+=("${OUTPUT_SUB_PATH}/docker/config")
fi

# === Write computed and default tokens to platform config dirs ===

# Kubernetes version is always computed - write to every platform config dir
kubernetes_version_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "KUBERNETES_VERSION")
for config_dir in "${platform_config_dirs[@]}"; do
  mkdir -p "${config_dir}"
  printf '%s' "${k8s_version}" > "${config_dir}/${kubernetes_version_config_name}"
done
log "  KUBERNETES_VERSION: ${k8s_version} written to platform config dir(s)"

# Nodegroup prefix is always computed - write to every platform config dir
nodegroup_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX")
for config_dir in "${platform_config_dirs[@]}"; do
  mkdir -p "${config_dir}"
  printf '%s' "${nodegroup_prefix}" > "${config_dir}/${nodegroup_config_name}"
done
log "  NODE_GROUP_DEFAULT_PREFIX: ${nodegroup_prefix} written to platform config dir(s)"

resolve_token "IAM_WITH_OIDC" "${IAM_WITH_OIDC}"
resolve_token "VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS" "${VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS}"
resolve_token "VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS" "${VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS}"
expand_comma_list_token "CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES" "CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPE" "${CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES}"
cloudwatch_tokens=("${expanded_tokens[@]}")
resolve_token "NODEGROUP_AMI_FAMILY" "${NODEGROUP_AMI_FAMILY}"
resolve_token "NODEGROUP_VOLUME_SIZE" "${NODEGROUP_VOLUME_SIZE}"
resolve_token "NODEGROUP_VOLUME_TYPE" "${NODEGROUP_VOLUME_TYPE}"
resolve_token "NODEGROUP_VOLUME_ENCRYPTED" "${NODEGROUP_VOLUME_ENCRYPTED}"

# Validate volumeType is a valid EBS type
case "${NODEGROUP_VOLUME_TYPE}" in
  gp2|gp3|io1|io2|st1|sc1|standard) ;;
  *)
    log_error "NODEGROUP_VOLUME_TYPE must be one of: gp2, gp3, io1, io2, st1, sc1, standard (got: ${NODEGROUP_VOLUME_TYPE})"
    validation_errors=$((validation_errors + 1))
    ;;
esac

# Validate volumeEncrypted is true or false
if [[ "${NODEGROUP_VOLUME_ENCRYPTED}" != "true" && "${NODEGROUP_VOLUME_ENCRYPTED}" != "false" ]]; then
  log_error "NODEGROUP_VOLUME_ENCRYPTED must be 'true' or 'false' (got: ${NODEGROUP_VOLUME_ENCRYPTED})"
  validation_errors=$((validation_errors + 1))
fi

if [[ "${nodegroup_type}" == "managed" ]]; then
  resolve_token "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE" "${NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE}"

  # Validate maxUnavailable is greater than 0
  if [[ "${NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE}" -le 0 ]]; then
    log_error "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE must be greater than 0 (got: ${NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE})"
    validation_errors=$((validation_errors + 1))
  fi
else
  # updateConfig is not supported for unmanaged nodegroups
  if has_config_file "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE"; then
    log_error "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE is not supported for unmanaged nodegroups - remove the config file"
    validation_errors=$((validation_errors + 1))
  fi
fi

# Spot instances - optional, managed only, must be true or false
has_global_spot="false"
NODEGROUP_SPOT=""
if [[ "${nodegroup_type}" == "managed" ]]; then
  if has_config_file "NODEGROUP_SPOT"; then
    NODEGROUP_SPOT=$(< "${CONFIG_SUB_PATH}/${checked_name}")
    NODEGROUP_SPOT="${NODEGROUP_SPOT%$'\n'}"
    if [[ "${NODEGROUP_SPOT}" != "true" && "${NODEGROUP_SPOT}" != "false" ]]; then
      log_error "NODEGROUP_SPOT must be 'true' or 'false' (got: ${NODEGROUP_SPOT})"
      validation_errors=$((validation_errors + 1))
    else
      has_global_spot="true"
    fi
  fi
else
  if has_config_file "NODEGROUP_SPOT"; then
    log_error "NODEGROUP_SPOT is not supported for unmanaged nodegroups (use instancesDistribution instead) - remove the config file"
    validation_errors=$((validation_errors + 1))
  fi
fi

resolve_token "NODEGROUP_MIN_SIZE" "${NODEGROUP_MIN_SIZE}"
resolve_token "NODEGROUP_MAX_SIZE" "${NODEGROUP_MAX_SIZE}"

# desiredCapacity defaults to minSize — config file for min wins over defaults file
desired_capacity_default="${NODEGROUP_DESIRED_CAPACITY:-${NODEGROUP_MIN_SIZE}}"
resolve_token "NODEGROUP_DESIRED_CAPACITY" "${desired_capacity_default}"

# Validate nodegroup sizing: min <= desired <= max
if [[ "${NODEGROUP_MIN_SIZE}" -gt "${NODEGROUP_MAX_SIZE}" ]]; then
  log_error "NODEGROUP_MIN_SIZE (${NODEGROUP_MIN_SIZE}) must be <= NODEGROUP_MAX_SIZE (${NODEGROUP_MAX_SIZE})"
  validation_errors=$((validation_errors + 1))
fi
if [[ "${NODEGROUP_DESIRED_CAPACITY}" -lt "${NODEGROUP_MIN_SIZE}" ]]; then
  log_error "NODEGROUP_DESIRED_CAPACITY (${NODEGROUP_DESIRED_CAPACITY}) must be >= NODEGROUP_MIN_SIZE (${NODEGROUP_MIN_SIZE})"
  validation_errors=$((validation_errors + 1))
fi
if [[ "${NODEGROUP_DESIRED_CAPACITY}" -gt "${NODEGROUP_MAX_SIZE}" ]]; then
  log_error "NODEGROUP_DESIRED_CAPACITY (${NODEGROUP_DESIRED_CAPACITY}) must be <= NODEGROUP_MAX_SIZE (${NODEGROUP_MAX_SIZE})"
  validation_errors=$((validation_errors + 1))
fi

if [[ ${validation_errors} -gt 0 ]]; then
  log_error "Validation failed with ${validation_errors} error(s)"
  exit 1
fi

# === Build token references ===

token_project_name=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PROJECT_NAME")
token_aws_region=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "AWS_REGION")
token_kubernetes_version=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "KUBERNETES_VERSION")
token_iam_with_oidc=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "IAM_WITH_OIDC")
token_vpc_id=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_ID")
token_vpc_private_access=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS")
token_vpc_public_access=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS")
token_secrets_encryption_key_arn=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "SECRETS_ENCRYPTION_KEY_ARN")
token_aws_account_id=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "AWS_ACCOUNT_ID")
token_cluster_security_group=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "CLUSTER_SECURITY_GROUP")


if [[ "${EKS_PRIVATE_NETWORKING}" == "true" ]]; then
  token_private_subnet_id_a=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PRIVATE_SUBNET_ID_A")
  token_private_subnet_id_b=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PRIVATE_SUBNET_ID_B")
  token_private_subnet_id_c=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PRIVATE_SUBNET_ID_C")
fi

if [[ "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
  token_public_subnet_id_a=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PUBLIC_SUBNET_ID_A")
  token_public_subnet_id_b=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PUBLIC_SUBNET_ID_B")
  token_public_subnet_id_c=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PUBLIC_SUBNET_ID_C")
fi

if [[ "${has_vpc_security_group}" == "true" ]]; then
  token_security_group=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_SECURITY_GROUP")
fi

if [[ "${has_vpc_shared_node_sg}" == "true" ]]; then
  token_vpc_shared_node_sg=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_SHARED_NODE_SECURITY_GROUP")
fi

if [[ "${has_private_cluster_config}" == "true" ]]; then
  token_private_cluster_enabled=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PRIVATE_CLUSTER_ENABLED")
fi

if [[ "${has_auto_mode_config}" == "true" ]]; then
  token_auto_mode_enabled=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "AUTO_MODE_CONFIG_ENABLED")
  if [[ "${auto_mode_needs_node_pools}" == "true" ]]; then
    expand_comma_list_token "AUTO_MODE_CONFIG_NODE_POOLS" "AUTO_MODE_CONFIG_NODE_POOL" "" # no default - value comes from CONFIG_SUB_PATH
    node_pools_tokens=("${expanded_tokens[@]}")
  fi
fi

if [[ "${has_vpc_control_plane_sg_ids}" == "true" ]]; then
  expand_comma_list_token "VPC_CONTROL_PLANE_SECURITY_GROUP_IDS" "VPC_CONTROL_PLANE_SECURITY_GROUP_ID" "" # no default - value comes from CONFIG_SUB_PATH
  cp_sg_ids_tokens=("${expanded_tokens[@]}")
  cp_sg_ids_count="${expanded_count}"
  printf '%s' "${cp_sg_ids_count}" > "${expected_values_dir}/control-plane-sg-ids-count"
fi

if [[ "${has_network_config}" == "true" ]]; then
  token_network_service_ipv4_cidr=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NETWORK_CONFIG_SERVICE_IP_V4_CIDR")
fi

# === Process all nodegroups (base + additional) ===
# Base nodegroup uses KAPTAIN_DEFAULT_NG suffix for tokens (name stays unsuffixed).
# Additional nodegroups use their own suffix. All share the same processing logic.

declare -a all_ng_suffixes_lower=("kaptaindefaultng")
declare -a all_ng_suffixes_upper=("KAPTAIN_DEFAULT_NG")
for i in "${!additional_ng_suffixes[@]}"; do
  all_ng_suffixes_lower+=("${additional_ng_suffixes[${i}]}")
  all_ng_suffixes_upper+=("${additional_ng_suffixes_upper[${i}]}")
done

for ng_idx in "${!all_ng_suffixes_lower[@]}"; do
  suffix_lower="${all_ng_suffixes_lower[${ng_idx}]}"
  suffix_upper="${all_ng_suffixes_upper[${ng_idx}]}"
  log ""

  if [[ "${suffix_upper}" == "KAPTAIN_DEFAULT_NG" ]]; then
    log "--- Base nodegroup: ${suffix_lower} (${suffix_upper}) ---"
  else
    log "--- Additional nodegroup: ${suffix_lower} (${suffix_upper}) ---"

    # Compute suffixed nodegroup prefix and write to platform config dirs
    ng_prefix_value="${nodegroup_prefix}-${suffix_lower}"
    ng_prefix_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX_${suffix_upper}")
    for config_dir in "${platform_config_dirs[@]}"; do
      printf '%s' "${ng_prefix_value}" > "${config_dir}/${ng_prefix_config_name}"
    done
    log "  NODE_GROUP_DEFAULT_PREFIX_${suffix_upper}: ${ng_prefix_value}"
  fi

  # Inherit always-present fields (defaults from global resolved values)
  # shellcheck disable=SC2154 # NODEGROUP_* vars set dynamically by resolve_token via eval
  resolve_token "NODEGROUP_INSTANCE_TYPE_${suffix_upper}" "${NODEGROUP_INSTANCE_TYPE}"
  resolve_token "NODEGROUP_AMI_FAMILY_${suffix_upper}" "${NODEGROUP_AMI_FAMILY}"
  resolve_token "NODEGROUP_VOLUME_SIZE_${suffix_upper}" "${NODEGROUP_VOLUME_SIZE}"
  resolve_token "NODEGROUP_VOLUME_TYPE_${suffix_upper}" "${NODEGROUP_VOLUME_TYPE}"
  resolve_token "NODEGROUP_VOLUME_ENCRYPTED_${suffix_upper}" "${NODEGROUP_VOLUME_ENCRYPTED}"
  resolve_token "NODEGROUP_MIN_SIZE_${suffix_upper}" "${NODEGROUP_MIN_SIZE}"
  resolve_token "NODEGROUP_MAX_SIZE_${suffix_upper}" "${NODEGROUP_MAX_SIZE}"
  resolve_token "NODEGROUP_DESIRED_CAPACITY_${suffix_upper}" "${NODEGROUP_DESIRED_CAPACITY}"

  if [[ "${nodegroup_type}" == "managed" ]]; then
    resolve_token "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE_${suffix_upper}" "${NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE}"
  fi

  # Validate suffixed volumeType
  ref="NODEGROUP_VOLUME_TYPE_${suffix_upper}"
  case "${!ref}" in
    gp2|gp3|io1|io2|st1|sc1|standard) ;;
    *)
      log_error "NODEGROUP_VOLUME_TYPE_${suffix_upper} must be one of: gp2, gp3, io1, io2, st1, sc1, standard (got: ${!ref})"
      validation_errors=$((validation_errors + 1))
      ;;
  esac

  # Validate suffixed volumeEncrypted
  ref="NODEGROUP_VOLUME_ENCRYPTED_${suffix_upper}"
  if [[ "${!ref}" != "true" && "${!ref}" != "false" ]]; then
    log_error "NODEGROUP_VOLUME_ENCRYPTED_${suffix_upper} must be 'true' or 'false' (got: ${!ref})"
    validation_errors=$((validation_errors + 1))
  fi

  # Validate suffixed sizing
  ref="NODEGROUP_MIN_SIZE_${suffix_upper}"; ng_min="${!ref}"
  ref="NODEGROUP_MAX_SIZE_${suffix_upper}"; ng_max="${!ref}"
  ref="NODEGROUP_DESIRED_CAPACITY_${suffix_upper}"; ng_desired="${!ref}"
  if [[ "${ng_min}" -gt "${ng_max}" ]]; then
    log_error "NODEGROUP_MIN_SIZE_${suffix_upper} (${ng_min}) must be <= NODEGROUP_MAX_SIZE_${suffix_upper} (${ng_max})"
    validation_errors=$((validation_errors + 1))
  fi
  if [[ "${ng_desired}" -lt "${ng_min}" ]]; then
    log_error "NODEGROUP_DESIRED_CAPACITY_${suffix_upper} (${ng_desired}) must be >= NODEGROUP_MIN_SIZE_${suffix_upper} (${ng_min})"
    validation_errors=$((validation_errors + 1))
  fi
  if [[ "${ng_desired}" -gt "${ng_max}" ]]; then
    log_error "NODEGROUP_DESIRED_CAPACITY_${suffix_upper} (${ng_desired}) must be <= NODEGROUP_MAX_SIZE_${suffix_upper} (${ng_max})"
    validation_errors=$((validation_errors + 1))
  fi

  # Optional simple fields — inherit from base if not overridden
  # volumeKmsKeyID
  ng_has_volume_kms="false"
  if has_config_file "NODEGROUP_VOLUME_KMS_KEY_ID_${suffix_upper}"; then
    ng_has_volume_kms="true"
  elif [[ "${has_global_volume_kms_key_id}" == "true" ]]; then
    resolve_token "NODEGROUP_VOLUME_KMS_KEY_ID_${suffix_upper}" "${NODEGROUP_VOLUME_KMS_KEY_ID}"
    ng_has_volume_kms="true"
  fi
  printf '%s' "${ng_has_volume_kms}" > "${expected_values_dir}/has-volume-kms-key-id-${suffix_lower}"

  # privateNetworking
  ng_has_private_networking="false"
  if has_config_file "NODEGROUP_PRIVATE_NETWORKING_${suffix_upper}"; then
    ng_has_private_networking="true"
  elif [[ "${has_global_private_networking}" == "true" ]]; then
    resolve_token "NODEGROUP_PRIVATE_NETWORKING_${suffix_upper}" "${NODEGROUP_PRIVATE_NETWORKING}"
    ng_has_private_networking="true"
  fi
  printf '%s' "${ng_has_private_networking}" > "${expected_values_dir}/has-private-networking-${suffix_lower}"

  # spot (managed only)
  ng_has_spot="false"
  if [[ "${nodegroup_type}" == "managed" ]]; then
    if has_config_file "NODEGROUP_SPOT_${suffix_upper}"; then
      ng_spot_val=$(< "${CONFIG_SUB_PATH}/${checked_name}")
      ng_spot_val="${ng_spot_val%$'\n'}"
      if [[ "${ng_spot_val}" != "true" && "${ng_spot_val}" != "false" ]]; then
        log_error "NODEGROUP_SPOT_${suffix_upper} must be 'true' or 'false' (got: ${ng_spot_val})"
        validation_errors=$((validation_errors + 1))
      else
        ng_has_spot="true"
      fi
    elif [[ "${has_global_spot}" == "true" ]]; then
      resolve_token "NODEGROUP_SPOT_${suffix_upper}" "${NODEGROUP_SPOT}"
      ng_has_spot="true"
    fi
  else
    if has_config_file "NODEGROUP_SPOT_${suffix_upper}"; then
      log_error "NODEGROUP_SPOT_${suffix_upper} is not supported for unmanaged nodegroups (use instancesDistribution instead) - remove the config file"
      validation_errors=$((validation_errors + 1))
    fi
  fi
  printf '%s' "${ng_has_spot}" > "${expected_values_dir}/has-spot-${suffix_lower}"

  # iamInstanceRoleArn
  ng_has_iam_role="false"
  if has_config_file "NODEGROUP_IAM_INSTANCE_ROLE_ARN_${suffix_upper}"; then
    ng_has_iam_role="true"
  elif [[ "${has_global_iam_instance_role_arn}" == "true" ]]; then
    resolve_token "NODEGROUP_IAM_INSTANCE_ROLE_ARN_${suffix_upper}" "${NODEGROUP_IAM_INSTANCE_ROLE_ARN}"
    ng_has_iam_role="true"
  fi
  printf '%s' "${ng_has_iam_role}" > "${expected_values_dir}/has-iam-instance-role-arn-${suffix_lower}"

  # Comma-list fields — inherit from base if not overridden
  # securityGroups.attachIDs
  ng_has_sg_attach="false"
  if has_config_file "NODEGROUP_SECURITY_GROUPS_ATTACH_IDS_${suffix_upper}"; then
    ng_has_sg_attach="true"
    expand_comma_list_token "NODEGROUP_SECURITY_GROUPS_ATTACH_IDS_${suffix_upper}" "NODEGROUP_SECURITY_GROUPS_ATTACH_ID_${suffix_upper}" ""
    printf '%s' "${expanded_count}" > "${expected_values_dir}/nodegroup-sg-attach-ids-count-${suffix_lower}"
  elif [[ "${has_global_sg_attach_ids}" == "true" ]]; then
    base_sg_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "NODEGROUP_SECURITY_GROUPS_ATTACH_IDS")
    base_sg_value=$(< "${CONFIG_SUB_PATH}/${base_sg_config_name}")
    base_sg_value="${base_sg_value%$'\n'}"
    expand_comma_list_token "NODEGROUP_SECURITY_GROUPS_ATTACH_IDS_${suffix_upper}" "NODEGROUP_SECURITY_GROUPS_ATTACH_ID_${suffix_upper}" "${base_sg_value}"
    printf '%s' "${expanded_count}" > "${expected_values_dir}/nodegroup-sg-attach-ids-count-${suffix_lower}"
    ng_has_sg_attach="true"
  fi
  printf '%s' "${ng_has_sg_attach}" > "${expected_values_dir}/has-sg-attach-ids-${suffix_lower}"

  # availabilityZones
  ng_has_az="false"
  if has_config_file "NODEGROUP_AVAILABILITY_ZONES_${suffix_upper}"; then
    ng_has_az="true"
    expand_comma_list_token "NODEGROUP_AVAILABILITY_ZONES_${suffix_upper}" "NODEGROUP_AVAILABILITY_ZONE_${suffix_upper}" ""
    printf '%s' "${expanded_count}" > "${expected_values_dir}/nodegroup-az-count-${suffix_lower}"
  elif [[ "${has_global_availability_zones}" == "true" ]]; then
    base_az_config_name=$(convert_token_name "${TOKEN_NAME_STYLE}" "NODEGROUP_AVAILABILITY_ZONES")
    base_az_value=$(< "${CONFIG_SUB_PATH}/${base_az_config_name}")
    base_az_value="${base_az_value%$'\n'}"
    expand_comma_list_token "NODEGROUP_AVAILABILITY_ZONES_${suffix_upper}" "NODEGROUP_AVAILABILITY_ZONE_${suffix_upper}" "${base_az_value}"
    printf '%s' "${expanded_count}" > "${expected_values_dir}/nodegroup-az-count-${suffix_lower}"
    ng_has_az="true"
  fi
  printf '%s' "${ng_has_az}" > "${expected_values_dir}/has-availability-zones-${suffix_lower}"

  # Flat/raw YAML fields — suffixed file overrides base, base inherited if present
  # labels
  ng_has_labels="false"
  ng_labels_file=""
  if has_config_file "NODEGROUP_LABELS_${suffix_upper}"; then
    ng_labels_file="${CONFIG_SUB_PATH}/${checked_name}"
    if validate_flat_yaml_tags "NODEGROUP_LABELS_${suffix_upper}" "${ng_labels_file}"; then
      ng_has_labels="true"
    fi
  elif [[ "${has_global_labels}" == "true" ]]; then
    ng_labels_file="${global_labels_file}"
    ng_has_labels="true"
  fi
  printf '%s' "${ng_has_labels}" > "${expected_values_dir}/has-labels-${suffix_lower}"

  # taints
  ng_has_taints="false"
  ng_taints_file=""
  if has_config_file "NODEGROUP_TAINTS_${suffix_upper}"; then
    ng_taints_file="${CONFIG_SUB_PATH}/${checked_name}"
    if ! yq -e '.' "${ng_taints_file}" &>/dev/null; then
      log_error "NODEGROUP_TAINTS_${suffix_upper}: file is not valid YAML"
      validation_errors=$((validation_errors + 1))
    else
      taint_count=$(yq '. | length' "${ng_taints_file}" 2>/dev/null || echo "0")
      if [[ "${taint_count}" -eq 0 ]]; then
        log_error "NODEGROUP_TAINTS_${suffix_upper}: file is empty or not a YAML list"
        validation_errors=$((validation_errors + 1))
      else
        taint_errors=0
        for idx in $(seq 0 $((taint_count - 1))); do
          taint_key=$(yq ".[${idx}].key" "${ng_taints_file}" 2>/dev/null || echo "")
          if [[ -z "${taint_key}" || "${taint_key}" == "null" ]]; then
            log_error "NODEGROUP_TAINTS_${suffix_upper}: entry ${idx} missing 'key'"
            taint_errors=$((taint_errors + 1))
          fi
          taint_effect=$(yq ".[${idx}].effect" "${ng_taints_file}" 2>/dev/null || echo "")
          if [[ -z "${taint_effect}" || "${taint_effect}" == "null" ]]; then
            log_error "NODEGROUP_TAINTS_${suffix_upper}: entry ${idx} missing 'effect'"
            taint_errors=$((taint_errors + 1))
          else
            case "${taint_effect}" in
              NoSchedule|PreferNoSchedule|NoExecute) ;;
              *)
                log_error "NODEGROUP_TAINTS_${suffix_upper}: entry ${idx} effect '${taint_effect}' must be one of: NoSchedule, PreferNoSchedule, NoExecute"
                taint_errors=$((taint_errors + 1))
                ;;
            esac
          fi
        done
        unique_pairs=$(yq '.[] | .key + ":" + .effect' "${ng_taints_file}" 2>/dev/null | sort -u | wc -l | tr -d ' ')
        if [[ "${unique_pairs}" -ne "${taint_count}" ]]; then
          log_error "NODEGROUP_TAINTS_${suffix_upper}: duplicate key+effect combinations found"
          taint_errors=$((taint_errors + 1))
        fi
        if [[ "${taint_errors}" -gt 0 ]]; then
          validation_errors=$((validation_errors + taint_errors))
        else
          ng_has_taints="true"
        fi
      fi
    fi
  elif [[ "${has_global_taints}" == "true" ]]; then
    ng_taints_file="${global_taints_file}"
    ng_has_taints="true"
  fi
  printf '%s' "${ng_has_taints}" > "${expected_values_dir}/has-taints-${suffix_lower}"

  # tags
  ng_has_tags="false"
  ng_tags_file=""
  if has_config_file "NODEGROUP_TAGS_${suffix_upper}"; then
    ng_tags_file="${CONFIG_SUB_PATH}/${checked_name}"
    if validate_flat_yaml_tags "NODEGROUP_TAGS_${suffix_upper}" "${ng_tags_file}"; then
      ng_has_tags="true"
    fi
    if grep -qE '^Name:' "${ng_tags_file}"; then
      log_error "NODEGROUP_TAGS_${suffix_upper}: 'Name' tag is reserved - eksctl sets it from the nodegroup name"
      validation_errors=$((validation_errors + 1))
    fi
  elif [[ "${has_global_tags}" == "true" ]]; then
    ng_tags_file="${global_tags_file}"
    ng_has_tags="true"
  fi
  printf '%s' "${ng_has_tags}" > "${expected_values_dir}/has-tags-${suffix_lower}"

  log "  Optional fields: volume-kms=${ng_has_volume_kms} private-net=${ng_has_private_networking} spot=${ng_has_spot} iam-role=${ng_has_iam_role} sg-attach=${ng_has_sg_attach} az=${ng_has_az} labels=${ng_has_labels} taints=${ng_has_taints} tags=${ng_has_tags}"
done

if [[ ${validation_errors} -gt 0 ]]; then
  log_error "Nodegroup validation failed with ${validation_errors} error(s)"
  exit 1
fi

# === Generate addon lists ===

IFS=',' read -ra all_addons <<< "${EKS_ADDONS_LIST}"

# Full cluster addons: exclude kube-proxy and vpc-cni if cilium mode (cilium replaces both)
declare -a cluster_addons=()
for addon in "${all_addons[@]}"; do
  if [[ "${EKS_CILIUM_EBPF_NETWORKING}" == "true" ]]; then
    if [[ "${addon}" == "kube-proxy" || "${addon}" == "vpc-cni" ]]; then
      continue
    fi
  fi
  cluster_addons+=("${addon}")
done

# === Template generators ===

# emit_nodegroup - Emit a single nodegroup YAML block
#
# Args:
#   $1 - suffix_upper: UPPER_SNAKE suffix (e.g., "KAPTAIN_DEFAULT_NG" for base, "KONG" for additional)
#
# Uses outer-scope variables for shared fields (subnets, project name, token styles)
# Reads per-nodegroup has-flags from expected-values dir
emit_nodegroup() {
  local suffix_upper="$1"
  local suffix_lower="$2"
  local tk="_${suffix_upper}"
  local suffix_dash="-${suffix_lower}"

  # Token references — always present
  # Name token: base nodegroup uses unsuffixed prefix, additional use suffixed
  local t_prefix t_instance t_ami t_vol_size t_vol_type t_vol_enc
  local t_desired t_min t_max
  if [[ "${suffix_upper}" == "KAPTAIN_DEFAULT_NG" ]]; then
    t_prefix=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX")
  else
    t_prefix=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX${tk}")
  fi
  t_instance=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_INSTANCE_TYPE${tk}")
  t_ami=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_AMI_FAMILY${tk}")
  t_vol_size=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_SIZE${tk}")
  t_vol_type=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_TYPE${tk}")
  t_vol_enc=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_ENCRYPTED${tk}")
  t_desired=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_DESIRED_CAPACITY${tk}")
  t_min=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_MIN_SIZE${tk}")
  t_max=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_MAX_SIZE${tk}")

  # Has-flags from expected-values
  local h_vol_kms h_priv_net h_spot h_iam_role h_sg_attach h_az h_labels h_taints h_tags
  h_vol_kms=$(< "${expected_values_dir}/has-volume-kms-key-id${suffix_dash}")
  h_priv_net=$(< "${expected_values_dir}/has-private-networking${suffix_dash}")
  h_spot=$(< "${expected_values_dir}/has-spot${suffix_dash}")
  h_iam_role=$(< "${expected_values_dir}/has-iam-instance-role-arn${suffix_dash}")
  h_sg_attach=$(< "${expected_values_dir}/has-sg-attach-ids${suffix_dash}")
  h_az=$(< "${expected_values_dir}/has-availability-zones${suffix_dash}")
  h_labels=$(< "${expected_values_dir}/has-labels${suffix_dash}")
  h_taints=$(< "${expected_values_dir}/has-taints${suffix_dash}")
  h_tags=$(< "${expected_values_dir}/has-tags${suffix_dash}")

  # Core fields
  echo "  - name: ${t_prefix}"
  echo "    amiFamily: ${t_ami}"
  echo "    instanceType: ${t_instance}"
  echo "    volumeSize: ${t_vol_size}"
  echo "    volumeType: ${t_vol_type}"
  echo "    volumeEncrypted: ${t_vol_enc}"

  if [[ "${h_vol_kms}" == "true" ]]; then
    local t_vol_kms
    t_vol_kms=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_KMS_KEY_ID${tk}")
    echo "    volumeKmsKeyID: ${t_vol_kms}"
  fi

  if [[ "${h_priv_net}" == "true" ]]; then
    local t_priv_net
    t_priv_net=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_PRIVATE_NETWORKING${tk}")
    echo "    privateNetworking: ${t_priv_net}"
  fi

  if [[ "${h_spot}" == "true" ]]; then
    local t_spot
    t_spot=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_SPOT${tk}")
    echo "    spot: ${t_spot}"
  fi

  if [[ "${h_iam_role}" == "true" ]]; then
    local t_iam_role
    t_iam_role=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_IAM_INSTANCE_ROLE_ARN${tk}")
    echo "    iam:"
    echo "      instanceRoleARN: ${t_iam_role}"
  fi

  if [[ "${h_sg_attach}" == "true" ]]; then
    local sg_count sg_idx
    sg_count=$(< "${expected_values_dir}/nodegroup-sg-attach-ids-count${suffix_dash}")
    echo "    securityGroups:"
    echo "      attachIDs:"
    for sg_idx in $(seq 1 "${sg_count}"); do
      local sg_token
      sg_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_SECURITY_GROUPS_ATTACH_ID${tk}_${sg_idx}")
      echo "        - ${sg_token}"
    done
  fi

  echo "    desiredCapacity: ${t_desired}"
  echo "    minSize: ${t_min}"
  echo "    maxSize: ${t_max}"

  if [[ "${nodegroup_type}" == "managed" ]]; then
    local t_update_max
    t_update_max=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE${tk}")
    echo "    updateConfig:"
    echo "      maxUnavailable: ${t_update_max}"
  fi

  # Subnets — shared tokens for all nodegroups
  if [[ "${EKS_PRIVATE_NETWORKING}" == "true" || "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
    echo "    subnets:"
    if [[ "${EKS_PRIVATE_NETWORKING}" == "true" ]]; then
      echo "      - ${token_private_subnet_id_a}"
      echo "      - ${token_private_subnet_id_b}"
      echo "      - ${token_private_subnet_id_c}"
    fi
    if [[ "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
      echo "      - ${token_public_subnet_id_a}"
      echo "      - ${token_public_subnet_id_b}"
      echo "      - ${token_public_subnet_id_c}"
    fi
  fi

  # availabilityZones
  if [[ "${h_az}" == "true" ]]; then
    local az_count az_idx
    az_count=$(< "${expected_values_dir}/nodegroup-az-count${suffix_dash}")
    echo "    availabilityZones:"
    for az_idx in $(seq 1 "${az_count}"); do
      local az_token
      az_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_AVAILABILITY_ZONE${tk}_${az_idx}")
      echo "      - ${az_token}"
    done
  fi

  # labels
  if [[ "${h_labels}" == "true" ]]; then
    local labels_file=""
    if has_config_file "NODEGROUP_LABELS${tk}"; then
      labels_file="${CONFIG_SUB_PATH}/${checked_name}"
    elif [[ -n "${global_labels_file}" ]]; then
      labels_file="${global_labels_file}"
    fi
    if [[ -n "${labels_file}" ]]; then
      echo "    labels:"
      inject_flat_yaml "NODEGROUP_LABELS${tk}" "${labels_file}" "      "
    fi
  fi

  # taints
  if [[ "${h_taints}" == "true" ]]; then
    local taints_file=""
    if has_config_file "NODEGROUP_TAINTS${tk}"; then
      taints_file="${CONFIG_SUB_PATH}/${checked_name}"
    elif [[ -n "${global_taints_file}" ]]; then
      taints_file="${global_taints_file}"
    fi
    if [[ -n "${taints_file}" ]]; then
      echo "    taints:"
      while IFS= read -r line; do
        echo "      ${line}"
      done < <(yq '.' "${taints_file}")
    fi
  fi

  # tags — system tags always present, user tags optional
  echo "    tags:"
  echo "      ManagedBy: \"Kaptain aws-eks-cluster-management system\""
  echo "      ManagedByGitRepo: ${token_project_name}"

  if [[ "${h_tags}" == "true" ]]; then
    local tags_file=""
    if has_config_file "NODEGROUP_TAGS${tk}"; then
      tags_file="${CONFIG_SUB_PATH}/${checked_name}"
    elif [[ -n "${global_tags_file}" ]]; then
      tags_file="${global_tags_file}"
    fi
    if [[ -n "${tags_file}" ]]; then
      inject_flat_yaml "NODEGROUP_TAGS${tk}" "${tags_file}" "      "
    fi
  fi
}

generate_cluster_yaml() {
  local include_nodegroups="$1"
  local addon_list=("${@:2}")

  cat <<YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${token_project_name}
  region: ${token_aws_region}
  version: "${token_kubernetes_version}"
  tags:
    ManagedBy: "Kaptain aws-eks-cluster-management system"
    ManagedByGitRepo: ${token_project_name}
YAML

  # Append user metadata tags (flat yaml, indented under tags:)
  if [[ "${has_metadata_tags}" == "true" ]]; then
    inject_flat_yaml "METADATA_TAGS" "${metadata_tags_file}" "    "
  fi

  echo "  annotations:"
  echo "    kaptain.org/aws-account-id: \"${token_aws_account_id}\""
  echo "    kaptain.org/eks-cluster-security-group: \"${token_cluster_security_group}\""

  # Append user metadata annotations (flat yaml, indented under annotations:)
  if [[ "${has_metadata_annotations}" == "true" ]]; then
    inject_flat_yaml "METADATA_ANNOTATIONS" "${metadata_annotations_file}" "    "
  fi

  cat <<YAML

iam:
  withOIDC: ${token_iam_with_oidc}

vpc:
  id: ${token_vpc_id}
  clusterEndpoints:
    privateAccess: ${token_vpc_private_access}
    publicAccess: ${token_vpc_public_access}
YAML

  if [[ "${has_vpc_security_group}" == "true" ]]; then
    echo "  securityGroup: ${token_security_group}"
  fi

  if [[ "${has_vpc_shared_node_sg}" == "true" ]]; then
    echo "  sharedNodeSecurityGroup: ${token_vpc_shared_node_sg}"
  fi

  if [[ "${has_vpc_control_plane_sg_ids}" == "true" ]]; then
    echo "  controlPlaneSecurityGroupIDs:"
    for token in "${cp_sg_ids_tokens[@]}"; do
      echo "    - ${token}"
    done
  fi

  if [[ "${EKS_PRIVATE_NETWORKING}" == "true" || "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
    echo "  subnets:"
  fi

  if [[ "${EKS_PRIVATE_NETWORKING}" == "true" ]]; then
    cat <<YAML
    private:
      ${token_aws_region}a:
        id: ${token_private_subnet_id_a}
      ${token_aws_region}b:
        id: ${token_private_subnet_id_b}
      ${token_aws_region}c:
        id: ${token_private_subnet_id_c}
YAML
  fi

  if [[ "${EKS_PUBLIC_NETWORKING}" == "true" ]]; then
    cat <<YAML
    public:
      ${token_aws_region}a:
        id: ${token_public_subnet_id_a}
      ${token_aws_region}b:
        id: ${token_public_subnet_id_b}
      ${token_aws_region}c:
        id: ${token_public_subnet_id_c}
YAML
  fi

  if [[ "${has_private_cluster_config}" == "true" ]]; then
    echo ""
    echo "privateCluster:"
    echo "  enabled: ${token_private_cluster_enabled}"
  fi

  cat <<YAML

cloudWatch:
  clusterLogging:
    enableTypes:
YAML

  for token in "${cloudwatch_tokens[@]}"; do
    echo "      - ${token}"
  done

  cat <<YAML

secretsEncryption:
  keyARN: ${token_secrets_encryption_key_arn}
YAML

  if [[ "${has_auto_mode_config}" == "true" ]]; then
    echo ""
    echo "autoModeConfig:"
    echo "  enabled: ${token_auto_mode_enabled}"
    if [[ "${auto_mode_needs_node_pools}" == "true" ]]; then
      echo "  nodePools:"
      for token in "${node_pools_tokens[@]}"; do
        echo "    - ${token}"
      done
    fi
  fi

  if [[ "${has_network_config}" == "true" ]]; then
    echo ""
    echo "kubernetesNetworkConfig:"
    echo "  serviceIPv4CIDR: ${token_network_service_ipv4_cidr}"
  fi

  cat <<YAML

addons:
YAML

  for addon in "${addon_list[@]}"; do
    echo "  - name: ${addon}"
    echo "    version: latest"
    # Check for optional service account role ARN config file
    local addon_upper_snake
    addon_upper_snake=$(echo "${addon}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    local sa_role_canonical="ADDONS_${addon_upper_snake}_SERVICE_ACCOUNT_ROLE_ARN"
    if has_config_file "${sa_role_canonical}"; then
      local sa_role_token
      sa_role_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${sa_role_canonical}")
      echo "    serviceAccountRoleARN: ${sa_role_token}"
    fi
  done

  if [[ "${include_nodegroups}" == "true" ]]; then
    local ng_yaml_key="managedNodeGroups"
    if [[ "${nodegroup_type}" == "unmanaged" ]]; then
      ng_yaml_key="nodeGroups"
    fi
    echo ""
    echo "${ng_yaml_key}:"

    # Emit all nodegroups (base first, then additional)
    for ng_emit_idx in "${!all_ng_suffixes_upper[@]}"; do
      emit_nodegroup "${all_ng_suffixes_upper[${ng_emit_idx}]}" "${all_ng_suffixes_lower[${ng_emit_idx}]}"
    done
  fi
}

generate_dockerfile() {
  local context_dir="$1"

  echo "FROM ${EKS_BASE_IMAGE_REGISTRY}/${EKS_BASE_IMAGE_NAMESPACE}/${EKS_BASE_IMAGE_NAME}:${EKS_BASE_IMAGE_TAG}"
  echo "COPY cluster.yaml /kd/eks/"

  if [[ -f "${context_dir}/cluster-controlplane-only.yaml" ]]; then
    echo "COPY cluster-controlplane-only.yaml /kd/eks/"
  fi

  if [[ -f "${context_dir}/aws-credentials.age" ]]; then
    echo "COPY aws-credentials.age /kd/secrets/"
  fi

  echo "USER kaptain"
}

# resolve_file - Three-tier file resolution
#
# Args:
#   $1 - filename
#   $2 - context_dir (docker build context)
#   $3 - source_dir (EKS_CLUSTER_YAML_SUB_PATH or SECRETS_SUB_PATH)
#
# Returns: 0 if file placed, 1 if not found
resolve_file() {
  local filename="$1"
  local context_dir="$2"
  local source_dir="$3"

  # Tier 1: Already in context dir
  if [[ -f "${context_dir}/${filename}" ]]; then
    log "  ${filename}: already in context dir (skipping)"
    return 0
  fi

  # Tier 2: Copy from source dir
  if [[ -f "${source_dir}/${filename}" ]]; then
    cp "${source_dir}/${filename}" "${context_dir}/${filename}"
    log "  ${filename}: copied from ${source_dir}/"
    return 0
  fi

  # Tier 3: Not found - caller handles generation
  return 1
}

# === Main ===

main() {
  log "=== EKS Cluster Management Prepare ==="
  log "Cluster origin: ${cluster_origin}"
  log "Kubernetes version: ${k8s_version}"
  log "Nodegroup prefix: ${nodegroup_prefix}"
  log "Base image: ${EKS_BASE_IMAGE_REGISTRY}/${EKS_BASE_IMAGE_NAMESPACE}/${EKS_BASE_IMAGE_NAME}:${EKS_BASE_IMAGE_TAG}"
  log "Cilium eBPF networking: ${EKS_CILIUM_EBPF_NETWORKING}"
  log "Private subnets: ${EKS_PRIVATE_NETWORKING}"
  log "Private cluster config: ${has_private_cluster_config}"
  log "Nodegroup private networking: ${has_global_private_networking}"
  log "Nodegroup IAM instance role ARN: ${has_global_iam_instance_role_arn}"
  log "Public networking: ${EKS_PUBLIC_NETWORKING}"
  log "Additional nodegroups: ${additional_ng_count}"
  if [[ ${additional_ng_count} -gt 0 ]]; then
    log "  Suffixes: ${additional_ng_suffixes[*]}"
  fi
  log "Platforms: ${DOCKER_PLATFORM}"
  log "======================================="

  # Track which files need token substitution
  local sub_files="${DOCKERFILE_SUBSTITUTION_FILES}"

  # Determine if controlplane-only yaml is needed
  local need_controlplane_only="false"
  if [[ "${EKS_CILIUM_EBPF_NETWORKING}" == "true" ]]; then
    need_controlplane_only="true"
  elif [[ -f "${EKS_CLUSTER_YAML_SUB_PATH}/cluster-controlplane-only.yaml" ]]; then
    need_controlplane_only="true"
  fi

  for i in "${!context_dirs[@]}"; do
    local context_dir="${context_dirs[${i}]}"
    log ""
    log "--- Preparing ${context_dir} ---"
    mkdir -p "${context_dir}"

    # cluster.yaml
    if ! resolve_file "cluster.yaml" "${context_dir}" "${EKS_CLUSTER_YAML_SUB_PATH}"; then
      log "  cluster.yaml: generating from template"
      generate_cluster_yaml "true" "${cluster_addons[@]}" > "${context_dir}/cluster.yaml"
    fi

    # cluster-controlplane-only.yaml (if needed)
    if [[ "${need_controlplane_only}" == "true" ]]; then
      if ! resolve_file "cluster-controlplane-only.yaml" "${context_dir}" "${EKS_CLUSTER_YAML_SUB_PATH}"; then
        log "  cluster-controlplane-only.yaml: generating from template"
        generate_cluster_yaml "false" "${all_addons[@]}" > "${context_dir}/cluster-controlplane-only.yaml"
      fi
    fi

    # aws-credentials.age (optional, never generated)
    if [[ -f "${SECRETS_SUB_PATH}/aws-credentials.age" ]]; then
      resolve_file "aws-credentials.age" "${context_dir}" "${SECRETS_SUB_PATH}" || true
    fi

    # Generate Dockerfile
    if [[ ! -f "${context_dir}/Dockerfile" ]]; then
      log "  Dockerfile: generating"
      generate_dockerfile "${context_dir}" > "${context_dir}/Dockerfile"
    else
      log "  Dockerfile: already in context dir (skipping)"
    fi
  done

  # Copy pre-substitution cluster yamls to canonical dir for diff/inspection
  local with_tokens_dir="${canonical_dir}/with-tokens"
  mkdir -p "${with_tokens_dir}"
  local first_context_dir="${context_dirs[0]}"
  cp "${first_context_dir}/cluster.yaml" "${with_tokens_dir}/cluster.yaml"
  log "  cluster.yaml: copied to ${with_tokens_dir}/"
  if [[ -f "${first_context_dir}/cluster-controlplane-only.yaml" ]]; then
    cp "${first_context_dir}/cluster-controlplane-only.yaml" "${with_tokens_dir}/cluster-controlplane-only.yaml"
    log "  cluster-controlplane-only.yaml: copied to ${with_tokens_dir}/"
  fi

  # Extend substitution files list with cluster yamls
  sub_files="${sub_files},cluster.yaml"
  if [[ "${need_controlplane_only}" == "true" ]]; then
    sub_files="${sub_files},cluster-controlplane-only.yaml"
  fi

  output_var "DOCKERFILE_SUBSTITUTION_FILES" "${sub_files}"

  # EKS cluster config uses tokens inside tag/label values that reference other
  # tokens (e.g., nodegroup name, project name). This needs at least 2 substitution
  # passes to fully resolve. Preserve any user-requested value above the minimum.
  if [[ ${TOKEN_SUBSTITUTION_PASSES} -lt 2 ]]; then
    TOKEN_SUBSTITUTION_PASSES=2
  fi
  output_var "TOKEN_SUBSTITUTION_PASSES" "${TOKEN_SUBSTITUTION_PASSES}"

  # === Validate no unrecognised config files ===
  local unrecognised_count=0
  for file in "${CONFIG_SUB_PATH}"/*; do
    [[ -e "${file}" ]] || continue
    local name
    name=$(basename "${file}")
    if ! grep -qxF "${name}" "${valid_config_list}"; then
      log_error "Unrecognised config file: ${CONFIG_SUB_PATH}/${name}"
      unrecognised_count=$((unrecognised_count + 1))
    fi
  done

  if [[ ${unrecognised_count} -gt 0 ]]; then
    log_error "${unrecognised_count} unrecognised config file(s) in ${CONFIG_SUB_PATH}/ — check for typos or case mismatches"
    exit 1
  fi

  log ""
  log "EKS Cluster Management Prepare complete"
  log "Substitution files: ${sub_files}"
}

main "$@"
