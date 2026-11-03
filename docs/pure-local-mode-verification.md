# 纯本地模式实施与验证记录

日期：2026-10-29。对应设计：`superpowers/specs/2026-10-29-pure-local-mode-design.md`；计划：`superpowers/plans/2026-10-29-pure-local-mode.md`。

## 当前状态：开发中，不是发布验收

实现位于 `codex/device-test-20261029` 隔离工作树，基于 `6c01709` 加未提交改动。原工作树、已有隧道恢复和联系人/最近页面修复保持不变。没有推送、部署、安装或发布。

已有跨 Swift、Java、Go 的策略/签名合同基础。Android 本轮新增：

- 独立同步持久化事务，保存首次云端配置快照；记录损坏、身份不匹配时保守禁用。
- 串行进入/退出协调器，排空未完成、必要 AVF 未确认、写入或恢复失败均不能给出生效确认。
- Relay HTTP/WebSocket 出口登记、取消、排空与代际隔离；断开连接本身阻塞时也不无限阻塞排空调用。
- 应用启动先读策略；旧注册和云端开关不能覆盖禁用状态。
- 反馈和通知 webhook 的请求拦截及排队任务失效；不修改 GitHub 更新偏好。
- 短信保留本地收件箱，清除云端上传义务；通话事件、旧云命令与媒体重试按代际失效。

通知 webhook 也会暂停，包括 Feishu、Bark 等自定义目的地。它们不一定属于 AirSIM Relay，但不能允许任意 webhook 或重定向绕过本模式；最终界面必须说明此影响。

## 已执行的验证

`sh android/phone-control-app/test-pure-local.sh`：真实策略、签名、持久化、协调器、出口和事件队列测试。覆盖磁盘失败、重启、重复进入保留快照、AVF 待确认、退出恢复失败、Android 本机退出优先、旧代际拒绝、排空超时。

`sh android/phone-control-app/test-pure-local-integration.sh`：在完整 Android 构建和 JVM 基础测试后执行。使用真实客户端和计数传输，确认禁用后的 Relay HTTP、反馈、通知 webhook 发送数为零；检验本地短信保留及云端积压丢弃。传输替身不连接实际服务器。

`./android-standalone/test.sh`：已通过完整回归及 debug APK 构建，包括新增纯本地测试、原有通话归属、短信、VoBLE 和 WebSocket 生命周期测试。旧测试在较新 JDK 上仍有反射修改 final 字段的警告，不是测试失败。

## 尚未完成，不能据此声称零 Relay 全链路验收

### 2026-10-30 离线检查点

本轮只使用本地代码及缓存依赖，没有推送、部署、发布或安装真机。

- AVF 的 HTTP/WebSocket 已加入受控出口；未完成的请求不视为排空。
- 新增回归实际复现旧短信重试在退出后再次发送（计数从预期 1 变成 2），修复后取消重试，旧云命令及结果上传也按操作代际拒绝；新代际仍保留正常退避。
- 注册任务在创建后台任务前登记，重试等待可取消；不是仅在发送前读取一次布尔开关。
- 新增 AVF 独立策略日志及启动读取。策略损坏、读取失败、纯本地开启或退出尚未完成时保持 Relay 禁用，不回退使用较旧的宽松策略；恢复前的配置快照保存在权限为 0600 的日志中。
- Java 协议编解码及状态 HMAC 测试通过，包括 nonce 不匹配和状态篡改拒绝。

本轮验证：

```sh
# module/module-agent 内，禁止 Go 下载模块/工具链
GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local go test -race ./...

# 先检查所有依赖已缓存，再运行；没有下载缺失依赖
sh android/phone-control-app/test-pure-local.sh
AIRSIM_ANDROID_BUILD_VARIANT=debug ./android-standalone/test.sh
git diff --check
```

全部通过。Go 日志 `/tmp/airsim-offline-go-final.log`；Android 日志 `/tmp/airsim-offline-android-tests.log`。Android 仍有既有 final 字段反射测试警告。没有重新运行 iOS 测试，也没有验证真实 AVF 协商或设备网络流量。

**AVF 策略文件目前只有存储及启动保护，认证接口尚未调用它完成进入/退出事务，因此仍不能从 App 开启完整纯本地模式。** 以下清单保持未完成。

1. Android coordinator 的实际 Environment 接线、Android 本机退出页面。
2. WLAN/BLE 认证策略接口及完整 ACK 证明；AVF 持久策略、真实出口关闭及确认。
3. iOS 全 Relay 出口约束、迟到 PushKit 处理、两端事务协调、首次配对集成。
4. 设置顶部滑动入口、VoiceOver、活动通话禁止切换和退出确认。
5. 完整功能的 iOS/Go 回归、最终独立审查与真机请求记录。

现有 `VoWLAN+VoBLE` 模式不等于上述全应用纯本地策略。Android 协调器单元测试中的 AVF 确认来自受控测试依赖，不代表真实 AVF 已适配。尚未进行三星/iPhone 的 LAN、热点、Tailscale、锁屏、DHCP 或通话短信实测，不以 Dashboard 离线代替抓包验收。
