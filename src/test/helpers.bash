# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# helpers.bash - Test helpers for layer-aws-eks-cluster-management
#
# Stages a buildon-shaped scripts tree under
#   ${OUTPUT_SUB_PATH}/test-fixtures/{main,defaults,lib}/
# so the layer scripts (which reference ${SCRIPT_DIR}/../defaults and ../lib)
# resolve to local fixture stubs. Stubs live in src/test/fixtures.

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

export BUILD_PLATFORM="${BUILD_PLATFORM:-test}"

OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
TEST_TARGET_DIR="${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test"
SCRIPTS_STAGE_DIR="${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test-fixtures"
SCRIPTS_DIR="${SCRIPTS_STAGE_DIR}/main"
MOCK_BIN_DIR="${TEST_TARGET_DIR}/$(basename "${BATS_TEST_FILENAME:-unknown}" .bats)/mock-bin"

_TEST_DIR_COUNTER=0

_stage_layer_scripts() {
  local layer_dir="${PROJECT_ROOT}/src/layer"
  local fixtures_dir="${PROJECT_ROOT}/src/test/fixtures"

  rm -rf "${SCRIPTS_STAGE_DIR}"
  mkdir -p "${SCRIPTS_DIR}" "${SCRIPTS_STAGE_DIR}/defaults" "${SCRIPTS_STAGE_DIR}/lib"

  local name
  for name in aws-eks-cluster-management-prepare aws-eks-cluster-management-pre-build-validate aws-eks-cluster-management-post-build-validate; do
    cp "${layer_dir}/${name}.bash" "${SCRIPTS_DIR}/${name}"
    chmod +x "${SCRIPTS_DIR}/${name}"
  done

  cp "${layer_dir}/aws-eks-cluster-management-defaults.bash" "${SCRIPTS_STAGE_DIR}/defaults/aws-eks-cluster-management.bash"
  cp "${fixtures_dir}/defaults/"*.bash "${SCRIPTS_STAGE_DIR}/defaults/"
  cp "${fixtures_dir}/lib/"*.bash "${SCRIPTS_STAGE_DIR}/lib/"
}

_stage_layer_scripts

source "${SCRIPTS_STAGE_DIR}/defaults/platform.bash"
source "${SCRIPTS_STAGE_DIR}/lib/log.bash"

create_test_dir() {
  local prefix="${1:-test}"
  local bats_file_base
  bats_file_base=$(basename "${BATS_TEST_FILENAME}" .bats)
  local test_base_dir="${TEST_TARGET_DIR}/${bats_file_base}/${BATS_TEST_NAME:-unknown}"

  _TEST_DIR_COUNTER=$((_TEST_DIR_COUNTER + 1))
  local dir="${test_base_dir}/${prefix}-${_TEST_DIR_COUNTER}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  echo "${dir}"
}

assert_output_contains() {
  local expected="$1"
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "Expected output to contain: ${expected}"
    echo "Actual output: ${output}"
    return 1
  fi
}

assert_contains() {
  local content="$1"
  local pattern="$2"
  local label="${3:-manifest}"
  if [[ "${content}" != *"${pattern}"* ]]; then
    echo "EXPECTED PATTERN: ${pattern}" >&3
    echo "ACTUAL ${label}:" >&3
    echo "${content}" >&3
    return 1
  fi
}

assert_docker_called() {
  local expected="$1"
  if ! grep -q -- "${expected}" "${MOCK_DOCKER_CALLS}" 2>/dev/null; then
    echo "Expected docker to be called with: ${expected}"
    echo "Actual calls:"
    cat "${MOCK_DOCKER_CALLS}" 2>/dev/null || echo "(none)"
    return 1
  fi
}
