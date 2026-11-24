# v0.9.8.27 发布与部署验证

## 源码与安装包

- develop；iOS／Watch／扩展 0.9.8（188），Android Standalone／AVF 0.9.8.27（142）。
- 安卓两种 APK 构建通过，与 v0.9.8.26 原发布证书一致；不使用 Debug 证书。
- 开屏新增端点管理 SVG、号码保留和设备目录说明；恢复熟悉的 UI。
- 最终 Release 归档成功，主 App／Watch／两种扩展均为 188，签名校验通过；4 个 Mach-O 的 Date 运行时扫描通过。App 配置为 production APNs 与既有 Cloudflare Relay 域名。
- 从独立副本生成 full／sideload unsigned IPA；原始签名归档与 dSYM 保留。
- 首次归档的运行时扫描发现 PR #46 局域网探测重试中的 Date.<= 弱符号；已改为等价的时间戳比较，重新归档验证。

## 回归

- iOS：端点删除／验证后替换／过时发现隔离、100 台设备目录与 ActivityKit 大小、33 组 Swift／Java IMS 号码、SIM 显示、8 项 LAN 路由、21 项更新策略与 26 项 PushKit phone／Watch 检查通过。
- Android phone-control-app/test.sh 与 android-standalone/test.sh 全部通过；逐卡信号检查覆盖 API 29／30／35／36。
- Worker 86 项通过，真实 workerd 路由集成通过；自托管 5 项测试通过（从 self-hosted 目录运行）。
- 未拨打真实电话或发送短信。

## Cloudflare

- Worker：airsim-push-relay，https://airsim-push.remotepilot.site。
- 新版本：635b6b34-fd06-47e4-a7c0-1ba911aed3c0；此前 5d70dca3-c67a-4637-8e43-d394f2181012。
- Wrangler 上传和路由／cron 部署成功。保留 KV、三个 DO 绑定、Secrets，WebRTC 仍关闭。
- 部署后 /healthz 返回 HTTP 429、1027：账户当天免费额度耗尽，不能据此宣称线上可用。未升级套餐或修改路由，需额度恢复后再确认。

## 阿里云 ECS

- 实例 i-bp1gixcvkyfkg57m95w1；公开入口 https://118.178.109.247。
- current 从 releases/20261121-v09826 切换至 releases/20261124-v09827。
- 8 个业务模块和 smoke 脚本与本地同步，保留自托管适配层／运行时／配置／数据库。适配层散列与本地一致。
- 仅重启 airsim-relay.service。原 AirSIM APNs／HTTPS 和 AirSIM Cloud Relay／APNs／HTTPS／TURN 六个服务 PID 均未改变。
- 停服后一致性备份：/opt/airsim-relay/backups/20261124-v09827/state-and-config.tar.gz，权限 0600；保留旧版本和自动回滚步骤。
- 本机健康、未授权管理接口拒绝、合成注册／心跳／鉴权／命令去重／双向二进制 PCM 均通过，合成注册已清理。
- 公开 HTTPS/WSS 同一组鉴权、去重、PCM 检查通过；8 个已部署业务模块 SHA-256 与发布源码逐个一致。
- 生产／沙盒 APNs 的 TLS 与 HTTP/2 探测通过；无真实推送。
- Notion 凭据仍未配置，为原部署状态；本轮不更改。
