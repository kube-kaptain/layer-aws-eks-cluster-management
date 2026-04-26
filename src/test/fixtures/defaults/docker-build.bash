#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Test stub for defaults/docker-build.bash
# Mirrors the validation + URI assembly that post-build-validate depends on.

# shellcheck disable=SC2034
DOCKER_REGISTRY_LOGINS="${DOCKER_REGISTRY_LOGINS:-}"
DOCKER_TARGET_REGISTRY="${DOCKER_TARGET_REGISTRY:-}"
DOCKER_TARGET_NAMESPACE="${DOCKER_TARGET_NAMESPACE:-}"
DOCKER_PUSH_TARGETS="${DOCKER_PUSH_TARGETS:-}"
TARGET_REGISTRY="${DOCKER_TARGET_REGISTRY}"
TARGET_NAMESPACE="${DOCKER_TARGET_NAMESPACE}"

if [[ "${SKIP_DOCKER_TARGET_VALIDATION:-}" != "true" ]]; then
  if [[ -z "${DOCKER_TARGET_REGISTRY}" ]]; then
    log_error "DOCKER_TARGET_REGISTRY is required"
    exit 1
  fi
  if [[ -z "${DOCKER_IMAGE_NAME:-}" ]]; then
    log_error "DOCKER_IMAGE_NAME is required"
    exit 1
  fi
  if [[ -z "${DOCKER_TAG:-}" ]]; then
    log_error "DOCKER_TAG is required"
    exit 1
  fi

  if [[ "${TARGET_REGISTRY}" == */* ]]; then
    log_error "DOCKER_TARGET_REGISTRY cannot contain slashes - use DOCKER_TARGET_NAMESPACE for paths"
    exit 1
  fi

  if [[ -n "${DOCKER_TARGET_NAMESPACE}" ]]; then
    if [[ "${DOCKER_TARGET_NAMESPACE}" == /* || "${DOCKER_TARGET_NAMESPACE}" == */ ]]; then
      log_error "DOCKER_TARGET_NAMESPACE cannot have leading or trailing slashes"
      exit 1
    fi
  fi

  if [[ -n "${TARGET_NAMESPACE}" ]]; then
    TARGET_IMAGE_FULL_URI="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}"
  else
    TARGET_IMAGE_FULL_URI="${TARGET_REGISTRY}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}"
  fi
fi
