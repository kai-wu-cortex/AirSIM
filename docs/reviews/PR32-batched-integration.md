# PR #32 分批整合记录

来源：PR https://github.com/kai-wu-cortex/AirSIM/pull/32 ，head `2788797`。
基线：develop `d472d54`（含 Watch 短信功能）。独立实现分支 `codex/pr32-batched-integration`。

## 第一批：正确生产身份

提交 `82bd5f6` 已合入并推送 develop。

- AVF `incoming_sms` 增加 `agent_id`，与配对身份同源；自动注册省略该字段时保留旧值。
- 继承发生在主配置和 `.last-good` 落盘前；显式新身份仍允许替换。
- iOS 两处轮询将本次 producer 传递到 inbox，完整认证路由优先匹配。
- 同交付保留非空 SIM 标签；原始 delivery_id 保持用于 ACK。
- 未采用原 PR 清空 sourceAgentID 的旧记录兼容代码。

验证：Go 完整 race 测试通过（新增再注册/损坏恢复/显式替换覆盖）；Worker 80 项及语法检查通过；15 项生产短信模型/真实存储检查通过；iOS/watchOS 和测试目标 build-for-testing 通过。

## 第二批：统一持久化与旧记录迁移

- APNs、VoWLAN inbox、VoBLE 接收统一调用 `LocalHistoryStore.ingestMessages`，在同一锁下合并并原子落盘。不会根据正文、号码或时间推断跨设备身份。
- 仅当当前配对目录确认唯一生产者、没有忘记设备记录，且确有同 delivery_id 的已认证副本/已记录别名时，将旧条目提升为 scoped 身份。历史中已出现另一来源时保守隔离。
- 不清空已认证 sourceAgentID，保留 Watch 按设备显示/回复、SIM 来源和小组件计数。
- inbox 等待前后比较目录快照和配对 revision；新增、删除、重新配对及 A→B→A 变化均不使用旧唯一性结论。持有配对锁执行存储事务，避免检查后再发生目录变更。
- 来源不明、多设备时收到的 legacy 交付记录持久化歧义标记；以后目录缩成单设备也不自动归属。
- 已证明的别名、迁移后的已读键和删除键与消息在同一文件原子写入。重启后不重复红点，删除后迟到的 legacy/APNs 副本不复活。
- 旧 UI 条目在后台迁移后执行已读/删除时，跟随已证明别名；若当前仍有独立 unknown 条目或曾标记歧义，则不操作另一设备的 scoped 记录。
- 入站只提交本批交付，不再把旧 UI 数组反复并入存储；ACK 等待期间的其他接收或删除以后续磁盘快照为准。读取损坏返回 nil，与合法空收件箱区分。
- ACK 只包含成功持久化或由持久删除标记消费的原始交付 ID。保存失败不 ACK；同 delivery_id 的不同设备保持独立。

## 自动化验收

- `sh iOS/scripts/test-sms-identity.sh`：62 项检查通过。编译真实模型、存储、配对目录与 Watch 策略；覆盖两种到达顺序、并发存储、目录变化、重启、删除/已读、来源隔离、旧 UI 操作、保存失败。
- `sh iOS/scripts/test-sms-history-xctest.sh`：现有 HistoryAttentionTests / SMSDeletionTests 共 10 项 XCTest 在 macOS 核心测试包运行通过。生产存储源码与测试断言保持原样提取。
- 两项 AppModel 集成回归已加入 LocalDeviceDirectoryTests：保留来源使 Watch 可见；拉取期间新增 B 后 A/legacy 保持两条。iOS 测试目标构建通过，但本轮未取得 iOS 模拟器 XCTest 执行结果。上一轮模拟器卡在测试启动，不将编译当作运行通过。
- 未改变 E2E 解密、防伪造、通话媒体、早期媒体及 PushKit/CallKit 路径；未宣称模拟边界验证等同真实 APNs 联测。

## U30Air 同步

已按授权通知“修复插件通话无声音”线程。该线程报告在 `codex/pr36-watch-support` 提交 `9f5c5eecc00f966d7930ea26ed0e5ae7a18caec1`，保留 Watch v2 父提交 `c7bdc00`。

U30 网关本来就使用持久 deviceID；固定 Agent 存在同类身份丢失，现已同步 sendSMS/注册继承。其报告固定 Agent 和插件完整 race/vet、30 项 Node、ARM64 双二进制及 Watch/early/cloud/SMS 回归通过。详见 U30Air `docs/reviews/PR32_SMS_PRODUCER_IDENTITY.md`。

U30 提交尚未 push、安装或发布。本线程也没有安装设备、部署 Worker、发布版本或发送真实短信。Worker 本次仅改测试，无需部署；AVF/U30 生产端修复需后续更新相应 Agent 才生效。

## 仍需用户实测

1. 同一短信先推送后拉取、先拉取后推送：一条记录、正确设备与 SIM、一次未读计数。
2. 旧 AVF 重新注册和重启后推送 agent_id 不丢失；两个设备独立显示。
3. 迁移前已读/已删除的旧短信：迁移后不新增红点、不复活。
4. Watch 对应设备的会话可见、SIM 回复正常；仍有歧义的旧短信保留独立，不自动指定来源。
