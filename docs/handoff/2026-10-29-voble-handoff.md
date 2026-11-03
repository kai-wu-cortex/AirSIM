# AirSIM / VoBLE 全项目交接 — 2026-10-29

交接对象：Codex
工作目录：`/Users/kyle/.codex/worktrees/voble/AirSIM`
当前分支：`VoBLE`
当前 HEAD：`06021aa fix: keep the Contacts navigation bar and search visible`

> 本文只记录源码、构建、发布和真机状态。不要提交 `release-assets/`、Dashboard Token、APNs key、Android keystore、设备 Secret 或完整日志。

---

## 1. 当前结论

- 已在 GitHub 发布 Apps `v0.9.8.18`：Android `0.9.8.18 (123)`，iOS `0.9.8 (147)`。
- TestFlight build 147 已上传成功，Apple 回执为 `Upload succeeded` / processing；尚未确认 Apple 处理完成或测试者可更新。
- 当前 HEAD `06021aa` 比 `v0.9.8.18` release tag 多一个联系人搜索修复；**该修复不在 147 发布包中**。
- Relay Durable Objects 免费额度当前超限，云端心跳/命令/媒体会出现 HTTP 500；这是当前最高优先级基础设施问题。
- Tailscale/蜂窝下接打失败目前最像控制端口或 PCM 端口过期/填错，不是 147 新引入的 Tailscale 代码。
- Apple Watch 真机撤铃验证尚未完成：Mac 与 Watch 的开发者连接被 `RemotePairingError 1035` 拒绝，Watch 当前从 `devicectl` 不可见。
- PR #11（NAS/自建 TLS 直连）已由作者关闭；代码可从 GitHub PR ref 取到，能适配当前 VoBLE，但没有 NAS/真机验收，不应直接发布。

---

## 2. 版本和提交

当前版本文件：

- `android-standalone/AndroidManifest.xml`：versionCode `123`，versionName `0.9.8.18`
- `android/phone-control-app/AndroidManifest.xml`：versionCode `123`，versionName `0.9.8.18`
- `iOS/AirSIM.xcodeproj/project.pbxproj`：CURRENT_PROJECT_VERSION `147`，MARKETING_VERSION `0.9.8`

近期提交（从新到旧）：

```text
06021aa fix: keep the Contacts navigation bar and search visible
5bd9d9b docs: record TestFlight build 147 upload
664f5dc release: AirSIM Apps v0.9.8.18
da907bb fix: dedupe Watch call payloads without timestamp
d5afb83 Merge pull request #7 from zeyugao/fix/watch-ring-stop-on-iphone-answer
7a6d24e fix: prepare CallKit audio before answering without failing the action
8e54bc3 fix: use the bound VoWLAN device for cold CallKit answers
7a32939 Merge pull request #9 from Mr-KIDBK/contrib/relay-401-reregister
ca5db2e Merge pull request #5 from zeyugao/VoBLE
```

Tag：

```text
v0.9.8.18   （release 说明/docs 的 tag；指向 5bd9d9b）
v0.9.8.17
rollback-2026-10-28-pre-cloud-signaling
v0.9.8.16
```

注意：`06021aa` 尚未进入 `v0.9.8.18` tag / TestFlight 147。

---

## 3. 已完成的功能与修复

### 3.1 VoWLAN 云端通知独立

- 新增 `CloudSignalingPreference`。
- 设置页“云端通知（APNs）”独立于媒体模式。
- 关闭本地模式不会再自动切换到自动模式。
- VoWLAN 下可以保留 PushKit/APNs；媒体仍优先 VoWLAN。
- 相关文件：`ConnectionModePreference.swift`、`AppModel.swift`、`VoIPPushController.swift`、`BackgroundStandbyController.swift`、`CallKitController.swift`、`AirSIMSetupView.swift`。

### 3.2 CallKit 修复

- CallKit 接听改为幂等，避免第二次 answer。
- 接听前尽力配置音频，但预配置失败不再 `fail()` 整个 CallKit action。
- 非纯云端模式下，CallKit 接听后等待 VoWLAN 路由恢复。
- 冷启动 CallKit 使用当前绑定 Android 的专属凭据和经过验证的端点，不再使用全局旧凭据/任意发现设备。
- 文件：`CallKitController.swift`、`AppModel.swift`、`BackgroundStandbyController.swift`。

