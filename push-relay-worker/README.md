# AirSIM Cloudflare Relay 部署手册

`push-relay-worker/` 中已经包含可部署的 Relay 后端，而不是域名占位文件。它负责 AirSIM iPhone、Apple Watch、Live Activity 与 Android AVF Agent 之间的公网控制、APNs 推送、状态同步、命令队列和通话媒体中继。AirSIM 与 DJOneHub 应使用相互隔离的 Worker、KV、Durable Objects 和域名；本项目维护者的 AirSIM 生产域名是 `https://airsim-push.remotepilot.site`，其他部署者应换成自己控制的 Cloudflare 自定义域名。

> 本文中的域名、Cloudflare 资源、Apple Team ID 和密钥都必须替换成部署者自己的值。不要复用其他 AirSIM 环境的 KV、Durable Objects、Dashboard token、设备 Secret 或 APNs 私钥。

## 维护者部署状态（2026-10-08）

| 项目 | 状态 |
| --- | --- |
| Worker | `airsim-push-relay` |
| Custom Domain | `https://airsim-push.remotepilot.site` |
| `ALLOWED_BUNDLE_ID` | `com.eric3u.airsim` |
| Worker 协议版本 | `/healthz` 报告 `0.2.0` |
| 配套应用发布 | [`v0.9.0`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.0) |
| 配套 AVF Agent | [`v0.4.5`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.5)，Debian 包 `0.4.5-1` |
| 存储 | AirSIM 专用 `DEVICES` KV 与 `MEDIA`、`STATUS`、`COMMANDS` Durable Objects |
| Secret | `APNS_P8`、`DASHBOARD_TOKEN` 名称已配置；值不在仓库中 |
| DJOneHub 隔离 | `https://push.remotepilot.site` 继续返回 `djonehub-push-relay` |

已验证 AirSIM `/healthz` 返回 `airsim-push-relay`，Dashboard 匿名 API 返回 `401`、正确 Bearer token 返回 `200`。记录检查时 AirSIM 环境的设备数和事件数均为 0，因此这只能证明基础设施、路由和 Dashboard 鉴权已就绪，不能证明真实设备注册、PushKit/APNs、Agent 心跳、命令或 PCM 媒体已经通过。

该地址只服务维护者控制的 `com.eric3u.airsim` 签名构建，不是公共多租户 Relay。任何使用自己 Apple Developer Team 和 Bundle ID 的部署者，都必须创建自己的 Worker、KV/DO、hostname、Secrets 和 APNs 配置。

## 1. 仓库中的实现

主要文件：

| 文件 | 用途 |
| --- | --- |
| `src/index.mjs` | HTTP/WebSocket API、设备认证、APNs JWT 与推送、命令和媒体中继 |
| `src/status-store.mjs` | 设备、心跳、Relay 状态和 Dashboard 事件持久化 |
| `src/dashboard.mjs` | 受保护的运维面板和虚拟来电测试 |
| `wrangler.example.toml` | Cloudflare Worker、KV、Durable Objects 和变量模板 |
| `test/relay.test.mjs` | 注册、认证、推送、命令和协议测试 |

当前后端包含：

- `POST /v1/devices/register`：iPhone/Watch/APNs token 自注册。
- `POST /v1/live-activities/register`：Live Activity update token 注册。
- `POST /v1/events/call`、`/call-owner`、`/call-state`、`/sms`：来电、通话状态和短信事件。
- `POST /v1/events/heartbeat`、`/v1/devices/status`：Agent 心跳和设备状态。
- `/v1/commands/*`、`/v1/calls/:uuid/actions*`：设备命令与通话动作。
- `/v1/calls/:uuid/connect`、`/v1/devices/:deviceID/commands/connect`：已认证 WebSocket。
- `GET /healthz`、`GET /dashboard`：健康检查和运维界面。

数据职责如下：

- `DEVICES` KV：设备与状态的容灾镜像、短期 Relay 数据。
- `STATUS` Durable Object：设备注册权威记录、Agent 心跳和 Dashboard 事件。
- `COMMANDS` Durable Object：每台设备的命令队列、结果和命令 WebSocket。
- `MEDIA` Durable Object：每次通话的双向媒体会话。

## 2. Apple 侧前提

### 2.1 Apple Developer 与真机签名

需要有效的 Apple Developer Program 团队和一台可用于真机调试的 Mac。本仓库是源码可见、仅限非商业用途的项目，不附带原作者的 App ID、开发团队权限、证书或 provisioning profile。仓库中的 `com.example.airsim` 只是不可直接发布的占位符；每位部署者都必须换成自己控制的唯一反向域名标识，并使用自己的 Apple Developer Team 重新签名。

