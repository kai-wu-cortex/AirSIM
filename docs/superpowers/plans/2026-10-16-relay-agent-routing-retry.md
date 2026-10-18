# Relay Agent Routing and Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本任务默认由当前会话顺序实施，不自动委派实现。

**Goal:** 多安卓配对时不互踢连接、不串发命令；限制短连接与兜底请求放大，保留旧客户端的安全兼容路径。

**Architecture:** 保留每个 Apple `device_id` 一个 COMMANDS Durable Object，在该对象内以安卓 `agent_id` 隔离连接与命令归属。新客户端使用版本化动作入口和固定目标，通话动作由持久化 call 归属决定。Android 重连与 HTTP 补拉共享冷却，稳定连接后才重置失败计数。

**Tech Stack:** Cloudflare Workers ESM / Durable Objects、Node test runner、Java 17 / Android API 29+、Swift / iOS 16.3+ / watchOS 10+、Go AVF Agent。

**Spec:** `docs/superpowers/specs/2026-10-15-relay-agent-routing-retry-design.md`（2026-10-16 已确认）。

## Global Constraints

- 不执行生产部署、真机安装、提交推送、Release、TestFlight 或账户套餐调整。
- 现有未提交的 build 82–85 改动保留；使用 `/Users/kyle/.codex/worktrees/voble/AirSIM`，不修改另一个主 checkout。
- 保持 VoWLAN、VoBLE 与当前连接模式独立；不改变默认 SIM、媒体编解码、正常心跳间隔，不新增 iOS Relay 状态查询定时器。
- 连接至少稳定 60 秒才清零；普通失败 3、6、12、24、48、60 秒并附加最多 25% 抖动；429／5xx 15 秒起、最高 300 秒，不能缩短有效 Retry-After；4001 至少冷却 60 秒。
- Agent ID 是有界、不含控制字符的非空标识，不是鉴权凭据；设备 Secret、call UUID、generation、owner 检查保持。
- 不要求清空配对数据，不改变存储 namespace，不暴露 Linux 8575/8576 或 Shell 7580。
- 日志不含 Secret、完整设备 ID、号码、短信、Push token、媒体密钥、凭据 URL 或 PCM。
- 每个任务先看到预期回归失败再写产品代码。每个任务完成后做文件范围与测试复核；按本任务约束不自动执行 git commit。

## Review Focus

1. 目标 A 断线、B 在线：A 的命令宁可等待／失败，不能由 B 执行（任务 2）。
2. B 携带 A 的 command ID 完成回执，或旧 A 关闭事件晚到：不得改变 A 新连接或结果（任务 1、2）。
3. Agent ID 含 URI 特殊字符、Unicode、超长 UTF-8 或控制字符：编码往返一致，拒绝歧义输入，无 legacy 名称碰撞（任务 1、4、5）。
4. 客户端缓存过新能力但 Relay 已回退：动作入口仍必须 404 安全失败，不发给未知安卓（任务 3、6）。
5. 关闭帧截断、非法 UTF-8、429 长 Retry-After、服务停止与换配对：不得丢失原因、提前重试、泄漏 socket 或复活旧任务（任务 4、5）。

## 文件职责与协议索引

新建纯策略文件，避免继续向大文件堆入解析与路由逻辑：

| 文件 | 职责 |
| --- | --- |
| `push-relay-worker/src/command-routing.mjs` | Agent ID 验证、scope key、缺省目标判定、归属比较 |
| `push-relay-worker/test/helpers/command-fixtures.mjs` | 无网络的 storage / socket / Response 101 测试边界 |
| `android/phone-control-app/src/com/airsim/phonecontrol/RelayCommandRetryState.java` | 有状态退避、共享冷却和 epoch 失效 |
| `android/phone-control-app/src/com/airsim/phonecontrol/WebSocketPeerClose.java` | 有类型的关闭码和允许列表原因分类 |
| `iOS/AirSIM/CloudAgentRouting.swift` | 目标快照、能力要求、结果查询退避纯策略 |

对外新增动作入口（旧入口保留）：

