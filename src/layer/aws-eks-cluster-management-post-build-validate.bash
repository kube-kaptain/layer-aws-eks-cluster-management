#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management-post-build-validate - Validate substituted cluster yaml and image integrity
#
# Runs after docker-build-dockerfile. Validates substituted cluster.yaml files
# on disk, then verifies the built image contains identical files.
#
# Phase 1 - Substituted file validation (against canonical values from prepare):
#   - metadata.name is exactly the canonical project-name
#   - metadata.region is exactly the canonical aws-region (and valid format)
#   - metadata.version is exactly the canonical kubernetes-version (and minor >= 2 digits)
#   - vpc.id looks like a VPC ID (vpc-<hex>)
#   - Subnet IDs look like subnet IDs (subnet-<hex>)
#   - All nodegroup names start with the canonical nodegroup-prefix
#   - If multiple nodegroups, names are unique
#   - No unsubstituted tokens remain
#
# Phase 2 - Image integrity:
#   - Checksum files on disk
#   - Run the built image and checksum the same files inside
#   - Compare checksums to ensure image matches validated files
#
# Inputs (environment variables):
#   DOCKER_PLATFORM            - Target platform(s)
#   TOKEN_DELIMITER_STYLE      - Token delimiter syntax (default: shell)
#   TOKEN_NAME_STYLE           - Case style for token names (default: PascalCase)
#   OUTPUT_SUB_PATH            - Build output directory (default: kaptain-out)
#   IMAGE_BUILD_COMMAND        - Container runtime: podman or docker
#   DOCKER_TAG                 - Image tag (from versions-and-naming)
#   DOCKER_IMAGE_NAME          - Image name (from versions-and-naming)
#   DOCKER_TARGET_REGISTRY     - Target registry
#   DOCKER_TARGET_NAMESPACE    - Target namespace
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
# shellcheck source=src/scripts/defaults/tokens.bash
source "${SCRIPT_DIR}/../defaults/tokens.bash"
# shellcheck source=src/scripts/defaults/docker-common.bash
source "${SCRIPT_DIR}/../defaults/docker-common.bash"
# shellcheck source=src/scripts/defaults/docker-build.bash
source "${SCRIPT_DIR}/../defaults/docker-build.bash"
# shellcheck source=src/scripts/defaults/aws-eks-cluster-management.bash
source "${SCRIPT_DIR}/../defaults/aws-eks-cluster-management.bash"

# === Source libs ===

# shellcheck source=src/scripts/lib/token-format.bash
source "${SCRIPT_DIR}/../lib/token-format.bash"
# shellcheck source=src/scripts/lib/docker-build-shared.bash
source "${SCRIPT_DIR}/../lib/docker-build-shared.bash"

# === Read canonical values from prepare output ===

canonical_dir="${OUTPUT_SUB_PATH}/aws-eks-cluster-management"
expected_values_dir="${canonical_dir}/expected-values"
canonical_error=0

for canonical_file in project-name aws-region kubernetes-version nodegroup-prefix cluster-origin nodegroup-type; do
  if [[ ! -f "${expected_values_dir}/${canonical_file}" ]]; then
    log_error "${expected_values_dir}/${canonical_file} not found - was aws-eks-cluster-management-prepare run?"
    canonical_error=1
  fi
done
if [[ "${canonical_error}" -ne 0 ]]; then
  exit 1
fi

project_name=$(< "${expected_values_dir}/project-name")
aws_region=$(< "${expected_values_dir}/aws-region")
kubernetes_version=$(< "${expected_values_dir}/kubernetes-version")
nodegroup_prefix=$(< "${expected_values_dir}/nodegroup-prefix")
cluster_origin=$(< "${expected_values_dir}/cluster-origin")
nodegroup_type=$(< "${expected_values_dir}/nodegroup-type")

if [[ "${nodegroup_type}" == "managed" ]]; then
  ng_yaml_key="managedNodeGroups"
