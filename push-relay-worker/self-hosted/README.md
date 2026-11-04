# AirSIM ECS 独立 Relay

这是现有 Cloudflare Relay 的第二种部署方式。`../src/` 原有业务代码保持不变；独立入口提供 Workers KV 所需接口、磁盘持久化、APNs HTTP/2 出口和每日清理。它不会把 API 或音频转发回 Cloudflare。

## 能力与边界

| 能力 | ECS 实现 |
| --- | --- |
| `/v1`、`/v2` 注册、鉴权、心跳、命令和通话状态 | 直接复用原 Worker |
| Dashboard、短信、来电与 Live Activity 推送 | 复用原 Worker；APNs 经本机 HTTP/2 适配器直达 Apple |
| WebSocket PCM 双向音频、通话所有权、路由与命令去重 | 原 Durable Object 类运行在原生 workerd |
| 设备注册、KV 镜像、命令、状态 | 本机 SQLite；与 Cloudflare 数据完全分开 |
| 手动 Notion 反馈 | 复用原实现，需要配置原 Notion integration 和数据库 |
| 定时清理 | systemd timer，UTC 04:17，调用仅本机可达的维护入口 |
| WebRTC / TURN | 本次未添加，保持原来的 WebSocket PCM |

使用原生 `workerd`，不是 `wrangler dev` 或 Miniflare 开发服务器。固定版本为 `1.20261103.1`，Node 为 `22.23.4`。workerd 的 `localDisk` 存储格式仍被上游标为实验性，因此升级运行时前必须备份并做恢复验证。当前为单机单进程部署，不具备 Cloudflare 的全球调度、冗余和自动故障转移；不能将多个进程随意挂到同一个 SQLite 目录。

## 安装与配置

1. 用官方发布源获取 Linux x64 Node 和 workerd，核对发布摘要。
2. 将仓库的 `push-relay-worker/src`、`push-relay-worker/self-hosted`、根目录 LICENSE/NOTICE/THIRD_PARTY_NOTICES.md 打包为 `source.tar.gz`，不含 node_modules 和秘密。
3. 在 root 独占的 staging 目录放置 `source.tar.gz`、`node.tar.xz`、`workerd.tgz`、`config.json` 和这些文件的 `SHA256SUMS`。
4. 根据 `config.example.json` 创建配置：`APNS_P8` 是完整 PEM，必须与 Key ID 和 Team ID 匹配。`DASHBOARD_TOKEN` 使用独立随机值；不得复用 Cloudflare API token。`NOTION_TOKEN` 与 `NOTION_DATABASE_ID` 缺失时反馈返回 503，不会假装已提交。
5. 审查并执行 `bash install-ecs.sh /root/PRIVATE_STAGE_DIRECTORY`。首次安装脚本拒绝覆盖已有安装；不会修改宝塔、SSH 或安全组。

服务器目录：

- `/opt/airsim-relay/current`：当前代码版本的符号链接。
- `/etc/airsim-relay/config.json`：服务账户可读的 0600 配置；包含秘密，禁止上传 Git。
- `/var/lib/airsim-relay`：持久数据，0700。
- `/run/airsim-relay/config.capnp`：启动时生成的配置，含秘密，0600，重启会重新生成。
- `127.0.0.1:8787`：Relay；`127.0.0.1:8789`：维护；`127.0.0.1:8790`：APNs 适配器。后三者均不可直接暴露到公网。

## 公网 IP HTTPS/WSS 入口

当前实例已启用 **`https://118.178.109.247`**，不需要配置域名。已安装受信任的 Let’s Encrypt IP 证书；客户端应使用 HTTPS，无需关闭证书验证。原域名方案 `airsim-ecs.remotepilot.site` 未启用。

入口由独立的 `airsim-relay-https.service` 管理，使用 Nginx 1.24.0（系统供应商维护版本）。`configure-ip.mjs IPv4 OUTPUT [--tls]` 生成配置：先生成 HTTP 验证入口，签发证书后加 `--tls` 生成正式入口。TCP 80 仅响应 ACME 验证路径，其他路径返回 404；TCP 443 提供 API、Dashboard 和 WSS。安全组与系统防火墙只为本次服务增加 80/443，内部三个端口仍绑定回环。默认访问日志关闭，避免媒体 URL 凭据落盘。

IP 入口安装时需要 Nginx、Python 3.11，以及 `/opt/airsim-relay/certbot` 中的 Certbot 5.9.0 独立环境；将 `configure-ip.mjs`、`reload-https.sh` 放在 `/opt/airsim-relay/ip-entry/`，后者设为可执行。准备 `/var/lib/airsim-acme-webroot` 和 Nginx 可写的 `/var/cache/airsim-relay-https`，安装对应 systemd 单元。证书签发命令如下（已有证书时不要重复签发）：