| 新入口 | 必须的路由字段 | 归属来源 |
| --- | --- | --- |
| `GET /v2/devices/:deviceID/commands/connect?agent_id=...` | `agent_id` | 经设备鉴权的安卓连接 |
| `POST /v2/commands/enqueue` | `target_agent_id` | iOS 发起动作时快照 |
| `POST /v2/commands/pull`、`/complete` | `agent_id` | 当前安卓身份 |
| `POST /v2/commands/result` | `target_agent_id` | 最初命令快照，不读当前设置 |
| `POST /v2/events/call`、`/call-state` | `agent_id` | 新来电／生命周期的安卓源 |
| `POST /v2/calls/:uuid/actions`、`GET /v2/calls/:uuid/actions/:id` | 现有 call 身份 | 服务端 call 记录固定的 Agent |

`/healthz` 和 `/v1/devices/status` 增加 `capabilities.agent_command_routing = 1`；新版安卓心跳报告 `command_routing_version = 1`。这只是显式能力声明，不新增状态轮询。旧 Relay 不认识 `/v2`：未知 POST 返回404、未知 GET 按现有实现返回405，因此不会执行一个忽略 target 字段的动作。

内部命令记录统一使用 `target_agent_id: string | null`；旧记录缺字段视为 legacy（null），绝不自动重新定向。连接 attachment 为 `{role:"agent", agent_id:string|null, connection_id:string}`。同一 device 内的 command ID 全局唯一，目标变化是冲突，不生成第二次实际动作。

---

### Task 1: 连接身份与替换隔离

**Files:** Create `push-relay-worker/src/command-routing.mjs`、`test/helpers/command-fixtures.mjs`、`test/command-routing.test.mjs`；modify `push-relay-worker/src/index.mjs` 的 connect handler 和 `DeviceCommandSession`。

**Interfaces:**

```typescript
// 仅为 ESM 导出的签名说明；运行实现仍使用 .mjs。
export declare function parseAgentID(value: unknown, options?: {optional?:boolean}): string|null;
export declare function agentSocketKey(agentID: string|null): string;
export declare function matchesTarget(recordAgentID: string|null|undefined, callerAgentID: string|null): boolean;
export declare function resolveTarget(requested: string|undefined, activeAgentIDs: Array<string|null>): string|null;
export declare class RoutingError extends Error { status:number; code:string; }
```

parseAgentID 不改变大小写，不去除标识内部字符；非法抛 RoutingError。legacy scope 为 `agent:legacy`，具名 scope 为 `agent:id:` 加ID。缺目标仅允许唯一候选；旧记录缺字段只匹配null。

- [ ] **1. 写失败测试。** 测试 fixture 导出 `makeCommandHarness()`，返回真实 `DeviceCommandSession`、内存 storage 和 `connect(agentID)`；只替代 Cloudflare socket／101 Response，不伪造路由结果。

```js
test("B connection does not replace A", async () => {
  const h = makeCommandHarness();
  const a = await h.connect("android-A");
  const b = await h.connect("android-B");
  assert.equal(a.closed, false);
  assert.equal(b.closed, false);
});
test("named legacy text does not collide with the legacy slot", () => {
  assert.notEqual(agentSocketKey(null), agentSocketKey("legacy"));
});
```

再写：A2 替换 A1、B 不受影响；A1 迟到 close/error 不关闭 A2；空值、控制字符、超过 128 UTF-8 字节拒绝；合法非 ASCII／URI 字符往返一致；CLOSING socket 不计为可用；legacy 第二连接收到 429 和 `Retry-After: 60`。

- [ ] **2. 观察 RED。** `cd push-relay-worker && node --test test/command-routing.test.mjs`；应因当前代码互踢或缺少策略导出失败，不能因 fixture 语法错误失败。
- [ ] **3. 最小实现。** ID 缺失仅在旧入口允许；先设备认证，再复制并覆盖内部 Agent header。保留 `agent` 总标签，附加 scope 标签，用 attachment 识别旧连接。只替换相同 scope 的 OPEN socket：

```js
for (const old of this.state.getWebSockets("agent")) {
  const attached = old.deserializeAttachment();
  if (matchesTarget(attached?.agent_id, callerAgentID) && old.readyState === 1) {
    if (callerAgentID === null) return busyLegacyResponse();
    old.close(4001, "replaced");
  }
}
```

`busyLegacyResponse()` 在 index.mjs 中定义，返回固定 JSON `legacy_agent_busy`、状态 429、Retry-After 60。关闭回调只处理传入 socket，不按 ID 删除后来连接。不记录完整 ID。

- [ ] **4. GREEN 与复核。** 跑目标测试和 `npm test && npm run check`；确认未更改 namespace、媒体服务或配对存储。