例如，拥有 `example.org` 的部署者可以选择 `org.example.airsim`。为主 App、Watch App 和 Live Activity Extension 创建三个 Explicit App ID：

| Target | 占位 Bundle ID | 替换规则 |
| --- | --- | --- |
| AirSIM | `com.example.airsim` | 改成部署者自己的主 Bundle ID，例如 `org.example.airsim` |
| AirSIMWatchApp | `com.example.airsim.watchkitapp` | 必须是主 Bundle ID 加 `.watchkitapp` |
| AirSIMLiveActivityExtension | `com.example.airsim.liveactivity` | 必须是主 Bundle ID 加 `.liveactivity` |

首次构建前必须同时修改：

1. Xcode → Signing & Capabilities 中三个 Target 的 Team 和 Bundle Identifier。
2. Watch Target 的 `WKCompanionAppBundleIdentifier`，使其等于新的主 App Bundle ID。
3. `wrangler.toml` 的 `ALLOWED_BUNDLE_ID`，使其等于新的主 App Bundle ID。
4. Apple Developer 中三个 Explicit App ID、capabilities 和对应 provisioning profile。
5. Debug/Release 实际签名 entitlement、Relay 注册字段和所有 APNs topic。

不要尝试注册或签名仓库历史版本中的原作者标识；它不属于源码使用者。仅修改 `DEVELOPMENT_TEAM` 也不够，三个 Bundle ID、Watch companion 关系和 Relay allowlist 必须一起修改。

主 App 和 Watch App 需要 Push Notifications capability。主 App 的 Background Modes 至少包含 Voice over IP 和 Remote notifications；本项目还使用后台音频。Live Activity Target 需要正确的 ActivityKit 配置。

仓库的主 App entitlement 包含：

```xml
<key>aps-environment</key>
<string>$(APS_ENVIRONMENT)</string>
```

Debug 当前映射为 `development`，并使用 Relay 的 `sandbox` APNs 环境；Release 映射为 `production`。请在签名后的 `.app` 中核对最终 entitlement，不要只看源码：

```sh
codesign -d --entitlements :- /path/to/AirSIM.app
```

`com.apple.developer.calling-app` 和 `com.apple.developer.messaging-app` 属于受 Apple 管理的 entitlement。只有团队账户已获授权、且 provisioning profile 确实包含它们时才能签入成品；否则应先完成 Apple 的 capability 申请或从目标配置移除。普通 CallKit UI 与 PushKit VoIP 推送的服务端工作流，不等于自动获得这两个受管 entitlement。

### 2.2 CallKit、PushKit 与证书的关系

- **开发/分发证书与 provisioning profile**：用于签名 App、安装到真机，并把正确的 `aps-environment` 写入 App entitlement。
- **PushKit**：iPhone 通过 `PKPushRegistry` 获取 VoIP token；收到 VoIP push 后，App 必须及时向 CallKit 报告来电。
- **CallKit**：负责系统来电界面和通话生命周期；它没有单独的 Relay 服务端证书。
- **APNs 服务端认证密钥**：Relay 使用 Apple Developer 下载的 `AuthKey_<KEY_ID>.p8`、Key ID 和 Team ID 创建 ES256 provider JWT，再连接 APNs。

本项目使用 APNs token-based authentication，不使用 `.p12` TLS certificate。创建密钥时在 Apple Developer 的 Keys 页面启用 Apple Push Notifications service，下载 `.p8`，记录 Key ID，并从 Membership 页面记录 Team ID。`.p8` 通常只允许下载一次，必须放入密码管理器；不要提交到 Git。

Relay 使用的 APNs topic：

| 场景 | `apns-push-type` | topic |
| --- | --- | --- |
| iPhone 来电 | `voip` | `${ALLOWED_BUNDLE_ID}.voip` |
| Watch 来电 | `voip` | `${ALLOWED_BUNDLE_ID}.watchkitapp.voip` |
| 普通通知/短信 | `alert` 或 `background` | `${ALLOWED_BUNDLE_ID}` |
| Live Activity | `liveactivity` | `${ALLOWED_BUNDLE_ID}.push-type.liveactivity` |

Relay 会根据注册记录中的 `environment` 选择 `api.sandbox.push.apple.com` 或 `api.push.apple.com`。开发签名产生的 token 不能发送到 production，TestFlight/App Store 的 production token 也不能发送到 sandbox。

