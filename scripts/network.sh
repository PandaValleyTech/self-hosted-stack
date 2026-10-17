#!/usr/bin/env bash
# Create the shared Docker network all stacks join (idempotent).
set -euo pipefail

network="${APP_NETWORK:-apps}"

if docker network inspect "$network" >/dev/null 2>&1; then
  echo "network '$network' already exists"
else
  docker network create "$network"
  echo "created network '$network'"
fi
