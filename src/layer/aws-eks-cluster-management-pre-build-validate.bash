#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management-pre-build-validate - Validate cluster yaml tokens before build
#
# Runs after prepare and hook-pre-docker-prepare, before docker-build-dockerfile.
# Validates that the generated/provided cluster.yaml files contain the correct
# token references in the right places BEFORE substitution occurs.
#
# Checks:
#   - metadata.name is exactly the PROJECT_NAME token
#   - metadata.region is exactly the AWS_REGION token
#   - metadata.version is exactly the KUBERNETES_VERSION token
#   - vpc.id is exactly the VPC_ID token
#   - Subnet IDs match token pattern (prefix + single AZ letter)
#   - All nodegroup names start with the NODE_GROUP_DEFAULT_PREFIX token
#   - If multiple nodegroups, names are unique (have distinguishing suffixes)
#   - vpc.securityGroup and vpc.controlPlaneSecurityGroupIDs are mutually exclusive
#   - Adopted clusters require vpc.securityGroup or vpc.controlPlaneSecurityGroupIDs
#   - vpc.securityGroup, if present, is exactly the VPC_SECURITY_GROUP token
#   - metadata.annotations["kaptain.org/eks-cluster-security-group"] is exactly the CLUSTER_SECURITY_GROUP token
#
# Inputs (environment variables):
#   DOCKER_PLATFORM            - Target platform(s) (from prepare)
#   TOKEN_DELIMITER_STYLE      - Token delimiter syntax (default: shell)
#   TOKEN_NAME_STYLE           - Case style for token names (default: PascalCase)
#   OUTPUT_SUB_PATH            - Build output directory (default: kaptain-out)
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

# === Read canonical values from prepare output ===

canonical_dir="${OUTPUT_SUB_PATH}/aws-eks-cluster-management"
expected_values_dir="${canonical_dir}/expected-values"

if [[ ! -f "${expected_values_dir}/cluster-origin" ]]; then
  log_error "${expected_values_dir}/cluster-origin not found - was aws-eks-cluster-management-prepare run?"
  exit 1
fi
cluster_origin=$(< "${expected_values_dir}/cluster-origin")

if [[ ! -f "${expected_values_dir}/nodegroup-type" ]]; then
  log_error "${expected_values_dir}/nodegroup-type not found - was aws-eks-cluster-management-prepare run?"
  exit 1
fi
nodegroup_type=$(< "${expected_values_dir}/nodegroup-type")

if [[ "${nodegroup_type}" == "managed" ]]; then
  ng_yaml_key="managedNodeGroups"
else
  ng_yaml_key="nodeGroups"
fi

cp_sg_ids_expected_count=0
if [[ -f "${expected_values_dir}/control-plane-sg-ids-count" ]]; then
  cp_sg_ids_expected_count=$(< "${expected_values_dir}/control-plane-sg-ids-count")
fi

ng_sg_attach_expected_count=0
if [[ -f "${expected_values_dir}/nodegroup-sg-attach-ids-count-kaptaindefaultng" ]]; then
  ng_sg_attach_expected_count=$(< "${expected_values_dir}/nodegroup-sg-attach-ids-count-kaptaindefaultng")
fi

ng_az_expected_count=0
if [[ -f "${expected_values_dir}/nodegroup-az-count-kaptaindefaultng" ]]; then
  ng_az_expected_count=$(< "${expected_values_dir}/nodegroup-az-count-kaptaindefaultng")
fi

# Additional nodegroup metadata
additional_ng_count=0
if [[ -f "${expected_values_dir}/additional-nodegroup-count" ]]; then
  additional_ng_count=$(< "${expected_values_dir}/additional-nodegroup-count")
fi

declare -a additional_ng_suffixes_upper=()
if [[ ${additional_ng_count} -gt 0 && -f "${expected_values_dir}/additional-nodegroup-suffixes" ]]; then
  IFS=',' read -ra additional_ng_suffixes_upper <<< "$(< "${expected_values_dir}/additional-nodegroup-suffixes")"
fi

expected_total_nodegroup_count=$((1 + additional_ng_count))

