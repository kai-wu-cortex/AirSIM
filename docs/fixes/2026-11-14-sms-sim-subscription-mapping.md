# 短信 SIM 被误判为“已移除”

## 实机证据

2026-11-14，Redmi 9（M2004J19C，Android API 31）已授权 READ_PHONE_STATE、READ_PHONE_NUMBERS、SEND_SMS；READ_PHONE_STATE AppOps 为 allow。

只读检查可枚举一个启用的 SIM 通话账户，但普通 `TelephonyManager.getSubscriptionId(handle)` 抛出 SecurityException（READ_PHONE_STATE 相关），对应订阅 ID 为 -1。按同一 PhoneAccountHandle 创建作用域的兼容查询也未取得 ID。尚未深入 MIUI 系统实现，因此不能断言具体是哪一项 OEM 权限规则导致异常。

旧短信代码将“完整账户 key 不存在”和“账户存在但 subscriptionId=-1”合并成“所选短信卡槽已移除”，造成误导。

## 修复

- 现代查询失败后尝试精确 PhoneAccountHandle 作用域查询；Android 29 保留旧 API 路径。
- 普通查询仍失败时，复用用户已授权、当前选择的 Shizuku 服务，只读解析完整账户 key。
- 权限服务重新枚举启用的 SIM 账户，严格匹配 component + opaque ID + user，查询并确认该订阅仍在活动列表中。不会解析/猜测 opaque ID，不按卡槽顺序、电话号码或默认卡代替所选卡。
- 新增只读 Binder transaction 9。旧服务不支持时返回不可用；版本提升至 Android 0.9.8.25（136），使权限服务版本跟随更新。
- 应用未获电话状态权限时，不调用辅助映射。未授权/未连接 Shizuku 或选择仅 Root 时不擅自切换权限渠道；该新增辅助查询尚未接入 RootBridgeTransport。
- 明确区分账户已移除和账户仍在但订阅信息不可用；实际发送仍经过 SEND_SMS、原发送策略及发送结果处理。
- `dumpsys activity service ...StandaloneAgentService sim-mapping` 仅输出计数、订阅/卡槽数值、查询异常类别等；不输出账户 key、ICCID、电话号码或短信。

## 验证与安装

- DefaultCallAccountTests：现代 API 失败/无效时作用域查询、精确双卡映射、无权限、卡槽不存在/未映射、授权辅助解析保持完整 key。
- PrivilegedSIMMappingTests：调用真实权限服务只读方法；API 29/31，账户重排、无效/超长 key、已停用订阅、移除账户、权限缺失、Binder 身份恢复，验证零短信发送。
- SMSCompatibilityTests：API 29–35 短信能力识别及 SmsManager 选卡。
- `android-standalone/test.sh` 通过；新增只读权限服务用例另行通过。测试日志 `/tmp/airsim-sms-slot-tests-final.log`、`/tmp/airsim-privileged-sim-tests.log`。
- 已保留数据覆盖安装 Redmi Standalone 0.9.8.25（136）。安装包 SHA-256：`6ca8f2c46fce9344b0030e471bc5abed13491751d4c99e0fd24dcae8bbf9abcf`。
- 安装后同一个启用账户成功解析 subscription=9，原普通查询仍抛出权限异常，证明新增授权辅助路径恢复了订阅映射。slotIndex 仍为 -1，不声称普通应用的全部 SIM 元数据权限已恢复。
- 本次未更新 iOS、Worker、独立 AVF，未提交或发布。

## 实机验收

2026-11-14，用户在 iPhone 保持 VoBLE 模式手动发送测试短信，确认“发送成功，对方已收到”。本次 Redmi 9 + iPhone 的短信发送及接收端收达通过用户实测；助手未代发短信。

其他设备、双实体 SIM 与 Root-only 实机尚未验收。