### Task 2: 命令归属、补拉与回执隔离

**Files:** Modify `push-relay-worker/src/index.mjs` 的 enqueue/pending/complete/flush/alarm/rescue 和 `sameCommandIntent`；extend `test/command-routing.test.mjs`、`test/relay.test.mjs`。

**Interfaces:** Consumes Task 1 helpers。记录新增 `target_agent_id`；`completeCommand(value, callerAgentID)` 验证归属后再执行幂等完成；`flushPending(socket)` 从 attachment 得到 caller。内部 HTTP caller 身份只由经认证的外部 handler 写入。

- [ ] **1. 写失败测试。** fixture 再提供 `enqueue(command)`、`pull(agentID)`、`complete(agentID,value)`，都通过真实 session.fetch 调用。

```js
test("offline A command cannot be pulled or completed by B", async () => {
  const h = makeCommandHarness();
  await h.connect("android-B");
  const id = "c87f982a-1750-4f03-9a96-6553e454f522";
  await h.enqueue({ command_id:id, type:"dtmf", number:"1",
    target_agent_id:"android-A", expires_at:new Date(Date.now()+60000).toISOString() });
  assert.deepEqual((await h.pull("android-B")).commands, []);
  assert.equal((await h.complete("android-B", {command_id:id,status:"completed"})).status, 403);
});
```

补充 WebSocket、alarm、rescue、重连补发全部只命中 A；同 ID 换目标／意图冲突；旧无目标记录只给 legacy；WS 完成必须使用 socket attachment，不信任消息内自报身份；空目标的多个在线候选 409。把 completed 记录也纳入“错误 Agent 回执不能成功”的测试，不能在归属检查前直接返回已完成。

- [ ] **2. RED。** `node --test test/command-routing.test.mjs`，当前逻辑应出现 B 获得 A 命令等具体断言失败。
- [ ] **3. 实现。** `resolveTarget()` 在接收时只执行一次并保存；显式合法目标即使离线也可以排队。具名队列不向 legacy 投递。复用同一目标判断覆盖所有发送入口：

```js
if (!matchesTarget(record.target_agent_id, callerAgentID)) continue;
// completeCommand 则先返回 forbidden，不修改 record 或 linked command。
```

`sameCommandIntent` 比较目标及原有动作字段，不把服务器时间戳视为新意图。救援命令继承父命令目标；关联完成仍核对目标一致。

- [ ] **4. GREEN 与复核。** 全 Relay 测试通过；检查每处 `getWebSockets("agent")`，不得残留全量命令广播或把未指定目标的新记录留待以后选择。

### Task 3: 版本化 HTTP 边界与通话目标固定

**Files:** Modify `push-relay-worker/src/index.mjs`、`src/status-store.mjs`（心跳能力字段透传）、`test/relay.test.mjs`；extend routing tests。

**Interfaces:** 新 `/v2` 路径见上表；call 状态新增 `agent_id`。请求 `target_agent_id`、持久化 `target_agent_id`、call `agent_id` 对应同一安卓，不能用 active heartbeat 覆盖。

- [ ] **1. 写 HTTP 集成失败测试。** 使用现有 `testEnvironment()` 的模拟注册和 `worker.fetch()`。断言：缺 target 的 v2 enqueue 400；合法 A 的命令只到 A；旧 v1 单连接可解析、两个候选 409；回执 device 不匹配 403；坏 ID 400 而非抛成 500。

```js
const response = await worker.fetch(post("/v2/commands/enqueue", {
  device_id: registration.device_id, device_secret: registration.device_secret,
  command_id: "c87f982a-1750-4f03-9a96-6553e454f522", type:"dtmf", number:"1"
}), env);
assert.equal(response.status, 400);
```

再测：A 通话建立后，B 最新心跳或 iOS 选中 B 不改变挂断／DTMF 目标；新来电没有 source Agent 时 v2 拒绝；legacy call 仍保持 legacy；并发相同 command ID 不产生双重执行；不同 target 的重复请求不能生成可被另一安卓领取的 call。

- [ ] **2. RED。** `npm test`，新路径当前应 404，先验证测试请求和认证有效，再进入实现。
- [ ] **3. 实现。** 显式路由表将新旧入口送入同一已认证 handler，传入路由版本参数；不要修改原 Request body 后反复消费流。v2 ID 缺失拒绝；v1 按 Task 2 唯一候选规则。所有 API 响应固定声明路由能力。

