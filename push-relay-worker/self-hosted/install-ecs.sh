#!/usr/bin/env bash
# First install only; intentionally refuses to overwrite an existing Relay.
# Stage: source.tar.gz, node.tar.xz, workerd.tgz, config.json, SHA256SUMS.
set -euo pipefail
stage=${1:?usage: install-ecs.sh PRIVATE_STAGE_DIRECTORY}
[[ $(id -u) == 0 ]] || { echo 'Run as root'; exit 1; }
[[ ! -e /opt/airsim-relay && ! -e /etc/airsim-relay ]] || {
  echo 'Existing installation preserved; use a reviewed upgrade procedure'; exit 1;
}
cd "$stage"
sha256sum --check SHA256SUMS
getent passwd airsim-relay >/dev/null || useradd --system --home-dir /var/lib/airsim-relay --shell /sbin/nologin airsim-relay
install -d -m 755 /opt/airsim-relay/releases/20261103-1 /opt/airsim-relay/node /opt/airsim-relay/workerd
tar -xzf source.tar.gz -C /opt/airsim-relay/releases/20261103-1
# Developer checkouts can contain 0600 source files. Normalize code only;
# secrets are installed separately below and retain 0600 permissions.
chown -R root:root /opt/airsim-relay/releases/20261103-1
find /opt/airsim-relay/releases/20261103-1 -type d -exec chmod 755 {} +
find /opt/airsim-relay/releases/20261103-1 -type f -exec chmod 644 {} +
tar -xJf node.tar.xz --strip-components=1 -C /opt/airsim-relay/node
tar -xzf workerd.tgz --strip-components=1 -C /opt/airsim-relay/workerd
ln -s releases/20261103-1 /opt/airsim-relay/current
install -d -o root -g airsim-relay -m 750 /etc/airsim-relay
install -o airsim-relay -g airsim-relay -m 600 config.json /etc/airsim-relay/config.json
install -d -o airsim-relay -g airsim-relay -m 700 /var/lib/airsim-relay
for unit in /opt/airsim-relay/current/push-relay-worker/self-hosted/systemd/*; do
  [[ ! -e /etc/systemd/system/$(basename "$unit") ]] || { echo 'Unit already exists; refusing overwrite'; exit 1; }
  install -m 644 "$unit" /etc/systemd/system/
done
/opt/airsim-relay/node/bin/node --version
/opt/airsim-relay/workerd/bin/workerd --version
systemctl daemon-reload
systemctl enable --now airsim-apns.service airsim-relay.service airsim-relay-prune.timer
for attempt in $(seq 1 20); do
  if curl --fail --silent http://127.0.0.1:8787/healthz; then exit 0; fi
  sleep 1
done
echo 'Relay did not become healthy; inspect systemd journal locally'; exit 1