else
  ng_yaml_key="nodeGroups"
fi

# Additional nodegroup metadata
additional_ng_count=0
if [[ -f "${expected_values_dir}/additional-nodegroup-count" ]]; then
  additional_ng_count=$(< "${expected_values_dir}/additional-nodegroup-count")
fi

declare -a additional_ng_suffixes_lower=()
if [[ ${additional_ng_count} -gt 0 && -f "${expected_values_dir}/additional-nodegroup-suffixes" ]]; then
  IFS=',' read -ra suffixes_upper <<< "$(< "${expected_values_dir}/additional-nodegroup-suffixes")"
  for s in "${suffixes_upper[@]}"; do
    additional_ng_suffixes_lower+=("$(echo "${s}" | tr '[:upper:]' '[:lower:]')")
  done
fi

expected_total_nodegroup_count=$((1 + additional_ng_count))

# === Determine context dirs and image URIs ===

declare -a context_dirs=()
declare -a image_uris=()

if [[ "${DOCKER_PLATFORM}" == *,* ]]; then
  IFS=',' read -ra platforms <<< "${DOCKER_PLATFORM}"
  for platform in "${platforms[@]}"; do
    platform_suffix="${platform//\//-}"
    case "${platform}" in
      linux/amd64)
        context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_AMD64}")
        ;;
      linux/arm64)
        context_dirs+=("${DOCKER_CONTEXT_SUB_PATH_LINUX_ARM64}")
        ;;
    esac
    image_uris+=("${TARGET_IMAGE_FULL_URI}-${platform_suffix}")
  done
else
  context_dirs=("${DOCKER_CONTEXT_SUB_PATH}")
  image_uris+=("${TARGET_IMAGE_FULL_URI}")
fi

# === Validation ===

errors=0

fail() {
  log_error "$1"
  errors=$((errors + 1))
}

# validate_flat_yaml_keys - Strict check that tag/label/annotation keys are clean after substitution
#
# Keys must be alphanumerics, hyphens, underscores, dots, slashes only.
# Catches unresolved token placeholders in key positions (yq accepts them as valid strings).
#
# Args:
#   $1 - yaml file path
#   $2 - yq path expression (e.g., ".metadata.tags")
validate_flat_yaml_keys() {
  local yaml_file="$1"
  local yq_path="$2"

  # Skip if section doesn't exist
  if ! yq -e "${yq_path}" "${yaml_file}" &>/dev/null; then
    return
  fi

  local keys
  keys=$(yq "${yq_path} | keys | .[]" "${yaml_file}" 2>/dev/null || true)
  while IFS= read -r key; do
    if [[ -z "${key}" ]]; then
      continue
    fi
    if [[ ! "${key}" =~ ^[A-Za-z][A-Za-z0-9_./-]*$ ]]; then
      fail "${yq_path}: key '${key}' contains invalid characters (unresolved token?)"
    fi
  done <<< "${keys}"
}

# validate_values_are_strings - Check all values in a YAML section are strings
#
# After token substitution, YAML-unsafe values (booleans, numbers, null, etc.)
# that were not quoted will be parsed as their coerced types by yq/eksctl.
# This catches any that slipped through without quotes.
#
# Args:
#   $1 - yaml file path
#   $2 - yq path expression (e.g., ".metadata.tags")
validate_values_are_strings() {
  local yaml_file="$1"
  local yq_path="$2"

  log ""
  log "    --- ${yq_path} ---"

  # Skip if section doesn't exist
  if ! yq -e "${yq_path}" "${yaml_file}" &>/dev/null; then
    log "    not present, skipping"
    return
  fi

  local value_count
  value_count=$(yq "${yq_path} | to_entries | length" "${yaml_file}" 2>/dev/null || echo "0")
  log "    ${value_count} entries"

  # Show each entry with its resolved YAML type
  local entries
  entries=$(yq "${yq_path} | to_entries[] | .key + \": \" + (.value | tostring) + \" (of type \" + (.value | tag) + \")\"" "${yaml_file}" 2>/dev/null || true)
  while IFS= read -r entry; do
    if [[ -z "${entry}" ]]; then
      continue
    fi
    if [[ "${entry}" == *"(of type !!str)" ]]; then
      log "    ${entry}"
    else
      fail "  ${yq_path}: ${entry} - not a string, quote it"
    fi
  done <<< "${entries}"
}

