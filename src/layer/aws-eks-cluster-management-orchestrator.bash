#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management-orchestrator.bash
#
# Drives the full EKS cluster management build sequence as a single
# postVersionsAndNaming hook on top of the basic-quality-and-versioning
# workflow. Replaces the dedicated aws-eks-cluster-management workflow
# that previously lived in buildon-github-actions.
#
# Sequence (each step aborts the build on non-zero exit):
#   1. Source defaults
#   2. Run prepare       (generates cluster.yaml + Dockerfile)
#   3. Run user pre-docker-prepare hook (optional)
#   4. Run pre-build-validate
#   5. Run buildon docker-build-dockerfile
#   6. Run post-build-validate
#   7. Run user post-docker-tests hook (optional)
#
# Inputs (environment, all set by buildon hook-post-versions-and-naming):
#   OUTPUT_SUB_PATH                       - Build output dir (typically kaptain-out)
#   VERSION, DOCKER_TAG, PROJECT_NAME etc - Standard buildon naming outputs
#
# Consumer config (read from user-data.aws-eks-cluster-management in
# kaptainpm/final/KaptainPM.yaml). All optional; defaults from
# aws-eks-cluster-management-defaults.bash apply when unset:
#
#   baseImage.registry        -> EKS_BASE_IMAGE_REGISTRY
#   baseImage.namespace       -> EKS_BASE_IMAGE_NAMESPACE
#   baseImage.name            -> EKS_BASE_IMAGE_NAME
#   baseImage.tag             -> EKS_BASE_IMAGE_TAG
#   clusterYamlSubPath        -> EKS_CLUSTER_YAML_SUB_PATH
#   privateNetworking         -> EKS_PRIVATE_NETWORKING
#   publicNetworking          -> EKS_PUBLIC_NETWORKING
#   ciliumEbpfNetworking      -> EKS_CILIUM_EBPF_NETWORKING
#   userPreDockerPrepare      -> path to consumer pre-docker-prepare hook script
#   userPostDockerTests       -> path to consumer post-docker-tests hook script
#
# Hook scripts are paths relative to repo root and must be executable.
#
# Inputs (required environment):
#   BUILD_SCRIPTS_REPO_ROOT - Path to the build scripts repo root
#                             (provided by the build system)

set -euo pipefail

if [[ -z "${BUILD_SCRIPTS_REPO_ROOT:-}" ]]; then
  echo "ERROR: BUILD_SCRIPTS_REPO_ROOT is not set." >&2
  echo "       This variable must be provided by the build system and points to" >&2
  echo "       the root of the build scripts repo (e.g. buildon-github-actions)." >&2
  exit 1
fi
if [[ ! -d "${BUILD_SCRIPTS_REPO_ROOT}/src/scripts" ]]; then
  echo "ERROR: BUILD_SCRIPTS_REPO_ROOT does not contain src/scripts:" >&2
  echo "       ${BUILD_SCRIPTS_REPO_ROOT}/src/scripts" >&2
  exit 1
fi

LAYER_PAYLOAD_DIR="${OUTPUT_SUB_PATH:-kaptain-out}"
BUILD_SCRIPTS_DIR="${BUILD_SCRIPTS_REPO_ROOT}/src/scripts"
export BUILD_SCRIPTS_DIR
FINAL_KPM="kaptainpm/final/KaptainPM.yaml"

read_user_data() {
  local key="$1"
  if [[ ! -f "${FINAL_KPM}" ]]; then
    echo ""
    return 0
  fi
  local value
  value=$(yq -r ".user-data.aws-eks-cluster-management.${key} // \"\"" "${FINAL_KPM}")
  if [[ "${value}" == "null" ]]; then
    value=""
  fi
  echo "${value}"
}

export_from_user_data() {
  local key="$1"
  local var_name="$2"
  local value
  value=$(read_user_data "${key}")
  if [[ -n "${value}" ]]; then
    export "${var_name}=${value}"
    echo "user-data: exported ${var_name} from .user-data.aws-eks-cluster-management.${key}"
  fi
}

# Export EKS config from user-data BEFORE sourcing defaults so user values
# win and unset values fall through to the defaults file.
export_from_user_data "baseImage.registry"    EKS_BASE_IMAGE_REGISTRY
export_from_user_data "baseImage.namespace"   EKS_BASE_IMAGE_NAMESPACE
export_from_user_data "baseImage.name"        EKS_BASE_IMAGE_NAME
export_from_user_data "baseImage.tag"         EKS_BASE_IMAGE_TAG
export_from_user_data "clusterYamlSubPath"    EKS_CLUSTER_YAML_SUB_PATH
export_from_user_data "privateNetworking"     EKS_PRIVATE_NETWORKING
export_from_user_data "publicNetworking"      EKS_PUBLIC_NETWORKING
export_from_user_data "ciliumEbpfNetworking"  EKS_CILIUM_EBPF_NETWORKING

USER_PRE_DOCKER_PREPARE_SCRIPT=$(read_user_data userPreDockerPrepare)
USER_POST_DOCKER_TESTS_SCRIPT=$(read_user_data userPostDockerTests)

banner() {
  echo
  echo "=== aws-eks-cluster-management-orchestrator: $1 ==="
  echo
}

run_step() {
  local label="$1"
  shift
  banner "${label}"

  local step_output_file="${LAYER_PAYLOAD_DIR}/reference-script-output/${label}"
  mkdir -p "$(dirname "${step_output_file}")"
  : > "${step_output_file}"

  if ! REFERENCE_SCRIPT_OUTPUT="${step_output_file}" "$@"; then
    echo "ERROR: ${label} failed (exit $?)" >&2
    exit 1
  fi

  if [[ -s "${step_output_file}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      export "${line%%=*}"="${line#*=}"
    done < "${step_output_file}"
  fi
}

run_optional_user_hook() {
  local label="$1"
  local script_path="$2"
  if [[ -z "${script_path}" ]]; then
    echo "(skipping ${label}: not configured)"
    return 0
  fi
  if [[ ! -f "${script_path}" ]]; then
    echo "ERROR: ${label} configured but file not found: ${script_path}" >&2
    exit 2
  fi
  if [[ ! -x "${script_path}" ]]; then
    echo "ERROR: ${label} configured but not executable: ${script_path}" >&2
    exit 3
  fi
  banner "${label}: ${script_path}"
  "${script_path}"
}

# Step 1: defaults
banner "load defaults"
# shellcheck source=aws-eks-cluster-management-defaults.bash
source "${LAYER_PAYLOAD_DIR}/aws-eks-cluster-management-defaults.bash"

# Step 2: prepare
run_step "prepare" bash "${LAYER_PAYLOAD_DIR}/aws-eks-cluster-management-prepare.bash"

# Step 3: user pre-docker-prepare hook (optional)
run_optional_user_hook "user pre-docker-prepare" "${USER_PRE_DOCKER_PREPARE_SCRIPT}"

# Step 4: pre-build-validate
run_step "pre-build-validate" bash "${LAYER_PAYLOAD_DIR}/aws-eks-cluster-management-pre-build-validate.bash"

# Step 5: buildon docker-build-dockerfile
run_step "docker-build-dockerfile" bash "${BUILD_SCRIPTS_DIR}/main/docker-build-dockerfile"

# Step 6: post-build-validate
run_step "post-build-validate" bash "${LAYER_PAYLOAD_DIR}/aws-eks-cluster-management-post-build-validate.bash"

# Step 7: user post-docker-tests hook (optional)
run_optional_user_hook "user post-docker-tests" "${USER_POST_DOCKER_TESTS_SCRIPT}"

banner "complete"
