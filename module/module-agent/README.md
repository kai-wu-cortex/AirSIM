# AirSIM Android AVF Agent

此 Agent 源自原 DJOneHub 控制面，但 AirSIM 的普通服务启动现在只接受 `android-avf` + `samsung_android`，缺少三星私网 PCM 地址时会拒绝启动。不会自动打开 QDC507 的 AT 端口，也不附带 QDC507 构建、刷写或固件包。

```sh
go test ./...
GOOS=linux GOARCH=arm64 go build -o /tmp/airsim-agent .
```

部署时须在设备内明确配置 `DJONEHUB_RUNTIME_PROFILE=android-avf`、`DJONEHUB_VOICE_BACKEND=samsung_android`、`DJONEHUB_SAMSUNG_PCM_ADDRESS=<AVF 私网 IP>:7580`，以及 `DJONEHUB_ANDROID_CONTROL_TOKEN_FILE` 指向权限受限的本地 token 文件。`DJONEHUB_*` 是目前与 Android 桥互通的旧协议配置名；更换它们需要 Android、iOS 与 Agent 同步迁移。请勿把 token 或设备私网地址提交到仓库。

Go 源码中仍有旧 QDC507 兼容函数与接口模型。它们在 AirSIM 正常启动路径被拒绝，但**尚未完成代码级裁剪与三星实机验证**。不要直接把此源码当作已审核的三星发行包。