# Phase 1: Validate substituted yaml on disk
validate_substituted_yaml() {
  local yaml_file="$1"

  if [[ ! -f "${yaml_file}" ]]; then
    fail "${yaml_file}: file not found"
    return
  fi

  log "Validating substituted ${yaml_file}..."

  log ""
  log "  --- Token substitution ---"
  # No unsubstituted tokens remain
  local pattern
  pattern=$(unresolved_token_regex "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}")
  local remnants
  remnants=$(grep -E "${pattern}" "${yaml_file}" 2>/dev/null || true)
  if [[ -n "${remnants}" ]]; then
    fail "${yaml_file}: unsubstituted tokens found:"
    log_error "${remnants}"
  else
    log "  unsubstituted tokens: none found"
  fi

  log ""
  log "  --- Metadata fields ---"
  # metadata.name must be exactly the canonical project name
  local cluster_name
  cluster_name=$(yq '.metadata.name' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${cluster_name}" || "${cluster_name}" == "null" ]]; then
    fail "${yaml_file}: metadata.name is missing"
  elif [[ "${cluster_name}" != "${project_name}" ]]; then
    fail "${yaml_file}: metadata.name '${cluster_name}' must be exactly '${project_name}'"
  else
    log "  metadata.name: ${cluster_name} (expected: ${project_name})"
  fi

  # metadata.region must be exactly the canonical aws region (also format-checked)
  local region
  region=$(yq '.metadata.region' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${region}" || "${region}" == "null" ]]; then
    fail "${yaml_file}: metadata.region is missing"
  elif [[ "${region}" != "${aws_region}" ]]; then
    fail "${yaml_file}: metadata.region '${region}' must be exactly '${aws_region}'"
  elif [[ ! "${region}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    fail "${yaml_file}: metadata.region '${region}' does not look like an AWS region"
  else
    log "  metadata.region: ${region} (expected: ${aws_region})"
  fi

  # metadata.version must be exactly the canonical kubernetes version (format-checked)
  local version
  version=$(yq '.metadata.version' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    fail "${yaml_file}: metadata.version is missing"
  elif [[ "${version}" != "${kubernetes_version}" ]]; then
    fail "${yaml_file}: metadata.version '${version}' must be exactly '${kubernetes_version}'"
  elif [[ ! "${version}" =~ ^[0-9]+\.[0-9]{2,}$ ]]; then
    fail "${yaml_file}: metadata.version '${version}' must be major.minor where minor is at least 2 digits"
  else
    log "  metadata.version: ${version} (expected: ${kubernetes_version})"
  fi

  # metadata.annotations["kaptain.org/eks-cluster-security-group"] must be an SG ID
  local cluster_sg_annotation
  cluster_sg_annotation=$(yq '.metadata.annotations["kaptain.org/eks-cluster-security-group"]' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${cluster_sg_annotation}" || "${cluster_sg_annotation}" == "null" ]]; then
    fail "${yaml_file}: metadata.annotations[kaptain.org/eks-cluster-security-group] is missing"
  elif [[ "${cluster_sg_annotation}" != "sg-known-after-creation" && ! "${cluster_sg_annotation}" =~ ^sg-[0-9a-f]+$ ]]; then
    fail "${yaml_file}: metadata.annotations[kaptain.org/eks-cluster-security-group] '${cluster_sg_annotation}' does not look like a security group ID (expected sg-<hex> or sg-known-after-creation)"
  else
    log "  metadata.annotations[kaptain.org/eks-cluster-security-group]: ${cluster_sg_annotation}"
  fi

  log ""
  log "  --- VPC ---"
  # vpc.id must look like a VPC ID
  local vpc_id
  vpc_id=$(yq '.vpc.id' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -z "${vpc_id}" || "${vpc_id}" == "null" ]]; then
    fail "${yaml_file}: vpc.id is missing"
  elif [[ ! "${vpc_id}" =~ ^vpc-[0-9a-f]+$ ]]; then
    fail "${yaml_file}: vpc.id '${vpc_id}' does not look like a VPC ID (expected vpc-<hex>)"
  else
    log "  vpc.id: ${vpc_id}"
  fi

  # Security group validation
  local has_sg="false"
  local has_cp_sg_ids="false"

  local sg_value
  sg_value=$(yq '.vpc.securityGroup' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -n "${sg_value}" && "${sg_value}" != "null" ]]; then
    has_sg="true"
    if [[ ! "${sg_value}" =~ ^sg-[0-9a-f]+$ ]]; then
      fail "${yaml_file}: vpc.securityGroup '${sg_value}' does not look like a security group ID (expected sg-<hex>)"
    else
      log "  vpc.securityGroup: ${sg_value}"
    fi
  fi

  local shared_node_sg_value
  shared_node_sg_value=$(yq '.vpc.sharedNodeSecurityGroup' "${yaml_file}" 2>/dev/null || echo "")
  if [[ -n "${shared_node_sg_value}" && "${shared_node_sg_value}" != "null" ]]; then
    if [[ ! "${shared_node_sg_value}" =~ ^sg-[0-9a-f]+$ ]]; then
      fail "${yaml_file}: vpc.sharedNodeSecurityGroup '${shared_node_sg_value}' does not look like a security group ID (expected sg-<hex>)"
    else
      log "  vpc.sharedNodeSecurityGroup: ${shared_node_sg_value}"
    fi
  fi

  local cp_sg_count
  cp_sg_count=$(yq '.vpc.controlPlaneSecurityGroupIDs | length' "${yaml_file}" 2>/dev/null || echo "0")
  if [[ "${cp_sg_count}" -gt 0 ]]; then
    has_cp_sg_ids="true"
    log "  vpc.controlPlaneSecurityGroupIDs: ${cp_sg_count} entries"
    local cp_sg_ids
    cp_sg_ids=$(yq '.vpc.controlPlaneSecurityGroupIDs[]' "${yaml_file}" 2>/dev/null || true)
    while IFS= read -r sg_id; do
      if [[ -z "${sg_id}" ]]; then
        continue
      fi
      if [[ ! "${sg_id}" =~ ^sg-[0-9a-f]+$ ]]; then
        fail "${yaml_file}: vpc.controlPlaneSecurityGroupIDs entry '${sg_id}' does not look like a security group ID (expected sg-<hex>)"
      else
        log "    ${sg_id}: valid SG ID"
      fi
    done <<< "${cp_sg_ids}"
  fi

  # Mutual exclusion: cannot have both securityGroup and controlPlaneSecurityGroupIDs
  if [[ "${has_sg}" == "true" && "${has_cp_sg_ids}" == "true" ]]; then
    fail "${yaml_file}: vpc.securityGroup and vpc.controlPlaneSecurityGroupIDs are mutually exclusive"
  fi

  # Adopted clusters require a control plane security group
  if [[ "${cluster_origin}" == "adopted" && "${has_sg}" == "false" && "${has_cp_sg_ids}" == "false" ]]; then
    fail "${yaml_file}: cluster origin is 'adopted' - vpc.securityGroup or vpc.controlPlaneSecurityGroupIDs is required"
  fi

  if [[ "${has_sg}" == "false" && "${has_cp_sg_ids}" == "false" ]]; then
    log "  vpc security group: not specified (eksctl will create one)"
  fi

  # Subnet keys must be region + single AZ letter; IDs must look like subnet IDs
  local subnet_type
  for subnet_type in private public; do
    if yq -e ".vpc.subnets.${subnet_type}" "${yaml_file}" &>/dev/null; then
      log "  vpc.subnets.${subnet_type}:"

      # Validate AZ keys: must be canonical region + single lowercase letter
      local az_keys
      az_keys=$(yq ".vpc.subnets.${subnet_type} | keys | .[]" "${yaml_file}" 2>/dev/null || true)
      while IFS= read -r az_key; do
        if [[ -z "${az_key}" ]]; then
          continue
        fi
        if [[ ! "${az_key}" =~ ^${aws_region}[a-z]$ ]]; then
          fail "${yaml_file}: ${subnet_type} subnet key '${az_key}' must be region + single AZ letter (e.g., ${aws_region}a)"
        else
          log "    ${az_key}: valid AZ key"
        fi
      done <<< "${az_keys}"

      # Validate subnet IDs: must look like subnet IDs
      local subnet_ids
      subnet_ids=$(yq ".vpc.subnets.${subnet_type}[].id" "${yaml_file}" 2>/dev/null || true)
      while IFS= read -r sid; do
        if [[ -z "${sid}" || "${sid}" == "null" ]]; then
          continue
        fi
        if [[ ! "${sid}" =~ ^subnet-[0-9a-f]+$ ]]; then
          fail "${yaml_file}: ${subnet_type} subnet id '${sid}' does not look like a subnet ID (expected subnet-<hex>)"
        else
          log "    ${sid}: valid subnet ID"
        fi
      done <<< "${subnet_ids}"
    fi
  done

  log ""
  log "  --- Node groups ---"
  # All nodegroup names start with computed prefix
  local nodegroup_count
  nodegroup_count=$(yq ".${ng_yaml_key} | length" "${yaml_file}" 2>/dev/null || echo "0")

  log "  ${ng_yaml_key}: ${nodegroup_count} found (expected: ${expected_total_nodegroup_count})"

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

      if [[ "${ng_name}" != "${nodegroup_prefix}"* ]]; then
        fail "${yaml_file}: ${ng_yaml_key}[${i}].name '${ng_name}' does not start with nodegroup prefix '${nodegroup_prefix}'"
      else
        # Base nodegroup: name is exactly the prefix
        # Additional nodegroups: name is prefix-suffix
        if [[ ${i} -eq 0 ]]; then
          log "  ${ng_yaml_key}[${i}].name: ${ng_name} (base, prefix: ${nodegroup_prefix})"
        else
          local adj_idx=$((i - 1))
          if [[ ${adj_idx} -lt ${#additional_ng_suffixes_lower[@]} ]]; then
            local expected_suffix="${additional_ng_suffixes_lower[${adj_idx}]}"
            local expected_name="${nodegroup_prefix}-${expected_suffix}"
            if [[ "${ng_name}" != "${expected_name}" ]]; then
              fail "${yaml_file}: ${ng_yaml_key}[${i}].name '${ng_name}' must be exactly '${expected_name}'"
            else
              log "  ${ng_yaml_key}[${i}].name: ${ng_name} (additional: ${expected_suffix})"
            fi
          fi
        fi
      fi

      ng_names+=("${ng_name}")
    done

    # Unique names check
    if [[ "${nodegroup_count}" -gt 1 && ${#ng_names[@]} -gt 0 ]]; then
      local unique_count
      unique_count=$(printf '%s\n' "${ng_names[@]}" | sort -u | wc -l | tr -d ' ')
      if [[ "${unique_count}" -ne "${nodegroup_count}" ]]; then
        fail "${yaml_file}: duplicate nodegroup names found - each must be unique (add suffixes)"
      else
        log "  nodegroup names: ${nodegroup_count} unique"
      fi
    fi

    # eksctl auto-sets Name tag on nodegroup EC2 instances - user-supplied Name conflicts
    for i in $(seq 0 $((nodegroup_count - 1))); do
      if yq -e ".${ng_yaml_key}[${i}].tags.Name" "${yaml_file}" &>/dev/null; then
        fail "${yaml_file}: ${ng_yaml_key}[${i}].tags.Name is reserved - eksctl sets it from the nodegroup name"
      fi
    done

    log ""
    log "  --- Node group value types ---"
    # Validate nodegroup labels and tags keys and values
    for i in $(seq 0 $((nodegroup_count - 1))); do
      validate_flat_yaml_keys "${yaml_file}" ".${ng_yaml_key}[${i}].labels"
      validate_flat_yaml_keys "${yaml_file}" ".${ng_yaml_key}[${i}].tags"
      validate_values_are_strings "${yaml_file}" ".${ng_yaml_key}[${i}].labels"
      validate_values_are_strings "${yaml_file}" ".${ng_yaml_key}[${i}].tags"
    done

    # Validate per-nodegroup fields on ALL nodegroups
    for ng_idx in $(seq 0 $((nodegroup_count - 1))); do
      log ""
      log "  --- Node group [${ng_idx}] field validation ---"

      # securityGroups.attachIDs
      local ng_sg_attach_count
      ng_sg_attach_count=$(yq ".${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs | length" "${yaml_file}" 2>/dev/null || echo "0")
      if [[ "${ng_sg_attach_count}" -gt 0 ]]; then
        log "  ${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs: ${ng_sg_attach_count} entries"
        local ng_sg_ids
        ng_sg_ids=$(yq ".${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs[]" "${yaml_file}" 2>/dev/null || true)
        while IFS= read -r sg_id; do
          if [[ -z "${sg_id}" ]]; then
            continue
          fi
          if [[ ! "${sg_id}" =~ ^sg-[0-9a-f]+$ ]]; then
            fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].securityGroups.attachIDs entry '${sg_id}' does not look like a security group ID (expected sg-<hex>)"
          else
            log "    ${sg_id}: valid SG ID"
          fi
        done <<< "${ng_sg_ids}"
      fi

      # volumeType
      local volume_type_value
      volume_type_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeType" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_type_value}" && "${volume_type_value}" != "null" ]]; then
        case "${volume_type_value}" in
          gp2|gp3|io1|io2|st1|sc1|standard)
            log "  ${ng_yaml_key}[${ng_idx}].volumeType: ${volume_type_value}"
            ;;
          *)
            fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeType '${volume_type_value}' must be one of: gp2, gp3, io1, io2, st1, sc1, standard"
            ;;
        esac
      fi

      # volumeEncrypted
      local volume_encrypted_value
      volume_encrypted_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeEncrypted" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_encrypted_value}" && "${volume_encrypted_value}" != "null" ]]; then
        if [[ "${volume_encrypted_value}" == "true" || "${volume_encrypted_value}" == "false" ]]; then
          log "  ${ng_yaml_key}[${ng_idx}].volumeEncrypted: ${volume_encrypted_value}"
        else
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeEncrypted '${volume_encrypted_value}' must be true or false"
        fi
      fi

      # volumeKmsKeyID
      local volume_kms_key_id_value
      volume_kms_key_id_value=$(yq ".${ng_yaml_key}[${ng_idx}].volumeKmsKeyID" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${volume_kms_key_id_value}" && "${volume_kms_key_id_value}" != "null" ]]; then
        if [[ "${volume_kms_key_id_value}" =~ ^arn:aws:kms:.+$ ]]; then
          log "  ${ng_yaml_key}[${ng_idx}].volumeKmsKeyID: ${volume_kms_key_id_value}"
        else
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].volumeKmsKeyID '${volume_kms_key_id_value}' must be a KMS key ARN (expected arn:aws:kms:...)"
        fi
      fi

      # spot
      local spot_value
      spot_value=$(yq ".${ng_yaml_key}[${ng_idx}].spot" "${yaml_file}" 2>/dev/null || echo "")
      if [[ -n "${spot_value}" && "${spot_value}" != "null" ]]; then
        if [[ "${spot_value}" == "true" || "${spot_value}" == "false" ]]; then
          log "  ${ng_yaml_key}[${ng_idx}].spot: ${spot_value}"
        else
          fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].spot '${spot_value}' must be true or false"
        fi
      fi

      # taints
      local taint_count
      taint_count=$(yq ".${ng_yaml_key}[${ng_idx}].taints | length" "${yaml_file}" 2>/dev/null || echo "0")
      if [[ "${taint_count}" -gt 0 ]]; then
        log "  ${ng_yaml_key}[${ng_idx}].taints: ${taint_count} entries"
        for idx in $(seq 0 $((taint_count - 1))); do
          local taint_key
          taint_key=$(yq ".${ng_yaml_key}[${ng_idx}].taints[${idx}].key" "${yaml_file}" 2>/dev/null || echo "")
          if [[ -z "${taint_key}" || "${taint_key}" == "null" ]]; then
            fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].taints[${idx}] missing 'key'"
          fi

          local taint_effect
          taint_effect=$(yq ".${ng_yaml_key}[${ng_idx}].taints[${idx}].effect" "${yaml_file}" 2>/dev/null || echo "")
          if [[ -z "${taint_effect}" || "${taint_effect}" == "null" ]]; then
            fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].taints[${idx}] missing 'effect'"
          else
            case "${taint_effect}" in
              NoSchedule|PreferNoSchedule|NoExecute)
                log "    taint[${idx}]: key=${taint_key} effect=${taint_effect}"
                ;;
              *)
                fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].taints[${idx}].effect '${taint_effect}' must be one of: NoSchedule, PreferNoSchedule, NoExecute"
                ;;
            esac
          fi
        done
      fi

      # availabilityZones
      local ng_az_count
      ng_az_count=$(yq ".${ng_yaml_key}[${ng_idx}].availabilityZones | length" "${yaml_file}" 2>/dev/null || echo "0")
      if [[ "${ng_az_count}" -gt 0 ]]; then
        log "  ${ng_yaml_key}[${ng_idx}].availabilityZones: ${ng_az_count} entries"
        local ng_azs
        ng_azs=$(yq ".${ng_yaml_key}[${ng_idx}].availabilityZones[]" "${yaml_file}" 2>/dev/null || true)
        while IFS= read -r az_value; do
          if [[ -z "${az_value}" ]]; then
            continue
          fi
          if [[ ! "${az_value}" =~ ^[a-z]{2}-[a-z]+-[0-9]+[a-z]$ ]]; then
            fail "${yaml_file}: ${ng_yaml_key}[${ng_idx}].availabilityZones entry '${az_value}' does not look like an AZ (expected region + single letter, e.g., eu-west-1a)"
          else
            log "    ${az_value}: valid AZ"
          fi
        done <<< "${ng_azs}"
      fi
    done
  fi

  # eksctl auto-sets Name tag - user-supplied Name in metadata tags feeds into nodegroups
  if yq -e ".metadata.tags.Name" "${yaml_file}" &>/dev/null; then
    fail "${yaml_file}: metadata.tags.Name is reserved - eksctl sets it from the nodegroup name"
  fi

  log ""
  log "  --- Metadata value types ---"
  # Validate metadata tags and annotations keys and values
  validate_flat_yaml_keys "${yaml_file}" ".metadata.tags"
  validate_flat_yaml_keys "${yaml_file}" ".metadata.annotations"
  validate_values_are_strings "${yaml_file}" ".metadata.tags"
  validate_values_are_strings "${yaml_file}" ".metadata.annotations"
}

