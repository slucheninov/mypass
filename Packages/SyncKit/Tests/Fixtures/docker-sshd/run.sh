#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER_NAME="mypass-test-sshd"
CLIENT_KEY_PATH="/tmp/citadel_smoke_key"

if [ ! -f test_key ] || [ ! -f test_key.pub ]; then
  echo "Generating client fixture keypair..."
  ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f test_key -C "mypass-sftp-fixture"
fi
if [ ! -f ssh_host_ed25519_key ] || [ ! -f ssh_host_ed25519_key.pub ]; then
  echo "Generating ed25519 host keypair..."
  ssh-keygen -t ed25519 -N "" -f ssh_host_ed25519_key -C "mypass-test-sshd-host-key"
fi
if [ ! -f ssh_host_rsa_key ] || [ ! -f ssh_host_rsa_key.pub ]; then
  echo "Generating RSA host keypair..."
  ssh-keygen -t rsa -b 4096 -N "" -f ssh_host_rsa_key -C "mypass-test-sshd-host-key-rsa"
fi

cp test_key "$CLIENT_KEY_PATH"
cp test_key.pub "$CLIENT_KEY_PATH.pub"
chmod 600 "$CLIENT_KEY_PATH"

echo "Building image..."
docker build -t mypass-test-sshd:latest .

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Starting container..."
docker run -d --name "$CONTAINER_NAME" -p 2222:22 \
  -v "$(pwd)/test_key.pub:/home/testuser/.ssh/keys/id_ed25519.pub:ro" \
  -e SFTP_USERS=testuser::1001:100:upload \
  mypass-test-sshd:latest

echo "Waiting for sshd to accept TCP connections on 127.0.0.1:2222..."
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/2222") 2>/dev/null; then
    exec 3<&- 2>/dev/null || true
    echo "sshd is up (attempt $i)."
    exit 0
  fi
  sleep 1
done

echo "sshd did not become ready within 30s" >&2
docker logs "$CONTAINER_NAME" >&2 || true
exit 1
