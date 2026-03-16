#!/usr/bin/env bash
# Shared helpers for remembrall hooks — thin loader
# Modules are split by domain for maintainability.
# All modules are sourced unconditionally — bash source overhead is ~2-5ms each.

_REMEMBRALL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

source "$_REMEMBRALL_LIB_DIR/lib-core.sh"
source "$_REMEMBRALL_LIB_DIR/lib-context.sh"
source "$_REMEMBRALL_LIB_DIR/lib-handoff.sh"
source "$_REMEMBRALL_LIB_DIR/lib-features.sh"
