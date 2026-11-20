# Android 139：终态清理与空闲网络恢复

基线：iPhone 199 / Android 138。用户反馈 2026-11-09 上午一次不可达；检查两端日志发现 09:48、09:55 网络/地址变化及自动恢复。

## 修复

- VoWLANControlGateway 不再以只在 dial/answer/hangup/reject HTTP 响应时更新的布尔量判断通话归属。改为检查该监听地址对应的 DirectCallOwnership 租约及其准确原生通话是否仍存在、未结束。
- 原生 STATE_DISCONNECTED 和 CallRepository.remove 按准确 call ID 释放租约。重复终态、旧 PCM 的结束回调不能释放替换后的租约，不能对其他电话调用挂断。
- 空闲时等已有网络变化门限（1 秒）收敛后再读取地址、重建监听，避免未稳定的地址快照引起反复关闭和创建。活动 PCM/通话仍遵守现有禁止中途换路的策略。
- 不更改音频输出静音、麦克风隔离、短信加密、推送配置或 VoWLAN 专用模式。

## 验证

- phone-control-app/test.sh 完整通过，包括 CallRepository、新网络稳定边界、Direct PCM 及音频隔离 21 场景。
- test-owned-dial.sh 通过；新增真实认证 HTTP 网关回归验证对方挂断但未收到本机 hangup 请求时 ownsCall=false，其他活动电话不使旧归属复活。
- JVM Uri 夹具补齐原有 early-media 路径需要的 getQueryParameter；生产 Uri 不变。
- 独立测试版 139 构建通过，pre-33 Java API 检查通过，沿用原独立测试版签名和包名。
- 覆盖安装成功，设备 versionCode=139；启动后内部 Agent 就绪、控制监听 7592 / PCM 7593 就绪、命令通道已连接。iPhone 保持 199。

真实 Wi-Fi 断网期间仍可能不可达。本轮减少残留状态和空闲网络抖动引起的重建，不能保证真实通话在断网期间不中断。待用户验证一次通话结束后的断网/恢复及下一通电话；没有自动拨打真实电话或切换用户网络。

## 实机复测：音频桥争用

用户反馈接通前真实音频丢失及安卓听筒出声。两端日志显示 iPhone 启动 receive-only 音频但没有收到 ready，安卓连续报告 receive-only bridge unavailable。系统日志发现原 standalone 与 earlytest 同时运行各自 Shizuku pcm_shell；两个 PhoneAudioBridge 争用 127.0.0.1:7580，测试版每 5 秒出现 EADDRINUSE。

确认无活动电话后，仅停止原 standalone 包及准确归属的旧 shell/桥进程；保留安装及数据。测试版随后记录 bridge_listening，进程列表确认只剩测试版的桥。未修改 139 代码、网络设置或加密配对。实际彩铃和安卓静音待用户再次确认；此冲突不能据此归因于 139 的终态清理改动。日常测试应避免同时启动两套 AirSIM。
