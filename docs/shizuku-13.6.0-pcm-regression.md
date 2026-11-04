# Shizuku 13.6.0 在 HyperOS 3 上的 PCM 启动回归

更新：2026-10-23。适用于 Android AirSIM Standalone／AVF Bridge 的 Shizuku PCM 桥。此问题来自 Shizuku 上游，不是 AirSIM 0.9.8.9 的代码缺陷。

## 现象

- AirSIM 显示 Shizuku 已连接，但 PCM 音频桥反复在“运行中/待启动”之间切换。
- 日志可见 PCM 子进程刚启动就退出，随后每约 5 秒重试：
  ```text
  pcm=running ... pcm_event=bridge_listening pcm_initialized=false
  pcm=stopped ...
  ```
  或上游桥日志：
  ```text
  event=listener_restarting
  result=retrying
  retry_delay_ms=5000
  ```
- 没有真实通话时不会出现 `audio_initialized`／`client_ready`；通话无法建立双向 PCM。
- 同一台 HyperOS 3 设备降级 Shizuku 后恢复正常。

## 已知原因

Shizuku **13.6.0** 包含一个强制创建应用上下文的回归，在部分 HyperOS 3 设备上会失败，导致 AirSIM 的 PCM UserService 每次启动即崩溃。官方仓库已有相同堆栈报告；**Shizuku 13.5.4 不包含该回归**。

AirSIM 侧没有通过修改安全模型、强制重启音频服务或掩盖异常来绕过该上游问题。

## 临时处理

1. 卸载 Shizuku 13.6.0。
2. 安装官方 **Shizuku 13.5.4**。
3. 打开 Shizuku，点击「通过无线调试启动」中的「启动」；已有配对可保留，不需要重新配对。
4. 回到 AirSIM 确认 PCM 桥稳定为「运行中」，再打一通真实电话检查双向音频。

不要使用来源不明的 Shizuku 重签包；不要把配对密钥、号码、Push token 或音频放进问题报告。

## 判据

- 正常：PCM 进程稳定存活，空闲时 `pcm_event=bridge_listening`、`pcm_initialized=false` 是预期；通话时出现 `audio_initializing` → `audio_initialized` → `client_ready`，且不再每 5 秒重启。
- 异常：PCM 子进程反复 `running → stopped`，或 `listener_restarting` 持续出现，且没有 `client_ready`。
- 另一个独立问题：旧 AVF 包在没有 `avf_tap_fixed` 的 Standalone 设备上后台重试；请停用/卸载旧 AVF 包，不要把它与 Shizuku 回归混为一谈。

## 版本与边界

- 复现环境：HyperOS 3，AirSIM 0.9.8.9；用户确认 AirSIM 升级后问题仍在。
- 恢复环境：Shizuku 13.5.4。
- 该记录不等于所有 HyperOS 3／Shizuku 版本都会失败；升级 Shizuku 前应在目标设备复验 PCM。
- 若上游发布修复版本，应重新验证后再升级；不要把降级当作永久方案。
- AirSIM 仍要求默认电话角色、Shizuku 授权、目标 OEM 的蜂窝音频能力；这些条件不因本问题改变。


## 2026-11-04：Redmi 9 / MIUI 13 补充实证

Redmi 9（MT6768、Android 12、MIUI 13）也已复现 13.6.0 的用户服务加载崩溃。此机表现为服务绑定超时，尚未执行到 AirSIM PCM 初始化；与上文“服务已连接后 PCM 反复退出”的现象应区分。限时启动对照捕获 `LoadedApk.makeApplication(LoadedApk.java:1395)` 空指针，13.5.4 可创建同一个服务；用户授权原位降级并重启后，实际 Shizuku 绑定与 PCM 监听恢复。详见 [Redmi 9 记录](android-redmi9-pcm-adaptation.md)。官方上游 [#1198](https://github.com/RikkaApps/Shizuku/issues/1198) 记录了相同异常，不应仅凭“联发科”品牌推断所有设备或所有启动错误都相同。
