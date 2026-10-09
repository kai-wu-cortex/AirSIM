# AirSIM Android AVF Agent

Agent 运行在三星 Android 的 AVF Linux 环境中，连接三星控制 App、通话音频桥、Cloudflare Relay 与 iPhone/Apple Watch 客户端。

当前 Agent 发布为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)（Debian 包 `0.4.6-1`），配套 Android/iOS 应用发布为 [`v0.9.3`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.3)。维护者 Relay 是 `https://airsim-push.remotepilot.site`；`https://push.remotepilot.site` 仅属于 DJOneHub。

首次安装、控制令牌配对、`8575` Agent 可达但 `8576` installerd 不可用、以及 Terminal 启动冲突的无损排障步骤，统一见 [AVF 安装指南](../../docs/AVF_INSTALL_GUIDE.md)。`/api/health` 成功不代表安装服务或配对已经就绪。

## 主要职责

- 暴露通话、短信、设备状态和诊断 API。
- 接收三星 Android 上报的 Telecom 与短信事件。
- 向三星控制 App 分发拨号、接听、拒接、挂断、DTMF 和短信命令。
- 管理 Relay 心跳、设备注册、云端命令与通话媒体。
- 校验 Android 控制 token，并限制私网调用来源。
- 监控三星 PCM 后端并上报媒体健康状态。

## 构建与测试

```sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
```

正式部署使用仓库根目录下 `module/packaging/build-avf-deb.sh` 生成的单一 `arm64` Debian 包。Agent 安装到 `/usr/bin/airsim-agent`，独立救援安装器安装到 `/usr/lib/airsim/airsim-installerd`。

## 必需配置

```sh
AIRSIM_RUNTIME_PROFILE=android-avf
AIRSIM_VOICE_BACKEND=samsung_android
AIRSIM_SAMSUNG_PCM_ADDRESS=<AVF_PRIVATE_IP>:7580
AIRSIM_DATA_DIR=/var/lib/airsim
AIRSIM_ANDROID_CONTROL_TOKEN_FILE=/var/lib/airsim/control.token
```

控制 token 文件必须只允许 Agent 服务账号读取。私网地址和 token 不得提交到仓库或写入公开日志。

## 云端 Relay 配置

Agent 不硬编码公网域名；它使用 iPhone 配对注册中下发的 `relay_url`。维护者 `com.eric3u.airsim` 构建使用 `https://airsim-push.remotepilot.site`，而 DJOneHub 继续使用 `https://push.remotepilot.site`。两套 Worker、KV、Durable Objects、设备身份和命令/媒体会话相互隔离，AirSIM Agent 不得连接 DJOneHub Relay。

重新签名的部署者必须配置自己的 Relay 地址、`ALLOWED_BUNDLE_ID` 和 APNs 凭据。Relay `/healthz` 成功只证明 Worker 可访问；还要分别验证设备注册、Agent 心跳、命令拉取、APNs 和媒体 WebSocket。

## 启动验证

在重启正式服务前运行：

```sh
AIRSIM_RUNTIME_PROFILE=android-avf \
AIRSIM_VOICE_BACKEND=samsung_android \
AIRSIM_SAMSUNG_PCM_ADDRESS=<AVF_PRIVATE_IP>:7580 \
/usr/bin/airsim-agent --startup-probe voice-backend
```

探针会验证配置、私网地址、TCP 连接与 `AIRSIMPCM1` / `AIRSIMREADY` 握手。

## 与三星控制 App 的接口

三星 App 使用受保护的 `/api/android/*` 接口完成：

- 配对注册
- 通话与短信事件上报
- 命令长轮询
- 命令结果回传
- 健康状态与能力查询

外部客户端不得直接访问 AVF 内部控制地址。VoWLAN 由三星 App 执行认证、路由白名单和响应大小限制后再转发。

## 安全与运维

- 服务运行配置固定为 `android-avf` 与 `samsung_android`。
- 日志隐藏 Android 控制请求正文、短信内容、设备 Secret 和 PCM 数据。
- Relay、Android App 和 Agent 的协议字段必须同步发布。
- 生产部署前需要完成三星实机通话、短信、重启恢复和长时间稳定性验收。
- Agent 本身不再安装更新；Android App 通过独立 `airsim-installerd` 校验签名、安装、健康检查和回滚。
