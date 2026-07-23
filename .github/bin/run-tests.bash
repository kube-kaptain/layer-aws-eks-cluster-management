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

if command -v bats >/dev/null 2>&1; then
  bats ./*.bats
elif command -v docker >/dev/null 2>&1; then
  docker run --rm \
    -v "${PROJECT_ROOT}:/workspace" \
    -w /workspace/src/test \
    -e "PROJECT_ROOT=/workspace" \
    "bats/bats:1.13.0" \
    --tap ./*.bats
else
  echo "ERROR: neither bats nor docker available" >&2
  exit 1
fi
