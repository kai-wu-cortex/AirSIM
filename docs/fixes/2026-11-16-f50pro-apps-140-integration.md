# F50 Pro 与 Apps 140 集成验证

本分支将 `develop` 的 Apps 0.9.8.25（Android 140，提交 `991162c`）合入 `F50Pro-AirSIM` 的 MU3356 适配（`fde7d68`）。保留无屏设备默认电话应用兜底、SIM Call Manager、Shell 音频桥及手动配对适配。未修改设备固件或 Relay 部署。

唯一手动解决的合并冲突位于 `VoWLANGatewayService.onCreate()`：保留新版实例和服务启动门登记，同时保留 F50 Pro 的无屏来电监听初始化。

## 本地验证

- `android-standalone/test.sh` 的 Java、音频桥、APK 编译、云端通话、网关生命周期、通话归属及纯本地策略阶段全部通过。
- 初次脚本运行在最后一步因 `apkanalyzer` 不在 PATH 而退出。补充 SDK 命令路径后，独立执行原脚本的 `apkanalyzer manifest print | verify_dialer_manifest.py`，退出码 0。未将初次脚本退出码误记为成功。
- APK 版本为 0.9.8.25（140），使用与此前设备安装包相同的本地开发签名，验证后覆盖安装；未卸载或清除应用数据。
- `git diff --check` 通过。

## 真机范围

- MU3356 已安装构建 140；原配对及云端配置保留，Agent 注册、命令 WebSocket 和心跳恢复。
- 系统仍识别默认电话应用及当前活动订阅；USB ADB 与既有 Wi-Fi 上联正常。
- 此记录不宣称真实通话接通、双向音频、双卡实际出号或重启后的音频桥恢复已通过。
- 云端显式选卡需要新版 Relay 返回该 Agent 的 `sim_slots`；升级 APK 本身不能补齐尚未部署的 Relay 行为。未修改维护者的服务器。

本构建为保留 F50 适配的本地集成包，不是维护者发布的正式签名 APK，也没有创建 GitHub Release。
