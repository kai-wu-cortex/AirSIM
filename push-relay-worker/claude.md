# Claude：AirSIM Relay 安全部署指南

协助部署前，依次阅读 `README.md`、`wrangler.example.toml`、`package.json`、`src/index.mjs`、`src/status-store.mjs` 和 `src/dashboard.mjs`。源码是接口事实来源；不能用旧 DJOneHub 配置、其他 AirSIM 环境资源或记忆中的 Wrangler 行为代替核对。

AirSIM 必须使用独立于 DJOneHub 的 Worker、KV、Durable Objects、Dashboard token 和 hostname。本项目维护者使用 `https://airsim-push.remotepilot.site`；不得让 AirSIM 接管 DJOneHub 的 `https://push.remotepilot.site`。

维护者部署截至 2026-10-08 已验证 `/healthz`、Dashboard 匿名 `401` 和正确 Bearer token `200`；检查时尚无 AirSIM 设备注册。不能据此宣称真实 APNs、Agent 心跳、命令或云端 PCM 已验收。

## 必须遵守

1. 先确认 Cloudflare account/zone、目标 hostname、Apple Team ID/Key ID、操作者自己的主 Bundle ID，以及 sandbox 或 production 环境。
2. `com.example.airsim` 仅为源码仓库占位符。部署者必须用自己的 Apple Developer Team 重签主 App、Watch 与 Live Activity，并同步 Relay `ALLOWED_BUNDLE_ID`。
3. App 签名证书/profile 与 Relay 的 APNs `.p8` 是两组不同凭据；CallKit 没有独立服务端证书。
4. `APNS_P8` 与 `DASHBOARD_TOKEN` 是必需 Worker Secret。`[secrets].required` 只声明名称，绝不能把真实值写入 TOML 或 `[vars]`。
5. `DASHBOARD_TOKEN` 是 AirSIM Dashboard Bearer token，不是 Cloudflare API token。
6. 不索取、不显示 `.p8`、Dashboard token、Cloudflare API token、设备 Secret 或 APNs token。让操作者在本地提示或 CI Secret Store 输入。
7. 每个环境创建独立 `DEVICES` KV；保留 `MEDIA`、`STATUS`、`COMMANDS` binding 和全部 migration tag。
8. 已在线 hostname 必须先只读检查 DNS、Custom Domain 和 route，不能直接覆盖。
9. Wrangler 不注册单台设备。已签名 App 通过 `/v1/devices/register` 自注册；禁止静态设备表和手工写 KV。
10. `wrangler secret put` 会创建并立即部署新 version，必须按生产变更对待。

## 推荐流程

```sh
cd push-relay-worker
npm ci
npm test
npm run check
npx wrangler whoami
cp wrangler.example.toml wrangler.toml
```

获得创建资源授权后：

```sh
npx wrangler kv namespace create DEVICES
npx wrangler deploy --dry-run --config wrangler.toml
```

必须确认 `wrangler.toml` 不再包含 `REPLACE_WITH_`、`com.example.airsim` 或错误域名。交互式添加 Secret：

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

首次部署或 CI 可将两个值放入受保护且已被 Git 忽略的临时 `.env.production`，然后原子上传：

```sh
npx wrangler deploy \
  --config wrangler.toml \
  --secrets-file .env.production
```

使用 `--secrets-file` 时，文件必须由 Secret Store 动态创建、任务结束后销毁且不得进入缓存。渐进式部署使用 `wrangler versions secret put` 和 versions deploy。

只有在操作者核对 dry-run 并明确要求上线后，才执行实际部署。随后检查 `/healthz`、Dashboard Bearer 鉴权、App 自动注册，以及真实 sandbox/production PushKit → CallKit 来电。报告必须列出未验证项，不能把“Worker 部署成功”等同于“真机推送成功”。

失败时优先回滚 Worker version并保留 KV/DO。不得删除 migration、重建设备库、切换 APNs 环境或覆盖域名来掩盖错误。