## 3. Cloudflare 前提

需要：

- 一个 Cloudflare 账户；自定义域名时，该域名对应 zone 必须在此账户中。
- Node.js 20 或更新版本。
- 本目录锁定的 Wrangler 版本，使用 `npx wrangler` 调用，避免全局版本差异。
- 一个新的 KV namespace；Durable Objects 由配置中的迁移在首次部署时创建。

安装依赖并登录：

```sh
cd push-relay-worker
npm ci
npx wrangler login
npx wrangler whoami
```

CI 中不要使用交互式登录，应使用权限最小化的 Cloudflare API token，并把它作为 CI Secret 提供；不要写入仓库。

## 4. 创建 Wrangler 配置

### 4.1 创建 KV

```sh
npx wrangler kv namespace create DEVICES
```

命令会返回 namespace ID。复制模板：

```sh
cp wrangler.example.toml wrangler.toml
```

然后编辑 `wrangler.toml`：

```toml
[vars]
APNS_TEAM_ID = "YOUR_APPLE_TEAM_ID"
APNS_KEY_ID = "YOUR_APNS_KEY_ID"
ALLOWED_BUNDLE_ID = "org.example.airsim"
WEBRTC_TRANSPORT_READY = "false"
WEBRTC_ROLLOUT_PERCENT = "0"

[[kv_namespaces]]
binding = "DEVICES"
id = "YOUR_KV_NAMESPACE_ID"
```

不要重命名代码依赖的 `DEVICES`、`MEDIA`、`STATUS`、`COMMANDS` binding，也不要删除或重排已有 Durable Object migration tag。生产环境初次部署后，后续 schema 变更必须新增 migration tag。

### 4.2 配置自定义域名

生产环境建议关闭 `workers.dev` 并配置 Custom Domain：

```toml
workers_dev = false

[[routes]]
pattern = "airsim-push.remotepilot.site"
custom_domain = true
```

将示例中的 `pattern` 改为 AirSIM 专用 hostname，例如 `airsim-push.remotepilot.site` 或 `airsim-push.example.com`。Custom Domain 部署会由 Cloudflare 建立 DNS 记录并签发证书；该 hostname 不能预先存在冲突的 CNAME。不要把 AirSIM Worker 绑定到正在承载 DJOneHub 的 `push.remotepilot.site`，也不要复用 DJOneHub 的 KV、Durable Objects 或 Dashboard token。

### 4.3 写入 Secret

普通变量可以保存在 `wrangler.toml`，但以下两个值是 **必需 Worker Secret**：

| Secret 名称 | 内容 | 用途 |
| --- | --- | --- |
| `APNS_P8` | Apple `AuthKey_<KEY_ID>.p8` 的完整 PEM 文本，包括 BEGIN/END 行 | Relay 创建 APNs provider JWT，必须与 `APNS_KEY_ID` 和 `APNS_TEAM_ID` 属于同一 Apple Team |
| `DASHBOARD_TOKEN` | 密码管理器生成的独立随机 Bearer token，建议至少 32 个随机字节；它不是 Cloudflare API token | 保护 `/dashboard/api/summary` 和 `/dashboard/api/virtual-call` |

`wrangler.toml` 中的配置是：

```toml
[secrets]
required = ["APNS_P8", "DASHBOARD_TOKEN"]
```

这段配置 **只声明 Secret 名称**，不设置也不上传 Secret 值。它让 Wrangler 在本地开发/类型生成时识别所需 Secret，并在部署时检查缺失项。绝不能把下面这种内容写进 `wrangler.toml` 或 `[vars]`：

```toml
# 错误示例：严禁提交真实值
APNS_P8 = "-----BEGIN PRIVATE KEY-----..."
DASHBOARD_TOKEN = "真实管理令牌"
```

#### 交互式添加到 Cloudflare

先完成 `wrangler.toml` 中的账户资源、Bundle ID 和域名配置，再执行：

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

第一个命令提示输入时，粘贴 `.p8` 的完整多行内容；第二个命令粘贴由密码管理器生成的随机 token。`secret list` 只显示 Secret 名称，不会显示值。Cloudflare 当前的 `wrangler secret put` 会创建并立即部署一个新的 Worker version，因此在线环境中添加、修改或轮换 Secret 都应视为一次生产发布。

使用渐进式版本发布时，不要直接使用 `secret put`，改用：

```sh
npx wrangler versions secret put APNS_P8 --config wrangler.toml
npx wrangler versions secret put DASHBOARD_TOKEN --config wrangler.toml
```

