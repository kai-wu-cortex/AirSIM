# AirSIM Handoff：通话音频、SMS 复制/卡槽与 VoWLAN 401

交接日期：2026-10-26 晚（Asia/Shanghai）。本文是工作区快照，不是发布或真机验收回执。

## 1. 接手结论

VoBLE 当前 HEAD 8731b75，比远端 main（cc2ade3）多 11 个提交。AirSIM-ZTE 仍停在 a60962a。

本轮后续完成了：

- 全厂商通话静音策略改为最低非零音量
- 红米/联发科 VOICE_DOWNLINK 全零诊断与修复
- 拨号号码复制/粘贴
- 短信正文复制、验证码复制、自动复制验证码
- 短信 SIM 卡槽标注
- KernelSU root bridge Looper 崩溃修复
- VoWLAN 长轮询 401 的一次幂等 GET 重签重试

尚未验证：新的 VoWLAN 401 重试是否真正消除长轮询失败；真机当前未连接。

## 2. 分支与发布状态

| 项目 | 状态 |
| --- | --- |
| VoBLE worktree | /Users/kyle/.codex/worktrees/voble/AirSIM |
| VoBLE HEAD | 8731b75 |
| origin/main | cc2ade3（落后 VoBLE 11 个提交） |
| AirSIM-ZTE | a60962a（未同步本轮） |
| main worktree | /Users/kyle/codex project/AirSIM，有 stash 与未跟踪文件 |
| Apps | Android 0.9.8.12 (117)，iOS 0.9.8 (141) |
| Release | v0.9.8.12 已发布；本轮后续修复未进入新 Release/TestFlight |

本轮代码提交：

    e93e8c6 feat: add visible SMS copy menu
    a0c4fde fix: prepare looper before KernelSU root bridge context
    84d9115 feat: auto-copy new SMS verification codes for keyboard paste
    717c3b0 feat: label received SMS with SIM slot
    cfca4d3 feat: copy SMS content and dial numbers
    51ebdd4 fix: use capture-safe minimum volume for every vendor
    bdb343f fix: keep Xiaomi VOICE_DOWNLINK capture unmuted at minimum volume
    5c75013 fix: retry idempotent VoWLAN GETs once after stale-signature 401
    8731b75 fix: discard cached LAN route after Wi-Fi/DHCP changes

## 3. 通话音频与红米问题

LocalOutputMuteController 已删除厂商分支，统一使用 MINIMUM_NONZERO_VOLUME：

- 不设置 muted=true
- 不使用 volume=0
- 保持 VOICE_DOWNLINK 采集流未静音

原因是部分 HAL 的 VOICE_DOWNLINK 采集与通话流静音/零音量耦合，真静音会把转发到 iPhone 的下行 PCM 压成全零。

证据：红米 Note 13 5G / 天玑 6080 日志中 muted=true volume=0 时 downlink_peak=0；音量加到 10 后立即恢复 12800→24204。

仍需真机验收。红米目标机未连接当前 ADB（当前只看到 U30Air）。安装 APK 后确认：

    output_policy=minimum_nonzero_volume
    minimum_volume=1
    pcm_down_peak > 0
    pcm_capture=observed

## 4. SMS 复制、验证码与卡槽

拨号页不再显示号码下方的复制/粘贴按钮行，保留长按号码菜单：复制号码、粘贴号码。粘贴会清理空格/括号/横线，仅保留 +*#0-9。

短信会话右上角菜单：复制最新短信、复制整段会话。长按单条短信可复制短信内容；正文支持选中复制。

验证码：会话顶部显示识别到的验证码并可复制；设置 → 短信 → 自动复制验证码到剪贴板（默认开启）。只处理 5 分钟内新收到短信，按 delivery_id 去重。

注意：这是剪贴板方案，不是键盘扩展；iOS 是否在键盘上方显示粘贴建议由系统决定。

SIM 卡槽：

- Android SMS 事件新增 sim_slot
- IncomingSMSReceiver 从 intent subscription extra 读取
- SMSInboxScanner 从 inbox sub_id 读取
- iPhone SMSMessage.simSlot 显示为 SIM 1 / SIM 2

旧短信没有该字段时不显示。

## 5. KernelSU root bridge

崩溃：

    RuntimeException: Can't create handler inside thread Thread[main]
    that has not called Looper.prepare()
    at ActivityThread.systemMain

修复：RootBridgeMain.main 在 ActivityThread.systemMain() 前执行：

    if (Looper.myLooper() == null) Looper.prepareMainLooper();

