# AirSIM — Samsung 通话链路独立项目

此目录是从旧项目工作树复制出的独立开发项目，原仓库未被移动或覆盖。范围为三星 Android 电话端、Shizuku 音频桥、Android AVF Linux Agent、iPhone/Watch 的三星 VoWLAN 与云端通话，以及独立 Cloudflare Relay。

| 目录 | 用途 |
| --- | --- |
| `android/phone-control-app` | 三星默认电话 App、热点配对、VoWLAN、诊断 |
| `android/phone-audio-bridge` | Shizuku shell UID 双向 PCM 桥 |
| `module/module-agent` | Android AVF Agent 与 Relay 客户端 |
| `iPadOS` | iPhone/Watch VoWLAN、CallKit、短信和云端媒体 |
| `push-relay-worker` | AirSIM 专用 Cloudflare Worker 模板、测试 |

## 隔离边界

- Android 包名为 `com.airsim.phonecontrol` / `com.airsim.bridge`，iOS/Watch Bundle ID 为 `com.eric3u.airsim*`；**不会覆盖**旧项目的三星端或 iOS 安装。
- iOS 默认入口仅显示三星配对、VoWLAN 与独立 Relay。旧 QDC507 模块的首次连接向导、设置页、Agent 维修 UI 和三个固件包没有进入 App 构建。拨号、短信与轮询仅选择已验证的三星 VoWLAN 或云端；不会回退到 `192.168.225.1`。
- Agent 源码仍保留来自旧项目的 QDC507 兼容实现，**不可把它当作已完成裁剪的三星专用发行包**。运行时默认 profile 为 `android-avf`。发布前需要进一步拆除 QDC507 编译路径与旧更新器，并做实机回归。
- Relay 的 `wrangler.example.toml` 仅是模板；独立 KV、Durable Objects、APNs 密钥、域名和苹果签名均需另行配置。没有使用原生产地址或密钥。

## 本地验证

Android：JDK 17、Android SDK Platform/Build Tools 35；iOS：Xcode；Agent：Go；Relay：Node.js。

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
(cd module/module-agent && go test ./...)
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iPadOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing
```

三星端需要用户自行设置为默认电话 App、授权 Shizuku，并与 Agent 进行一次性配对。请勿把 AVF 私网服务、PCM Bridge 或设备密钥暴露到公网。项目内不应提交 APK、调试 keystore、APNs `.p8`、Agent bearer token、配对凭据及 PCM 数据。

当前仅完成源码分离和本机构建；**未**签名安装、部署 Relay、迁移已有用户凭据或验证三星实机双向通话。新包名意味着旧应用的配对与授权不会自动继承。
