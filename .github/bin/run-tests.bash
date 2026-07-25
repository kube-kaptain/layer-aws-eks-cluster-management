#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# run-tests.bash - Run BATS tests for layer-aws-eks-cluster-management
#
# Run all tests:    .github/bin/run-tests.bash
# Run one file:     bats src/test/<file>.bats

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR="${PROJECT_ROOT}/src/test"

if [[ $# -gt 0 ]]; then
  echo "ERROR: this runner runs all *.bats. To run specific files use: bats <file>"
  exit 1
fi

OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
rm -rf "${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test"
mkdir -p "${PROJECT_ROOT}/${OUTPUT_SUB_PATH}/test"

cd "${TEST_DIR}"

# bats must run on the host, not in an isolated container: the tests shell out
# to yq (and other host tools the build system already validates), which an
# alpine bats image would not carry. If bats is missing, install it (Ubuntu with
# passwordless sudo); macOS dev machines already have it via Homebrew.
if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found - installing via apt (Ubuntu)..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq bats
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats is not available and could not be installed" >&2
  exit 1
fi

echo "Build scripts location source variable and value:"
if [[ -n "${BUILD_SCRIPTS_REPO_ROOT:-}" ]]; then
  echo "  Variable: BUILD_SCRIPTS_REPO_ROOT"
  echo "  Location: ${BUILD_SCRIPTS_REPO_ROOT}"
elif [[ -n "${KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT:-}" ]]; then
  echo "  Variable: KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT"
  echo "  Location: ${KAPTAIN_USER_SCRIPTS_BUILD_SCRIPTS_REPO_ROOT}"
else
  echo "Neither variable is set, cannot proceed."
  exit 42
fi

bats ./*.bats
