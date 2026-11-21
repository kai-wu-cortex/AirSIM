# Relay 同步部署：2026-11-21

源码：develop `8bab98a`，Apps v0.9.8.26 配套。保留线上配置与数据。

## Cloudflare

- `airsim-push.remotepilot.site` 已部署，版本 `5d70dca3-c67a-4637-8e43-d394f2181012`。
- 上一版本 `c8250384-03eb-4271-a712-7bb4508dce0f`。KV、3 个 Durable Object、Secrets、路由和定时任务保留，WebRTC 仍关闭。
- Worker 84 项测试、Wrangler dry-run 通过。
- Mac 与 ECS 公网复核均返回 HTTP 429，正文 `error code: 1027`。这是 [Cloudflare 免费层每日请求额度超限](https://developers.cloudflare.com/workers/observability/errors/)。未升级付费计划、绕过鉴权或更换线上域名。
- 部署成功，但额度恢复前不能宣称公网可用。免费额度按 UTC 零点重置，见 [平台限制](https://developers.cloudflare.com/workers/platform/limits/)。

## 阿里云 ECS

- 实例 `i-bp1gixcvkyfkg57m95w1`，HTTPS IP 入口 `https://118.178.109.247`。
- current 切换到 `/opt/airsim-relay/releases/20261121-v09826`，旧目录 `/opt/airsim-relay/releases/20261115-sim-id` 保留。
- 只覆盖 8 个业务模块和 smoke 脚本，运行时、自托管适配层、配置、数据和 Durable Object namespace 不变。
- 上传包 SHA-256：`831dd439dc39666f39276caa4906e3a66df4116c11caae97071776cb301648ea`，9 个文件在 ECS 校验一致。
- 停止 AirSIM Relay 后，完整数据（含 SQLite/WAL）与配置备份到 `/opt/airsim-relay/backups/20261121-v09826/state-and-config.tar.gz`，0600 权限。切换脚本带失败回退。
- 内部及公网 HTTPS/WSS 合成验证通过：健康、未认证管理 API 拒绝、注册、心跳、设备鉴权、命令去重、双向二进制 PCM；本轮合成注册已删除，没有拨打真实电话、发送短信或推送。
- Apple production/sandbox 的 TLS、HTTP/2 握手通过，无凭据请求返回 405，不等于实际 APNs 验收。
- AirSIM Cloud Relay／APNs／HTTPS／TURN，以及原 AirSIM APNs／HTTPS 的 MainPID 前后完全一致。
- ECS 原有 Notion 凭据仍缺失，本次未补配。服务 active；Mac 公网 TLS 和 healthz 通过。

锁屏来电／CallKit、云端双卡拨号、短信与实际双向语音仍需用户联测；本次合成测试不能替代真机验收。
