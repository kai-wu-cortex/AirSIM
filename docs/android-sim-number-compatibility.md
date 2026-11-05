# 多卡号码读取兼容性

2026-11-04，VoBLE 工作树，统一 Android Standalone。

用户在早期媒体验收通过后反馈，多卡界面显示“号码未提供”。当前应用 READ_PHONE_STATE 与 READ_PHONE_NUMBERS 均已授权。通过配对认证读取实际 `/v1/health`，设备号码为空，两张 SIM 的号码、slot_index 与 sub_id 也都为空/未知；系统订阅记录的两张在用卡有号码。诊断只输出“是否存在号码”，未把号码或配对密钥写入文档。

现有代码只在 subscription 映射与读取成功时填充 SIM 号码，异常后直接保留空值；同一 Telecom PhoneAccount 提供的号码未被使用。只读电话账户探针确认两账户各自提供 address / subscriptionAddress。该探针的进程环境不等同于 App，不能用探针内的订阅服务异常堆栈推断 App 的具体 ROM 异常原因。

## 修复行为

- 保持原订阅接口为优先来源；缺失时读取**同一个已启用蜂窝 PhoneAccount** 的 `getSubscriptionAddress()`，再读取 `getAddress()`，只接受 `tel:` 地址。
- 最后可使用已确认 subscription ID 对应的 `createForSubscriptionId(...).getLine1Number()`；不从 opaque Telecom ID、卡片列表顺序或号码反推订阅/卡槽。
- 电话状态和号码权限仍是前提。未提供的号码保持为空，不借历史数据、其他 SIM 或联系人补齐。
- 设备摘要先使用 App 明确选中的通话卡，其次系统默认通话账户，再使用已确认的默认语音订阅/唯一在用卡。显式选择已被移除时保持未知；多卡没有可确定默认卡时不随意显示第一张有号码的卡。
- 这只补显示元数据，不修改系统默认 SIM、呼出选卡、短信路由或音频路径。iPhone 仍通过原 health/sim_slots 字段接收结果。

Android 官方说明：[PhoneAccount](https://developer.android.com/reference/android/telecom/PhoneAccount) 将 subscriptionAddress 定义为可供显示的订阅号码，address 为该账户的地址；[TelephonyManager](https://developer.android.com/reference/android/telephony/TelephonyManager) 提供绑定订阅的查询接口。号码存在仍不代表运营商验证过的身份。

## 定向回归

覆盖订阅映射失败时各账户独立号码回退、原订阅结果优先、SIM 顺序变化不串号、无号码权限不读取、空/null/非 tel 地址保持未知、默认账户及手动选择、移除已选 SIM 不借其他卡号码。沿用 API 29 兼容检查与完整核心回归。

## 构建与实机结果

完整 `sh android/phone-control-app/test.sh`、Debug 构建与 `git diff --check` 均通过。已保留数据覆盖安装统一版本 `0.9.8.21 (132)`，启动成功。包为 `android-standalone/build/candidate-132/AirSIM-Android-Standalone-debug.apk`，SHA-256：`37cc7fafc8a9e17dfa40bb53e7ffbd1892eae09b2f8d72ed1a981d0063460ece`。

安装后通过原配对认证重新读取真实 `/v1/health`：

- `phone_number` 从空恢复为非空。
- 两个 `sim_slots` 各自返回非空且不同的号码；在内存中与当前在用订阅号码比较一致，未输出号码本身。
- `slot_index` / `sub_id` 仍为 -1，表示现有订阅映射不可用；没有借这次号码回退伪造卡槽、订阅编号或默认语音标记。
- iPhone 无需更新，使用已有字段刷新即可。未代用户拨号、发送短信或录音；未发布或推送。

上一版 131 的运营商早期媒体修复保留。本次确认的是号码元数据恢复，不是新增全机型音频或短信选卡验收。
