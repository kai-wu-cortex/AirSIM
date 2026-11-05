import { mkdirSync, readFileSync, readdirSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const q = JSON.stringify;
export function generateConfig({ config, dataDir, httpPort = 8787, maintenancePort = 8789, apnsPort = 8790 }) {
  for (const port of [httpPort, maintenancePort, apnsPort]) {
    if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid port');
  }
  const names = ['APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_P8', 'ALLOWED_BUNDLE_ID', 'DASHBOARD_TOKEN',
    'NOTION_TOKEN', 'NOTION_DATABASE_ID', 'WEBRTC_TRANSPORT_READY', 'WEBRTC_ROLLOUT_PERCENT'];
  if (!config.DASHBOARD_TOKEN || config.DASHBOARD_TOKEN.length < 32) throw new Error('DASHBOARD_TOKEN must contain at least 32 characters');
  if (!config.ALLOWED_BUNDLE_ID) throw new Error('ALLOWED_BUNDLE_ID is required');
  if (config.WEBRTC_TRANSPORT_READY === 'true') throw new Error('This deployment only implements legacy_pcm');
  const modules = ['self-hosted/entry.mjs', 'self-hosted/kv.mjs',
    ...readdirSync(join(root, 'src')).filter(f => f.endsWith('.mjs')).map(f => 'src/' + f)];
  const classes = ['CallMediaSession', 'AgentStatusRegistry', 'DeviceCommandSession', 'LocalKV'];
  return `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
 services = [
  (name = "relay", worker = (
   modules = [${modules.map(p => `(name = ${q(p)}, esModule = ${q(readFileSync(join(root, p), 'utf8'))})`).join(',\n')}],
   compatibilityDate = "2026-08-20",
   bindings = [
    ${names.filter(n => typeof config[n] === 'string').map(n => `(name = ${q(n)}, text = ${q(config[n])})`).join(',\n')},
    (name = "MEDIA", durableObjectNamespace = "CallMediaSession"),
    (name = "STATUS", durableObjectNamespace = "AgentStatusRegistry"),
    (name = "COMMANDS", durableObjectNamespace = "DeviceCommandSession"),
    (name = "KV_STORE", durableObjectNamespace = "LocalKV")
   ],
   durableObjectNamespaces = [${classes.map(c => `(className = ${q(c)}, uniqueKey = ${q('airsim-ecs-v1-' + c)}, enableSql = true)`).join(',\n')}],
   durableObjectStorage = (localDisk = "data"),
   globalOutbound = "outbound"
  )),
  (name = "outbound", worker = (
   modules = [(name = "outbound.mjs", esModule = ${q(readFileSync(join(root, 'self-hosted/outbound.mjs'), 'utf8'))})],
   compatibilityDate = "2026-08-20",
   bindings = [(name = "APNS_HTTP", service = "apns"), (name = "INTERNET", service = "internet")]
  )),
  (name = "apns", external = (address = "127.0.0.1:${apnsPort}", http = ())),
  (name = "data", disk = (path = ${q(resolve(dataDir))}, writable = true))
 ],
 sockets = [
  (name = "http", address = "127.0.0.1:${httpPort}", http = (forwardedProtoHeader = "X-Forwarded-Proto"), service = "relay"),
  (name = "maintenance", address = "127.0.0.1:${maintenancePort}", http = (), service = (name = "relay", entrypoint = "Maintenance"))
 ]
);
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [configPath, outputPath, dataDir] = process.argv.slice(2);
  if (!configPath || !outputPath || !dataDir) throw new Error('Usage: node configure.mjs CONFIG_JSON OUTPUT_CAPNP DATA_DIRECTORY');
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  mkdirSync(dirname(outputPath), { recursive: true, mode: 0o700 });
  writeFileSync(outputPath, generateConfig({ config, dataDir }), { mode: 0o600 });
  console.log('Generated private workerd config; no secret values printed');
}