# === Build expected token strings ===

token_project_name=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "PROJECT_NAME")
token_aws_region=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "AWS_REGION")
token_kubernetes_version=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "KUBERNETES_VERSION")
token_vpc_id=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_ID")
token_nodegroup_prefix=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX")
token_vpc_security_group=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_SECURITY_GROUP")
token_vpc_shared_node_sg=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_SHARED_NODE_SECURITY_GROUP")
token_cluster_security_group=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "CLUSTER_SECURITY_GROUP")


# Direct-emit config tokens - these are emitted during generation, not substitution.
# If found in a user-provided template, substitution will produce broken YAML
# because only the first line gets correct indentation.
declare -a blocked_direct_emit_tokens=()
for blocked_name in NODEGROUP_TAINTS NODEGROUP_LABELS NODEGROUP_TAGS METADATA_TAGS METADATA_ANNOTATIONS; do
  blocked_direct_emit_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${blocked_name}")")
done

# Comma-list source tokens - these are expanded to numbered tokens during generation.
# The source file contains a comma-separated string, not a YAML list.
# Use the numbered tokens instead (e.g., VpcControlPlaneSecurityGroupId1, ...Id2).
declare -a blocked_comma_list_tokens=()
for blocked_name in CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES AUTO_MODE_CONFIG_NODE_POOLS VPC_CONTROL_PLANE_SECURITY_GROUP_IDS NODEGROUP_SECURITY_GROUPS_ATTACH_IDS NODEGROUP_AVAILABILITY_ZONES ADDITIONAL_NODEGROUPS; do
  blocked_comma_list_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${blocked_name}")")
done

# Add per-nodegroup suffixed versions of blocked tokens (base + additional nodegroups)
declare -a all_blocked_suffixes=("KAPTAIN_DEFAULT_NG")
for suffix in "${additional_ng_suffixes_upper[@]+"${additional_ng_suffixes_upper[@]}"}"; do
  all_blocked_suffixes+=("${suffix}")
done
for ng_suffix in "${all_blocked_suffixes[@]}"; do
  for blocked_name in NODEGROUP_TAINTS NODEGROUP_LABELS NODEGROUP_TAGS; do
    blocked_direct_emit_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${blocked_name}_${ng_suffix}")")
  done
  for blocked_name in NODEGROUP_SECURITY_GROUPS_ATTACH_IDS NODEGROUP_AVAILABILITY_ZONES; do
    blocked_comma_list_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${blocked_name}_${ng_suffix}")")
  done
done

# Build expected controlPlaneSecurityGroupIDs tokens (numbered)
declare -a expected_cp_sg_tokens=()
if [[ "${cp_sg_ids_expected_count}" -gt 0 ]]; then
  for idx in $(seq 1 "${cp_sg_ids_expected_count}"); do
    expected_cp_sg_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "VPC_CONTROL_PLANE_SECURITY_GROUP_ID_${idx}")")
  done
fi

# Build expected nodegroup securityGroups.attachIDs tokens (numbered)
declare -a expected_ng_sg_attach_tokens=()
if [[ "${ng_sg_attach_expected_count}" -gt 0 ]]; then
  for idx in $(seq 1 "${ng_sg_attach_expected_count}"); do
    expected_ng_sg_attach_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_SECURITY_GROUPS_ATTACH_ID_${idx}")")
  done
fi

# Build expected nodegroup availabilityZones tokens (numbered)
declare -a expected_ng_az_tokens=()
if [[ "${ng_az_expected_count}" -gt 0 ]]; then
  for idx in $(seq 1 "${ng_az_expected_count}"); do
    expected_ng_az_tokens+=("$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_AVAILABILITY_ZONE_${idx}")")
  done
fi

