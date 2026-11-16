# F50 Pro 云端 Telecom 控制修复

在保留 F50 适配的 Apps 0.9.8.25 / Android 140 集成分支上，处理云端调用返回 `Telecom invocation timeout` 和去电一直等待控制确认的两个可复现问题。

## 触发与修复

- `executeCloudCommand()` 持有网关监视器并等待主线程执行 Telecom；`SIMSlotObserver` 在主线程调用的 `simSlotsChanged()` 又需要同一监视器。现在 SIM 修订号使用原子计数，发布变化不再等待云端命令锁；命令串行化和重复请求缓存保持原有行为。
- iPhone 在发起去电后也发送 `answer` 以确认该通话的媒体会话。原实现对仍在 DIALING 的去电调用原生接听路径，返回 `call is not answerable`。现在只对已经验证完整云端通话身份、仍属待接通去电的命令确认媒体，不调用原生 `Call.answer()`。仍需默认电话角色；没有将通话标记为 ACTIVE，双向 PCM 仍取决于真实接通状态。
- 来电接听仍调用 Telecom 并等待 ACTIVE；错误代际、已结束通话和缺少电话角色仍被拒绝。

## 验证范围

新增 `CloudTelecomControlTests` 使用真实网关和通话仓库，配合合成 Android 服务复现锁反转及去电媒体确认。修改前两项均失败；修改后定向用例通过。测试不拨打真实号码、不连接运营商或外部服务器。

`android-standalone/test.sh` 完整回归退出 0，包含云端通话、来电原生接听、默认电话角色、错误通话代际与已结束会话拒绝、服务生命周期、通话归属、纯本地隔离及 APK Manifest 验证。`git diff --check` 通过。

已用原签名覆盖安装 MU3356，保留配对数据，并恢复 Shell 音频桥。安装后发现 Wi-Fi 未连接，通过主动扫描重新连接既有网络，随后确认设备获得原 IP、域名可解析、云端心跳及命令通道恢复。此次未刷固件，也没有修改路由器设置。

修复仍沿用 0.9.8.25 / 140 版本号，是本地测试修订而非新正式版本。APK SHA256：`5939f226e1b2f0d1e15c66a8f244a28093bce26579a28d0258cf9ddac60f5c6b`。

实际运营商接通与双向声音仍等待用户复测；此前系统记录的 NORMAL_UNSPECIFIED 断开不等于这两项软件缺陷已经解释全部未接通原因。

设备诊断应区分 Android 两套断开码：`android.telecom.DisconnectCause.REMOTE` 为 3，LOCAL 为 2；`android.telephony.DisconnectCause.NORMAL_UNSPECIFIED` 为 65。设备显示的网络原因 31 未给出具体拒绝原因，不能据此认定为用户主动挂断或某种运营商套餐限制。
