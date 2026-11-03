# 2026-10-30 云端心跳 HTTP 500 排查

实时 Worker 日志确认：`/v1/events/heartbeat` 抛出
`Exceeded allowed volume of requests in Durable Objects free tier.`。
云端命令 WebSocket 接口也受影响。不是纯本地开关或配对失败。

## 本次处理

- 已知 DO 请求额度耗尽返回 HTTP 503、`relay_capacity_exhausted` 和
  `Retry-After: 300`；不会返回心跳成功，也不把高频写入转移到 KV。
- Android 自动心跳遵守 Retry-After（最低 30 秒、最高 1 小时），
  等待时间使用单调时钟；手动心跳失败同样推迟自动重试。
- 手动按钮仍允许用户主动重试，不会打开云端或绕过纯本地出口限制。

## 运维恢复与验收

部署者需在 Cloudflare 查看 Durable Objects 使用量，等待额度恢复，
或自行确认费用后调整套餐。代码更新不等于额度恢复。
期间本地 VoWLAN/VoBLE 不依赖此云端心跳；云端命令/媒体功能不能保证可用。

恢复后验证：安卓手动心跳成功；iPhone 云端自检显示新鲜 Agent 心跳；
再进行云端拨打/接听测试。仅 healthz 成功不能证明 DO 或云端通话恢复。

Worker 集成仓库测试 64 项通过；部署快照的 relay、routing、feedback 测试
63 项通过；Android HeartbeatRetryTests 通过，APK 构建及签名校验通过。
混合版本路由测试需要 Git 历史，已在集成仓库运行，不在临时快照中运行。
