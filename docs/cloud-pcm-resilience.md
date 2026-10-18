# 云端挂断与 PCM 抖动处理（v0.9.7.1）

本轮保留现有 Relay WebSocket、鉴权、CallKit/PushKit 和 raw PCM 协议，不改变 VoWLAN、VoBLE 或旧 Linux Agent 的媒体实现。

## 挂断终结

iPhone 提交 `ending` 后立即关闭通话展示、铃声和 Watch 通话提示，同时继续等待原有持久化挂断命令的 Agent/基带确认。UI 关闭不代表远端挂机已成功；最终失败仍显示错误。

生命周期归并器最多保留 64 个结束身份，拒绝同一通话的晚到 `ringing/connecting/active`，包括较高 generation 的回调。轮询结果也不能绕过归并器重新创建 CallKit 通话。云端媒体回调绑定 WebSocket 连接身份，并在异步日志之后再次验证；旧通话的控制回执不修改新通话的媒体状态。灵动岛在等待云端状态查询后重新读取当前生命周期，不使用等待前的通话快照。

## 音频策略

- 两端采用 20 ms/320 字节、8 kHz、16-bit 单声道 PCM；保持协议兼容，不新增编解码依赖。
- 接收端初始预留 4 帧（80 ms），按到达抖动和缺帧上调，目标最多 10 帧（200 ms）；稳定到达 100 帧后逐步降低目标。
- 接收队列硬上限 12 帧（240 ms）；iPhone 播放器最多另排 2 帧（40 ms）。这是应用层队列上限，不是端到端延迟保证。
- 短暂缺帧最多用 2 帧衰减音频补偿（40 ms），恢复时做 5 ms 边界平滑。更长中断重新预缓冲，不无限循环旧声音。这是简单 PCM 缺帧补偿，不是完整 NetEq、Opus PLC 或 FEC。
- 发送端最多积压 12 帧，超过 250 ms 的待发语音丢弃；每次只发一帧，阻塞恢复后不追赶式突发发送。
- Android 分离 PCM 采集、网络发送、网络接收和 PCM 播放。网络音频写入不占用读取控制帧的线程；音频写入阻塞超过 2 秒会关闭所属连接，让现有重连流程恢复，旧工作线程不能关闭新连接。
- Android WebSocket 重建时重置媒体启动状态，允许 iPhone 重发 `answer` 后重新启动 PCM。
- 每 5 秒记录队列大小、目标缓冲、丢帧、缺帧和补偿帧计数；不记录 PCM 内容。

## 参考与边界

设计参考 [WebRTC NetEq 的自适应缓冲与播放时钟](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md) 和 [Telegram libtgvoip 的抖动缓冲](https://github.com/telegramdesktop/libtgvoip/blob/master/JitterBuffer.cpp)，独立实现适合现有 PCM 通路的简化策略，未复制其实现或引入其依赖。

当前仍使用 WebSocket/TCP。TCP 重传和队头阻塞、操作系统与 Relay 内部排队不能靠本地缓冲消除。raw PCM 没有源端序号/时间戳；iPhone 的序号只是本地到达顺序，不能据此计算网络丢包率或完整端到端延迟。严重弱网仍可能中断；迁移 WebRTC/Opus、SRTP/UDP 与 TURN 是另一个需要双端和服务端协同的项目，本轮不实施。

## 验证

自动化覆盖：挂断后晚到状态、较高 generation、下一通结束后的旧事件、回调身份、发送积压/过期、突发接收上限、缓冲回落、短时补偿、播放窗口，以及合成 PCM 下阻塞网络发送不阻塞接收播放。Android 定向旧 API 扫描随构建执行。

真机验收须使用匹配签名与 sandbox Relay 的 Release 构建，保留数据覆盖安装；不得把模拟测试等同于实际听感验收。

1. 云端拨出/接听后挂断；观察 30 秒，通话 UI、Watch 和灵动岛不得恢复为旧通话。
2. 挂断后立即开始另一通，旧回执不得结束或激活新通话。
3. 双向说话并制造短暂网络抖动；检查声音、缓冲目标回落和丢帧分类，不保存或上传语音。
4. 中断网络后恢复，确认重新 `answer` 能重新启动 PCM；实际长断网不保证无缝恢复。
5. 再测试 VoWLAN 与 VoBLE，确认没有被云端缓冲路径接管。

未完成实际通话验收前，不以本文声明真机问题已解决。发布与部署必须分别获得用户授权；本次应用发布不部署 Relay。

2026-10-14 本地验证：iOS 110 项测试通过；Android Standalone 全套测试、合成 PCM 阻塞/超时测试、旧 Java API 定向扫描与 `NewApi` lint 通过（不代表完整 lint 无其他历史告警）。Release 构建已保留数据覆盖安装到 iPhone Air 主 AirSIM `0.9.7 (81)`（sandbox／开发推送签名）和 Redmi Standalone `0.9.7.1 (81)`，均启动成功。用户完成本轮云端真机通话并反馈「不再重现，声音更稳」；这是本轮人工验收结果，不代表所有弱网条件或运营商场景都已覆盖。随后用户授权提交、推送并发布 Apps v0.9.7.1，production TestFlight 构建另行通过 Xcode 上传，不把 sandbox 实测当作 production 推送验收。
