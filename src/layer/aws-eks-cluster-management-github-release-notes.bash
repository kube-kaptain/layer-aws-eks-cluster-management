#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management-github-release-notes - Render the GitHub release body
#
# Runs as the prePublish hook: after the release change data image is packaged
# and docker multi-tag has run, before the git tag push, docker push and GitHub
# release. Every image the release will list is known by then.
#
# Substitutes the layer's release notes template and writes it where the layer's
# spec.platform.githubActions.release.notesFile points. The body is buildon's
# default basic-quality-and-versioning body with a short description and
# podman/docker run commands for the built image on top. The image lists come
# from buildon's own format-release-image-list so they match a default release.
#
# Renders only on GitHub runners, and only when GITHUB_RELEASE_NOTES_FILE is the
# layer default. A consumer that points notesFile elsewhere supplies its own
# file, and one that clears it gets buildon's default body; either way this
# script leaves it alone.
#
# Inputs (environment variables, set by buildon for every hook):
#   GITHUB_ACTIONS                - "true" on GitHub runners
#   GITHUB_SERVER_URL             - GitHub server URL (GitHub runners)
#   GITHUB_REPOSITORY             - owner/repo (GitHub runners)
#   GITHUB_RELEASE_NOTES_FILE     - Resolved notesFile from final KaptainPM.yaml
#   VERSION                       - Version (from versions-and-naming)
#   PROJECT_NAME                  - Project name (from versions-and-naming)
#   DOCKER_TAG                    - Image tag (from versions-and-naming)
#   DOCKER_IMAGE_NAME             - Image name (from versions-and-naming)
#   DOCKER_TARGET_REGISTRY        - Target registry
#   DOCKER_TARGET_NAMESPACE       - Target namespace (may be empty)
#   OUTPUT_SUB_PATH               - Build output directory (default: kaptain-out)
#   BUILD_SCRIPTS_REPO_ROOT       - Build scripts repo root (or BUILD_SCRIPTS_DIR directly)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${BUILD_SCRIPTS_DIR:-}" ]]; then
  BUILD_SCRIPTS_DIR="${BUILD_SCRIPTS_REPO_ROOT:?BUILD_SCRIPTS_REPO_ROOT is required}/src/scripts"
fi

# shellcheck source=src/scripts/defaults/platform.bash
source "${BUILD_SCRIPTS_DIR}/defaults/platform.bash"
# shellcheck source=src/scripts/lib/log.bash
source "${BUILD_SCRIPTS_DIR}/lib/log.bash"

# Must match spec.platform.githubActions.release.notesFile in the layer KaptainPM.yaml
LAYER_NOTES_FILE="kaptain-out/aws-eks-cluster-management/github-release-notes.md"
TEMPLATE_FILE="${SCRIPT_DIR}/aws-eks-cluster-management-github-release-notes.md.template"

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  log "Not on a GitHub runner - not rendering GitHub release notes"
  exit 0
fi

notes_file="${GITHUB_RELEASE_NOTES_FILE:-}"
if [[ "${notes_file}" != "${LAYER_NOTES_FILE}" ]]; then
  log "Release notes file '${notes_file}' is not the layer default '${LAYER_NOTES_FILE}' - not rendering"
  exit 0
fi

: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${VERSION:?VERSION is required}"
: "${PROJECT_NAME:?PROJECT_NAME is required}"
: "${DOCKER_TAG:?DOCKER_TAG is required}"
: "${DOCKER_IMAGE_NAME:?DOCKER_IMAGE_NAME is required}"
: "${DOCKER_TARGET_REGISTRY:?DOCKER_TARGET_REGISTRY is required}"
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  log_error "Release notes template not found: ${TEMPLATE_FILE}"
  exit 1
fi

# Same construction as buildon's docker-build defaults and release-change-data-oci-package
if [[ -n "${DOCKER_TARGET_NAMESPACE:-}" ]]; then
  image_repo="${DOCKER_TARGET_REGISTRY}/${DOCKER_TARGET_NAMESPACE}/${DOCKER_IMAGE_NAME}"
else
  image_repo="${DOCKER_TARGET_REGISTRY}/${DOCKER_IMAGE_NAME}"
fi
image_uri="${image_repo}:${DOCKER_TAG}"
release_change_data_uri="${image_repo}:${DOCKER_TAG}-release-change-data"
release_download_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/download/${VERSION}"
release_image_list=$("${BUILD_SCRIPTS_DIR}/util/format-release-image-list" "${OUTPUT_SUB_PATH}" "${VERSION}")

notes=$(<"${TEMPLATE_FILE}")
notes="${notes//\{\{IMAGE_URI\}\}/${image_uri}}"
notes="${notes//\{\{VERSION\}\}/${VERSION}}"
notes="${notes//\{\{PROJECT_NAME\}\}/${PROJECT_NAME}}"
notes="${notes//\{\{RELEASE_DOWNLOAD_URL\}\}/${release_download_url}}"
notes="${notes//\{\{RELEASE_CHANGE_DATA_URI\}\}/${release_change_data_uri}}"
notes="${notes//\{\{RELEASE_IMAGE_LIST\}\}/${release_image_list}}"

# An empty image list leaves a blank last line
while [[ "${notes}" == *$'\n' ]]; do
  notes="${notes%$'\n'}"
done

if [[ "${notes}" == *"{{"* ]]; then
  log_error "Unsubstituted placeholder left in release notes from ${TEMPLATE_FILE}:"
  log_error "$(grep -o '{{[^}]*}}' <<< "${notes}" | sort -u | tr '\n' ' ')"
  exit 1
fi

mkdir -p "$(dirname "${notes_file}")"
printf '%s\n' "${notes}" > "${notes_file}"

log "Rendered GitHub release notes to ${notes_file}:"
log "${notes}"
