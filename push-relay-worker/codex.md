# Codex：AirSIM Relay 部署助手

本文件用于指导 Codex 协助部署 `push-relay-worker`。部署事实以当前源码、`README.md`、`wrangler.example.toml` 和 `package-lock.json` 为准；文档与源码冲突时，先指出差异，不得猜测生产配置。

当前兼容基线（2026-10-08）为 Apps `v0.9.2`、AVF Agent `v0.4.5`（Debian `0.4.5-1`）与 Relay 协议 `0.2.0`。维护者地址是 `https://airsim-push.remotepilot.site`；`https://push.remotepilot.site` 仅属于 DJOneHub。

## 目标与边界

目标是将 AirSIM Relay 安全部署到操作者自己的 Cloudflare 账户，并让使用操作者 Apple Developer Team 重新签名的 iPhone/Watch App 完成自动注册、PushKit → CallKit 来电和 Dashboard 鉴权。

AirSIM 必须使用独立于 DJOneHub 的 Worker、KV、Durable Objects、Dashboard token 和 hostname。本项目维护者使用 `https://airsim-push.remotepilot.site`；`https://push.remotepilot.site` 继续属于 DJOneHub，禁止 AirSIM 部署接管或复用。

维护者部署截至 2026-10-08 已验证 `/healthz`、Dashboard 匿名 `401` 和正确 Bearer token `200`；检查时尚无 AirSIM 设备注册。不要把基础设施与鉴权就绪描述成真实 APNs、Agent 心跳、命令或云端 PCM 已验收。

以下操作必须取得用户明确授权后才能执行：创建 Cloudflare 资源、写入或轮换 Secret、部署 Worker、绑定或迁移域名、修改 DNS、回滚线上版本。只读检查、测试和 `wrangler deploy --dry-run` 可以先执行。

## 操作者必须自行持有

- Cloudflare account/zone 权限和目标 hostname。
- 独立的新 KV namespace；禁止复用其他环境的资源 ID。
- 自己的 Apple Developer Team、唯一主 Bundle ID、开发/分发签名和 provisioning profile。
- 与该 Team 对应的 APNs Key ID、Team ID 和 `AuthKey_<KEY_ID>.p8`。
- 密码管理器生成的 Dashboard Bearer token。

不得要求用户把 `.p8`、Dashboard token、Cloudflare API token、设备 Secret 或 APNs token 粘贴到聊天。让操作者在本机 Wrangler 提示或 CI Secret Store 中输入，并且只报告名称是否配置成功。

## 不可更改的部署契约

- Worker 入口：`src/index.mjs`。
- KV binding：`DEVICES`。
- Durable Objects：`MEDIA/CallMediaSession`、`STATUS/AgentStatusRegistry`、`COMMANDS/DeviceCommandSession`。
- 必须保留 migration：`v1-call-media`、`v2-agent-status`、`v3-device-commands`；线上变更只能追加新 tag。
- 普通变量：`APNS_TEAM_ID`、`APNS_KEY_ID`、`ALLOWED_BUNDLE_ID`、`WEBRTC_TRANSPORT_READY`、`WEBRTC_ROLLOUT_PERCENT`。
- 必需 Worker Secret：`APNS_P8`、`DASHBOARD_TOKEN`。
- `[secrets].required` 只声明 Secret 名称，不包含、生成或上传 Secret 值。
- `com.example.airsim` 是源码仓库占位符，不能发布。主 App、Watch、Live Activity、provisioning profile、Relay allowlist 与 APNs topic 必须使用操作者自己的统一标识关系。
- Debug/development 签名对应 APNs `sandbox`；Release/TestFlight 对应 `production`。
- Wrangler 只部署基础设施；设备由签名 App 调用 `POST /v1/devices/register` 自注册，不能维护静态设备表或手工预填 KV。

## 安全操作顺序

### 1. 只读检查

```sh
cd push-relay-worker
npm ci
npm test
npm run check
npx wrangler whoami
```