# Build subnet token patterns (prefix + single AZ letter) using two-reference diff
_build_subnet_pattern() {
  local ref_a ref_b
  ref_a=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "$1")
  ref_b=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "$2")
  local i=0
  while [[ "${ref_a:${i}:1}" == "${ref_b:${i}:1}" && ${i} -lt ${#ref_a} ]]; do
    ((i++))
  done
  echo "${ref_a:0:${i}}?${ref_a:$((i+1))}"
}

private_subnet_pattern=$(_build_subnet_pattern "PRIVATE_SUBNET_ID_A" "PRIVATE_SUBNET_ID_B")
public_subnet_pattern=$(_build_subnet_pattern "PUBLIC_SUBNET_ID_A" "PUBLIC_SUBNET_ID_B")

# === Determine context dirs ===

declare -a context_dirs=()

if [[ "${DOCKER_PLATFORM}" == *,* ]]; then
  IFS=',' read -ra platforms <<< "${DOCKER_PLATFORM}"
  for platform in "${platforms[@]}"; do
    case "${platform}" in
      linux/amd64) context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_AMD64}") ;;
      linux/arm64) context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_ARM64}") ;;
    esac
  done
else
  context_dirs=("${DOCKER_CONTEXT_SUB_PATH}")
fi

# === Validation ===

errors=0

fail() {
  log_error "$1"
  errors=$((errors + 1))
}

