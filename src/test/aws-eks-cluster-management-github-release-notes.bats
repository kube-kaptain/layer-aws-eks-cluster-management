#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load helpers

LAYER_NOTES_FILE="kaptain-out/aws-eks-cluster-management/github-release-notes.md"
IMAGE_REPO="ghcr.io/kaptain-test-repos/fastidious/fastidious-falcon-lower-envs"

# Run from a per-test sandbox so the relative paths land inside it. The values
# and push lists match fixtures/release/GitHubReleasePage.md, a 1.0.0 release
# of a consumer repo named fastidious-falcon-lower-envs.
setup() {
  local sandbox_rel
  sandbox_rel=$(create_test_sandbox "work")
  cd "${PROJECT_ROOT}/${sandbox_rel}"

  export GITHUB_ACTIONS="true"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="kaptain-test-repos/fastidious-falcon-lower-envs"
  export GITHUB_RELEASE_NOTES_FILE="${LAYER_NOTES_FILE}"
  export OUTPUT_SUB_PATH="kaptain-out"
  export VERSION="1.0.0"
  export PROJECT_NAME="fastidious-falcon-lower-envs"
  export DOCKER_TAG="1.0.0"
  export DOCKER_IMAGE_NAME="fastidious/fastidious-falcon-lower-envs"
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kaptain-test-repos"

  mkdir -p kaptain-out/docker-push-all
  printf '%s\n' \
    "${IMAGE_REPO}:1.0.0-linux-amd64" \
    "${IMAGE_REPO}:1.0.0-linux-arm64" \
    "${IMAGE_REPO}:1.0.0-release-change-data-linux-amd64" \
    "${IMAGE_REPO}:1.0.0-release-change-data-linux-arm64" \
    > kaptain-out/docker-push-all/image-uris
  printf '%s\n' \
    "${IMAGE_REPO}:1.0.0" \
    "${IMAGE_REPO}:1.0.0-release-change-data" \
    > kaptain-out/docker-push-all/manifest-uris
}

@test "renders exactly the body of the fixture release page" {
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]

  # The example's first two lines are the release title (set by buildon, not
  # the notes file) and a blank line
  local expected actual
  expected=$(tail -n +3 "${PROJECT_ROOT}/src/test/fixtures/release/GitHubReleasePage.md")
  actual=$(<"${LAYER_NOTES_FILE}")
  if [[ "${actual}" != "${expected}" ]]; then
    diff <(echo "${expected}") <(echo "${actual}") >&3 || true
    return 1
  fi
}

@test "ends the rendered file with exactly one trailing newline" {
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  [ "$(tail -c 1 "${LAYER_NOTES_FILE}" | od -An -c | tr -d ' ')" == '\n' ]
  [ "$(tail -c 2 "${LAYER_NOTES_FILE}" | od -An -c | tr -d ' ')" != '\n\n' ]
}

@test "builds image addresses without a namespace when none is set" {
  export DOCKER_TARGET_NAMESPACE=""
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  local notes
  notes=$(<"${LAYER_NOTES_FILE}")
  assert_contains "${notes}" "podman run -it --rm ghcr.io/fastidious/fastidious-falcon-lower-envs:1.0.0 /bin/bash" "notes"
  assert_contains "${notes}" "[ghcr.io/fastidious/fastidious-falcon-lower-envs:1.0.0-release-change-data]" "notes"
}

@test "omits the image list sections when nothing was pushed" {
  rm -rf kaptain-out/docker-push-all
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  local notes
  notes=$(<"${LAYER_NOTES_FILE}")
  [[ "${notes}" != *"### All Docker"* ]]
  [[ "${notes}" == *"* Release Change Data Image: [${IMAGE_REPO}:1.0.0-release-change-data](https://${IMAGE_REPO}:1.0.0-release-change-data)" ]]
}

@test "skips rendering off GitHub runners" {
  export GITHUB_ACTIONS=""
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  assert_output_contains "Not on a GitHub runner"
  [ ! -e "${LAYER_NOTES_FILE}" ]
}

@test "skips rendering when notesFile points at a consumer file" {
  export GITHUB_RELEASE_NOTES_FILE="docs/MyReleaseNotes.md"
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  assert_output_contains "not rendering"
  [ ! -e "${LAYER_NOTES_FILE}" ]
  [ ! -e "docs/MyReleaseNotes.md" ]
}

@test "skips rendering when notesFile is cleared" {
  export GITHUB_RELEASE_NOTES_FILE=""
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -eq 0 ]
  assert_output_contains "not rendering"
  [ ! -e "${LAYER_NOTES_FILE}" ]
}

@test "fails when the docker image name is missing" {
  unset DOCKER_IMAGE_NAME
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  [ "$status" -ne 0 ]
  assert_output_contains "DOCKER_IMAGE_NAME is required"
}

@test "fails when the template has an unknown placeholder" {
  local template="${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes.md.template"
  cp "${template}" "${template}.orig"
  echo "{{UNKNOWN_THING}}" >> "${template}"
  run "${SCRIPTS_DIR}/aws-eks-cluster-management-github-release-notes"
  mv "${template}.orig" "${template}"
  [ "$status" -ne 0 ]
  assert_output_contains "{{UNKNOWN_THING}}"
  [ ! -e "${LAYER_NOTES_FILE}" ]
}
