#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Test stub for defaults/docker-common.bash

# shellcheck disable=SC2034
IMAGE_BUILD_COMMAND="${IMAGE_BUILD_COMMAND:?IMAGE_BUILD_COMMAND is required - run validate-tooling first}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