### 3.3 通讯录

- 识别 iOS 18 `.limited` 通讯录权限，不再伪装成完整授权。
- 联系人变更监听和强制刷新。
- 联系人搜索栏回归已修复：`06021aa`，让联系人 Tab 保持导航栏可见。
- 注意：该搜索修复不在 TestFlight 147。

### 3.4 短信

- PR #5 合并：原生风格会话、日期分组、文本选择、复制、多选删除、系统分享、Tab 栏转场。
- 后续发现并修复 Watch payload 去重：`da907bb`。
- PR #5 引入的短信 UI 规模较大，仍需真机检查 VoiceOver、大字体、iPad 和侧滑返回。

### 3.5 Watch 撤铃

- PR #7 合并：iPhone CallKit active/ended 通过 WatchConnectivity 镜像。
- 增加 call ID/UUID/alias 匹配、tombstone、迟到 APNs 防重拉。
- 修复 Watch payload 去重：`da907bb`。
- **尚未完成真实 Watch 安装/撤铃验证。**

### 3.6 Relay 401 恢复

- PR #9 合并。
- Standalone 只有 HTTP 401 触发重新注册；退避 1/2/4…60 分钟。
- 心跳成功且其他通道无 401 时复位。
- 相关：`RelayRegistrationRecovery.java`、`StandaloneAgentService.java`。
- 注意：只处理 401，不处理当前 Relay 的 HTTP 500。

### 3.7 开屏展示

- 只修改 `iOS/AirSIM/AppUpdateView.swift` 和 `AppReleaseNotes.items`。
- 页面内容：VoWLAN CallKit、通讯录、短信会话、Watch 停铃。
- 没有改业务逻辑。

---

## 4. 当前发布资产

本地未跟踪目录：

```text
release-assets/0.9.8.18/
  AirSIM-Android-Standalone-0.9.8.18-build123.apk
  AirSIM-Android-AVF-0.9.8.18-build123.apk
  AirSIM-iOS-0.9.8-build147-unsigned.ipa
  AirSIM-iOS-0.9.8-build147-sideload-unsigned.ipa
  SHA256SUMS.txt
  LICENSE
  NOTICE
  THIRD_PARTY_NOTICES.md
```

校验和：

```text
b2a27ea8eb42d7cc6609243d0c08db6ba13551d3fbc9a76bf73c1a73157eb88d  Standalone APK
8e11f711c499b256505f31894ed1db65b6c9452dabe69390ed658ed20e9ad13c  AVF APK
87890a6e0723ccb1bb507342c475c4c967f9fef359c6eef8566a601e435d56c4  full IPA
ab8900a9801ebc7fbefdf612374b32a3c7f0e1da324a4b4fbfd43e4d76a9ee80  sideload IPA
```

GitHub：

```text
https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.8.18
```

发布资产未提交到 Git，不要误加。

---

## 5. TestFlight 状态

构建 147 上传成功：

```text
Upload succeeded
Uploaded package is processing
```

上传时间约 2026-10-29 01:20（Asia/Shanghai）。

已经遇到并解决的上传问题：

- 系统 HTTP/HTTPS/SOCKS 代理 `127.0.0.1:7890` 会让 Xcode 的 Apple 账户登录产生 TLS 错误。
- 正确上传方式：关闭系统 HTTP/HTTPS/SOCKS 代理，并清除环境代理变量后执行 `xcodebuild -exportArchive`。
- 上传结束后必须恢复系统代理。

复现使用的命令：

```sh
networksetup -setwebproxystate Wi-Fi off
networksetup -setsecurewebproxystate Wi-Fi off
networksetup -setsocksfirewallproxystate Wi-Fi off
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
  xcodebuild -exportArchive \
    -archivePath /tmp/AirSIM-0.9.8.18.xcarchive \
    -exportOptionsPlist /tmp/AirSIM-ExportOptions.plist \
    -exportPath /tmp/AirSIM-export-0.9.8.18 \
    -allowProvisioningUpdates
networksetup -setwebproxystate Wi-Fi on
networksetup -setsecurewebproxystate Wi-Fi on
networksetup -setsocksfirewallproxystate Wi-Fi on
```

