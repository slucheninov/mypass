FROM atmoz/sftp:alpine

# Fixed SSH host keys baked into the image so TrustOnFirstUseHostKeyValidator
# (Task 10) trust stays valid across container rebuilds — a freshly
# generated host key on every `docker build` would otherwise force a
# re-trust (new TOFU pin) on every CI run. Generated once by run.sh below,
# committed alongside this Dockerfile (see README.md).
COPY ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
COPY ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
COPY ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key
COPY ssh_host_rsa_key.pub /etc/ssh/ssh_host_rsa_key.pub
RUN chmod 600 /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key
