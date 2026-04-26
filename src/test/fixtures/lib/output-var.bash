#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# output-var - Output variable helper for CI systems
#
# Provides output_var() which:
#
# 1. echoes name=value to stdout,
# 2. writes to GITHUB_OUTPUT if available
# 3. writes to REFERENCE_SCRIPT_OUTPUT if available
# 4. exports fordownstream scripts in the same shell context
#

output_var() {
  local name="${1}"
  local value="${2}"

  echo "${name}=${value}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "${GITHUB_OUTPUT}"
  fi

  if [[ -n "${REFERENCE_SCRIPT_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "${REFERENCE_SCRIPT_OUTPUT}"
  fi

  export "${name}"="${value}"
}
