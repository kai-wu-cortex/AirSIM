# Issue #20：VoBLE 断线恢复评审

日期：2026-11-05。基线：`develop` / `ead7bf8`。

问题来源：[Issue #20](https://github.com/kai-wu-cortex/AirSIM/issues/20)，反馈版本 v0.9.8.20。Issue 没有双端日志、机型、系统版本或明确复现时序，因此不能确认首次蓝牙断线的原因。以下发现解释的是断线后自动恢复可能卡住的路径，不代表已在报告者设备复现。

## 发现

### P1：握手队列的占用在断线后可能不释放

位置：`iOS/AirSIM/VoBLEDeviceHub.swift:202–214,288–300`；`VoBLECentralController.swift:1070–1072`。

Hub 仅在 ready/stopped/failed 时释放 handshake。认证途中无错误断线会进入 scanning，不释放占用；有错误断线则可能同步经历 failed → scanning，而异步状态订阅因“当前状态必须等于事件状态”跳过 failed。重新发现同一设备被 handshake 检查拒绝，其他设备也不能启动排队的握手。

这不表示每次已就绪连接断开都会锁队列：ready 已释放占用；缺陷触发点是握手尚未完成时断开。

建议：用带连接代次的握手完成/失败/取消事件释放所有权，不让 UI 状态流承担资源回收。旧连接事件不能释放新连接占用。

### P1：连接后认证阶段缺少超时恢复出口

位置：`iOS/AirSIM/VoBLECentralController.swift:598–600,625–638,1022–1025,1064–1068`。

didConnect 取消连接超时后开始服务发现，后续服务发现、订阅和认证没有对应的阶段超时。若回调或认证响应没有到达，会停在认证中；再次 connect 同一 peripheral 又因 connecting/authenticating 状态直接返回。系统自动重连也被排除在现有超时策略之外，回前台后仍没有有界恢复出口。

已有控制请求超时不等于认证流程超时。已有 Hub 最多 5 次退避重试也不能保证推进上述内层状态。因此，“完全没有自动重连”的说法不准确，实际问题是重试可能无法推进状态。

建议：加入按连接代次隔离的阶段超时与前台恢复检查；区分等待用户确认配对码和等待网络响应。先取消旧连接并确认收尾，再启动下一次连接，不破坏正常通话或后台系统重连。

### P1：Android 关闭 GATT 后残留旧认证所有者

位置：`android/phone-control-app/src/com/airsim/phonecontrol/voble/VoBLEGattServer.java:502–517`。

close 增加 generation、关闭 server、清空 devices，却没有逐个 channel.disconnect 或通知 GatewayService.onDisconnected。旧服务器回调随后会被 generation 防护丢弃。如果关闭前普通断线回调尚未完成，原 channel 的 authenticatedOwner、订阅和服务会话仍可能存在。蓝牙重开后，若 iPhone 使用不同 BLE 地址，会被 canAuthenticate 判定为另一个所有者而拒绝。devices 已清空，新连接时的旧设备清理也无法补救。

建议：关闭时一次性退休全部连接、认证所有者、订阅和媒体会话，同时保留 generation 防护与持久化配对凭据。此项是源码路径确认，尚未进行真实蓝牙开关/地址轮换验收。

### P2：Android 部分广播启动失败没有进入重试调度

位置：`VoBLEGattServer.java:88–101,144–147,351–357`；`VoBLEGatewayService.java:224–235`。

现有 2/4/8 秒重试由 onAdvertisingFailed 触发，但 startAdvertising 抛异常、服务添加失败和部分 start 返回 false 的路径只关闭/记录日志，没有接入该调度。服务可能仍存活，但不再广播，直到再次启动服务或切换蓝牙。

建议：统一启动失败结果与有限次数退避恢复，明确权限缺失、蓝牙关闭、服务销毁时不重试，避免无限重启循环。

## 验证

- 临时加入两项 XCTest，用真实 Hub、状态 reducer 和现有 RadioIOProbe 构造“认证中断线 → 再发现”时序，没有无线设备操作。
- `testIssue20ReviewCleanDisconnectMustReleaseHandshakeQueue`：失败，排队设备 B 未创建 session。
- `testIssue20ReviewFailedThenScanningMustReleaseHandshakeQueue`：失败，同一断言，证明瞬态 failed 被跳过后队列仍占用。
- 2 项执行完毕，2 项预期的断言失败，无意外异常。它们是缺陷复现，不是通过的修复回归。
- 临时测试已恢复，生产源码未修改。运行日志：`/tmp/airsim-issue20-review-tests.log`；临时测试源片段：`/tmp/airsim-issue20-repro.patch`（Swift 片段，非统一 diff）。
- 对比 v0.9.8.20 与当前 HEAD，VoBLEDeviceHub、VoBLERadioController 和 VoBLEGattServer 文件均无变化；仅升级版本不能认为上述缺陷已经消除。

## 修复与验收顺序

1. 修复 iOS 握手所有权释放，覆盖无错误断线、failed 紧接 scanning、旧事件迟到以及多设备队列。
2. 增加连接/服务发现/认证阶段恢复，覆盖丢失回调、前后台切换、系统重连长期不完成；确保旧代次事件不会取消新连接。
3. 补齐 Android close 清理和启动失败重试，验证蓝牙开关、GATT 重建、BLE 地址变化及订阅重新建立。
4. 双端同一时间窗口日志关联首次断线：iOS disconnected 错误域/错误码、is_reconnecting/local_cancel；Android GATT status/newState、服务与广播生命周期。再区分无线链路、系统省电、服务被回收或主动取消。

本次未修复、安装、发布或进行真实通话。以上修复不要求修改 Relay HTTP API 或 U30Air Agent 协议。首断原因和修复后的长时间后台稳定性仍需真机验证。
