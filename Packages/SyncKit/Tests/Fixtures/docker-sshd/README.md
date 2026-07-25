# SFTP test fixture (`atmoz/sftp`)

Provides the real SFTP server that `Packages/SyncKit/Tests/SyncKitTests/SFTPBackendTests.swift`
(Task 10) connects to when `MYPASS_SFTP_INTEGRATION_TESTS=1` is set.

## Usage

```sh
./run.sh                                                    # build + start + healthcheck
MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests   # from Packages/SyncKit
./teardown.sh                                                # stop + remove
```

## What `run.sh` sets up

- Container `mypass-test-sshd`, image built from the local `Dockerfile` (pins `atmoz/sftp:alpine`
  plus fixed SSH host keys), port-mapped `2222:22`.
- User `testuser`, public-key auth only (`SFTP_USERS=testuser::1001:100:upload`, empty password
  field disables password auth). The `upload` directory is created and chowned to `testuser` by
  the image's own init script — required because `SFTPBackendTests.swift` hardcodes remote paths
  under `/upload/`.
- Client key pair `test_key`/`test_key.pub` (committed in this directory) copied to
  `/tmp/citadel_smoke_key`/`.pub` — the exact path Task 8's `CitadelDependencySmokeTests.swift`
  and Task 10's `SFTPBackendTests.swift` already hardcode.

## Regenerating the fixture keys

These were generated once via (`run.sh` regenerates them automatically if the files are
ever deleted — the commands below are shown for reference/reproducibility):

```sh
# Client auth key — passphrase-protected, matches Task 8/10's hardcoded passphrase.
ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f test_key -C "mypass-sftp-fixture"

# Server host keys — unencrypted (sshd cannot prompt for a passphrase on its own host key).
ssh-keygen -t ed25519 -N "" -f ssh_host_ed25519_key -C "mypass-test-sshd-host-key"
ssh-keygen -t rsa -b 4096 -N "" -f ssh_host_rsa_key -C "mypass-test-sshd-host-key-rsa"
```

These are test-only, local-Docker-fixture credentials with a well-known passphrase — never
used for anything beyond this fixture, and never granting access to anything but the throwaway
container `run.sh` creates.
