# AirSIM 全项目 Claude 部署辅助

你正在处理 AirSIM：一个用三星 Android 手机承载蜂窝通话与短信，并让 iPhone / Apple Watch 通过 VoWLAN 或 Cloudflare Relay 使用这些能力的多端项目。

当前发布基线（2026-10-10）：Android Standalone/iOS Apps `v0.9.5`（build `78`），兼容用 AVF Agent `v0.4.6`（Debian `0.4.6-1`），Relay 协议 `0.2.1`。维护者 AirSIM Relay 为 `https://airsim-push.remotepilot.site`；DJOneHub 的 `https://push.remotepilot.site` 不得用于 AirSIM。历史 Release 文档中的旧版本号属于归档事实，不能机械替换。

## 开始前

依次完成：

1. 阅读根目录 `README.md`。
2. 阅读目标子目录的 `README.md`、源码和测试。
3. 运行 `git status --short`，保留用户现有改动。
4. 用 `rg` 查找跨端协议、环境变量、端口或 Bundle ID 的全部引用。
5. 只修改任务需要的文件，并同步相关测试与文档。
6. 安装、配对或恢复任务还要阅读 `docs/AVF_INSTALL_GUIDE.md` 与 `LLM.txt`；今后相关修改同步更新根目录和对应组件 README、安装指南、`LLM.txt`、`codex.md`、`claude.md`。

不要依赖旧品牌、旧部署域名或记忆中的 Cloudflare/Apple 行为。当前源码和锁定版本是事实来源。

## 系统边界

- `android-standalone`：推荐的单 APK 构建入口；复用 Android 实现并启用内置 Agent，不依赖 AVF Linux。
- `android/phone-control-app`：三星默认电话角色、Android Telecom、短信、VoWLAN、配对、AVF 启动引导和安装管理。
- `android/phone-audio-bridge`：Shizuku `UserService`，负责双向通话 PCM。
- `module/module-agent`：AVF Linux 中的设备状态、控制 API、Relay 与媒体编排。
- `module/avf-installerd`：独立救援安装服务，只安装通过签名和包元数据校验的 Debian 包。
- `module/packaging`：单一 `arm64` Debian 包、systemd 单元、签名与首次安装脚本。
- `iOS`：iPhone、Apple Watch、CallKit、PushKit、ActivityKit、短信和传输选择。
- `push-relay-worker`：Cloudflare Worker、KV、Durable Objects、APNs、Dashboard 与 WebSocket。

跨组件协议变更必须同时更新生产者、消费者、模型、测试和文档。不得只让一端编译通过。

## 强制安全规则

1. AVF Agent、installerd 和 PCM 只能监听内部私网或 loopback。
2. VoWLAN 必须保留时间戳、nonce、HMAC、路由白名单和大小限制。
3. 通话 PCM 不落盘，日志不能包含 PCM、完整短信、Push token 或 Secret。
4. Agent 不得自行更新；更新、修复和回滚只能由独立 installerd 执行。
5. installerd 不得执行任意 shell，也不得接受错误包名、非 `arm64` 或未签名包。
6. 紧急呼叫交给系统电话能力，不得宣称 AirSIM 可承担紧急通信。
7. 普通 Android App 不能绕过 OEM 或系统签名限制强制开启被隐藏/删除的 AVF 功能。
8. AVF 的 `/api/health` 只证明 Agent 可达；`8576` installerd、控制 token 与真实电话链路必须分别验证。不要硬编码唯一 AVF 网段，也不要用清除 Terminal 数据或删除 `current.deb` 作为常规修复。

