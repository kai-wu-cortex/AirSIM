# AirSIM Cloudflare Relay

该 Worker 为三星 Android AirSIM 系统提供公网控制与媒体中继，使 iPhone 和 Apple Watch 在不连接三星局域网时仍可接收来电、发送命令和使用通话音频。

## 主要职责

- 注册 iPhone、Apple Watch、Live Activity 与三星 AVF Agent。
- 接收 Agent 心跳、通话事件、短信事件和设备状态。
- 发送 iPhone PushKit、通知 APNs、Watch VoIP 与 ActivityKit 推送。
- 维护设备命令、通话动作及其结果。
- 通过 Durable Objects 中继已认证的双向媒体 WebSocket。
- 提供受保护的运维 Dashboard 与虚拟来电测试入口。

## 本地验证

```sh
cd push-relay-worker
npm ci
npm test
npm run check
```

## Cloudflare 资源

部署环境需要独立创建：

- KV namespace
- 设备状态与命令 Durable Objects
- Worker 路由或自定义域名
- Dashboard 访问 token
- Apple APNs 私钥、Team ID 与 Key ID

复制模板并填写新环境配置：

```sh
cp wrangler.example.toml wrangler.toml
wrangler secret put APNS_P8
wrangler secret put DASHBOARD_TOKEN
```

## Apple 配置

在 Apple Developer 中为以下 Bundle ID 配置 App ID、PushKit、APNs、ActivityKit 与签名：

- `com.eric3u.airsim`
- `com.eric3u.airsim.watchkitapp`
- `com.eric3u.airsim.liveactivity`

部署后分别验证 APNs sandbox 与 production 环境，确认 iPhone、Watch 和实时活动使用正确 topic。

## 安全要求

- 设备 Secret、Dashboard token 和 APNs `.p8` 只能通过 Worker Secret 保存。
- 所有设备命令必须绑定已认证的设备身份。
- 通话媒体必须校验 call UUID、角色、generation 与单次 call secret。
- Dashboard 不显示完整凭据、Push token、电话号码或媒体内容。
- Worker、Agent 和 iOS/watchOS 的 JSON 与媒体协议变更必须同步发布。
