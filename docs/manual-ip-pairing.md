# 手动 IP＋端口配对（候选 build 83）

适用于自动发现一直停在“发现中”、但两端 IP 可以互访的场景。手动地址只是现有 VoWLAN 直连的发现替代方式，不增加第四种通话模式，不要求开启 AirSIM 云端，也不改变蓝牙模式或自动选择顺序。安卓 APK 和 iOS App 都需更新；已发布 build 81 不支持此入口。候选版尚未发布，真实 Tailscale 设备验收待执行。

## 使用

1. 安卓确认 AirSIM 默认电话角色和 Shizuku PCM 桥已就绪，再打开“一次性配对”窗口。
2. iPhone「设置 → 三星连接 → 配对安卓手机」切换“手动地址”。
3. 输入安卓局域网 IPv4，或安卓在 Tailscale App 中显示的 IPv4；另填安卓 AirSIM 当次配对页显示的随机配对端口及六位码。端口每次开窗口可能变化，有效期两分钟。
4. “本地模式配对”打开时不读取或写入 Relay／推送参数；关闭时仍按原规则要求云端配置就绪。它只控制本次配对，不改全局模式。
5. 点击“连接并加密配对”。App 自动取得实际控制与 PCM 端口，认证通过后保存直连地址；拨号和短信继续复用现有 VoWLAN 控制、媒体链路。

**不要填无线 ADB 端口、7592/7593 的通话端口或 Linux 8575/8576。** 第一版只支持 IPv4，不支持主机名、MagicDNS、IPv6、URL 或路径。

使用 Tailscale 时，两端需已接入允许互访的 tailnet，且访问规则允许配对及实际控制／PCM 端口。安卓可能无法枚举出 userspace Tailscale 的虚拟 IP，因此配对页也会提示从 Tailscale App 复制本机 IPv4。不能仅凭看到 `100.x` 就确认网络已连通。Tailscale 使用范围为 [`100.64.0.0/10`](https://tailscale.com/docs/concepts/tailscale-ip-addresses)，不是所有 `100.x` 地址。AirSIM 不内嵌 Tailscale，不更改其登录、VPN、退出节点或 ACL；Tailscale 本身仍可能使用其转发节点。

## 重连与清理

Tailscale 地址的 HTTP 控制与 PCM 使用系统 VPN 路由，不强制绑定 Wi-Fi 或 USB 网卡；普通局域网地址保留原有 Wi-Fi 约束。灵动岛的 VoWLAN 操作唤起主 App，使用当前认证端点，不访问旧 USB 模块固定地址。本功能只验收 iPhone→安卓路径；Apple Watch 自身没有到该 VPN 地址的路由时，不保证 Watch 直接建立 PCM，不能把手机配对成功当作 Watch 语音已可用。

仅保存经本次加密会话认证的设备 ID、地址和控制／PCM 端口，不保存号码。每次恢复仍执行 HMAC 健康检查、读取当前设备身份和 SIM 信息；保存地址不能直接把拨号状态标为在线。Bonjour 不可用时继续尝试保存地址；手动地址不可达而同一设备有新的 Bonjour 地址时，可以恢复到已发现端点。通话中路径失效仍结束当前通话，不静默把通话转往另一设备。

删除配对设备同时删除手动地址，不能通过旧地址自动加回。若网关重启后控制端口因冲突而变化，局域网 Bonjour 可发现新端口；纯 VPN 且无广播时需要重新打开安卓配对窗口，用新端口再配对。地址更换亦按此操作。不会扫描整个网段或探测所有端口。

## 协议与安全

- 增量 `GET /pair/v1/info` 只在原两分钟窗口开放，返回 `product=airsim-pair`、`version=1`、`session_id`、`server_public_key` 和毫秒 `expires_at`，等同原 Bonjour TXT 的公开会话材料；不返回六位码、设备密钥或云端参数。
- 复用 `POST /pair/v1/claim` 的 X25519、HKDF-SHA256、AES-GCM 加密。手动客户端带 `want_direct_route=true`；新安卓回传同一入站接口的实际 `control_port`、`pcm_port` 和 `route_proof`，不猜默认端口。旧版自动发现客户端可继续忽略新增字段。
- 端口证明使用本次注册包中的 VoWLAN secret 做 HMAC-SHA256，base64url 无填充；规范串是 `AIRSIM-DIRECT1\nsession_id\nclient_public_key\nagent_id\ncontrol_port\npcm_port`。iOS 验证后才接受路由。
- 直连网关仅绑定允许的 Wi-Fi／热点、指定 VPN IPv4 和回环地址，不使用公网通配监听。Tailscale userspace 入站 TCP 会被代理到回环（[上游实现](https://github.com/tailscale/tailscale/blob/main/wgengine/netstack/netstack.go)）；回环入口仍需 HMAC、时间戳、nonce 和 PCM 认证，不能以回环来源代替认证。
- 所有接口共享重放缓存和 PCM 单会话门闩。内部 READY 握手有超时，关闭网关会关闭持有的 Socket，不能永久占住语音门闩。代理断链仅结束与该租约绑定的 Telecom 通话；晚到的拨号／接听结果不能留下一通无人控制的蜂窝电话，也不能操作下一通或其他来电。
- Linux AVF 8575/8576 及 Shell PCM 7580 仍限内部私网／回环，不对外开放。手动公网 IP、任意 HTTP 地址不被接受。

## 验证边界

本地候选 build 83 已通过 iOS 122 项回归测试、Android Standalone 完整测试（含 47 项 PCM 桥检查）及真实 TCP PCM 集成测试；Release 归档、两种 APK 签名校验和 full／sideload 未签名 IPA 结构校验通过。安装包在 `iOS/build/candidate83/`，未安装或发布；IPA 需要重新签名，不能直接安装。

回归覆盖地址／端口边界、公网拒绝、跨端 HMAC 向量、完整加密 claim 与篡改端口拒绝、保存／删除／绑定、失效手动地址与新 Bonjour 合并、真实 TCP 超时和取消，以及 JVM 真实 TCP PCM 卡握手清理、进程内语音门闩恢复和按通话 ID 断链清理。这些不等同于 iPhone＋安卓＋Tailscale 真机验收；仍需检查实际配对、冷启动重连、双向音频、短信、VPN 断开、局域网切换及其他通话不受影响。
