#!/usr/bin/env sh
set -eu
/usr/sbin/nginx -e stderr -t -c /etc/airsim-relay/nginx.conf
/bin/systemctl reload airsim-relay-https.service
