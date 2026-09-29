# AirSIM iOS 与 watchOS

该目录包含面向三星 Android 电话端的 iPhone、Apple Watch、Live Activity 与共享模型。客户端通过 VoWLAN 直连三星手机，或通过独立 Cloudflare Relay 使用远程通话与短信。

## Xcode 工程

打开：

```text
iOS/AirSIM.xcodeproj
```

主要 target：

- `AirSIM`：iPhone / iPad 主 App
- `AirSIMWatchApp`：Apple Watch App
- `AirSIMLiveActivityExtension`：锁屏与灵动岛实时活动
- `AirSIMTests`：传输选择和协议边界测试

## 客户端能力

- 三星设备一次性加密配对
- VoWLAN 服务发现、HMAC 鉴权和健康检查
- CallKit 拨号、来电、接听、挂断、静音与 DTMF
- PushKit、通知 APNs 与 ActivityKit
- Apple Watch 拨号、接听和通话媒体
- 短信列表、发送、通知和联系人整合
- VoWLAN 与云端 Relay 传输选择
- 本地通话记录、诊断和媒体健康状态

## 首次配置

1. 在三星手机启动 AirSIM，并确认 Agent 与 Shizuku 音频桥就绪。
2. 将 iPhone 连接到三星热点或同一局域网。
3. 在三星端打开两分钟配对窗口。
4. 在 iPhone 输入三星端显示的六位配对码。
5. 等待 VoWLAN 状态显示为就绪。
6. 如需远程模式，在设置中填写独立 Relay 地址并启用云端通话与短信。

## 构建与测试

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

在指定模拟器运行测试：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 签名与推送

需要为主 App、Watch App 和 Live Activity Extension 配置独立 App ID、证书与 provisioning profile。Relay 地址通过 `AIRSIM_PUSH_RELAY_URL` 注入，APNs 环境通过 `AIRSIM_APNS_ENVIRONMENT` 配置。

新安装需要重新完成三星配对、通知授权、CallKit/PushKit 注册和 Watch 配套安装。

## 安全与隐私

- VoWLAN Secret 保存在 Keychain，不写入 UserDefaults 或日志。
- 配对使用 X25519、HKDF-SHA256 与 AES-256-GCM。
- 控制请求使用 HMAC-SHA256、时间窗口和 nonce 防重放。
- 通话 PCM 仅在内存和网络流中处理，不落盘。
- 日志与错误界面不得显示设备 Secret、HMAC、Push token 或完整媒体地址。

## 当前状态

模拟器构建与测试已覆盖主要协议和传输选择。正式发布前仍需完成 Apple 签名、实体 iPhone/Apple Watch 安装、三星实机拨号接听、双向语音、短信与后台推送验收。
