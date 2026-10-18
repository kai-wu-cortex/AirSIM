# Relay 多安卓命令隔离与重试

本文描述未发布的工作区改动，不表示生产 Relay、APK、IPA 或 TestFlight 已升级。正常心跳仍为 30 秒；不新增 iOS 云端状态查询定时器，VoWLAN / VoBLE 不依赖本协议。

## 命令归属

同一 Apple `device_id` 仍对应一个 COMMANDS Durable Object。具名安卓连接通过 `agent_id` 分槽，只替换同槽连接；Agent ID 是路由标识，不是鉴权凭据，设备 Secret 校验仍保留。ID 非空、最多 128 个 UTF-8 字节，不含控制字符或前后空白，大小写与内部字符原样保留。

每条命令在接收时固定 `target_agent_id`；断线、重连、HTTP 补拉、重试 alarm、救援挂断和完成回执都不能换目标。同一命令 ID 全局幂等，相同意图返回原结果（拨号重试返回原媒体身份）；更换目标或意图返回 409。

通话持久化 `agent_id`。挂断、拒接、接听由该通话归属路由；DTMF 同时检查 call UUID、generation、有效期及目标，不读取用户后来选择的手机。Watch 的来电、呼出回复及本地媒体模型复制保留源 Agent 和 generation。缺源字段的旧推送保持 legacy，不从当前选择补猜。

## 协议与旧版本

`/healthz` 和 `/v1/devices/status` 声明 `capabilities.agent_command_routing = 1`。新版安卓心跳声明 `command_routing_version = 1`；Apple 客户端要求目标自身在线且支持该协议，不把“最后上报心跳的手机”当成唯一可用目标。

| 动作 | 新入口 | 必须字段 |
| --- | --- | --- |
| 命令连接 | `GET /v2/devices/:deviceID/commands/connect` | query `agent_id` |
| 新建 / 查询命令 | `POST /v2/commands/enqueue`、`/result` | `target_agent_id` |
| 补拉 / 完成 | `POST /v2/commands/pull`、`/complete` | `agent_id` |
| 来电 / 生命周期 | `POST /v2/events/call`、`/call-state` | `agent_id` |
| 通话动作 / 查询 | `POST /v2/calls/:uuid/actions`、`GET /v2/calls/:uuid/actions/:id` | 既有通话身份与设备鉴权 |

媒体连接路径不变。新客户端遇到旧 Relay 的 404 / 405 明确失败，绝不静默退回不理解目标的 v1 动作。旧 v1 客户端仅在唯一在线候选时解析目标；多个候选返回 409。旧无目标队列只由 legacy 领取，具名 ID `legacy` 不与无 ID 槽混同。第二个无 ID 连接收到 429、Retry-After 60，不互踢。

缺 AndroidAgentID 的 AVF 配置需通过原配对流程补全，不删除用户数据，也不拿 SIM 号码生成新身份。更换 SIM 不改变 Agent ID。

## 请求控制与诊断

Standalone 连接存活至少 60 秒才重置失败档位；普通失败 3 / 6 / 12 / 24 / 48 / 60 秒，加至多 25% 抖动。429 / 5xx 从 15 秒开始，指数退避基础值最高 300 秒；有效 Retry-After 即使更长也遵守。4001 被替换至少等 60 秒，重复替换继续延长。HTTP 兜底受 15 秒门限及同一冷却约束，WSS 在线时不补拉。AVF 保留稳定一分钟重置，补齐具名协议与同类冷却限制。

Standalone 关闭云端、停止服务或变更 relay / device / secret / agent 时取消旧连接代次；号码、设备名称或 token 更新不重连命令通道。日志只写原因分类、失败档位、等待时间等，不写服务器任意关闭正文、号码、短信、完整身份、媒体或设备密钥。

配置由唯一读取器提供快照，旧网络返回不能重新启用旧配置；执行器拿到执行锁后再验归属。AVF 配置代次也覆盖关闭后重开，旧回执与失败不影响新配置。Standalone 在 TCP / TLS / 升级握手前登记可关闭资源，并设置 8 秒 TCP 连接超时；服务停止和配对变化可取消尚未建成的连接。

iOS 仅为在途命令查询结果，0.5 / 1 / 2 秒封顶退避；固定同一个命令 ID、目标和注册快照，终态或取消即停止，不重发实际动作。

## 后续上线顺序与验收

需另行授权：先部署兼容的 Relay，再升级安卓 / AVF，最后升级 Apple 客户端。回退 Relay 时暂停新建定向云端动作，不能把具名队列改成广播；本地链路保持独立。

本地回归覆盖多连接、离线目标、跨目标回执、并发命令、实际旧路由的 404 / 405、关闭帧、重连策略及模型复制。APK 构建、模拟器测试和无签名 iOS / Watch 构建不等于真实弱网、锁屏、Watch 停止响铃或生产请求量验收。未执行生产部署或真实电话 / 短信测试。

本轮本地结果：Relay 61 项与独立本地 workerd 多连接验证通过；Android 全套含 API 29–35 兼容检查、Standalone / Bridge 构建通过；AVF Go 全套与 race 通过；iOS 137 项通过，iOS / Watch / Live Activity 无签名 Release 构建通过。独立只读审查发现的三项配置取消问题已在一次修复中增加确定性回归并修复，未进行二次独立审查。
