# ECS 第二套 Relay 部署记录（2026-11-03）

## 当前结论

**独立 Relay 已在 `https://118.178.109.247` 上线；公网 HTTPS/WSS 合成链路及证书续期演练通过，可开始用户真机切换验收。** 原 Cloudflare 服务未部署、未修改，其设备数据库未复制或删除。

- ECS：`i-bp1gixcvkyfkg57m95w1`，`cn-hangzhou`。
- 系统：Alibaba Cloud Linux 3 / x86_64，约 2 GiB 内存、40 GiB 系统盘。
- 公网入口：`https://118.178.109.247`，用户选择直接使用 IP；原计划域名 `airsim-ecs.remotepilot.site` 未配置。
- 旧服务：`airsim-push.remotepilot.site`，保持原样。
- 源码基线：VoBLE `1f35376`；七个 `push-relay-worker/src/*.mjs` 已逐一比对 SHA-256，与本机现有业务代码完全一致。
- 新增适配层：`push-relay-worker/self-hosted/`；此项源码与文档尚未提交/推送。
- 运行目录：`/opt/airsim-relay/current -> releases/20261103-2`。
- 业务运行包 SHA-256（不含后续独立 IP 入口配置）：`9ed7a0d41c3dbcf768b30e849e6e191ceed942e8f5580bd59b42ac729427462e`。
- 固定运行时：workerd `1.20261103.1`、Node `v22.23.4`；安装前校验官方包摘要。

## 已实现

复用现有 Worker 的注册、APNs、心跳、Dashboard、命令路由/去重、通话状态、WebSocket PCM、短信、Live Activity 与反馈业务代码。运行适配层提供本机持久化 KV、原生 Durable Objects/SQLite、APNs HTTP/2 出口、维护端点和 systemd 服务。API/媒体链路均不调用原 Cloudflare Relay。Notion 和 Apple 仍分别是反馈与系统推送的外部依赖。

以下服务及计时器均已启用并实际处于 active：

- `airsim-relay.service`：仅监听 `127.0.0.1:8787` 与维护端口 `127.0.0.1:8789`。
- `airsim-apns.service`：仅监听 `127.0.0.1:8790`。
- `airsim-relay-prune.timer`：UTC 04:17 执行既有 30 天设备清理策略。
- `airsim-relay-https.service`：Nginx 独立入口；TCP 443 提供 HTTPS/WSS，TCP 80 仅提供 ACME 验证，其他路径 404。
- `airsim-relay-cert-renew.timer`：每 6 小时检查短期 IP 证书续期（加 0–15 分钟随机延迟），成功后平滑重载 Nginx。

已向安全组 `sg-bp1gixcvkyfkg57plf5g` 增加 TCP 80/443 公网入站规则，系统防火墙也已放行；既有其他规则保持原样。维护及 APNs 内部端口未向公网开放。Nginx 默认访问日志关闭，所有临时文件路径限定在独立可写目录。

证书由 Let’s Encrypt YE2 签发，SAN 为 `IP Address:118.178.109.247`，当前到期时间为 **2026-11-10 08:15:04 北京时间**。证书位于 `/etc/airsim-relay/letsencrypt/live/airsim-relay-ip/`；Certbot 5.9.0 安装在独立 Python 3.11 环境。staging 签发与 `renew --dry-run --run-deploy-hooks` 都成功，正常外网请求未绕过 TLS 验证。

服务使用 `airsim-relay` 非登录用户。配置和运行时生成的秘密文件为 0600，数据目录为 0700。现有 SSH 和宝塔面板保留。

APNs `.p8` 已从本机匹配 Key ID 的既有文件配置；私钥通过 OpenSSL 解析检查。独立 Dashboard token 已生成，保存在 ECS 的 `/etc/airsim-relay/config.json` 和本机 `~/Library/Application Support/AirSIM/relay-ecs/config.json`，没有打印、提交或放入源码包。

## 验证证据

1. 现有 Worker 77 项自动化测试通过。
2. 新增 5 项自动化测试通过（连同原测试共 82 项）：IP 入口的 HTTP/TLS 配置与非法地址拒绝；真实 workerd 进程的鉴权/注册/心跳/命令去重/目标路由/双向 PCM/重启持久化/维护隔离；KV TTL 与分页；HTTP/2 转换、错误透传与目标限制；通过版本符号链接启动 APNs 服务。
3. ECS 现场执行 `self-hosted/smoke.mjs`：HTTP 健康、Dashboard 未授权拒绝、合成设备注册、心跳、错误密钥拒绝、拨号意图去重和双向二进制 PCM 全部通过。未连接真实 Agent，未拨打电话、发送真实短信或真实设备推送；本轮合成注册已清理。
4. ECS 到 Apple production 与 sandbox 的 TLS 证书校验及 ALPN `h2` 成功；无认证的 GET `/` 返回预期的 HTTP 405。
5. 通过已运行的 APNs bridge 使用故意无效的 provider token 请求，Apple 返回 `403 InvalidProviderToken`，证明转换和错误返回路径实际可用。**此项不是对生产推送凭据有效性或真机来电的验收。**
6. Mac 外网通过正式 HTTPS IP 入口完成合成注册、鉴权、心跳、命令去重、WSS 双向二进制 PCM，测试设备随后清理；Dashboard 返回 200，未认证管理 API 返回 401。真实设备和电话未参与。
7. `git diff --check` 通过；新运行时生产依赖 `npm audit --omit=dev` 无已知漏洞。

现场发现并解决：开发机某些业务源文件权限为 0600，初装时服务账户无法读取，安装脚本现对纯代码目录归一化权限；APNs 入口通过 `current` 符号链接启动时路径比较失败，现比较 realpath 并加入回归测试。HTTPS 入口另修复了严格文件系统保护下 Nginx 默认临时目录不可写的问题。三个内部端口均仅监听回环。

## 待完成与真机验收

1. **Notion 反馈**：查找本机相关配置和部署临时文件后，未找到 `NOTION_TOKEN` 与 `NOTION_DATABASE_ID`，二者目前为空；反馈明确返回 503。需要恢复既有 integration 凭据和数据库配置后才能称为全功能可用。
2. **用户真机验收**：尚未切换任何 iPhone、三星或 U30Air；需验证新 Relay 注册/心跳、锁屏 PushKit/CallKit、来去电双向音频、短信、Live Activity、手动反馈、网络切换，以及切回 Cloudflare。合成 PCM 测试不代表实际通话质量已验收。
3. **可用性/备份**：当前是单实例，不具备 Cloudflare 全球平台的 HA；workerd localDisk 格式为上游实验性接口，运行时升级前需备份与恢复演练。尚未配置异地备份、流量/磁盘告警或证书续期失败通知。

下一位执行者先核实以上状态，不要将 `healthz=200` 或合成链路通过解释为真机验收完成。配置所有相关端为同一个 Relay 后再进行真实测试，不能混用两套独立状态库。详细安装与切换方法见 [self-hosted README](../../push-relay-worker/self-hosted/README.md)。
