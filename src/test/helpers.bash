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

# OUTPUT_SUB_PATH must be a relative path under PROJECT_ROOT. Defensively reset
# if the outer env (e.g. a polluted interactive shell) has set it absolute,
# otherwise SCRIPTS_STAGE_DIR below ends up doubled (PROJECT_ROOT/PROJECT_ROOT/...).
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
case "${OUTPUT_SUB_PATH}" in
  /*) OUTPUT_SUB_PATH="kaptain-out" ;;
esac
TEST_TARGET_DIR="${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test"
SCRIPTS_STAGE_DIR="${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test-fixtures"
SCRIPTS_DIR="${SCRIPTS_STAGE_DIR}/main"

# Capture any real build-scripts tree the outer build points us at BEFORE we
# repoint BUILD_SCRIPTS_DIR at the staged fixture tree below. Used only to stage
# the handful of REAL utils tests genuinely need (a stub can't fake scanning);
# everything else stays a stub.
_INCOMING_BUILD_SCRIPTS_DIR="${BUILD_SCRIPTS_DIR:-}"

# The layer scripts source buildon defaults/libs via ${BUILD_SCRIPTS_DIR}. Point
# it at the staged fixture tree so tests resolve the stubs (never a real buildon
# checkout). Forced, not defaulted: tests must always use the fixtures.
export BUILD_SCRIPTS_DIR="${SCRIPTS_STAGE_DIR}"
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

  # Layer scripts source their own defaults co-located (${SCRIPT_DIR}/aws-eks-cluster-management-defaults.bash),
  # so stage the layer defaults next to the scripts in main/, not under defaults/.
  cp "${layer_dir}/aws-eks-cluster-management-defaults.bash" "${SCRIPTS_DIR}/aws-eks-cluster-management-defaults.bash"
  cp "${fixtures_dir}/defaults/"*.bash "${SCRIPTS_STAGE_DIR}/defaults/"
  cp "${fixtures_dir}/lib/"*.bash "${SCRIPTS_STAGE_DIR}/lib/"

  # Stage the REAL scan-unresolved-tokens util (not a stub): post-build-validate
  # shells out to it to detect unsubstituted token remnants, and a stub cannot
  # fake real scanning. Source of truth is the build-scripts tree - the outer
  # build's BUILD_SCRIPTS_DIR when it points at a real tree, else the
  # user-scripts repo-root var + src/scripts. The util sources its ../lib and
  # ../defaults siblings, which resolve to the staged stubs (they carry the
  # functions it needs). If neither source resolves, the util is not staged and
  # the tests that need it skip.
  mkdir -p "${SCRIPTS_STAGE_DIR}/util"
  # Probe for the real util file itself (not just a util/ dir) and never trust
  # our own staging dir as the source: BUILD_SCRIPTS_DIR is exported and, across
  # bats tests, arrives already pointing at the staging tree, which would be a
  # self-reference back to the empty util/ we just created.
  local real_scripts_src=""
  if [[ -n "${_INCOMING_BUILD_SCRIPTS_DIR}" \
        && "${_INCOMING_BUILD_SCRIPTS_DIR}" != "${SCRIPTS_STAGE_DIR}" \
        && -f "${_INCOMING_BUILD_SCRIPTS_DIR}/util/scan-unresolved-tokens" ]]; then
    real_scripts_src="${_INCOMING_BUILD_SCRIPTS_DIR}"
  elif [[ -n "${KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT:-}" \
          && -f "${KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT}/src/scripts/util/scan-unresolved-tokens" ]]; then
    real_scripts_src="${KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT}/src/scripts"
  fi
  if [[ -n "${real_scripts_src}" ]]; then
    cp "${real_scripts_src}/util/scan-unresolved-tokens" "${SCRIPTS_STAGE_DIR}/util/scan-unresolved-tokens"
    chmod +x "${SCRIPTS_STAGE_DIR}/util/scan-unresolved-tokens"
  fi
}

_stage_layer_scripts

source "${SCRIPTS_STAGE_DIR}/defaults/platform.bash"
source "${SCRIPTS_STAGE_DIR}/lib/log.bash"

# create_test_sandbox - Per-test relative sandbox under OUTPUT_SUB_PATH.
#
# Returns a RELATIVE path of the form
#   kaptain-out/tests/bats/<batsfile-basename>/<bats-test-name>[/<suffix>]
# rm -rf + mkdir -p the absolute equivalent, then cd to PROJECT_ROOT so the
# returned relative path resolves consistently when the script-under-test reads
# it as ${OUTPUT_SUB_PATH}/<...>.
#
# Args:
#   $1 - optional suffix appended to the relative subpath (e.g. "target", "base")
create_test_sandbox() {
  local suffix="${1:-}"
  local batsfile_base
  batsfile_base=$(basename "${BATS_TEST_FILENAME:-unknown}" .bats)
  local test_name="${BATS_TEST_NAME:-shared}"
  local sandbox_rel="kaptain-out/tests/bats/${batsfile_base}/${test_name}"
  if [[ -n "${suffix}" ]]; then
    sandbox_rel="${sandbox_rel}/${suffix}"
  fi
  local sandbox_abs="${PROJECT_ROOT}/${sandbox_rel}"
  rm -rf "${sandbox_abs}"
  mkdir -p "${sandbox_abs}"
  cd "${PROJECT_ROOT}" || return 1
  echo "${sandbox_rel}"
}

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
