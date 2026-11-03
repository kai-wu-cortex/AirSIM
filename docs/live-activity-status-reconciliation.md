# 灵动岛设备状态与重复活动修复

## 问题与边界

同一设备可能在锁屏显示一张在线卡片、一张离线卡片，或 App 已在线而灵动岛仍离线。代码中存在以下路径：

- Controller 只认领 `Activity.activities.first`，已有句柄后不再检查重复、结束或被移除的活动。
- 更新只比较本地 `lastState`，远程推送改变实际内容后，同样的本地在线快照不会重新写入。
- 多个 `@MainActor` 更新在 `await` 期间仍可交错，主线程不等于异步操作串行。
- 状态页已经展示多设备状态，Relay 却仍可能为来电 push-to-start，或把现有卡片替换成不带设备列表的旧通话内容。
- LocalDeviceDirectory、设备信息和部分云端状态变化未直接触发状态卡刷新。

## 实现

每个 App 保留一个汇总活动，内部列出已配对设备；保留当前有效活动，立即结束其余活动及残留的 ended 卡片。每次同步重新读取系统内容，过期句柄不再阻止前台创建替代活动。后台只认领、更新和清理现有活动。

ActivityKit 操作串行执行，并合并待处理请求。关闭功能或停止活动会使进行中的旧请求失效；旧离线写入完成后必须继续应用最新在线快照。系统新增活动会触发去重，不依赖下一次网络轮询。

有明确设备快照时，该设备的 VoWLAN / VoBLE / Relay 状态决定在线与否，避免全局状态和设备列表互相矛盾。状态变化只更新内容，不额外轮询 Relay。

新版 iOS 注册携带 `live_activity_presentation: agent_status`。Worker 对此设备停止通过来电、通话归属和通话终态事件创建或改写实时活动；VoIP PushKit、CallKit 与普通通知仍正常投递。旧客户端没有此能力字段时保留旧行为，旧 Agent 重注册不会清除已声明的能力。纯本地注册不携带此云端字段。

## 验证与部署

2026-11-01：合并 PR #19 后，iOS 测试构建成功；30 项定向 XCTest 全部通过（9 项新增活动协调测试、纯本地/Relay 出口测试及既有活动展示回归）；Worker 完整单元测试 68 项通过；`git diff --check` 通过。日志分别为 `/tmp/airsim-liveactivity-build.log`、`/tmp/airsim-liveactivity-tests.log` 和 `/tmp/airsim-liveactivity-worker-tests.log`。本轮未安装真机、未部署 Worker。

- XCTest 覆盖重启去重、结束句柄替换、远程内容覆盖后的纠正、更新乱序、关闭时的在途更新、新增远程活动、设备在线状态和注册字段隔离。
- Worker 测试覆盖没有 update token 时不再 push-to-start、有旧 token 时不覆盖状态卡，同时仍发送 VoIP 和归属通知；旧客户端行为继续回归。
- 完整修复需要新版 iOS 和新版 Worker。只部署 Worker 不会自动修复旧客户端已存在的重复卡片；客户端需要运行一次进行清理。
- 这不是让 iOS 后台永久执行：App 被挂起且没有新观测时，状态卡只能保留最近同步的设备状态，不能据此声称实时在线。真实锁屏、系统活动恢复与推送仍需真机验收。

真机检查：打开 App 后同一应用只剩一张设备汇总卡；切换 Wi-Fi / Tailscale / 蓝牙后，App 与卡片状态一致；来电和挂断不新增卡片；关闭再开启实时活动不留重复项；杀掉后重新打开仍能认领并更新原活动。测试纯本地时确认没有 Relay 请求。

ActivityKit 生命周期和活动恢复接口依据：[Apple — Displaying live data with Live Activities](https://developer.apple.com/documentation/ActivityKit/displaying-live-data-with-live-activities)。系统不可枚举的历史残影或另一 Bundle ID 的活动不在本 App 可清理的范围内，不能把单元测试结果等同于所有系统锁屏异常均已解决。