```js
// 新动作与旧 Relay 的未知路径安全失败，不依赖缓存能力判断。
const version = url.pathname.startsWith("/v2/") ? 2 : 1;
// call_control 与 dtmf：读取 call.agent_id，拒绝请求试图换目标。
command.target_agent_id = call.agent_id ?? null;
```

对 DTMF 的 v2 enqueue 同时要求 `call_uuid` 与 `generation`，读取并验证所属 device、有效期和固定 Agent，不当成可独立改目标的通用命令。来电 push／call-state 响应保留 agent_id，虚拟来电不触发安卓命令。已有无目标通话不补猜身份。

- [ ] **4. GREEN。** 全 Relay 测试与语法检查；通过旧版 worker fixture 确认 `/v2` 动作 404，不触发旧 `/v1` 接口。

### Task 4: Standalone 重连冷却、关闭帧与协议身份

**Files:** Create `RelayCommandRetryState.java`、`WebSocketPeerClose.java` under `android/phone-control-app/src/com/airsim/phonecontrol/`；create matching `RelayCommandRetryTests.java` and `WebSocketPeerCloseTests.java` under shared test package；modify `StandaloneAgentService.java`、`StandaloneWebSocket.java`、`StandaloneRelayClient.java`、`RelayHTTPException.java`、`StandaloneCloudMediaManager.java`、`CommandPollingPolicy.java`、shared `test.sh`。

**Interfaces:**

```text
package: com.airsim.phonecontrol
record RetryDecision(long delayMillis, int failures, String reason)
RelayCommandRetryState.failed(long nowMillis, long connectedDurationMillis, Throwable error, double jitterUnit): RetryDecision
RelayCommandRetryState.remainingMillis(long nowMillis): long
RelayCommandRetryState.reset(): void
WebSocketPeerClose extends IOException
WebSocketPeerClose.code(): int
WebSocketPeerClose.category(): String
WebSocketPeerClose.decode(byte[] payload): WebSocketPeerClose throws IOException
```

前三个状态方法均同步。调用方传入单调时间，不读 wall-clock。关闭分类只允许 replaced / normal / protocol / remote_error。上面列出接口，不是可编译的产品代码；实施时先写测试，再写实际方法。

- [ ] **1. 写纯策略失败测试。** `failed(0,1000,new EOFException(),0)` 首次 3000ms，之后短连接依次 6000/12000/24000/48000/60000；连接 60000ms 后断开回到首档。4001 连续失败至少 60000ms；429／5xx 不小于现有策略；Retry-After 600 秒不能被 300 秒 cap 截短。jitter=0/1 的区间、NaN 的安全处理、时钟回退／溢出边界要有断言。

```java
var retry = new RelayCommandRetryState();
var first = retry.failed(0, 1000, new java.io.EOFException(), 0);
var second = retry.failed(4000, 1000, new java.io.EOFException(), 0);
check(first.delayMillis() == 3000 && second.delayMillis() == 6000, "short successes must not reset");
check(retry.remainingMillis(5000) > 0, "HTTP pull shares WebSocket cooldown");
```

关闭帧用实际字节解析：空 payload=无状态；长度1拒绝；非法保留关闭码拒绝；非法 UTF-8 拒绝；合法4001映射replaced，诊断不包含原始原因正文。

- [ ] **2. RED。** 将新测试接入共享 test.sh，运行 `./android-standalone/test.sh`，确认缺策略／旧行为导致失败，未触发真实短信或电话。
- [ ] **3. 实现解析与策略。** `RelayHTTPException` 新增 retryAfterMillis（保留旧构造器）；HTTP 响应和 WSS 握手均解析 Retry-After 秒数／HTTP-date 后转为 duration。握手资源在所有失败路径 finally 关闭；成功返回后才转移 socket 所有权。策略核心如下，所有输入取测试传入值：