validate_cluster_yaml_tokens() {
  local yaml_file="$1"

  if [[ ! -f "${yaml_file}" ]]; then
    fail "${yaml_file}: file not found"
    return
  fi

  log "Validating tokens in ${yaml_file}..."

  # metadata.name must be exactly the PROJECT_NAME token
  local cluster_name
  cluster_name=$(yq '.metadata.name' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${cluster_name}" || "${cluster_name}" == "null" ]]; then
    fail "${yaml_file}: metadata.name is missing"
  elif [[ "${cluster_name}" != "${token_project_name}" ]]; then
    fail "${yaml_file}: metadata.name '${cluster_name}' must be exactly '${token_project_name}'"
  fi

  # metadata.region must be exactly the AWS_REGION token
  local region
  region=$(yq '.metadata.region' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${region}" || "${region}" == "null" ]]; then
    fail "${yaml_file}: metadata.region is missing"
  elif [[ "${region}" != "${token_aws_region}" ]]; then
    fail "${yaml_file}: metadata.region '${region}' must be exactly '${token_aws_region}'"
  fi

  # metadata.version must be exactly the KUBERNETES_VERSION token
  local version
  version=$(yq '.metadata.version' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    fail "${yaml_file}: metadata.version is missing"
  elif [[ "${version}" != "${token_kubernetes_version}" ]]; then
    fail "${yaml_file}: metadata.version '${version}' must be exactly '${token_kubernetes_version}'"
  fi

  # metadata.annotations["kaptain.org/eks-cluster-security-group"] must be exactly the CLUSTER_SECURITY_GROUP token
  local cluster_sg_annotation
  cluster_sg_annotation=$(yq '.metadata.annotations["kaptain.org/eks-cluster-security-group"]' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${cluster_sg_annotation}" || "${cluster_sg_annotation}" == "null" ]]; then
    fail "${yaml_file}: metadata.annotations[kaptain.org/eks-cluster-security-group] is missing"
  elif [[ "${cluster_sg_annotation}" != "${token_cluster_security_group}" ]]; then
    fail "${yaml_file}: metadata.annotations[kaptain.org/eks-cluster-security-group] '${cluster_sg_annotation}' must be exactly '${token_cluster_security_group}'"
  fi

  # vpc.id must be exactly the VPC_ID token
  local vpc_id
  vpc_id=$(yq '.vpc.id' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${vpc_id}" || "${vpc_id}" == "null" ]]; then
    fail "${yaml_file}: vpc.id is missing"
  elif [[ "${vpc_id}" != "${token_vpc_id}" ]]; then
    fail "${yaml_file}: vpc.id '${vpc_id}' must be exactly '${token_vpc_id}'"
  fi

  # Security group validation
  local has_sg="false"
  local has_cp_sg_ids="false"

  local sg_value
  sg_value=$(yq '.vpc.securityGroup' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -n "${sg_value}" && "${sg_value}" != "null" ]]; then
    has_sg="true"
    if [[ "${sg_value}" != "${token_vpc_security_group}" ]]; then
      fail "${yaml_file}: vpc.securityGroup '${sg_value}' must be exactly '${token_vpc_security_group}'"
    fi
  fi

  local shared_node_sg_value
  shared_node_sg_value=$(yq '.vpc.sharedNodeSecurityGroup' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -n "${shared_node_sg_value}" && "${shared_node_sg_value}" != "null" ]]; then
    if [[ "${shared_node_sg_value}" != "${token_vpc_shared_node_sg}" ]]; then
      fail "${yaml_file}: vpc.sharedNodeSecurityGroup '${shared_node_sg_value}' must be exactly '${token_vpc_shared_node_sg}'"
    fi
  fi

  local cp_sg_count
  cp_sg_count=$(yq '.vpc.controlPlaneSecurityGroupIDs | length' "${yaml_file}" 2>/dev/null || echo "0")
  if [[ "${cp_sg_count}" -gt 0 ]]; then
    has_cp_sg_ids="true"

    if [[ "${cp_sg_ids_expected_count}" -eq 0 ]]; then
      fail "${yaml_file}: vpc.controlPlaneSecurityGroupIDs present but VPC_CONTROL_PLANE_SECURITY_GROUP_IDS config not provided"
    elif [[ "${cp_sg_count}" -ne "${cp_sg_ids_expected_count}" ]]; then
      fail "${yaml_file}: vpc.controlPlaneSecurityGroupIDs has ${cp_sg_count} entries but expected ${cp_sg_ids_expected_count}"
    else
      for idx in $(seq 0 $((cp_sg_count - 1))); do
        local entry
        entry=$(yq ".vpc.controlPlaneSecurityGroupIDs[${idx}]" "${yaml_file}" 2>/dev/null || echo "")
        local expected_token="${expected_cp_sg_tokens[${idx}]}"
        if [[ "${entry}" != "${expected_token}" ]]; then
          fail "${yaml_file}: vpc.controlPlaneSecurityGroupIDs[${idx}] '${entry}' must be exactly '${expected_token}'"
        fi
      done
    fi
  elif [[ "${cp_sg_ids_expected_count}" -gt 0 ]]; then
    fail "${yaml_file}: VPC_CONTROL_PLANE_SECURITY_GROUP_IDS config provided (${cp_sg_ids_expected_count} entries) but vpc.controlPlaneSecurityGroupIDs missing from YAML"
  fi

  # Mutual exclusion: cannot have both
  if [[ "${has_sg}" == "true" && "${has_cp_sg_ids}" == "true" ]]; then
    fail "${yaml_file}: vpc.securityGroup and vpc.controlPlaneSecurityGroupIDs are mutually exclusive"
  fi

  # Adopted clusters require a control plane security group
  if [[ "${cluster_origin}" == "adopted" && "${has_sg}" == "false" && "${has_cp_sg_ids}" == "false" ]]; then
    fail "${yaml_file}: cluster origin is 'adopted' - vpc.securityGroup or vpc.controlPlaneSecurityGroupIDs is required"
  fi

  # Subnet keys must be AWS_REGION token + single AZ letter; IDs must match token pattern
  local subnet_type subnet_pattern
  for subnet_type in private public; do
    if yq -e ".vpc.subnets.${subnet_type}" "${yaml_file}" &>/dev/null; then
      if [[ "${subnet_type}" == "private" ]]; then
        subnet_pattern="${private_subnet_pattern}"
      else
        subnet_pattern="${public_subnet_pattern}"
      fi

      # Validate AZ keys: must be region token + single letter
      local az_keys
      az_keys=$(yq ".vpc.subnets.${subnet_type} | keys | .[]" "${yaml_file}" 2>/dev/null || true)
      while IFS= read -r az_key; do
        if [[ -z "${az_key}" ]]; then
          continue
        fi
        # shellcheck disable=SC2254 # pattern is intentionally a glob
        if [[ "${az_key}" != ${token_aws_region}[a-z] ]]; then
          fail "${yaml_file}: ${subnet_type} subnet key '${az_key}' must be AWS_REGION token + single lowercase AZ letter (e.g., ${token_aws_region}a)"
        fi
      done <<< "${az_keys}"

      # Validate subnet IDs: must match token pattern
      local subnet_ids
      subnet_ids=$(yq ".vpc.subnets.${subnet_type}[].id" "${yaml_file}" 2>/dev/null || true)
      while IFS= read -r sid; do
        if [[ -z "${sid}" || "${sid}" == "null" ]]; then
          continue
        fi
        # shellcheck disable=SC2053 # pattern is intentionally a glob
        if [[ "${sid}" != ${subnet_pattern} ]]; then
          fail "${yaml_file}: ${subnet_type} subnet id '${sid}' does not match expected token pattern '${subnet_pattern}'"
        fi
      done <<< "${subnet_ids}"
    fi
  done

  # Validate nodegroup count and names
  local nodegroup_count
  nodegroup_count=$(yq ".${ng_yaml_key} | length" "${yaml_file}" 2>/dev/null || echo "0")

  if [[ ${additional_ng_count} -gt 0 && "${nodegroup_count}" -ne "${expected_total_nodegroup_count}" ]]; then
    fail "${yaml_file}: ${ng_yaml_key} has ${nodegroup_count} entries but expected ${expected_total_nodegroup_count} (1 base + ${additional_ng_count} additional)"
  fi

  if [[ "${nodegroup_count}" -gt 0 ]]; then
    declare -a ng_names=()
    for i in $(seq 0 $((nodegroup_count - 1))); do
      local ng_name
      ng_name=$(yq ".${ng_yaml_key}[${i}].name" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -z "${ng_name}" || "${ng_name}" == "null" ]]; then
        fail "${yaml_file}: ${ng_yaml_key}[${i}].name is missing"
        continue
      fi

      # Name must start with the nodegroup prefix token (suffixed for additional nodegroups)
      local expected_prefix_token="${token_nodegroup_prefix}"
      if [[ ${i} -gt 0 ]]; then
        local adj=$((i - 1))
        if [[ ${adj} -lt ${#additional_ng_suffixes_upper[@]} ]]; then
          expected_prefix_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODE_GROUP_DEFAULT_PREFIX_${additional_ng_suffixes_upper[${adj}]}")
        fi
      fi
      if [[ "${ng_name}" != "${expected_prefix_token}"* ]]; then
        fail "${yaml_file}: ${ng_yaml_key}[${i}].name '${ng_name}' does not start with NODE_GROUP_DEFAULT_PREFIX token '${expected_prefix_token}'"
      fi

      ng_names+=("${ng_name}")
    done

    # If multiple nodegroups, names must be unique
    if [[ "${nodegroup_count}" -gt 1 && ${#ng_names[@]} -gt 0 ]]; then
      local unique_count
      unique_count=$(printf '%s\n' "${ng_names[@]}" | sort -u | wc -l | tr -d ' ')
      if [[ "${unique_count}" -ne "${nodegroup_count}" ]]; then
        fail "${yaml_file}: duplicate nodegroup names found - each must be unique (add suffixes)"
      fi
    fi

    # Validate per-nodegroup tokens for each nodegroup entry
    for ng_idx in $(seq 0 $((nodegroup_count - 1))); do
      local tk="" suffix_dash=""

      if [[ ${ng_idx} -eq 0 ]]; then
        tk="_KAPTAIN_DEFAULT_NG"
        suffix_dash="-kaptaindefaultng"
      else
        local adj_idx=$((ng_idx - 1))
        if [[ ${adj_idx} -lt ${#additional_ng_suffixes_upper[@]} ]]; then
          local ng_suffix="${additional_ng_suffixes_upper[${adj_idx}]}"
          tk="_${ng_suffix}"
          local suffix_lower
          suffix_lower=$(echo "${ng_suffix}" | tr '[:upper:]' '[:lower:]')
          suffix_dash="-${suffix_lower}"
        fi
      fi

      # Read per-nodegroup expected counts
      local expected_sg_count=0 expected_az_count=0
      if [[ -f "${expected_values_dir}/nodegroup-sg-attach-ids-count${suffix_dash}" ]]; then
        expected_sg_count=$(< "${expected_values_dir}/nodegroup-sg-attach-ids-count${suffix_dash}")
      fi
      if [[ -f "${expected_values_dir}/nodegroup-az-count${suffix_dash}" ]]; then
        expected_az_count=$(< "${expected_values_dir}/nodegroup-az-count${suffix_dash}")
      fi

      # Validate securityGroups.attachIDs tokens
      local actual_sg_count
      actual_sg_count=$(yq ".${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs | length" "${yaml_file}" 2>/dev/null || echo "0")
      if [[ "${actual_sg_count}" -gt 0 ]]; then
        if [[ "${expected_sg_count}" -eq 0 ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs in YAML but config not provided"
        elif [[ "${actual_sg_count}" -ne "${expected_sg_count}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs has ${actual_sg_count} entries but expected ${expected_sg_count}"
        else
          for idx in $(seq 0 $((actual_sg_count - 1))); do
            local entry expected_token
            entry=$(yq ".${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs[${idx}]" "${yaml_file}" 2>/dev/null || echo "")
            expected_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_SECURITY_GROUPS_ATTACH_ID${tk}_$((idx + 1))")
            if [[ "${entry}" != "${expected_token}" ]]; then
              fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs[${idx}] '${entry}' must be exactly '${expected_token}'"
            fi
          done
        fi
      elif [[ "${expected_sg_count}" -gt 0 ]]; then
        fail "${yaml_file}: securityGroups.attachIDs config provided (count: ${expected_sg_count}) but missing from YAML on ${ng_yaml_key}[${ng_idx}]"
      fi

      # Validate availabilityZones tokens
      local actual_az_count
      actual_az_count=$(yq ".${ng_yaml_key}[${ng_idx}].availabilityZones | length" "${yaml_file}" 2>/dev/null || echo "0")
      if [[ "${actual_az_count}" -gt 0 ]]; then
        if [[ "${expected_az_count}" -eq 0 ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].availabilityZones in YAML but config not provided"
        elif [[ "${actual_az_count}" -ne "${expected_az_count}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].availabilityZones has ${actual_az_count} entries but expected ${expected_az_count}"
        else
          for idx in $(seq 0 $((actual_az_count - 1))); do
            local entry expected_token
            entry=$(yq ".${ng_yaml_key}[${ng_idx}].availabilityZones[${idx}]" "${yaml_file}" 2>/dev/null || echo "")
            expected_token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_AVAILABILITY_ZONE${tk}_$((idx + 1))")
            if [[ "${entry}" != "${expected_token}" ]]; then
              fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].availabilityZones[${idx}] '${entry}' must be exactly '${expected_token}'"
            fi
          done
        fi
      elif [[ "${expected_az_count}" -gt 0 ]]; then
        fail "${yaml_file}: availabilityZones config provided (count: ${expected_az_count}) but missing from YAML on ${ng_yaml_key}[${ng_idx}]"
      fi

      # Validate volume tokens
      local expected_vol_type expected_vol_enc expected_vol_kms expected_spot
      expected_vol_type=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_TYPE${tk}")
      expected_vol_enc=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_ENCRYPTED${tk}")
      expected_vol_kms=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_VOLUME_KMS_KEY_ID${tk}")
      expected_spot=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "NODEGROUP_SPOT${tk}")

      local volume_type_value
      volume_type_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeType" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_type_value}" && "${volume_type_value}" != "null" ]]; then
        if [[ "${volume_type_value}" != "${expected_vol_type}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeType '${volume_type_value}' must be exactly '${expected_vol_type}'"
        fi
      fi

      local volume_encrypted_value
      volume_encrypted_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeEncrypted" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_encrypted_value}" && "${volume_encrypted_value}" != "null" ]]; then
        if [[ "${volume_encrypted_value}" != "${expected_vol_enc}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeEncrypted '${volume_encrypted_value}' must be exactly '${expected_vol_enc}'"
        fi
      fi

      local volume_kms_key_id_value
      volume_kms_key_id_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeKmsKeyID" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_kms_key_id_value}" && "${volume_kms_key_id_value}" != "null" ]]; then
        if [[ "${volume_kms_key_id_value}" != "${expected_vol_kms}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeKmsKeyID '${volume_kms_key_id_value}' must be exactly '${expected_vol_kms}'"
        fi
      fi

      local spot_value
      spot_value=$(yq ".${ng_yaml_key}[${ng_idx}].spot" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${spot_value}" && "${spot_value}" != "null" ]]; then
        if [[ "${spot_value}" != "${expected_spot}" ]]; then
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].spot '${spot_value}' must be exactly '${expected_spot}'"
        fi
      fi
    done
  fi

  # Block direct-emit tokens that don't work with substitution (multi-line YAML)
  local yaml_content
  yaml_content=$(< "${yaml_file}")
  for blocked_token in "${blocked_direct_emit_tokens[@]}"; do
    if [[ "${yaml_content}" == *"${blocked_token}"* ]]; then
      log "Please remove ${blocked_token} from your src/eks/cluster.yaml template AND your src/config/ directory since it produces corrupt results"
      fail "${yaml_file}: ${blocked_token} is not allowed in cluster.yaml templates because the substitution process would produce corrupt output."
    fi
  done

  # Block comma-list source tokens (expanded to numbered tokens during generation)
  for blocked_token in "${blocked_comma_list_tokens[@]}"; do
    if [[ "${yaml_content}" == *"${blocked_token}"* ]]; then
      log "Please use the individually numbered tokens instead of ${blocked_token} (e.g. the token minus trailing s and with a number suffix for each entry)"
      fail "${yaml_file}: ${blocked_token} is a comma-separated source token that gets expanded to numbered tokens during generation — use the numbered tokens instead"
    fi
  done
}

# === Main ===

main() {
  log "=== EKS Cluster Management Pre-Build Validate ==="
  log "Cluster origin: ${cluster_origin}"
  log "Nodegroup type: ${nodegroup_type} (YAML key: ${ng_yaml_key})"
  log "Expected PROJECT_NAME token: ${token_project_name}"
  log "Expected AWS_REGION token: ${token_aws_region}"
  log "Expected KUBERNETES_VERSION token: ${token_kubernetes_version}"
  log "Expected VPC_ID token: ${token_vpc_id}"
  log "Private subnet pattern: ${private_subnet_pattern}"
  log "Public subnet pattern: ${public_subnet_pattern}"
  log "Expected NODE_GROUP_DEFAULT_PREFIX token: ${token_nodegroup_prefix}"
  if [[ "${cp_sg_ids_expected_count}" -gt 0 ]]; then
    log "Expected VPC_CONTROL_PLANE_SECURITY_GROUP_ID count: ${cp_sg_ids_expected_count}"
  fi
  if [[ "${ng_sg_attach_expected_count}" -gt 0 ]]; then
    log "Expected NODEGROUP_SECURITY_GROUPS_ATTACH_ID count: ${ng_sg_attach_expected_count}"
  fi
  if [[ "${ng_az_expected_count}" -gt 0 ]]; then
    log "Expected NODEGROUP_AVAILABILITY_ZONE count: ${ng_az_expected_count}"
  fi
  log "Additional nodegroups: ${additional_ng_count}"
  if [[ ${additional_ng_count} -gt 0 ]]; then
    log "  Suffixes: ${additional_ng_suffixes_upper[*]}"
  fi
  log "Expected total nodegroups: ${expected_total_nodegroup_count}"
  log "=================================================="

  for context_dir in "${context_dirs[@]}"; do
    log ""
    log "--- Validating ${context_dir} ---"

    validate_cluster_yaml_tokens "${context_dir}/cluster.yaml"

    if [[ -f "${context_dir}/cluster-controlplane-only.yaml" ]]; then
      validate_cluster_yaml_tokens "${context_dir}/cluster-controlplane-only.yaml"
    fi
  done

  log ""
  if [[ ${errors} -gt 0 ]]; then
    log_error "Pre-build validation failed with ${errors} error(s)"
    exit 1
  fi

  log "Pre-build validation complete - all token checks passed"
}

main "$@"
