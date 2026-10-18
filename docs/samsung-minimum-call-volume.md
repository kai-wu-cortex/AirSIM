# 三星接通后自动降低通话音量（Android 候选 90）

## 已确认的行为

此前候选 88 的静音标记和原生策略零音量回读，未通过用户的实际听筒静音测试。本轮按用户确认的替代方案，三星改为显式设置系统支持的最低通话音量；**最低档不代表完全无声**。

- 仅针对三星，其他厂商沿用原策略。
- 必须已有唯一、已认证的远程通话所有权，PCM 已就绪，而且原生通话处于 active/held。配对、预热 PCM、来电响铃或拨号等待接听都不降低音量；同时出现其他原生通话时恢复原值。
- Shizuku shell 进程读取 `getStreamMinVolume(STREAM_VOICE_CALL)`，显式调用 `setStreamVolume`。不固定假设最低档是 0 或 1，不改变媒体音量、麦克风静音、PCM 增益或路由。
- 本轮最低档分支不再依赖之前失败的 Samsung 原生零音量策略。首次接管时保存原通话音量与原静音位；重复设置/Watchdog 修复不能覆盖原快照。
- 挂断、媒体链路失效、服务清理等沿用已有恢复和重试流程。先恢复原音量，最后恢复原静音位；部分失败保留快照供重试。

## 诊断与限制

`local_output=minimum` / `output_policy=minimum_volume` / `minimum_volume=N` 区别于静音。`verified_minimum=true` 仅说明回读的可听音量档位符合目标；`verified_muted` 仍表示系统原有静音位，不借最低档伪造静音成功。原本已静音时通过 last-audible index 保存、校验和恢复音量，避免把静音期间显示的 0 当作原档位。

Watchdog 对最低档目标检查实际档位漂移，最多沿用原有 3 次修复、15 秒冷却。TXT 继续保留 `acoustic_check=unavailable`；不会仅因 `muted=false` 就把正常的最低档判为失败并反复修复。

系统 Binder 调用超时不代表底层操作已取消，原有恢复重试必须继续；新增用例覆盖晚完成的最低档写入、链路断开恢复以及旧降音量重试失效。物理听感、对 iPhone 双向语音的实际影响、听筒/扬声器切换时设备独立音量的恢复仍需真机验证；本实现保存的是通话流原档位，不声称逐输出设备的声学验证。

## 验证

- 先复现旧实现不显式设置最低档、Watchdog 误判最低档、Samsung 接听前降音量三个失败，再验证修复。
- `sh android-standalone/test.sh` 完整通过，含最低档 0/1/2、重复操作、原有静音位、忽略写入、恢复失败重试、延迟写入后恢复、Watchdog 目标校验、15 组通话音量生命周期和原有 PCM/权限/配对回归。构建有既有过时 API/JDK 工具告警，但退出成功。
- Standalone APK：`android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`，0.9.7.1（90）。特权服务 revision=11，按新 build code 替换旧实例，不重启全局 Shizuku、不终止独立 AVF 桥。
- 不修改 iOS、Relay 或配对凭据；未提交推送、未公开发布。最终听感需用户在 iPhone 接通后确认三星是否明显变小，且 iPhone 双向语音不变，挂断后三星通话音量恢复。
- 已通过无线 ADB 保留数据覆盖安装到用户三星 SM-F766U，设备包信息确认 build 90，主界面启动。持久日志确认新服务 `uid=2000 service_revision=11 pcm=running`；待机 `local_output=normal`，没有在没有远程通话时降低音量。实际通话最低档与恢复效果仍待用户复验。

参考：[Android AudioManager 通话音量接口](https://developer.android.com/reference/android/media/AudioManager#getStreamMinVolume(int))。

## 候选 90 真机失败与候选 91 修正

用户确认 90 在 VoBLE 实际通话中未自动降低音量。2026-10-16 19:24–19:25（GMT+8）的三星日志显示原生通话 active、PCM 双向计数持续增加，但整个通话保持 `local_output=normal output_policy=not_applied`，Watchdog 只有 stop，没有发出降低音量请求。因此不能归因于三星拒绝音量写入或随后调高。

根因位于远程通话归属校验：`RemoteCallAudioScope` 使用 `IdentityHashMap` 按媒体对象保存通话 ID；其 `containsValue` 对字符串值同样采用引用相等。VoBLE 控制消息解析出的 ID 与 Telecom ID 文本相同、对象不同，导致校验失败。91 保留媒体 owner 的对象身份和唯一原生通话保护，只将通话 ID 校验改为文本相等；云端解析 ID 也受益。不以“PCM 正在运行”替代通话归属，不放宽为任意本机通话。

新增生命周期回归先在旧代码失败，再验证 BLE／云端独立字符串 ID 可以触发最低音量、释放 owner 恢复原档位；不同通话不能接管，释放其他 owner 不能撤销当前策略。生命周期共 18 个场景。候选 91 的设备最低档和实际听感仍须真机确认，不将测试通过当作声学验证。

91 的完整 `sh android-standalone/test.sh` 已退出成功（仍有既有 53 项 API／工具告警），包括原有 PCM、Shizuku、短信兼容、BLE 服务生命周期回归；本次修改复核无阻塞发现。2026-10-16 19:37（GMT+8）保留数据覆盖安装到三星 SM-F766U 成功，设备包信息确认 `versionCode=91`、应用已启动。未修改 iOS／Relay、未自动拨打电话，等待用户复验物理音量和通话双向语音。