```java
if (connectedDurationMillis >= 60_000) failures = 0;
failures = Math.min(failures + 1, 31);
long base = Math.min(60_000L, 3_000L << Math.min(failures - 1, 5));
double unit = Double.isFinite(jitterUnit) ? Math.max(0, Math.min(1, jitterUnit)) : 0;
long delay = base + (long) (base * .25 * unit);
// error 的429/5xx使用15秒起、300秒封顶的独立分支；4001使用60秒起的独立分支。
// 两个分支都在计算抖动后与已解析retryAfterMillis取max，不缩短服务器要求。
```
- [ ] **4. 接入服务。** 命令连接用 `/v2/.../commands/connect?agent_id=`；pull/complete 用 `/v2` 并携带当前 Agent ID。握手成功只记录单调 connectedAt，不清零；断线时调用策略。HTTP pull 同时受 `commandChannelConnected`、15秒间隔和共享冷却约束。429／5xx 的 HTTP/WSS 任一路失败都延长同一截止时间；心跳维持原间隔和既有错误处理。
- [ ] **5. 取消与日志测试后实现。** 用可关闭的 socket factory 测试 service lifecycle：关闭云端、换 device/relay/secret/agent 或停止服务会关闭旧 socket，epoch 失效后不能重连；metadata／号码变化不能无故重连。新来电与 call-state 使用 `/v2/events` 带源 ID，心跳声明 command_routing_version。日志只输出代次、存活时长、原因类别、失败档位、等待值和兜底开关。
- [ ] **6. GREEN 与构建。** `./android-standalone/test.sh` 和 `./android/phone-control-app/build.sh`；核对 Android API 29–35 兼容检查。不得运行安装脚本，也不要覆盖 candidate85 已验证安装包。

### Task 5: AVF Agent 身份、关闭原因与旧配置安全失败

**Files:** Modify `module/module-agent/cloud_command.go`、`cloud_command_test.go`、`cloud_websocket.go`、对应 websocket tests、`push.go`、`push_test.go`。

**Interfaces:** `cloudDeviceCommand.TargetAgentID string`、`cloudCommandCall.AgentID string`；`cloudCommandURL(registration)` 用 `url.Values` 生成 v2 agent_id query。`pushManager.pullCommands()`、`completeCommand()` 从同一 registration 快照携带 `agent_id`。保持命令结果缓存与 `cloudCommandExecMu`。

- [ ] **1. 失败测试。**

```go
func TestCloudCommandURLPinsAgentID(t *testing.T) {
  endpoint, err := cloudCommandURL(pushRegistration{
    RelayURL:"https://relay.example", DeviceID:"apple-test", DeviceSecret:"test-only-secret",
    AndroidAgentID:"android-A:slot/1",
  })
  if err != nil { t.Fatal(err) }
  u, err := url.Parse(endpoint); if err != nil { t.Fatal(err) }
  if u.Path != "/v2/devices/apple-test/commands/connect" || u.Query().Get("agent_id") != "android-A:slot/1" {
    t.Fatalf("agent identity was not pinned")
  }
}
```

补测空 Agent ID 的旧配置不给自己捏造新身份，不访问 Relay 死循环；HTTP pull/complete 使用同一 ID；目标不匹配在执行 AT／Android 命令前失败；旧 Relay 404／405 不回退 v1；关闭码4001保留原因但不输出任意服务器正文；现有一分钟稳定连接后清零测试不退化。

- [ ] **2. RED。** `(cd module/module-agent && go test ./...)`；确认 URL 路径、身份或目标检查的断言失败。
- [ ] **3. 实现。** 更新 URL／payload／event 路径与源 Agent 字段，先核对 target 再调用既有去重执行器。注册没有 AndroidAgentID 时显示需补全原配对配置，不删除数据、不用号码生成 ID；重试前等待本地配置变化／有界休眠。保留既有稳定连接判定与有限退避，新增关闭分类。

```go
relay.Path = "/v2/devices/" + url.PathEscape(registration.DeviceID) + "/commands/connect"
query := url.Values{}
query.Set("agent_id", registration.AndroidAgentID)
relay.RawQuery = query.Encode()
```
- [ ] **4. GREEN。** 完整 Go 测试与必要的 `go test -race ./...`；仅构建，不签发 Debian 包、不触碰 installerd 或现网 Agent。

### Task 6: iOS 目标快照、能力与结果查询

**Files:** Create `iOS/AirSIM/CloudAgentRouting.swift`；modify `VoIPPushController.swift`、`APIModels.swift`、`AppModel.swift`、`IPhoneCloudCallSession.swift`、`iOS/AirSIM.xcodeproj/project.pbxproj`；extend `iOS/AirSIMTests/AirSIMTests.swift`。

**Interfaces:**

