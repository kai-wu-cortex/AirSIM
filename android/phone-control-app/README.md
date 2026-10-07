# AirSIM 三星 Android 控制 App

该 App 运行在三星 Android 手机上，是 AirSIM 的蜂窝通话与短信控制入口。Android Telecom 负责运营商通话状态和操作，App 负责将状态同步给 Android AVF Agent，并为 iPhone 与 Apple Watch 提供经过认证的 VoWLAN 服务。

## 主要职责

- 申请并维护默认电话 App 角色。
- 监听来电、拨出、接通、挂断和 DTMF 状态。
- 将通话与短信事件发送给 AVF Agent。
- 执行 Agent 下发的拨号、接听、拒接、挂断和短信命令。
- 提供限时配对窗口与六位确认码。
- 在三星热点接口上发布经过认证的 VoWLAN 控制与 PCM 服务。
- 维护前台守护服务、Shizuku 状态和故障诊断。
- 通过独立 AVF installerd 检查、安装和回滚签名 Debian 包。
- 启动时检测 AVF、AOSP Linux Terminal 和 AVF 私网状态，并提供可复制的一键安装命令。

## 运行要求

- 三星 Android 测试手机，目标 SDK 35。
- 用户将 AirSIM 设置为默认电话 App。
- 官方 Shizuku 管理器已启动，并向 AirSIM 授权。
- Android AVF Agent 可通过设备内部私网访问。
- Agent 控制 token 已写入 App 私有存储。

## 构建与测试

在仓库根目录运行：

```sh
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

调试 APK 输出到：

```text
android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk
```

## 三星手机配置

1. 安装 APK 并启动 AirSIM。
2. 如果启动提示显示 AVF Linux 尚未运行，点“启动 Linux Terminal”；若 Terminal 未启用，点“打开开发者选项”并启用 Linux 开发环境。
3. Linux 首次启动后，确认 v0.4.4 签名 Release 已发布，再复制并在 Terminal 中执行；未发布时不要改用占用 DJOneHub `7575` 的旧版安装脚本：

   ```sh
   bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.4/install-avf.sh | sudo sh'
   ```

4. 在系统设置中选择 AirSIM 作为默认电话 App。
5. 启动 Shizuku，并在 AirSIM 的 Shizuku 区域完成授权。
6. 在 Terminal 运行 `sudo airsim-avf-pair`，从当前 AVF 私网确定 Agent 地址，把输出的控制 token 保存到 App。不要把 token 粘贴到日志、截图或仓库。
7. 确认 Agent、音频桥和 VoWLAN 状态均为就绪。
8. 打开两分钟配对窗口，让 iPhone 输入三星端显示的六位配对码。

安装命令也固定显示在 App 的“设置 → AVF Linux 首次安装”中，可随时复制；**复制不会自动运行**，须在 Debian Terminal 粘贴并按回车。App 只会在 AVF 未启动，或 AVF 已启动但 Agent 尚未配置时显示启动提示。`Agent 可达 · 尚未配对` 只表示 `8575` 的无凭据健康检查通过，不代表安装管理或通话控制已就绪；`installerd` 还需要 `8576` 服务和控制 token。修复版线上引导脚本遇到已有 `current.deb` 会优先恢复服务而非拒绝运行；发布前仍需按[AVF 安装与无损排障指南](../../docs/AVF_INSTALL_GUIDE.md)手动检查 systemd 服务，不要清除 Linux Terminal 数据。

Terminal 若报 `udev` 需要较新 `libudev1`、`unmet dependencies`，属于 AVF Debian 包状态问题。先在 Terminal 运行 `apt-cache policy udev libudev1` 和 `sudo apt-get -s -f install`，检查模拟计划；不要直接让 App 或脚本自动执行 `apt --fix-broken install`。

## 厂商系统兼容性边界

AirSIM 会识别小米、Redmi、OPPO、OnePlus、realme、vivo、iQOO 和荣耀等厂商，并区分“Terminal 已安装但停用”“Terminal 未安装”和“系统未公开 AVF”三种情况。App 可以启动已安装的 AOSP Linux Terminal，或跳转到开发者选项，但普通第三方 App 无法强制补装厂商固件删除的 Terminal、打开未公开的 AVF 系统功能，或绕过系统签名权限。遇到后两种情况需要厂商系统更新、包含 Terminal 的系统镜像，或由 OEM 将 AirSIM 作为特权系统组件集成。

## 通话与音频策略

普通来电默认使用 `remote_silent`：三星端保持受控静音，由 iPhone 或 Apple Watch 呈现来电并承载音频。紧急通话始终交回系统预装电话 App。Shizuku 服务以 shell UID 运行音频桥，并在通话结束时恢复先前的系统音量状态。

## 网络与安全

- Agent 配置仅接受 AVF 私网地址；AVF 网段由系统动态分配，不能固定为 `10.185.5.0/24`。App 优先根据 `avf_tap_fixed` 所在网段推断来宾地址，仍需在当前设备上验证。
- bearer token 只保存在 Android 私有偏好设置中，不写入日志。
- VoWLAN 仅绑定有效的三星热点地址，不监听通用网络接口。
- 所有控制请求均执行路由白名单、消息大小、时间戳、随机数与 HMAC 校验。
- 原始 PCM、配对明文和认证材料不得进入诊断日志。
- Agent API 使用 AVF 端口 `8575`，救援安装服务使用 `8576`；两者复用首次引导生成的控制 token。
- 旧版 AirSIM 保存的 `:7575` 地址会迁移到 `:8575`；`7575` 可能属于同机 DJOneHub，不再视为 AirSIM 在线证据。未发布端口迁移版 Agent 前，不能用旧版在线包做共存安装。
- Android 管理端只提交签名的 `airsim-avf-agent_*_arm64.deb`，芯片厂商差异由 App 的能力探测处理，不选择不同 Debian 包。
- “检查并安装最新 Agent”从 `kai-wu-cortex/AirSIM` 的最新 GitHub Release 选择唯一的 `airsim-avf-agent_*_arm64.deb` 及同名 `.sig`；Release 缺包、缺签名、多包或非 HTTPS 下载都会被拒绝。
