#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Test stub for defaults/docker-dockerfile.bash

# shellcheck disable=SC2034
# shellcheck disable=SC2154
DOCKERFILE_SQUASH="${DOCKERFILE_SQUASH:-squash}"
DOCKERFILE_NO_CACHE="${DOCKERFILE_NO_CACHE:-true}"
DOCKERFILE_SUBSTITUTION_FILES="${DOCKERFILE_SUBSTITUTION_FILES:-Dockerfile}"
DOCKERFILE_SUB_PATH="${DOCKERFILE_SUB_PATH:-src/docker}"
DOCKERFILE_SUB_PATH_LINUX_AMD64="${DOCKERFILE_SUB_PATH_LINUX_AMD64:-src/docker-linux-amd64}"
DOCKERFILE_SUB_PATH_LINUX_ARM64="${DOCKERFILE_SUB_PATH_LINUX_ARM64:-src/docker-linux-arm64}"
DOCKER_CONTEXT_SUB_PATH="${OUTPUT_SUB_PATH}/docker/substituted"
DOCKER_CONTEXT_SUB_PATH_LINUX_AMD64="${OUTPUT_SUB_PATH}/docker-linux-amd64/substituted"
DOCKER_CONTEXT_SUB_PATH_LINUX_ARM64="${OUTPUT_SUB_PATH}/docker-linux-arm64/substituted"
