import { isIP } from 'node:net';
import { writeFileSync, renameSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function nginxIPConfig(ip, tls = false) {
  if (isIP(ip) !== 4) throw new Error('A public IPv4 literal is required');
  return `user nginx;
worker_processes auto;
pid /run/airsim-relay-https/nginx.pid;
error_log stderr crit;
events { worker_connections 4096; }
http {
  access_log off;
  server_tokens off;
  client_max_body_size 5m;
  client_body_temp_path /var/cache/airsim-relay-https/client_temp;
  proxy_temp_path /var/cache/airsim-relay-https/proxy_temp;
  fastcgi_temp_path /var/cache/airsim-relay-https/fastcgi_temp;
  uwsgi_temp_path /var/cache/airsim-relay-https/uwsgi_temp;
  scgi_temp_path /var/cache/airsim-relay-https/scgi_temp;
  map $http_upgrade $airsim_connection_upgrade { default upgrade; '' close; }
  server {
    listen 80 default_server;
    server_name ${ip};
    location ^~ /.well-known/acme-challenge/ {
      root /var/lib/airsim-acme-webroot;
      default_type text/plain;
      try_files $uri =404;
    }
    # Do not expose authenticated APIs over plaintext, even via redirects.
    location / { return 404; }
  }
  ${tls ? `server {
    listen 443 ssl default_server;
    server_name ${ip};
    ssl_certificate /etc/airsim-relay/letsencrypt/live/airsim-relay-ip/fullchain.pem;
    ssl_certificate_key /etc/airsim-relay/letsencrypt/live/airsim-relay-ip/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:AirSIMSSL:10m;
    ssl_session_timeout 1d;
    location / {
      proxy_pass http://127.0.0.1:8787;
      proxy_http_version 1.1;
      # A fixed Host prevents client-controlled Host from changing generated media URLs.
      proxy_set_header Host ${ip};
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $airsim_connection_upgrade;
      proxy_buffering off;
      proxy_read_timeout 6h;
      proxy_send_timeout 6h;
    }
  }` : ''}
}
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [ip, output] = process.argv.slice(2);
  if (!output) throw new Error('Usage: configure-ip.mjs IPv4 OUTPUT [--tls]');
  const temporary = output + '.new';
  writeFileSync(temporary, nginxIPConfig(ip, process.argv.includes('--tls')), { mode: 0o640 });
  renameSync(temporary, output);
}