如果 TestFlight 看不到构建：先等 Apple processing；检查 App Store Connect → TestFlight → Builds 及 Export Compliance。当前 `ITSAppUsesNonExemptEncryption=false` 已在 Info.plist。

---

## 6. 当前最高优先级问题

### P0 — Relay Durable Objects 免费额度超限

Worker 日志：

```text
Exceeded allowed volume of requests in Durable Objects free tier.
```

影响：

- `/v1/events/heartbeat` 返回 500
- `commands/connect` WebSocket handshake 500
- 云端 PCM WebSocket 500
- Dashboard 显示 0 在线
- PushKit 不保证，云端接听不可用

不要通过重装 App 解决。处理方向：

1. 升级 Cloudflare Workers / Durable Objects 额度，或
2. 减少旧 Android Agent/命令连接，降低 DO 请求量，或
3. 重新设计命令/心跳存储，不能只用 KV 心跳（KV 免费写入额度也会超）。

当前 Worker 最新部署版本：

```text
8557af4c-29eb-4a14-97f0-c824e8b4a4f7
```

注意：临时 Notion 读取路由已移除并重新部署。

### P1 — Tailscale/蜂窝下接打失败，HTTP 500/无效 HTTP

用户反馈：

- 局域网正常。
- 蜂窝 + Tailscale 下接打不正常。
- 出现 `Agent 代理返回了无效 HTTP 响应`。

重点排查：

1. Android 当前控制端口和 PCM 端口是否变化。
2. iOS 手动 Tailscale 路由是否仍保存旧端口。
3. Tailscale ACL 是否放行控制/PCM，而不只是配对端口。
4. `无效 HTTP` 表示 TCP 连通但不是 AirSIM HTTP，最常见是 HTTP 请求发到了 PCM/配对端口。
5. 重新按当前端口配对，配对时选“仅本次配对不写入云端”。
6. 如果 Android 重启后端口变化，需要更新手动路由；当前没有自动刷新端口的实现。

尚未拿到用户当前 Android control/PCM 端口和 iOS 实际保存端口；下一步先收集这两组值。

### P1 — 联系人搜索

已修复源码，未发布：

```text
06021aa fix: keep the Contacts navigation bar and search visible
```

需要进入下一次 148 构建/TestFlight。

### P1 — Watch 真机验证

当前阻塞：

```text
com.apple.dt.RemotePairingError error 1035
The device rejected the Bluetooth connection attempt.
```

曾执行 `devicectl manage unpair` 重新配对，但 Watch 仍不可见。需要用户：

- 解锁 Watch
- 打开 Developer Mode
- 保持靠近 iPhone/Mac
- 在 Xcode Devices/Bluetooth 重新信任配对
- 让 `xcrun devicectl list devices` 重新出现可用 Watch

之后安装：

```text
/tmp/watch-real-device/Build/Products/Debug-iphoneos/AirSIM.app/Watch/AirSIMWatchApp.app
```

测试：

1. iPhone App 无后台/锁屏收到 APNs 来电。
2. Watch 响铃。
3. iPhone CallKit 接听。
4. Watch 在数秒内停止响铃，iPhone 继续通话。
5. 迟到的同一 APNs 不重新拉起 Watch。
6. Watch 接听/拒绝路径不误挂断 iPhone。

### P2 — Notion 反馈链接无法读取

用户提供的页面没有共享给 Relay 使用的 Notion integration `WebCMS`：

```text
Could not find page with ID ...
Make sure the relevant pages and databases are shared with your integration "WebCMS".
```

需要用户分享页面给 WebCMS，或直接粘贴正文/日志。临时读取路由已删除，不要把 Notion token 写入代码。

---

## 7. PR #11 评估（未合并，已关闭）

PR：

```text
https://github.com/kai-wu-cortex/AirSIM/pull/11
状态：CLOSED，作者关闭
目标：main，不是 VoBLE
```

功能：NAS/软路由自建域名 + TLS 终止 + 双 TCP 转发（HTTPS 控制、PCM TLS），给已配对 Android 增加可选远程直连，不经过 Relay。

代码获取：

```sh
git fetch origin refs/pull/11/head:refs/remotes/origin/pr11
```

适配当前 VoBLE 时只有 `VoWLANController.swift` 冲突：

