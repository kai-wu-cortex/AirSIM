# PR #33：按需求分三批整合

基线：develop 4a6cc37；来源：PR #33 a19a2ea（前置 #30 已合入）。

## 第一批：来电通知

- 保留号码与 SIM 信息；Android call-owner 增量字段向旧客户端兼容。
- 只有明确 incoming + ended + missed 才产生未接通知；已观察 active 优先，迟到 active 不恢复终态。
- Worker 去重隔离 device、agent、UUID、generation；iOS 清理通知不把缺少 agent 当作跨设备通配符。
- 本地历史发现新未接后等待 2 秒、查询已送达通知再兜底，不因云端开关开启而吞掉旧 Agent 的提醒。
- 晚到 APNs 的 Notification Service Extension 清理相同通话的本地提醒；保留短信端到端解密。
- 未接提醒不再次响铃。历史导入不补发旧提醒。

限制：APNs 投递与系统扩展执行是异步的；不能承诺两条通知在所有系统挂起/超时场景绝无短暂重叠。旧 Agent 缺少 agent_id 时保守不跨设备清理。原生 Android call_id 为不复用 UUID；没有代次的历史仅以明确设备 + 原生通话 ID 关联。

## 第二批：早期媒体体验

- 设置 → 来电与短信增加“运营商接通前语音”，默认开启，通话期间不可更改。
- VoWLAN/VoBLE/云端分别在通话身份建立时快照偏好。关闭后使用本地等待音，不提前开启双向媒体。
- 现有 EARLY_MEDIA 租约、AIRSIMRX01 内部握手、云端 U30Air early_media 兼容保持不变。
- VoWLAN 增加协商中/不支持/暂不可用提示，换通话、接通或结束时清理；BLE/云端复用现有能力反馈。
- 首个下行音频到达才停止等待音。仍不提前标为 active 或开始计时。


## 第三批：安卓隔离

- 吸收 PR 的“挂断期间避免本机短暂漏音”和路由变化后重申输出策略需求。
- 原生 Telecom 已确认 DISCONNECTING/DISCONNECTED，且此前只有这一通认证远端通话持有输出策略时，最多延续 2 秒；onCallRemoved/服务销毁立即释放。
- 普通 PCM/VPN 断线不视为挂断，立即恢复安卓接管；另一通原生通话出现时取消延续；重复终态不延长超时。
- Route 改变仅重申既有策略，走共享 Root/Shizuku coordinator。保留 preserve_volume / minimum_nonzero_volume 和手动音量，不更改 PCM gain 或全局麦克风。
- 不吸收未经机型验证的全局 microphone mute 与所有设备强制物理输出 index=0。当前没有证明它们独立于通话采集的硬件证据；已有 UI 会说明保留采集音量与本机漏音的取舍。

边界：如果远端先关闭媒体、而挂断命令及 Telecom 终态尚未到达，该窗口仍按“链路丢失”恢复本机声音。不能把所有网络断线都持续静音，也不能宣称本轮实现了所有机型完全无声。此后可在明确通话身份的挂断意图协议及机型能力证据基础上继续优化。


## 不合入

仅 VoWLAN 限制、第二套早期媒体租约/内部握手、作者构建号、旧设置页，不覆盖现有多模式、纯本地模式、E2E 短信与音量保留策略。

## 协议与协同上线

接口和认证不变。`/v2/events/call` 增加 `slot_index`；`/v1/events/call-owner` 可选增加 `agent_id`、`direction`、`number`、`slot_index`、`timestamp`、`missed`，原有 call_id/call_uuid/generation/owner/phase 保持。

- `missed=true` 必须来自设备端终态，不能由 Relay 根据“没有 active 请求”猜测；新 Android Standalone 转发原生事件事实。
- Worker 对 iOS 转发 `notification_status`（answered/ended/missed）和源设备身份。短信 payload/加密/认证保持原样。
- U30Air 不必为兼容旧接口强制升级；如需云端未接提醒及 SIM 信息，设备线程应补发上述可选字段。缺少字段时只发原有后台所有权事件；iOS 能同步到带来源的明确未接历史时仍可本地兜底。
- Worker 的观察记录沿用现有存储降级能力，不是跨请求分布式强一致事务；在存储故障/并发重试时不能承诺 APNs 恰好一次。设备事实与 iOS/扩展去重共同防护。
- 建议后续先部署兼容 Worker，再安装客户端；本轮没有执行生产部署、设备安装、Release/TestFlight，未向其他线程发送任务。

## 自动化验证

- Worker：`node --test push-relay-worker/test/*.test.mjs`，80 项通过，包括旧字段兼容、代次/设备隔离、重复终态、迟到 active、接通过的来电不报未接。
- iOS：iOS 27.2 Duo 模拟器 AirSIMTests 全量 582 项通过（0 失败）；此后通知异步提交竞态及呼出专属状态文案收尾，最终重跑通知/偏好/所有传输定向 19 项通过。
- 定向组合包含通知身份、偏好、真实 BLE 协调器禁用早期媒体、所有通道早期媒体、租约、Relay 出口控制，29 项通过。
- Android：phone-control-app/test.sh 全套通过，包括既有 Root/Shizuku 音量策略、E2E、早期媒体 TCP 集成；新增尾段状态机覆盖 3 传输的超时、重复事件、网络断开、多通话、更换身份及销毁。
- 最终音频定向回归：真实 InCallService + 控制器的 21 个模拟场景通过，包含路由重申时保留手动采集音量。
- Standalone Debug 完整构建通过；iOS App 与 Notification Service Extension 随测试构建通过；git diff --check 通过。

## 待用户实机验收

1. 每台设备/每个 SIM：未接、接听、拒接各一次；核对号码、SIM、旧来电提醒清理和通知数量。测试先本地后 APNs、先 APNs 后同步、断网和旧 U30Air。
2. 三模式分别拨号：开启/关闭运营商接通前语音；确认真实音频、等待音切换、接通前不计时、不上传麦克风，接通后双向通话与扬声器正常。
3. 三模式下本机音频：远端挂断、普通断网重连、安卓手动接管、原生通话未移除、第二通来电；检查 2 秒上限和音量恢复。
4. Root/Shizuku、保留采集音量/最低非零音量分别检查，尤其 Pixel 6 和采集受音量影响的设备。未验证的独立物理输出/全局麦克风静音不开放。

模拟器/JVM/构建通过不等于上述实机验收已完成。没有发起真实电话、短信或录音。
