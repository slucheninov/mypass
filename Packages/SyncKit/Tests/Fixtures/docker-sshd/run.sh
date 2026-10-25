#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER_NAME="mypass-test-sshd"
CLIENT_KEY_PATH="/tmp/citadel_smoke_key"
CLIENT_KEY_PASSPHRASE="correct-horse-battery-staple"

# ensure_keypair NAME PASSPHRASE COMMENT ssh-keygen-type-args...
# Both halves present: nothing to do. Private half only: derive the public half from it
# with the passphrase it was created with (never regenerate, so an existing private key
# keeps its identity). Public half only, or neither: it is an orphan of a deleted private
# key, so drop it and generate a fresh pair. Every ssh-keygen call below is non-interactive
# (-N / -P given, and the target files are removed first), so a half pair can never trigger
# the "Overwrite (y/n)?" prompt. These are disposable fixture keys; nothing outside this
# directory is touched.
ensure_keypair() {
  local name="$1" passphrase="$2" comment="$3"
  shift 3
  if [ -f "$name" ] && [ -f "$name.pub" ]; then
    return 0
  fi
  if [ -f "$name" ]; then
    echo "Deriving missing public key $name.pub from $name..."
    if ! ssh-keygen -y -P "$passphrase" -f "$name" >"$name.pub.tmp"; then
      rm -f "$name.pub.tmp"
      echo "Cannot derive $name.pub: $name exists but does not open with the expected fixture passphrase." >&2
      echo "Delete $name (a disposable fixture key) and re-run to generate a fresh pair." >&2
      return 1
    fi
    printf '%s %s\n' "$(cut -d' ' -f1,2 "$name.pub.tmp")" "$comment" >"$name.pub"
    rm -f "$name.pub.tmp"
    return 0
  fi
  echo "Generating fixture keypair $name..."
  rm -f "$name.pub"
  ssh-keygen "$@" -N "$passphrase" -f "$name" -C "$comment"
}

ensure_keypair test_key "$CLIENT_KEY_PASSPHRASE" "mypass-sftp-fixture" -t ed25519
ensure_keypair ssh_host_ed25519_key "" "mypass-test-sshd-host-key" -t ed25519
ensure_keypair ssh_host_rsa_key "" "mypass-test-sshd-host-key-rsa" -t rsa -b 4096

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
