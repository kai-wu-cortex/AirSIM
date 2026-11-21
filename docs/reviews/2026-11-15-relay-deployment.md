# Relay 同步部署记录（2026-11-15）

源码基线：develop `991162cb57941ede64d7a186c8720fe74b9acd88`（v0.9.8.25 发布后的文档提交；业务源码与该 Release 相同）。

## Cloudflare

- 地址：https://airsim-push.remotepilot.site
- 新版本：`aa4d2c26-d546-4225-9eb5-21397425826d`，部署状态确认 100% 流量。
- 上一版本：`e7952e87-9e77-4571-9fa1-cbcd0b1c6fec`，可通过 Wrangler 回退。
- 保留 KV、3 个 Durable Object 绑定、Secrets、域名和定时任务；WebRTC 开关仍关闭。
- Worker 82 项测试、Wrangler dry-run 通过；公网 healthz 返回 200，未认证管理 API 返回 401（通过本机现有代理复核）。本机直连探测存在超时，Python urllib 请求返回 403；未据此修改线上访问策略，用户所在网络的可达性仍需实测。

## 阿里云 ECS

- 实例：`i-bp1gixcvkyfkg57m95w1`，杭州；地址：https://118.178.109.247
- 新目录：`/opt/airsim-relay/releases/20261115-991162c`，current 已切换。
- 旧目录：`/opt/airsim-relay/releases/20261108-pr33-10cdd49`，保留可回退。
- 仅同步 8 个业务模块和 smoke 脚本；Node/workerd、自托管适配器、配置、数据位置和 DO namespace 不变。
- 上传包 SHA-256：`209ab4bfe1120782228f90c6750825432eb9ead4ea26da48650eee564ea7b06e`。服务器逐文件校验通过。
- 停止 Relay 后，完整数据目录（含 SQLite/WAL）和配置备份至 `/opt/airsim-relay/backups/20261115-991162c/state-and-config.tar.gz`，权限 0600。
- 仅重启 airsim-relay，01:39:34（Asia/Shanghai）恢复 active；AirSIM Cloud Relay/APNs/HTTPS/TURN、原 APNs 和 HTTPS 入口的 MainPID 均保持不变。
- 自托管 5 项测试通过。ECS 内部及 Mac 公网 HTTPS/WSS 合成测试通过：注册、鉴权、心跳、命令去重和双向二进制 PCM。
- 公网额外验证：SIM 列表可读取、拨号选卡透传、同一意图换卡返回 409。测试使用独立随机设备，无真实 Agent/电话/短信/推送；合成注册已清理。
- Apple production/sandbox TLS 与 HTTP/2 协商通过；无凭据 GET 返回预期 405，不代表真实推送已验收。

ECS 公网 TLS 校验通过，证书有效至 2026-11-18 11:17:33（Asia/Shanghai），续期 timer active；Dashboard 200、未认证管理 API 401。

## 行为与验收边界

新增云端 SIM 列表及 dial/send_sms 的 sim_account 透传与去重保护。客户端需等待 Android 新心跳才能获取最新 SIM 信息。

ECS 原有 Notion 反馈凭据仍缺失（NOTION_TOKEN、NOTION_DATABASE_ID），这次没有补齐或改变。真实来电、锁屏 CallKit、双向语音、选卡拨号及短信仍需用户联测；合成测试不能替代真实验收。

本次未修改 AirSIM Cloud、TURN、手机安装包或独立 Agent，未重新发布 Release/TestFlight。