- 保留当前 VoWLAN verification watchdog。
- 同时保留 PR 的 `remoteConfigurationGeneration` / `configureRemoteRoute`。
- 保留当前 `probeNow(attempted:)` 与 PR 的 TLS 远程探测逻辑。
- 已在一个临时 worktree 解决冲突并通过 `build-for-testing`。
- `RemoteDirectTests` 9 项通过。

不要直接合并发布：

- 需要 NAS/router、DDNS、证书、端口映射。
- 需要 IPv4/IPv6、证书续期、Android 重启端口变化、iPhone/Watch 公网音频验收。
- 这是高级用户功能，不是开箱即用。

---

## 8. 当前设备状态（可能变化，使用前重新确认）

已知最近状态：

- iPhone Air：开发包最近为 `0.9.8 (146)`；TestFlight 147 已上传但未确认安装。
- Android SM-F766U：曾安装开发包 `0.9.8.17 (122)`；最新 release 123 已构建但未确认安装。
- Apple Watch Series 11：Mac developer pairing 被拒绝，当前 `devicectl` 不可见。
- Android 无线 ADB 经常断连；使用前执行 `adb devices -l`。

确认命令：

```sh
xcrun devicectl list devices
xcrun devicectl device info apps --device 00008150-0019598E01C0401C
xcrun devicectl device info apps --device 00008310-000C2AAC0240E01E
adb devices -l
adb shell dumpsys package com.airsim.phonecontrol.standalone | grep version
```

---

## 9. 构建与验证命令

iOS 模拟器：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/airsim-build \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

iOS 真机开发包：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -configuration Debug -destination 'generic/platform=iOS' \
  -xcconfig iOS/build/relay-routing-install/Install.xcconfig \
  -allowProvisioningUpdates \
  -derivedDataPath /tmp/airsim-device build
```

Android：

```sh
./android/phone-control-app/test.sh
./android-standalone/build.sh
```

Relay：

```sh
cd push-relay-worker
npm test
npm run check
```

注意：`android-standalone/test.sh` 有已知基线失败（`test-gateway-lifecycle.sh` 的 fake Handler/BroadcastReceiver 方法缺失）；不要把它误报成业务回归。

---

## 10. 发布流程提醒

1. 升版本前先确认没有未提交业务改动。
2. Android release 需要 keychain 中的 `AirSIM Android Release Keystore Password` / `Key Password`，不要回显。
3. iOS production archive 使用 `/tmp/AirSIM-AppStore.xcconfig` 或等价自动签名配置；公开 IPA 必须重新生成 unsigned full/sideload。
4. TestFlight 上传前关闭系统 HTTP/HTTPS/SOCKS 代理及环境代理，否则 Xcode Apple 账户 TLS 会失败。
5. 上传成功只代表 Apple 接收；processing、外测审核、测试者可见分别核实。
6. 不要提交 `release-assets/`。
7. 当前 `v0.9.8.18` 已发布；联系人搜索修复 06021aa 需要新的 148 版本，不要覆盖已有 release tag。

---

## 11. 安全边界

- Dashboard Token 在用户 Downloads；不要输出或提交。
- APNs `APNS_P8`、NOTION_TOKEN、Android keystore、设备 Secret、PCM secret 一律不打印、不写仓库。
- `wrangler.toml` 被 Git 忽略，包含生产配置/secret 名称，不能覆盖或提交真实值。
- Notion 页面是私有的；读取需要用户授权给 WebCMS，临时生产路由已清理。
- 不要把“构建成功”“上传成功”“Apple processing”“测试者可见”混为一谈。

---

## 12. 建议 Codex 的下一步顺序

1. **先恢复 Relay DO 额度**，否则所有云端/APNs 验证没有意义。
2. 用当前 Android 实际 control/PCM 端口复现 Tailscale 蜂窝失败，记录 iOS Verbose 的 host/port 和原始 HTTP 响应；不要先改业务代码。
3. 把联系人搜索修复 06021aa 进入新版本 148，并做一次 TestFlight。
4. 重新配对 Apple Watch，安装 Watch App，完成撤铃真机验证。
5. 如用户确认要做 NAS TLS 直连，再基于 PR #11 ref 单独开分支，不要混入当前发布。
6. 用户分享 Notion 页面给 WebCMS 或粘贴日志后，再分析反馈。

