# 小米短信确认弹窗调查（尚未完成免确认验收）

2026-11-14，用户确认 VoBLE 发送成功且接收端收到，但每次需在 Redmi 上确认“AirSIMBridge 发送短信”。用户要求使用已授权的 Shizuku/Root 实现自动发送。

## 已确认

- 上次实际发送日志：Root 返回 `error:NullPointerException`，Shizuku 也返回 `error:NullPointerException`，然后使用 `sms_send_path=system subscription=9`，最终普通 App 路径回调成功。
- 因此此前成功收达并未验证权限服务发送成功；不能据此宣称 Shizuku 已免确认。
- Android 0.9.8.25（138）诊断包已保留数据覆盖安装。
- 新增只读 `sms-preflight` dumpsys / Binder transaction 10；使用固定合成文本做 SmsManager 准备和分段，不调用发送 API。Redmi 返回 `ready:parts=1`。
- 为 Shizuku 真正发送异常记录 manager/divide/send 阶段，以及最多六个类名/方法名；不记录异常 message、号码、正文。
- `test-privileged-sms.sh` 通过，新增两项预检测试确认零发送及身份恢复，异常消息不外泄。
- 只读查看这台 Redmi 的系统 SmsManager/ISms 实现用于核查兼容性，未修改系统文件、全局短信权限或安全中心。

## 定位与修复（139）

- 投屏确认弹窗来自 MIUI Security Center 的 `com.miui.permcenter.ctaverify.SendSmsVerificationActivity`。
- 20:16 的诊断捕获 Shizuku `stage=send` 的空指针，栈指向 `IAppOpsService.reportRuntimeAppOpAccessMessageAndGetConfig` 和 `AppOpsManager` 的访问记录逻辑。随后旧代码回退普通 App 发送；普通发送超时后弹窗仍未消失。
- 系统实现使用 `ActivityThread.currentOpPackageName()` 归属权限访问。裸 `app_process` 缺少 Application，可能得到空包名；不能据此判断短信未提交，用户观察到已发送具有可能性。尚无该条短信接收端证据。
- 新增 `PrivilegedSmsRuntime`：为已授权权限进程补齐最小 Application 上下文；shell 使用系统提供的真实 shell Context，不运行 AirSIM Application.onCreate，不禁用 AppOps，也不伪装短信 App。
- Root 和 Shizuku 发送都区分准备失败与发送结果不确定。仅明确的发送前失败允许回退；发送阶段异常、超时、远端结果丢失等停止跨路径重发，提示先检查收件方。
- “仅 Shizuku”现在不会先尝试 Root。精确订阅选择、配对认证和 App 的 SEND_SMS 权限检查保留。
- 更新前取消了旧的已超时回退弹窗，未确认发送。已保留数据覆盖安装 Android `0.9.8.25 (139)`。

## 验证与待验收

- `android-standalone/test.sh` 全部通过，包含 API 29–35 短信兼容性、权限进程初始化、SIM 映射及不确定结果禁止回退用例；`git diff --check` 通过。
- Redmi 9 实机只读预检返回 `sms_preflight ready:parts=1 appops_attribution=true`。此预检只准备 SmsManager 和固定合成文本分段，零短信发送。
- 用户实测 139：短信已到达，对方回信也在 iPhone 收到；但 iPhone 立即提示结果未确认且没有保存发信。不能把 139 视为修复完成。Root-only 的实际发送尚未验收。
- `ok:<segments>` 仅表示发送 API 已返回，不等于运营商投递成功或接收端收达。不得以预检/单元测试代替真实收达验收。

本轮没有代发短信、改变系统安全中心的全局设置或新增自动点击授权；没有提交、发布或部署。

## 发送回执补齐（140）

- 139 在 Shizuku 调用结果不确定时正确阻止了跨路径重发，但权限发送原先没有传入 sent PendingIntent，无法利用系统实际发送回执纠正状态。
- iOS `AppModel.sendSMS` 只在发送成功后调用 `saveSentMessage`；安卓错误回传导致发信记录缺失。安卓收件箱同步不含系统已发送记录，因此收到对方回信也不会自动补回这条发信。
- 新增 Binder transaction 11，保留旧 transaction 6。App 创建每段唯一、一次性且不可修改的回执 PendingIntent，传入授权服务；服务验证分段数量后，将同一批 token 传给 SmsManager。不会重新发送以探测结果。
- 权限调用返回成功或发送阶段异常，均等候系统 sent 回执（最多 45 秒）。所有段成功才回传成功；部分成功/超时仍未确认；明确失败回传实际系统错误。重复或越界回执不能提前完成。
- 使用新的独立 action UUID 和包限定接收器隔离不同发送；结束后注销接收器并取消 token。日志只记录随机短 trace、段数、结果码，不记录号码或正文。
- VoBLE 原有短信请求超时为 60 秒，可以容纳此回执窗口；成功结果复用现有 iOS 发信历史写入。既有 139 缺失的发信不会被这次修改自动补回。
- 新路径仅用于当前 Shizuku Binder 发送；Root JSON 桥仍使用原路径，不能宣称 Root 回执已完善。旧权限服务不支持新事务时，仅在明确未执行事务的情况下安全回退。
- 自动化增加：发送后抛异常时仍将正确回执 token 交给系统、单段/多段仅发送一次、分段数不符零发送、部分/重复/越界回执不能冒充成功、真实失败不重发。实机收达/免弹窗/发信记录仍需用户手动验收。
- 140 APK 构建通过并保留数据覆盖安装，设备 `dumpsys package` 确认 `0.9.8.25 / versionCode=140`；实机只读预检仍通过。定向权限短信测试 23 项通过，短信兼容性回归及 `android-standalone/test.sh` 全量回归通过。

## 140 实机验收

2026-11-14，用户针对错误提示、iPhone 发信内容、收达与重复短信的验收问题回复「OK 解决了」。

同步只读日志确认北京时间 20:59:05 的同一发送 trace：权限调用仍返回 `error:send_unknown:NullPointerException`，约 420 ms 后收到该段系统 sent 回执 `result=-1`（Activity.RESULT_OK），随后解析为 `ok:1 callbacks=1` 并回传 Shizuku 发送成功，没有进入普通 App 回退发送。

因此，本轮修复验证的是通过真实系统回执正确收敛发送结果，而不是底层厂商空指针已经消失。短信已发送及 iPhone 记录问题经用户确认解决；当前样本为单段 Shizuku 发送，多段和 Root-only 仍不作实机通过声明。
