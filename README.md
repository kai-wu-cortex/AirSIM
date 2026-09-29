# AirSIM

AirSIM 是以三星 Android 手机为蜂窝通信终端的跨设备通话与短信系统。三星端负责运营商通话、短信和系统音频控制；Android AVF 中的 Agent 负责设备状态、云端连接和命令编排；iPhone 与 Apple Watch 提供 CallKit、拨号、接听、短信和通话界面；Cloudflare Relay 提供公网事件、推送与媒体中继。

## 系统组成

| 目录 | 组件 | 主要职责 |
| --- | --- | --- |
| `android/phone-control-app` | 三星 Android 控制 App | 默认电话角色、Android Telecom、配对、VoWLAN、短信与守护服务 |
| `android/phone-audio-bridge` | 三星音频桥 | 通过 Shizuku 提供双向通话 PCM |
| `module/module-agent` | Android AVF Agent | 控制 API、设备状态、Relay 心跳、命令与媒体编排 |
| `iOS` | iPhone / Apple Watch App | CallKit、PushKit、VoWLAN、短信、实时活动与通话媒体 |
| `push-relay-worker` | Cloudflare Relay | 设备注册、APNs、云端命令、Dashboard 与公网媒体 |

## 通信链路

局域网模式使用三星热点或同一局域网：

```text
iPhone / Apple Watch
        │ VoWLAN 控制与 PCM
        ▼
三星 Android 控制 App
        │ AVF 私网
        ▼
Android AVF Agent ── Android Telecom / Shizuku 音频桥
```

远程模式通过独立 Relay：

```text
iPhone / Apple Watch ⇄ Cloudflare Relay ⇄ Android AVF Agent ⇄ 三星 Android
```

每通电话在建立时选择 VoWLAN 或云端 Relay，并在通话结束前保持该传输路径。

## 开发环境

- Android：JDK 17、Android SDK Platform 35、Build Tools 35
- iOS / watchOS：Xcode
- Agent：Go
- Relay：Node.js 与 Cloudflare Wrangler
- 三星测试手机：Android Telecom、Shizuku、无线调试与 Android AVF 环境

## 本地验证

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
(cd module/module-agent && go test ./...)
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

## 三星设备部署流程

1. 在三星手机安装 AirSIM，并将其设置为默认电话 App。
2. 启动 Shizuku，向 AirSIM 授予权限，并确认音频桥可用。
3. 在 Android AVF 中部署 Agent，配置私网地址、控制令牌和 Relay 注册信息。
4. 在三星端开启配对窗口，在 iPhone 上输入六位配对码。
5. 验证 VoWLAN 健康状态、拨号、接听、短信和双向音频。
6. 配置独立 Cloudflare Relay 与 APNs 后，再验证远程模式。

## 安全要求

- AVF 服务和 PCM 端口只能监听三星设备内部私网。
- VoWLAN 请求必须经过时间戳、随机数和 HMAC 校验。
- 配对密钥、设备 Secret、Agent token、APNs `.p8` 和真实号码不得提交到仓库。
- 日志只能记录生命周期、计数和错误，不得记录密钥或 PCM 内容。
- APK、签名文件、生产配置和本地 Relay 密钥均由 `.gitignore` 排除。

## 当前状态

仓库已完成 Android、Agent、iOS/watchOS 与 Relay 的源码整合和本地自动化验证。生产 Relay、Apple 签名、三星实机长期稳定性和真实双向通话仍需在目标环境中完成验收。
