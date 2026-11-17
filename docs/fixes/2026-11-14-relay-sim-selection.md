# Relay 模式 SIM 选卡修复

## 已确认原因

- iPhone 拨号页已有双卡选择器，但卡槽列表仅来自 VoWLAN/BLE；安卓 Standalone 心跳、Relay 状态和 iOS 云端模型均未携带列表，纯云端冷启动没有选项。
- iOS 云端拨号没有传入所选 PhoneAccount；Worker 的 enqueue 仅为 `send_sms` 保留 `sim_account`，`dial` 会丢弃。
- 安卓网关现有云端拨号执行链已经读取 `sim_account` 并调用 `DefaultCallAccount.dialExtras`。指定卡已移除或无法查询时会报错，不会改用另一张卡。

## 行为与协议

- Standalone 在已认证 `/v1/events/heartbeat` 上报 `sim_slots`，沿用本地健康检查的卡槽格式；不改变本地或蓝牙拨号协议。
- Worker 限制最多 8 个条目，校验标识、文本长度和字段类型，移除重复标识及非白名单字段。`/v1/devices/status` 在对应 Agent 下返回列表。
- 空数组表示没有可用卡槽；字段缺失表示旧版 Agent 未提供此能力，不能从别的 Agent 借用列表。
- iOS 云端模式下拨号与短信选卡使用对应 Agent 的云端列表；拨号选卡仍按 Agent 保存，短信仍保持独立偏好。
- 本次拨号发送前固定 Agent 与所选卡；已有目标时不增加一次同步状态查询，不修改稳定的 operation ID，不引入自动重拨。
- Worker 为 dial/send_sms 都校验并转发 `sim_account`；同一个 command ID 试图改卡返回 409，重试原命令保持幂等。
- 老客户端不传选卡字段时保持原安卓默认卡行为。旧 Agent 未提供列表时不虚构 SIM 1/2。

## 联测及部署要求

需要新 iOS、新 Standalone 和新 Worker 协同。仅更新 iPhone 或仅刷新页面无法补齐旧 Relay 丢参数的问题。自托管 Relay 也需同步 Worker 源码；AVF/U30Air 未上报卡槽的设备本次不宣称获得选卡能力。

1. 安卓双卡启用，权限正常，发送一次云端心跳。
2. iPhone 仅走云端，重新打开 App 或运行云端自检取得新列表；拨号页可选择两张卡。
3. 分别选卡拨号，由用户核对安卓实际出号卡；正常接听、挂断、早期媒体另行真机验证。
4. 多安卓切换不串卡；关闭一张卡后重新刷新，旧卡不应继续列出；旧列表未刷新时安卓应拒绝不可用卡。
5. 短信也可看到云端卡槽；通话与短信各自的选卡偏好不相互覆盖。

自动化结果与真机验收分开记录；本修复尚未安装、部署或发布。

## 2026-11-14 验证记录

- Worker 82 项测试通过，包含卡槽鉴权、按 Agent 隔离、空列表清除、异常字段、选卡参数传递、同一拨号/短信意图换卡拒绝与旧客户端兼容。
- Worker 本地 workerd 路由集成通过。
- `android-standalone/test.sh` 完整通过，包含实际源码构建、云端拨号、服务生命周期、纯本地模式和早期媒体模拟测试；没有发起真实电话或短信。
- `iOS/scripts/test-cloud-sim-roster.sh` 7 项实际 Swift 模型协议检查通过，覆盖双卡字段、独立 Agent、空列表、旧版缺失字段及编码往返。
- iOS 新增 XCTest 覆盖云端冷启动双卡、选择第二卡传入拨号、无额外状态查询、移除卡槽和短信列表更新；模拟器测试宿主两次未启动用例，不能标记为测试通过。
- 云端显式选卡还要求该 Agent 的云端快照确认相同 PhoneAccount，否则提示更新/刷新，不静默降级到安卓默认卡。
- 待真机：两张 SIM 实际出号与短信出号、单卡移除、多安卓切换、正常通话音频/早期媒体及挂断。
- 最终 iOS `build-for-testing` 成功（arm64/x86_64 模拟器 App、Watch 与 XCTest），`git diff --check` 通过；这只证明可编译，不替代上述未执行的 XCTest 和双卡真机验收。