让操作者确认当前 Cloudflare account。检查目标 hostname 是否已有 DNS、Custom Domain 或 Worker route；若存在，停止写操作并先报告所有权和迁移风险。

### 2. 准备本地配置

```sh
cp wrangler.example.toml wrangler.toml
npx wrangler kv namespace create DEVICES
```

第二条命令会创建云端资源，必须先获得授权。把返回的新 namespace ID、操作者自己的 Apple Team/Key ID、主 Bundle ID 和目标域名写入已被 Git 忽略的 `wrangler.toml`。不得覆盖其他环境的 ID。

### 3. 验证配置但不上传

```sh
npx wrangler deploy --dry-run --config wrangler.toml
```

向操作者展示脱敏后的 Worker 名、KV ID 后四位、DO bindings、route、Bundle ID 和 APNs 环境。任何 `REPLACE_WITH_`、`com.example.airsim` 或错误 hostname 残留都必须阻止部署。

### 4. 注入必需 Secret

交互式生产配置：

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

`APNS_P8` 是完整多行 PEM；`DASHBOARD_TOKEN` 是 AirSIM Dashboard 自己的随机 Bearer token，不是 Cloudflare API token。`secret list` 只能用于确认名称。

注意：`wrangler secret put` 会创建并立即部署一个新 Worker version，因此它本身属于生产写操作。首次部署或 CI 需要将两个 Secret 与代码一次上传时，使用受保护、已被 Git 忽略的临时文件：

```sh
npx wrangler deploy \
  --config wrangler.toml \
  --secrets-file .env.production
```

CI 必须从平台 Secret Store 动态生成 `.env.production`，结束后销毁且不得缓存。渐进式发布使用 `wrangler versions secret put`，随后走 version deploy，不要直接 `secret put`。

### 5. 部署和验收

用户确认 dry-run 摘要并明确要求上线后：

```sh
npm run deploy
curl --fail --show-error https://YOUR_RELAY_HOST/healthz
```

继续验证：

1. 匿名 Dashboard API 返回 `401`，正确 Bearer token 可以读取脱敏 summary。
2. 已重签 App 注册成功，Dashboard 出现 registration 事件。
3. Debug 真机只使用 sandbox；Release/TestFlight 只使用 production。
4. iPhone VoIP、普通 APNs、Watch VoIP 和 Live Activity 各自 topic 正确。
5. 后台/锁屏真实 PushKit 来电能及时进入 CallKit。
6. 错误设备 Secret、跨设备命令、过期通话和未认证媒体均被拒绝。

## 禁止事项

- 不读取、打印、提交、缓存或转存任何真实 Secret。
- 不把 `.p8` 或 Dashboard token 写进 `[vars]`、TOML、源码、README、命令参数或日志。
- 不使用原作者或 `com.example.airsim` 的 Bundle ID/App ID 签名。
- 不把 AirSIM Worker 绑定到正在承载 DJOneHub 的 hostname，也不复用 DJOneHub 的 KV/DO。
- 不删除或重排 Durable Object migration，不删除 KV/DO 来“重新部署”。
- 不手工修改设备记录绕过 `device_secret` 校验。
- 不声称 CallKit 有独立服务端证书；Relay 使用 APNs token key。
- 不在缺少真实真机验证时声称 PushKit/CallKit 已上线成功。

## 失败与回滚

- `BadDeviceToken`：核对 sandbox/production，不要盲目切换环境。
- `DeviceTokenNotForTopic`：核对主 Bundle ID、Watch/Live Activity 后缀、profile 和 APNs topic。
- `InvalidProviderToken`：核对 `.p8`、Key ID 和 Team ID 是否属于同一 Team。
- Secret 或代码发布失败：保留 KV/DO，回滚到上一 Worker version；不要删除 migration。
- 域名冲突：停止部署，保留现有 route，向用户报告需迁移的具体绑定。

完成报告必须包括测试结果、Worker version、hostname、健康检查、iOS/APNs 环境、注册与真实推送结果、回滚点及所有未验证项；凭据只能以“已配置/未配置”表示。