# Phase 2: Validate image integrity
validate_image_integrity() {
  local context_dir="$1"
  local image_uri="$2"

  log ""
  log "Validating image integrity: ${image_uri}..."

  # Collect files to check and their disk checksums as parallel arrays
  declare -a check_files=()
  declare -a disk_checksums=()

  for file in cluster.yaml cluster-controlplane-only.yaml; do
    if [[ -f "${context_dir}/${file}" ]]; then
      check_files+=("${file}")
      local checksum
      checksum=$(sha256sum "${context_dir}/${file}" | cut -d' ' -f1)
      disk_checksums+=("${checksum}")
      log "  ${file} disk checksum: ${checksum}"
    fi
  done

  if [[ ${#check_files[@]} -eq 0 ]]; then
    fail "${context_dir}: no cluster yaml files found to verify"
    return
  fi

  # Build a command to checksum files inside the image
  local checksum_cmd="sha256sum"
  for file in "${check_files[@]}"; do
    checksum_cmd="${checksum_cmd} /kd/eks/${file}"
  done

  # Run the image and get checksums
  local image_output
  image_output=$(${IMAGE_BUILD_COMMAND} run --rm --entrypoint="" "${image_uri}" sh -c "${checksum_cmd}" 2>&1) || {
    fail "Failed to run image ${image_uri} for integrity check"
    return
  }

  # Compare checksums
  for i in "${!check_files[@]}"; do
    local file="${check_files[${i}]}"
    local expected="${disk_checksums[${i}]}"
    local image_checksum
    image_checksum=$(echo "${image_output}" | grep "/kd/eks/${file}" | cut -d' ' -f1)
    if [[ -z "${image_checksum}" ]]; then
      fail "${image_uri}: /kd/eks/${file} not found in image"
    elif [[ "${image_checksum}" != "${expected}" ]]; then
      fail "${image_uri}: /kd/eks/${file} checksum mismatch (disk: ${expected}, image: ${image_checksum})"
    else
      log "  ${file} image checksum matches disk"
    fi
  done
}

# === Main ===

main() {
  log "=== EKS Cluster Management Post-Build Validate ==="
  log "Cluster origin: ${cluster_origin}"
  log "Project name: ${project_name}"
  log "AWS region: ${aws_region}"
  log "Kubernetes version: ${kubernetes_version}"
  log "Nodegroup prefix: ${nodegroup_prefix}"
  log "Additional nodegroups: ${additional_ng_count}"
  log "Expected total nodegroups: ${expected_total_nodegroup_count}"
  log "==================================================="

  # Phase 1: Validate substituted files on disk
  for context_dir in "${context_dirs[@]}"; do
    log ""
    log "--- Phase 1: Validating substituted files in ${context_dir} ---"

    validate_substituted_yaml "${context_dir}/cluster.yaml"

    if [[ -f "${context_dir}/cluster-controlplane-only.yaml" ]]; then
      validate_substituted_yaml "${context_dir}/cluster-controlplane-only.yaml"
    fi
  done

  # Copy substituted cluster yamls to canonical dir for diff/inspection
  local substituted_dir="${canonical_dir}/substituted"
  mkdir -p "${substituted_dir}"
  local first_context_dir="${context_dirs[0]}"
  cp "${first_context_dir}/cluster.yaml" "${substituted_dir}/cluster.yaml"
  log "  cluster.yaml: copied to ${substituted_dir}/"
  if [[ -f "${first_context_dir}/cluster-controlplane-only.yaml" ]]; then
    cp "${first_context_dir}/cluster-controlplane-only.yaml" "${substituted_dir}/cluster-controlplane-only.yaml"
    log "  cluster-controlplane-only.yaml: copied to ${substituted_dir}/"
  fi

  # Phase 2: Validate image integrity
  for i in "${!context_dirs[@]}"; do
    log ""
    log "--- Phase 2: Validating image integrity ---"
    validate_image_integrity "${context_dirs[${i}]}" "${image_uris[${i}]}"
  done

  log ""
  if [[ ${errors} -gt 0 ]]; then
    log_error "Post-build validation failed with ${errors} error(s)"
    exit 1
  fi

  log "Post-build validation complete - all checks passed"
}

main "$@"
