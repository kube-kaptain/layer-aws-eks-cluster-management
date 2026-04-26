#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Test stub: provides BUILD_PLATFORM + BUILD_PLATFORM_LOG_PROVIDER as the real
# defaults/platform.bash does, without the platform plugin gating.

# shellcheck disable=SC2034  # variables consumed by sourcing scripts
BUILD_PLATFORM="${BUILD_PLATFORM:?BUILD_PLATFORM is required}"
BUILD_PLATFORM_LOG_PROVIDER="${BUILD_PLATFORM_LOG_PROVIDER:-stdout}"