```swift
struct CloudCommandTarget: Equatable, Sendable {
    let agentID: String
    let routingVersion: Int
}
enum CloudAgentRouting {
    static func select(boundAgentID: String?, agents: [CloudAndroidAgent],
                       relayRoutingVersion: Int?) throws -> CloudCommandTarget
    static func resultDelay(attempt: Int) -> TimeInterval
}
// 新参数不从函数内部反复读取设置。
// startCloudOutgoingCall(number:target:mediaTransport:timeout:)
// sendCloudSMS(to:message:target:)
// sendCloudDTMF(_:call:) -- call 是已锁定的 IncomingVoIPCall。
```

`CloudAgentStatus.commandRoutingVersion: Int?`、`CloudAndroidAgent.commandRoutingVersion: Int?` 向后兼容缺字段。`IncomingVoIPCall.agentID: String?` 从 push／enqueue 结果传递；蓝牙、虚拟来电构造器默认 nil，不影响本地模式。

- [ ] **1. 选择与编码失败测试。** 绑定 A 时 B 的最新心跳不改变目标；A 离线不能选 B 冒充 A；未绑定且多个在线具名 Agent 报歧义；无新协议能力不能创建新云端动作。JSON 编码必须含 target_agent_id，结果查询继续用同一个 target，不生成新 command ID。

```swift
func testShortResultPollingRemainsBounded() {
    XCTAssertEqual(CloudAgentRouting.resultDelay(attempt: 0), 0.5)
    XCTAssertEqual(CloudAgentRouting.resultDelay(attempt: 10), 2)
}
```

再测：新能力缓存仍在、服务器只支持 v1 时，新动作只请求 `/v2` 并因404明确失败，不调用 v1；进入终态或任务取消后停止查询；旧无agent push按legacy展示，不根据当前绑定填充虚假源 ID。

- [ ] **2. RED。** 用原模拟器测试命令执行 AirSIMTests，新策略／编码断言应失败；不同时运行两个共用 DerivedData 的 Xcode 构建。
- [ ] **3. 实现。** AppModel 发起云端动作前快照目标；`boundCloudReady` 不再要求目标恰好是“最后心跳 Agent”，而是该 Agent 自身在线并支持定向。采用 v2 路径；请求失败不得自动回退 v1。结果查询0.5、1、2秒封顶，不新增常驻循环；每次请求与 sleep 前后检查取消和超时，终态立即退出。

```swift
body["target_agent_id"] = target.agentID
// waitForCloudCommand 的每次请求继续使用同一个 target 和 commandID。
try Task.checkCancellation()
try await Task.sleep(for: .seconds(CloudAgentRouting.resultDelay(attempt: attempt)))
try Task.checkCancellation()
```
- [ ] **4. 通话动作。** CloudCallControlClient 采用 v2 call actions；DTMF 使用锁定 call 的 agentID、UUID、generation，不能读当前选择。保持现有结束 tombstone 和异步代次保护，挂断后不复活页面。
- [ ] **5. GREEN。** 完整 iOS 130项基线加新回归通过；新文件加入主target及测试可见的源列表，不加入不需要 UIKit 的扩展。无签名 iOS/Watch 构建通过，不安装／上传。

### Task 7: Watch 及来电全链路归属

**Files:** Modify `iOS/AirSIM/WatchCallCoordinator.swift`、`iOS/Shared/WatchCallPayload.swift`、`iOS/AirSIMWatchApp/WatchCallSession.swift`、`iOS/Shared/AirSIMLiveActivityShared.swift` 中实际生成云端动作的部分；extend iOS tests。

**Interfaces:** `WatchVoIPCall.agentID: String?`，现有 WatchConnectivity reply／call payload 使用 `agent_id`；legacy 字段缺失仍可解码。新 Watch 呼出由 iPhone 在发起时决定唯一 `CloudCommandTarget`，回执与后续动作保存该快照。

- [ ] **1. 失败测试。** synthetic push 中 agent A 解码后传入 Watch；iPhone 选择改 B，Watch 挂断A／拒接A仍请求A的 call；延迟的取消拨号不会结束 B 的新通话。缺 agent 的旧 payload 不强填当前选择；本地 Watch PCM 行为保持。

