# PushKit / CallKit 崩溃修复（iPhone 与 Watch）

## 依据与边界

Xcode 下载的 iPhone build 175 样本包含 `PKPushRegistry._terminateAppIfThereAreUnhandledVoIPPushes` / SIGABRT；另一组虽按 SwiftUI 栈顶归类，实际终止码为 `FRONTBOARD 0xbaadca11`。Watch build 175、176 样本也包含 `CAROUSEL 0xbaadca11`。这些记录指向 VoIP 推送的系统来电上报／接收器生命周期问题，不能仅凭这些样本确认每次触发的具体载荷。截图中最新两条 iPhone 176 反馈的堆栈尚未取得。

源码可确认：两端的过期、缺字段、错误 UUID 或其他无效载荷解析抛错后，直接完成 PushKit 回调，未报告系统来电。iPhone 还将强制上报推迟到 `Task { @MainActor ... }`；Watch 的接收器原本依赖 SwiftUI `StateObject` 构造，没有应用启动委托初始化入口。

## 改动

- `VoIPPushDelivery` 同步解析并发起 CallKit 上报；每次投递的 completion 由独立、加锁的一次性闸门管理。
- 解析失败时保留严格校验，不把过期或异常载荷交给业务接听／媒体链路。使用**新 UUID** 和通用 AirSIM 标题向系统上报；成功回调后结束这一个临时会话，再完成 PushKit 回调。上报失败也完成回调，不重试上报，不向真实设备发挂断命令。
- 不复用无效载荷的 UUID，不覆盖当前来电状态；避免迟到或损坏载荷误结束当前通话。系统可能短暂显示随后结束的来电，这是异常 VoIP 投递的收尾，不应通过直接丢弃推送来消除。
- iPhone PushKit 的接收委托直接在已配置的主队列上执行上报，不再先创建异步 Task。联系人查询仍异步，且迟到查询不能再发布已结束通话。
- iPhone 启动时始终创建接收器。关闭云端通知／开启纯本地时仍取消所需推送类型及业务注册，但保留 registry/delegate 对象以处理已在途投递；不因此开启 Relay 请求或业务接听。
- Watch 使用进程级唯一 `WatchCallSession.shared`，在 `WKApplicationDelegate.applicationDidFinishLaunching` 中初始化；SwiftUI 复用同一实例。麦克风授权请求放在 registry 就绪之后。
- 保留有效重复推送的现有 UUID 上报方式，不结束该 UUID；其他设备占用、已结束来电的既有处理规则保持。iPhone 新增回归使用真实 `CallKitController`，通过注入系统边界避免产生真实来电。

## 自动化验证

本轮结果：

| 检查 | 结果 |
| --- | --- |
| iPhone + Watch 模拟器 `build-for-testing` | 通过，退出码 0 |
| `PushKitDeliveryRegressionTests` + `OtherDeviceCallReminderTests` | 42 项通过、0 失败；其中新增 6 项；最终 xcodebuild 退出码 0 |
| `test-pushkit-delivery.sh` | 通过；26 个 iPhone/Watch 拒绝／上报失败组合，外加有效载荷、回调顺序、一次性完成与身份隔离 |
| `test-watch-reliability.sh` | 341 项断言通过 |
| `test-watch-mirror.sh` | 8 项生产状态同步断言通过（系统边界模拟） |
| `git diff --check` | 通过 |

构建日志：`/tmp/airsim-pushkit-build-final.log`。最终原生回归：`/tmp/airsim-pushkit-verified.log`、`/tmp/airsim-pushkit-verified.xcresult`。

首次模拟器运行停在宿主启动阶段；重启本次测试模拟器后，用例已全部通过，但整轮限时在 Xcode 收集结果时中断。因此再次执行完整选定套件，最终取得上述正常退出结果，未将中断命令记为成功。没有清除模拟器数据。

CallKit 系统上报使用测试注入，APNs 及系统冷启动唤醒仍须以下真机验收；编译和模拟测试不等于线上崩溃已消失。

测试源码：
- `iOS/AirSIMTests/OtherDeviceCallReminderTests.swift` 中 `PushKitDeliveryRegressionTests`：过期／无效载荷必须先报告，报告失败正常完成，重复回调只完成一次，无效 UUID 与当前通话隔离，有效来电／重复推送，云端关闭／纯本地在途推送，重置与迟到回调。
- `iOS/scripts/test-pushkit-delivery.sh`：编译实际共享处理器与 iPhone、Watch 载荷解析器，测试拒绝分支与报告回调的先后顺序、失败分支、UUID 隔离、正常载荷。
- 既有 `test-watch-reliability.sh`、`test-watch-mirror.sh`：Watch 迟到事件、跨设备通话状态与所有权回归。

## 仍需真机验收

1. 安装修复后的 iPhone 与 Watch 包，后台锁屏／冷启动后正常来电，分别接听、拒接、由另一端接听。
2. 在受控测试环境投递过期、缺字段、同一来电重复推送；核对 completion、CallKit 报告及系统终止记录。不能用模拟器断言 APNs 冷启动已修复。
3. 已接通时收到迟到或异常推送：当前音频、计时、接听端所有权不得改变，不能向安卓额外发送接听／挂断。
4. 云端通知关闭或纯本地开启后，到达的在途 VoIP 推送只做系统收尾，不开启云端通话。
5. 继续检查新版本 TestFlight 的相同崩溃分组；本修复不声称解决旧 Date 运行时问题、所有小组件崩溃或尚未取得堆栈的 iPhone 176 反馈。

本轮不安装、不发布、不部署 Worker，也不发起真实电话或短信。工作树原有 Android 短信、Issue #40、云端 SIM 等改动保留。

## Apple 依据

- [Responding to VoIP Notifications from PushKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
- [SIGKILL / 0xbaadca11](https://developer.apple.com/documentation/xcode/sigkill)
- [Apple DTS：接收器尽早初始化并维持生命周期](https://developer.apple.com/forums/thread/772696)