socket 服务循环保留，不调用 Looper.loop()。提交 a0c4fde。root 真机尚未复测。

## 6. VoWLAN 401 / 长轮询

日志特征：

    GET /api/health                          HTTP 200
    GET /api/events?after=1                  HTTP 401（约 20 秒后）
    GET /api/calls/events?after=0            HTTP 401（约 30 秒后）
    GET /api/calls/events?after=184467...    HTTP 200

Android 侧同时出现：

    vowlan_control_forwarded GET /api/events
    vowlan_control_failed path=unknown
    SocketTimeoutException: Read timed out

判断：更像长轮询连接排队/取消导致签名时间窗过期和半连接读超时，不是永久密钥不匹配。健康检查通过说明 secret 本身有效。

已做修复：幂等 GET 收到 401 后，用新 nonce/timestamp 重签并重试一次；不重放 POST。提交 5c75013。

尚未验证。当前设备不可用；需要新 trace 确认：

    第一次 401
    → 第二次 200

如果仍 401，下一步抓 Android vowlan_control_rejected 和 iOS 请求时间戳，检查 30 秒时钟窗、nonce 复用、多个 pairing 记录。

### DHCP / Wi-Fi 重连后的旧 IP

日志在 09:53 出现 NETWORK_CHANGED，但之后一直复用旧 LAN host，直到前台再次重建浏览器。已修复：网络路径变化时，本地 LAN 的缓存 endpoint 和手动 LAN route 会被丢弃，等待新的 Bonjour/健康检查；Tailscale/非本地子网路由保留，通话中不切换。

提交 8731b75。需要真机验证 DHCP 换 IP 后出现新的 DISCOVERED/VERIFIED，而不是继续探测旧 host。

## 7. 通知转发（此前一版交接的延续）

已实现 iPhone 配置 → 配对下发 → Android 直连 Webhook：

- Bark / Discord / Slack / 企业微信 / 飞书 / Telegram / QQ 官方 Bot / 通用 Webhook
- 自定义短信/来电/未接来电模板
- 独立发送队列，不经过 Relay/APNs
- Webhook URL/token 不上传 Relay
- 飞书签名和响应 code 校验
- Bark V2 /push + device_key
- 来电去重使用 call_id + state + direction
- 短信事件兼容旧无 event 字段

已知阻断：

- 飞书返回 Bot Not Enabled，需在飞书群启用/重建机器人
- Cloudflare Durable Objects 免费额度曾耗尽；APNs fallback 已部署，但云端媒体仍可能失败
- 转发配置存 Android 私有 SharedPreferences，尚未加独立 Keystore 加密

## 8. 验证状态

已通过：Android test.sh 全量、Standalone 构建、iOS build-for-testing、通知转发/SMS/Bark/飞书/root/401 编译。

未完成：红米 Note 13 真机音频复测、KernelSU root bridge 真机复测、最新 401 重试真实长轮询验证、所有转发渠道端到端验收、新 Release/TestFlight。

## 9. 关键文件

- iOS/AirSIM/PhoneViews.swift：拨号、短信复制、验证码、SIM 卡槽显示
- iOS/AirSIM/APIModels.swift：SMSMessage.simSlot
- iOS/AirSIM/AppModel.swift：自动复制验证码触发
- iOS/AirSIM/AirSIMSetupView.swift：自动复制设置
- iOS/AirSIM/AirSIMAPI.swift：VoWLAN 401 重试
- android/phone-control-app/src/com/airsim/phonecontrol/LocalOutputMuteController.java
- android/phone-control-app/src/com/airsim/phonecontrol/IncomingSMSReceiver.java
- android/phone-control-app/src/com/airsim/phonecontrol/SMSInboxScanner.java
- android/phone-control-app/src/com/airsim/phonecontrol/WireJson.java
- android/phone-control-app/src/com/airsim/phonecontrol/RootBridgeMain.java

## 10. 下一步

1. 连接红米，安装最新 APK，复测 VOICE_DOWNLINK 下行峰值。
2. 连接 KernelSU 设备，确认 root bridge 不再因 Looper 崩溃。
3. 用当前 iPhone 跑一次 VoWLAN 长轮询，确认 401 后重试是否成功。
4. 处理飞书 Bot Not Enabled。
5. 变更 Wi-Fi/DHCP 后确认旧 LAN host 不再被复用。
6. 需要发布时再构建 Release/TestFlight；当前 main 还落后 VoBLE 11 个提交。
