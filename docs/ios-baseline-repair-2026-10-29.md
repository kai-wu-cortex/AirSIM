# iOS 基线测试修复记录（2026-10-29）

工作分支：`codex/device-test-20261029`，基于 `6c01709` 加工作区改动。用户要求先修复基线失败，纯本地模式实现暂缓；没有推送、安装真机、发布或部署 Worker。

## 原始结果与原因

最初失败运行的记录中，198 个 iOS 单元测试有 5 个用例产生 13 条失败断言。定向重跑复现了相同失败。

| 场景 | 原因与处理 |
| --- | --- |
| 云端拨号前状态查询 | `f83c3a7` 已有意移除“每次拨号先查状态”的门槛，旧测试仍要求额外查询。保留优化；在真实发送边界注入可控实现，验证目标身份、请求次数、错误传播及用户主动重试，不访问真实 Relay。 |
| 云端自检失败清空目录 | 同一优化保留最近一次有效观察。测试改为要求失败返回 nil、显示探测错误、保留目标；不将缓存当作新的探测成功。 |
| VoWLAN 铃声 | 已提交的 CallKit 路径会抑制重复 App 铃声。将回退铃声测试与模拟器原生 CallKit 异步回调隔离，仍验证主设备响铃、其他设备不抢铃、接听后停止。 |
| 双设备结束事件超时 | 用例依赖共享模式、CallKit 和默认历史数据，且此前云端用例误入真实发送路径。隔离模式、控制器及临时历史目录，保留真实鉴权 HTTP、A 通话中 B 来电、结束回执和目标不串线断言。 |
| 短信导航 | 截图显示按钮及会话行正常，但进程内 SwiftUI 可访问性枚举为空。迁到 `AirSIMUITests`，由系统 UI 自动化点击真实控件；不使用私有可访问性 API。 |

## UI 测试隔离

`SMSNavigationFixture` 仅在 `DEBUG && targetEnvironment(simulator)` 编译。显式测试启动参数选择合成短信，使用临时历史目录、独立 UI 偏好和进程级联网偏好覆盖；跳过正常设备连接生命周期。真机及 Release 不含该夹具。

UI 测试覆盖：三轮设置/短信标签切换、打开并取消新短信、打开会话、会话遮住底部标签栏、返回并再次打开。原进程内导航测试在替代测试通过后移除，而非跳过回归检查。

## 已完成验证

- iOS 27.0 模拟器 `AirSIM-Relay-Policy-Repro`：云端 5 项、铃声回退、双设备链路定向验证通过。
- 新短信 XCUITest：三轮往返通过，0 失败。
- `./android-standalone/test.sh`、`sh android/phone-control-app/test-pure-local.sh`、AVF `go test ./...` 通过。
- `Release / generic iOS / CODE_SIGNING_ALLOWED=NO` 构建通过；正式二进制中未发现 `AIRSIM_UI_FIXTURE`、`SMSNavigationFixture` 或合成短信标识。
- 串行全量 iOS 验证通过：354 个单元测试、1 个 UI 测试，均为 0 失败；`xcodebuild` 返回 0 和 `TEST SUCCEEDED`。包含纯本地基础协议/策略的 9 项测试，不代表纯本地功能已经完成。
- 首次组合运行的单元测试宿主在启动阶段收到终止信号，未执行用例，不能算通过；结束遗留测试运行后，以 `-parallel-testing-enabled NO` 完整重跑得到以上结果。结果包：`/tmp/airsim-baseline-repaired-serial.xcresult`。

关键命令：

```sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,id=9E3C93A6-0972-4AFE-952B-AFC414F598AC' \
  -derivedDataPath /tmp/airsim-pure-local-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/airsim-baseline-release \
  CODE_SIGNING_ALLOWED=NO build
```

模拟器结果不代表真实蜂窝通话、蓝牙音频、锁屏 PushKit 或 Tailscale 真机验收；纯本地模式也尚未完成接线与全链路验证。
