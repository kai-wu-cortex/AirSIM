# 三星蜂窝通话输出静音（Android 候选 88）

## 真机证据与适用范围

2026-10-16 15:36–15:38（Asia/Shanghai），三星 SM-F766U / Android 16 / Standalone 87，经 iPhone VoWLAN 拨号：

- 用户反馈三星仍能听见通话声音；Shizuku 为 shell UID 2000，已获授权。
- 通话期间框架持续报告 `muted=true volume=0 mode=2 speaker=false`。
- AudioPolicy 的原生 `Telephony Rx -> Earpiece` patch 处于活动状态；AirSIM 的 `VOICE_TX` AudioTrack 则正确输出到 `TELEPHONY_TX`，并未走普通听筒 AudioTrack。
- Shizuku 的 PCM 守护进程仍是安装 87 之前启动的旧实例，缺少新版 PCM 证据字段。

这证明原有框架标志不足以验收用户要求的物理听筒无声，不证明某个未经测试的 HAL 接口必定可用。不要将三星上的结果推广到其他厂商。

## 修复内容

- Shizuku UserService 的 version 跟随 APK build code，不再固定为 9。构建更新后由 Shizuku 替换该 App 的旧服务，不重启全局 Shizuku、不终止其他应用服务。状态新增 `service_revision=10`。
- 新通话即使继承 `muted=true`，也重新提交输出静音操作，不将历史标志当作本次硬件状态。
- 仅三星在已有远程通话所有权、PCM 就绪的控制范围内，对内置听筒和扬声器请求原生通话策略零音量。操作前保存原生 index 与原静音标志，挂断、媒体失效等沿用原有恢复路径。没有释放 Telecom 的 patch、修改麦克风／全局主静音、录制音频或调整 iPhone PCM 增益。
- 在特权进程中反射解析实际存在的 `AudioSystem.setStreamVolumeIndexAS`：兼容带独立 muted 参数的四参数形式与旧三参数形式。检查返回码及 index 回读；缺失、拒绝或回读异常不计成功。不猜 Binder transaction、不使用非零音量脉冲。
- `output_policy=zero_readback` 只表示策略请求已接受且回读为零，**不表示声学静音已验证**。TXT 中仍保留 `acoustic_check=unavailable`。
- 静音期间保存 last-audible 音量，避免把 `getStreamVolume()` 返回的零误当成用户原音量。恢复先音量、后静音位，避免正音量写入取消用户原有静音；部分失败保留快照以重试。
- 限时准备只创建私有候选快照，成功返回后才交给当前通话。超时后晚完成的读取不会发布状态，也不会污染下一通电话的恢复值。

参考：[Shizuku UserService 生命周期](https://github.com/RikkaApps/Shizuku-API/blob/master/api/src/main/java/rikka/shizuku/Shizuku.java)、[AOSP 通话音量策略](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/android16-qpr2-release/services/audiopolicy/managerdefault/AudioPolicyManager.cpp)。AOSP 会缓存最近的 voice volume，故仅再次查询标志不能证明 HAL 已重新应用静音；本实现也不把 API 回读当作物理验证。

## 验收

自动回归覆盖历史静音位、新通话重发、原音量与静音恢复、忽略指令、接口拒绝、恢复重试、三／四参数契约及旧服务版本升级。运行 `sh android-standalone/test.sh`；真机验收必须另做：VoWLAN 接通后三星听筒／扬声器无声、iPhone 双向语音保留，挂断后普通安卓电话输出与原音量正常。

若三星策略回读为零仍有声，应记录为尚未解决的 OEM 蜂窝输出问题，不能继续把多次相同的框架静音请求报告成“自动修复成功”。

## 本轮执行记录

- `sh android-standalone/test.sh` 完整通过（`/tmp/airsim-88-final-tests.log`），包含新增音量策略、接口契约、超时准备与恢复用例，原生 PCM 55 项检查、13 组通话静音生命周期等原有测试通过。
- Standalone 与 AVF Bridge 的 Android 0.9.7.1（88）Debug APK 构建成功。未提交推送、未公开发布、未修改 Relay 或 iOS。
- 2026-10-16 15:56（Asia/Shanghai），Standalone 已保留数据覆盖安装到用户三星 Flip7。服务 PID 从 19204 替换为 24420，PCM 桥从 19262 替换为 24458；状态确认 `uid=2000 service_revision=10 pcm=running`。未重启全局 Shizuku，未终止旧 AVF 的独立桥。
- 启动未见本次崩溃。16:03 真机通话仍报告 `output_policy=zero_readback pcm_capture=observed pcm_route=verified`，但用户确认三星听筒仍有声。因此候选 88 **未通过物理输出静音验收**；此项仍未解决，不能用框架回读代替声学验证。