```sh
/opt/airsim-relay/certbot/bin/certbot certonly \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-profile shortlived --webroot \
  --webroot-path /var/lib/airsim-acme-webroot \
  --ip-address 118.178.109.247 --cert-name airsim-relay-ip \
  --config-dir /etc/airsim-relay/letsencrypt \
  --work-dir /var/lib/airsim-acme-state \
  --logs-dir /var/log/airsim-acme \
  --deploy-hook /opt/airsim-relay/ip-entry/reload-https.sh
```

首次签发后，生成带 TLS 的 `/etc/airsim-relay/nginx.conf`，验证配置并重载入口；启用 `airsim-relay-cert-renew.timer`。该计时器每 6 小时检查续期，另有最多 15 分钟随机延迟。短期 IP 证书必须保持自动续期；续期成功通过 hook 验证 Nginx 配置并平滑重载。当前部署已通过 staging 签发及生产证书的续期演练。若公网 IP 变化，需要为新 IP 签发证书并更新客户端地址。

```sh
systemctl status airsim-relay-https airsim-relay-cert-renew.timer
/opt/airsim-relay/certbot/bin/certbot renew \
  --cert-name airsim-relay-ip \
  --config-dir /etc/airsim-relay/letsencrypt \
  --work-dir /var/lib/airsim-acme-state \
  --logs-dir /var/log/airsim-acme --dry-run --run-deploy-hooks
```

`nginx.example.conf` 另提供域名部署模板。IP 技术部署不构成对服务所在地备案适用性的判断。

## 切换使用

第二个 Relay 地址为 **`https://118.178.109.247`**；原地址 `https://airsim-push.remotepilot.site` 保留。公网合成链路已通过，真实设备仍需按下述步骤验收。

在 iPhone 设置的“云端 Relay”中填写新 URL，点击“保存 Relay 地址”。此设置需要云端运行策略允许；纯本地模式不注册云端。让 iPhone 与安卓/网关建立可用本地连接，以便现有同步注册流程把新 Relay 配置同步给 Agent。然后确认 Agent 使用的也是新 URL，运行云端自检，并检查新 Dashboard 出现对应设备和新鲜心跳。

两个 Relay 的注册、命令和通话状态相互隔离，不能一端使用 Cloudflare、另一端使用 ECS，也不支持通话进行中切换。无需复制旧 Relay 的全量设备数据库。回退时在空闲状态把所有相关端同步改回原 URL，再运行自检；ECS 停机不会自动替用户完成这个回退。

## 运维与验收

```sh
systemctl status airsim-relay airsim-apns airsim-relay-prune.timer
curl --fail http://127.0.0.1:8787/healthz
journalctl -u airsim-relay -u airsim-apns --since '10 minutes ago'
```

`/healthz` 仅说明 HTTP 服务运行，不代表 APNs、Notion、设备心跳或通话均已通过验收。不要将包含秘密的配置或媒体 URL 粘贴到日志/工单。

备份须包含配置、代码/运行时版本和完整 `/var/lib/airsim-relay`。最简单可靠的备份方式是在维护窗口先停止 Relay、复制整个数据目录（包括 SQLite/WAL 文件），再启动；会中断进行中的语音和命令连接，实际执行前应得到操作者批准。不要在运行中只复制 `.sqlite` 并漏掉 WAL。恢复到隔离端口验证注册鉴权、命令去重后再切换。当前尚未配置独立备份存储、容量告警或证书续期失败通知，应在长期使用前补齐。

本地验证：

```sh
cd push-relay-worker
npm test
cd self-hosted
npm ci
npm test
```

新增测试用真实 workerd 进程与合成设备验证：注册/鉴权、心跳、命令去重与路由、HTTPS→WSS 地址生成、二进制双向 PCM、APNs 出口路由、HTTP/2 传输与错误透传、重启持久化、TTL 与分页、维护入口隔离。不会对真实设备发起电话或推送。

当前 APNs 密钥已配置，Notion integration 凭据和数据库 ID 尚未恢复，手动反馈会返回 503。仍需用户真机验收：前后台/锁屏 CallKit、三星和 U30Air 来去电与双向音频、短信与角标、Live Activity、手动反馈、VPN/网络切换、切回 Cloudflare。自动化结果不等于这些真机项目已通过。

参考：[workerd 自托管运行时](https://github.com/cloudflare/workerd)、[workerd 配置与 localDisk 说明](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp)、[阿里云备案适用场景](https://help.aliyun.com/zh/icp-filing/what-scenarios-need-to-be-filed-in-aliyun)。
