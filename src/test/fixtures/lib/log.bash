#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Test stub for lib/log.bash
# Defines log/log_error/log_warning directly (no provider plugin lookup).

log() { echo "$*"; }
log_error() { echo "ERROR: $*"; }
log_warning() { echo "WARNING: $*"; }
