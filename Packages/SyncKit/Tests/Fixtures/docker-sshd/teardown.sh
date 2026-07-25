#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="mypass-test-sshd"

docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "$CONTAINER_NAME removed."
