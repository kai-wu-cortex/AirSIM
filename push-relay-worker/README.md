# AirSIM Push Relay

AirSIM 的独立 Cloudflare Worker。处理三星 AVF Agent 心跳、设备注册、CallKit/PushKit 来电、短信 APNs、Dashboard 与公网双向 PCM。`wrangler.example.toml` 不含生产 namespace、路由或密钥，不能直接部署到既有 DJOneHub Worker。

## 本地检查

```sh
npm ci
npm test
npm run check
```

## 新环境部署准备

1. 复制 `wrangler.example.toml` 为本地 `wrangler.toml`，填入**新建**的 AirSIM KV namespace 与 Apple Team/Key ID；配置新域名。
2. 在 Apple Developer 建立 `com.eric3u.airsim`、Watch 和 Activity 扩展对应 App ID、PushKit/APNs 能力及签名。不要复用原 DJOneHub 的配置文件或假定旧 token 可用。
3. 用 `wrangler secret put APNS_P8` 与 `wrangler secret put DASHBOARD_TOKEN` 设置新环境密钥。不要提交 `.p8`、设备 Secret、Dashboard token 或真实用户号码。
4. 验证全新 AirSIM 注册、Agent 心跳和 APNs sandbox/production 环境，然后再进行域名切换与实机测试。

源码中保留某些 `DJOneHub` JSON/protocol 字段，仅用于与尚未迁移的 Agent/iOS 媒体协议互通；这不是将新 Worker 部署到原生产域名的许可。
