# VoBLE 挂断后灵动岛仍计时（iOS 候选 89）

## 现象与复现

2026-10-16 用户反馈 iPhone 主 AirSIM 0.9.7（88）蓝牙通话由 iPhone 挂断后，灵动岛和锁屏仍显示“通话中 · 蓝牙”并计时。此前切换蓝牙模式的卡顿，用户已确认消失；本修复不恢复高频轮询。

代码与自动测试复现了一条确定的错误路径：

1. 蓝牙拨号先产生 iPhone 临时 ID，并写入统一通话状态。
2. Android Telecom 返回真实 ID，蓝牙协调器已接纳它，统一状态却将不同 ID 当作另一通电话拒绝。
3. `applyVoBLEState` 原先忽略这一拒绝，仍发布 active 记录给 UI 和实时活动。
4. 挂断的真实 ID 与统一状态中的临时 ID 不同，`finishVoBLECall` 因身份不匹配跳过清理。ActivityKit 不会自行知道远端通话已经结束。

这证明代码缺口与症状一致，不等同于已取得用户这通电话的完整 iOS 事件轨迹；真机效果需复验。

## 修复

- 仅在显式 VoBLE 交接时允许临时 ID 替换：来源必须为 Agent，UUID 和 generation 完全相同，旧状态必须为 connecting，新状态只能为 connecting/active。旧临时 ID 加入已退役集合，不能复活；不得绕过 ending/ended 意图，也不能替换别的电话。
- 如果本机先挂断，临时 ID 已进入 ending，则只允许同一 UUID/generation 的真实 ID 以 ended/failed 完成终止交接，不接受 connecting/active。结束清理同时检查 UUID/generation 和归并结果，避免仍卡在 ending 或误清下一通电话。
- 状态归并被拒绝后，不再先修改 remoteCall、CallKit、Watch 或实时活动。
- 实时活动异步任务执行时重新读取统一状态过滤后的当前通话，不捕获排队时的旧 active 数据。
- 实时活动构建器将 ending/ended/failed 或已带 endedAt 的记录当作无活动通话，回到在线待机/离线态，不生成通话计时或挂断按钮。待机灵动岛按原用户开关保留。

## 验证

五项新增回归涵盖 ID 交接后正常结束、错误 UUID/generation 拒绝、挂断/换线后旧展示数据失效、结束记录不能变成 active，以及临时 ID 下提前挂断的终止交接。先验证旧行为失败，再验证修复；完整 iOS 测试 161/161 通过，快速挂断边界已复审。

签名 Release 构建及签名校验通过，已保留数据覆盖安装到 iPhone Air 主「AirSIM」，设备应用列表确认 0.9.7（89），启动命令成功。实际蓝牙通话挂断后的灵动岛效果仍等待真机复验，未以安装/启动冒充通话验收。

没有修改 Android、Relay、配对凭据或已验证的音频编解码队列。未提交推送或发布 TestFlight。真机验收需覆盖 iPhone 挂断及对方挂断，观察约 30 秒，确认不再恢复通话计时，并确保下一通正常显示。