这样只创建新 version，之后再通过版本部署流程发布。

#### 首次部署或 CI 同时上传两个 Secret

为了避免分两次更新，可以在本机或 CI 临时创建已被 Git 忽略的 `.env.production`：

```dotenv
APNS_P8="-----BEGIN PRIVATE KEY-----\n完整私钥内容\n-----END PRIVATE KEY-----"
DASHBOARD_TOKEN="密码管理器生成的随机值"
```

然后将代码和两个 Secret 一次上传：

```sh
npx wrangler deploy \
  --config wrangler.toml \
  --secrets-file .env.production
```

CI 应从平台的 Secret Store 动态生成该临时文件，任务结束后销毁，不能把它放入缓存或构建产物。`--secrets-file` 是增量的：未列入文件的现有 Secret 会保留，不会自动删除。

#### 本地开发

本地 `wrangler dev` 可使用未提交的 `.dev.vars`：

```dotenv
APNS_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
DASHBOARD_TOKEN="replace-with-a-local-only-random-token"
```

存在 `.dev.vars` 时不要再混用 `.env`。因为已声明 `secrets.required`，只有列出的两个名称会作为 Secret 加载，缺失项会产生警告。`.dev.vars*`、`.env*`、`wrangler.toml` 和所有 `.p8` 已被 `.gitignore` 排除。

## 5. 验证并部署

先运行仓库测试和语法检查：

```sh
npm test
npm run check
npx wrangler deploy --dry-run
```

确认输出中的 Worker 名称、KV ID、Durable Object bindings 和 route 都属于目标环境，再部署：

```sh
npm run deploy
```

验证：

```sh
curl --fail --show-error https://airsim-push.remotepilot.site/healthz
```

预期响应类似：

```json
{"ok":true,"service":"airsim-push-relay","version":"0.2.0"}
```

Dashboard 页面位于 `/dashboard`。其 API 使用 Bearer token：

```sh
curl --fail --show-error \
  -H "Authorization: Bearer ${AIRSIM_DASHBOARD_TOKEN}" \
  https://airsim-push.remotepilot.site/dashboard/api/summary
```

不要在 shell history、截图或工单中暴露真实 token。

## 6. 配置 iOS App

主 App 的 `Info.plist` 从构建设置读取：

- `AIRSIM_PUSH_RELAY_URL`：例如 `https://airsim-push.remotepilot.site`，不要带尾部路径。
- `AIRSIM_APNS_ENVIRONMENT`：Debug 使用 `sandbox`，Release/TestFlight 使用 `production`。
- `APS_ENVIRONMENT`：Debug 为 `development`，Release 为 `production`，必须与签名 profile 一致。

可以在 Xcode Target 的 Build Settings 中设置，也可以在自动化构建时覆盖：

```sh
xcodebuild \
  -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -configuration Debug \
  AIRSIM_PUSH_RELAY_URL=https://airsim-push.remotepilot.site \
  AIRSIM_APNS_ENVIRONMENT=sandbox \
  APS_ENVIRONMENT=development
```

正式包改用 `Release`、`production` 和分发签名。不要让用户在 App 中输入 `.p8`；APNs 私钥只属于 Relay。

## 7. 设备如何自动注册

Wrangler 只负责部署 Worker、绑定 KV/DO、配置域名和 Secret，**不会替每台设备生成或写入 APNs token**。设备加入由已签名 App 自动完成：

1. App 首次启动时注册 PushKit，并单独申请普通通知权限；系统分别返回 VoIP token 和普通 APNs token，Watch 与 Live Activity token 可在稍后补齐。
2. App 在本机生成并保管 `device_id` 与 `device_secret`。
3. App 把 token、Bundle ID、APNs 环境、Relay URL 和媒体能力提交到 `POST /v1/devices/register`，并同步给已配对的 Agent。
4. Relay 验证 Bundle ID、token 格式和环境，保存 `device_secret` 的哈希，不保存明文 Secret；`STATUS` Durable Object 是权威记录，KV 是镜像/回退。
5. 同一 `device_id` 后续注册必须提供相同 Secret。系统更新或 APNs token 轮换时，App 自动重新注册。

因此“加入一台设备”的正确操作是：安装已签名 App → 设置 Relay URL → 与 Agent 配对 → 开启云端模式/通知 → 保持 App 前台一次直至注册成功。不要在 Wrangler 文件中维护设备清单，也不要手工预填 KV。