```swift
func testWatchPushKeepsSourceAgent() throws {
    let payload: [AnyHashable: Any] = [
        "event":"incoming_call", "call_id":"synthetic-call-A",
        "call_uuid":"c87f982a-1750-4f03-9a96-6553e454f522", "agent_id":"android-A",
        "call_secret":String(repeating:"x", count:32),
        "media_url":"wss://relay.example/v1/calls/c87f982a-1750-4f03-9a96-6553e454f522/connect"
    ]
    XCTAssertEqual(try WatchVoIPCall(userInfo: payload).agentID, "android-A")
}
```

全部参数是仿真数据，不发送APNs，不访问媒体URL。继续覆盖 outgoingReply 和 usingLocalMedia 复制模型时不丢 agentID。

- [ ] **2. RED。** iOS tests 因模型缺字段／动作错误目标失败，而非因缺少必需测试媒体字段失败。
- [ ] **3. 实现。** 云端呼出回复追加目标，Watch 来电快照保留源；通话 UUID／generation 与 Agent 始终一同传递。灵动岛、Watch 动作优先使用 call 归属；本地／蓝牙动作不要求云端 Agent ID。

```swift
// WatchCallCoordinator 构造既有云端拨号 reply 字典时：
if let agentID = outgoing.agentID { reply["agent_id"] = agentID }
// WatchVoIPCall 的 userInfo 初始化器中，验证后保存可选源字段：
self.agentID = userInfo["agent_id"] as? String
```
- [ ] **4. GREEN。** iOS完整回归、Watch target 和 Live Activity target 无签名构建；真机 Watch 接听／停止响铃仍标记未验收。

### Task 8: 混合版本、完整验证与文档交付

**Files:** Update `push-relay-worker/README.md`、`android-standalone/README.md`、`android/phone-control-app/README.md`、`iOS/README.md`、`docs/AVF_INSTALL_GUIDE.md`、`README.md`、`LLM.txt`、`codex.md`、`claude.md`；create `docs/relay-agent-routing.md`。

**Interfaces:** 对外协议字段和错误码以任务1–7为准；测试不得调用维护者生产 Relay；不把本轮源码状态写成已经发布。

- [ ] **1. 新增混合版本失败测试。** Node测试场景矩阵：旧iOS＋单legacy可用；旧iOS＋A/B返回409；新iOS＋旧Relay返回404且零动作；新Agent＋旧Relay不静默回退；legacy旧队列不被A领取；A换卡后ID稳定；不同device同agent名字仍完全隔离。
- [ ] **2. RED→GREEN。** 若矩阵失败，只修复矩阵对应的路由边界，不扩展去修全部夜间500、网络媒体或其它已知待办。
- [ ] **3. 顺序运行完整验证。**

```sh
(cd push-relay-worker && npm test && npm run check)
./android-standalone/test.sh
(cd module/module-agent && go test ./... && go test -race ./...)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'platform=iOS Simulator,id=C61995AB-0BE5-4AA8-BD06-2E7AB8E58449' \
  -derivedDataPath /tmp/AirSIM-VoBLE-derived CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO test
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/AirSIM-VoBLE-derived CODE_SIGNING_ALLOWED=NO build
git diff --check
```

模拟器 UUID 必须先用本机设备列表确认仍可用；若变化只替换命令中的已验证 UUID，不创建／删除用户设备。Android测试会重建忽略的debug构建目录，不覆盖`iOS/build/candidate85`；本轮无发布产物要求。

- [ ] **4. 文档与隐私复核。** 说明 v2 / v1、唯一目标／歧义拒绝、旧配置需补配、心跳不变、部署顺序和回退限制。检索本轮新增日志，确认无 raw body、query URL、服务器任意reason或私密字段。既有diff保留；不暂存无关改动，不自动commit。
- [ ] **5. 完成前复核。** 依verification-before-completion流程核对实际命令退出码及新旧测试数，记录未执行的真机／生产步骤。按执行方式做最终审查；若使用独立只读审查，限制为本轮改动，不授权修改或部署。

## 自审与执行方式

设计中的连接隔离对应任务1；所有命令投递／完成路径对应任务2；通话固定和版本安全对应任务3；Standalone退避／取消对应任务4；旧AVF对应任务5；Apple目标选择／轮询对应任务6；Watch对应任务7；兼容矩阵与文档对应任务8。Review Focus五项均在所属任务有具体测试。

用户已确认，当前会话按 executing-plans 顺序实施；逐项测试与偏差决定记录在本计划对应的本地 ledger。本轮不创建额外实现任务，不自动部署、安装、提交或发布。
