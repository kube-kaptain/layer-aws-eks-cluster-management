#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# aws-eks-cluster-management.bash - Defaults for EKS cluster management image preparation
#
# Two override patterns:
#   ${VAR:-default}  - Input-overrideable: CI wrapper or env var can change these
#   VAR="default"    - Config-file-overrideable: only a file in CONFIG_SUB_PATH can change these
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts


# === Input-overrideable (env var or CI wrapper) ===

# Base image parts (FROM line)
EKS_BASE_IMAGE_REGISTRY="${EKS_BASE_IMAGE_REGISTRY:-ghcr.io}"
EKS_BASE_IMAGE_NAMESPACE="${EKS_BASE_IMAGE_NAMESPACE:-kube-kaptain}"
EKS_BASE_IMAGE_NAME="${EKS_BASE_IMAGE_NAME:-aws/aws-eks-cluster-management}"
EKS_BASE_IMAGE_TAG="${EKS_BASE_IMAGE_TAG:-1.10}"

# Networking switches
EKS_PRIVATE_NETWORKING="${EKS_PRIVATE_NETWORKING:-true}"
EKS_PUBLIC_NETWORKING="${EKS_PUBLIC_NETWORKING:-false}"
EKS_CILIUM_EBPF_NETWORKING="${EKS_CILIUM_EBPF_NETWORKING:-false}"

# Source locations in consuming repo
EKS_CLUSTER_YAML_SUB_PATH="${EKS_CLUSTER_YAML_SUB_PATH:-src/eks}"
SECRETS_SUB_PATH="${SECRETS_SUB_PATH:-src/secrets}"


# === Config-file-overrideable (file in CONFIG_SUB_PATH overrides) ===

# Cluster config
KUBERNETES_MAJOR_VERSION="1"
# KUBERNETES_MINOR_VERSION - required, no default (validated by prepare script)
EKS_ADDONS_LIST="coredns,kube-proxy,vpc-cni,aws-ebs-csi-driver,aws-efs-csi-driver"
IAM_WITH_OIDC="true"
VPC_CLUSTER_ENDPOINTS_PRIVATE_ACCESS="true"
VPC_CLUSTER_ENDPOINTS_PUBLIC_ACCESS="false"
CLOUD_WATCH_CLUSTER_LOGGING_ENABLE_TYPES="api,audit,authenticator,controllerManager,scheduler"

# Nodegroup defaults
NODEGROUP_AMI_FAMILY="AmazonLinux2023"
NODEGROUP_VOLUME_SIZE="20"
NODEGROUP_VOLUME_TYPE="gp3"
NODEGROUP_VOLUME_ENCRYPTED="true"
NODEGROUP_UPDATE_CONFIG_MAX_UNAVAILABLE="1"
NODEGROUP_MIN_SIZE="3"
NODEGROUP_MAX_SIZE="12"
# NODEGROUP_DESIRED_CAPACITY - defaults to NODEGROUP_MIN_SIZE (derived in prepare script)