仅在诊断测试环境时，可用占位值检查 API 形状：

```sh
curl --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{
    "device_id":"test-device-01",
    "device_secret":"replace-with-at-least-16-random-characters",
    "voip_token":"00112233445566778899aabbccddeeff",
    "alert_token":"",
    "watch_voip_token":"",
    "live_activity_push_to_start_token":"",
    "bundle_id":"org.example.airsim",
    "environment":"sandbox",
    "media_transport":"legacy_pcm"
  }' \
  https://airsim-push.remotepilot.site/v1/devices/register
```

不要对生产设备复制此示例 Secret。生产 Secret 应由 App 随机生成并保存在 Keychain 中。

## 8. 上线验收

分别使用 Debug 真机包和 Release/TestFlight 包执行一次：

1. `/healthz` 正常，Dashboard 可以用 token 读取，但匿名访问 API 返回 `401`。
2. iPhone 安装包的 `aps-environment` 与 `AIRSIM_APNS_ENVIRONMENT` 一致。
3. App 启动后注册成功，Dashboard 出现 registration 事件。
4. 锁屏、App 后台和 App 被系统回收后，VoIP push 仍能出现 CallKit 来电界面。
5. 接听、拒接、挂断和超时事件能回传 Agent，重复事件不会生成第二个通话。
6. 普通通知、Watch 来电和 Live Activity 分别验证自己的 topic。
7. Agent 断线、Secret 错误、过期命令和媒体认证失败均被拒绝。
8. `WEBRTC_TRANSPORT_READY=false` 时保持 `legacy_pcm`；准备灰度时再单独调整 rollout。

## 9. 常见故障

| 现象 | 优先检查 |
| --- | --- |
| `APNs credentials are incomplete` | `APNS_TEAM_ID`、`APNS_KEY_ID` 和 `APNS_P8` 是否在同一环境 |
| APNs `InvalidProviderToken` | Team ID/Key ID 是否对应 `.p8`，Worker 时间和 PEM 内容是否正确 |
| APNs `BadDeviceToken` | sandbox/production 是否混用，token 是否已轮换 |
| APNs `DeviceTokenNotForTopic` | Bundle ID、provisioning profile、`.voip`/Watch/Live Activity topic 是否一致 |
| 注册 `400` | 至少一个 token、十六进制格式、Bundle ID、Watch Bundle ID 和环境字段 |
| 注册 `401` | 相同 `device_id` 使用了不同 `device_secret`；不要直接覆盖生产记录 |
| 来电接口 `409` | 设备还没有 iPhone 或 Watch VoIP token |
| Dashboard `503` | `DASHBOARD_TOKEN` 尚未配置 |
| 自定义域名部署失败 | hostname 是否已有冲突 CNAME/Worker route，zone 是否属于当前账户 |

查看实时日志时注意脱敏：

```sh
npx wrangler tail
```

日志不得记录 `.p8`、完整 APNs token、设备 Secret、完整电话号码或媒体内容。

## 10. 安全与回滚

- Secret 只通过 Wrangler Secret/CI Secret 管理；密钥疑似泄露时立即在 Apple/Cloudflare 轮换并撤销旧值。
- Dashboard token 与设备 Secret 分离，设备不能调用 Dashboard 管理 API。
- Worker 只保存设备 Secret 哈希；媒体连接还会校验 call UUID、角色、generation 和单次 call secret。
- APNs payload 在本实现中统一限制为 4096 字节。
- 发布前保留上一 Worker version。故障时优先回滚 Worker version，不要删除 KV namespace 或 Durable Object migration。
- Worker、Agent、iOS/watchOS 的 JSON 和媒体协议变更必须兼容旧客户端或同步发布。

## 11. AI 辅助部署

同目录的 `codex.md`、`claude.md` 和 `LLM.txt` 为部署助手提供仓库事实、安全边界和验收顺序。它们不能替代操作者持有的 Apple/Cloudflare 权限，也不得包含真实凭据。

## 12. 官方参考

- Apple：[使用认证 token 与 APNs 通信](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens)、[注册 App 接收远程通知](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[响应 PushKit VoIP 通知](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)、[使用 CallKit 收发 VoIP 通话](https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls)。
- Cloudflare：[Wrangler 配置](https://developers.cloudflare.com/workers/wrangler/configuration/)、[Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)、[Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)、[创建 KV namespace](https://developers.cloudflare.com/kv/get-started/)、[Durable Object migrations](https://developers.cloudflare.com/durable-objects/reference/durable-objects-migrations/)。