v0.4.5 是一次签名信任根迁移：v0.4.4 的私钥未留存，旧 installerd 会拒绝新签名。已有 `0.4.4-1` 的设备必须在 AVF Terminal 执行经核对的 `rotate-avf-key.sh`，保留旧包和状态，之后才恢复 App 内签名更新。新发行私钥只存在于仓库外的受限存储与 GitHub Actions Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`；签名操作不得回显或提交私钥。具体步骤见 `docs/AVF_INSTALL_GUIDE.md`。

严禁提交或回显：`APNS_P8`、`DASHBOARD_TOKEN`、Cloudflare API token、Apple `.p8`、设备 Secret、Agent token、HMAC、Debian 发布私钥、Android keystore、Apple 证书/profile、真实号码和短信内容。

## Apple 签名规则

`com.example.airsim` 是源码仓库中的占位符。每位部署者必须用自己的 Apple Developer Team 重新配置：

- 主 App：部署者的唯一 Bundle ID。
- Watch App：主 Bundle ID 加 `.watchkitapp`。
- Live Activity：主 Bundle ID 加 `.liveactivity`。
- 测试 Target：主 Bundle ID 加 `.tests`。
- Watch companion 标识：等于主 App Bundle ID。
- Relay `ALLOWED_BUNDLE_ID`：等于主 App Bundle ID。

只改 Team 或签名证书而保留他人的 Bundle ID 不可行。Debug token 对应 APNs sandbox，TestFlight/App Store token 对应 production；不能混用。

## Relay 规则

生产者必须使用自己的 Cloudflare 账户、KV、Durable Objects 和自定义域名。维护者 AirSIM Worker 是 `airsim-push-relay`，地址为 `https://airsim-push.remotepilot.site`，只允许 `com.eric3u.airsim`；它不是第三方重签 App 的公共服务。DJOneHub 的 `https://push.remotepilot.site` 必须保持独立，AirSIM 不得接管其 hostname、KV、Durable Objects 或 Dashboard token。客户端和 Agent 不能把任何历史域名当作硬编码依赖。

截至 2026-10-08，维护者部署只完成了健康检查与 Dashboard 鉴权验收，AirSIM 环境尚无设备注册；不得据此宣称真实 APNs、Agent 心跳或云端 PCM 已通过。

`APNS_P8` 与 `DASHBOARD_TOKEN` 是必需 Worker Secret：

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

`wrangler.example.toml` 的 `[secrets] required` 只声明名称，不保存值。Secret 不能写入 `[vars]`、Git、构建产物或日志。执行 `secret put` 和生产 `deploy` 都是外部状态变更，只有用户明确要求时才能执行。

## 许可证边界

AirSIM 使用 `PolyForm-Noncommercial-1.0.0`，只授权个人学习、研究、实验及许可证列明的其他非商业用途。不得把项目描述为 OSI 开源软件，也不得协助将 AirSIM 用于收费服务、商业产品、企业内部商业目的或其他预期商业应用，除非用户能提供版权所有者的单独书面商业许可。修改、构建或再分发时必须保留根目录 `LICENSE`、`NOTICE` 和适用的第三方声明。

## 标准验证

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

按变更范围运行最小充分验证。修改协议或共享配置时运行两端测试；发布前运行全套。文档变更至少执行 `git diff --check`、相对链接检查和敏感值扫描。

## 部署顺序

1. 构建并安装三星 Android App，设置默认电话角色并授权 Shizuku。
2. 启动 AVF Linux，按 `docs/AVF_INSTALL_GUIDE.md` 在 Debian Terminal 中执行带 `pipefail` 和超时的签名安装命令；App 按钮只负责复制，不能替用户在来宾系统执行。已有 `current.deb` 且 `8576` 不可用时应恢复 installerd，而非删除回滚包。运行 `sudo airsim-avf-pair`，保存当前动态 AVF 地址与控制 token。源码引导脚本的修复只有在明确授权发布新 Release 后才会进入线上命令。
   若报 `udev` 与 `libudev1` 精确版本依赖冲突，先读取 `apt-cache policy` 和 `sudo apt-get -s -f install` 的模拟结果，不自动运行 `apt --fix-broken install`；引导脚本要在安装 Agent 前检查现有 Debian 包状态。
3. 分别验证 `8575` AirSIM Agent（`product=airsim`）、`8576` installerd、音频桥和 Android Telecom 控制面。现有 DJOneHub 保留在 `7575`；旧 AirSIM Release 会与它冲突，不能用于共存安装。Terminal 的 `VM is not in stopped state` 应先无损排查启动冲突，不归因于 Agent 包。
4. 使用部署者自己的 Apple 身份配置并签名 iOS/watchOS 工程。
5. 如需远程模式，创建独立 Relay 资源、设置 Secret、dry-run 后再部署。
6. 先验证 VoWLAN，再验证公网 Relay、APNs sandbox/production 和 Watch 链路。
7. 完成三星来电/去电、短信、双向音频、后台唤醒、断网、重启和回滚验收。

## 报告格式

最终回复要区分：

- 已修改与已验证。
- 尚未执行的真机或生产操作。
- 需要用户提供的账户、设备、签名或域名条件。
- 已知风险与下一步。

不要把 dry-run 写成部署成功，不要把模拟器编译写成真机可用，也不要把代码中的能力写成已经通过运营商网络验收。
