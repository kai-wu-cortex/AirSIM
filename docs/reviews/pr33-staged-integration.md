# PR #33：按需求分三批整合

基线：develop 4a6cc37；来源：PR #33 a19a2ea（前置 #30 已合入）。

## 第一批：来电通知

- 保留号码与 SIM 信息；Android call-owner 增量字段向旧客户端兼容。
- 只有明确 incoming + ended + missed 才产生未接通知；已观察 active 优先，迟到 active 不恢复终态。
- Worker 去重隔离 device、agent、UUID、generation；iOS 清理通知不把缺少 agent 当作跨设备通配符。
- 本地历史发现新未接后等待 2 秒、查询已送达通知再兜底，不因云端开关开启而吞掉旧 Agent 的提醒。
- 晚到 APNs 的 Notification Service Extension 清理相同通话的本地提醒；保留短信端到端解密。
- 未接提醒不再次响铃。历史导入不补发旧提醒。

限制：APNs 投递与系统扩展执行是异步的；不能承诺两条通知在所有系统挂起/超时场景绝无短暂重叠。旧 Agent 缺少 agent_id 时保守不跨设备清理。原生 Android call_id 为不复用 UUID；没有代次的历史仅以明确设备 + 原生通话 ID 关联。

## 第二批：早期媒体体验

- 设置 → 来电与短信增加“运营商接通前语音”，默认开启，通话期间不可更改。
- VoWLAN/VoBLE/云端分别在通话身份建立时快照偏好。关闭后使用本地等待音，不提前开启双向媒体。
- 现有 EARLY_MEDIA 租约、AIRSIMRX01 内部握手、云端 U30Air early_media 兼容保持不变。
- VoWLAN 增加协商中/不支持/暂不可用提示，换通话、接通或结束时清理；BLE/云端复用现有能力反馈。
- 首个下行音频到达才停止等待音。仍不提前标为 active 或开始计时。


## 第三批：安卓隔离

- 吸收 PR 的“挂断期间避免本机短暂漏音”和路由变化后重申输出策略需求。
- 原生 Telecom 已确认 DISCONNECTING/DISCONNECTED，且此前只有这一通认证远端通话持有输出策略时，最多延续 2 秒；onCallRemoved/服务销毁立即释放。
- 普通 PCM/VPN 断线不视为挂断，立即恢复安卓接管；另一通原生通话出现时取消延续；重复终态不延长超时。
- Route 改变仅重申既有策略，走共享 Root/Shizuku coordinator。保留 preserve_volume / minimum_nonzero_volume 和手动音量，不更改 PCM gain 或全局麦克风。
- 不吸收未经机型验证的全局 microphone mute 与所有设备强制物理输出 index=0。当前没有证明它们独立于通话采集的硬件证据；已有 UI 会说明保留采集音量与本机漏音的取舍。

边界：如果远端先关闭媒体、而挂断命令及 Telecom 终态尚未到达，该窗口仍按“链路丢失”恢复本机声音。不能把所有网络断线都持续静音，也不能宣称本轮实现了所有机型完全无声。此后可在明确通话身份的挂断意图协议及机型能力证据基础上继续优化。


## 不合入

仅 VoWLAN 限制、第二套早期媒体租约/内部握手、作者构建号、旧设置页，不覆盖现有多模式、纯本地模式、E2E 短信与音量保留策略。

## 协议与协同上线

接口和认证不变。`/v2/events/call` 增加 `slot_index`；`/v1/events/call-owner` 可选增加 `agent_id`、`direction`、`number`、`slot_index`、`timestamp`、`missed`，原有 call_id/call_uuid/generation/owner/phase 保持。

- `missed=true` 必须来自设备端终态，不能由 Relay 根据“没有 active 请求”猜测；新 Android Standalone 转发原生事件事实。
- Worker 对 iOS 转发 `notification_status`（answered/ended/missed）和源设备身份。短信 payload/加密/认证保持原样。
- U30Air 不必为兼容旧接口强制升级；如需云端未接提醒及 SIM 信息，设备线程应补发上述可选字段。缺少字段时只发原有后台所有权事件；iOS 能同步到带来源的明确未接历史时仍可本地兜底。
- Worker 的观察记录沿用现有存储降级能力，不是跨请求分布式强一致事务；在存储故障/并发重试时不能承诺 APNs 恰好一次。设备事实与 iOS/扩展去重共同防护。
- 建议后续先部署兼容 Worker，再安装客户端；本轮没有执行生产部署、设备安装、Release/TestFlight，未向其他线程发送任务。

## 自动化验证

- Worker：`node --test push-relay-worker/test/*.test.mjs`，80 项通过，包括旧字段兼容、代次/设备隔离、重复终态、迟到 active、接通过的来电不报未接。
- iOS：iOS 27.2 Duo 模拟器 AirSIMTests 全量 582 项通过（0 失败）；此后通知异步提交竞态及呼出专属状态文案收尾，最终重跑通知/偏好/所有传输定向 19 项通过。
- 定向组合包含通知身份、偏好、真实 BLE 协调器禁用早期媒体、所有通道早期媒体、租约、Relay 出口控制，29 项通过。
- Android：phone-control-app/test.sh 全套通过，包括既有 Root/Shizuku 音量策略、E2E、早期媒体 TCP 集成；新增尾段状态机覆盖 3 传输的超时、重复事件、网络断开、多通话、更换身份及销毁。
- 最终音频定向回归：真实 InCallService + 控制器的 21 个模拟场景通过，包含路由重申时保留手动采集音量。
- Standalone Debug 完整构建通过；iOS App 与 Notification Service Extension 随测试构建通过；git diff --check 通过。

## 待用户实机验收

1. 每台设备/每个 SIM：未接、接听、拒接各一次；核对号码、SIM、旧来电提醒清理和通知数量。测试先本地后 APNs、先 APNs 后同步、断网和旧 U30Air。
2. 三模式分别拨号：开启/关闭运营商接通前语音；确认真实音频、等待音切换、接通前不计时、不上传麦克风，接通后双向通话与扬声器正常。
3. 三模式下本机音频：远端挂断、普通断网重连、安卓手动接管、原生通话未移除、第二通来电；检查 2 秒上限和音量恢复。
4. Root/Shizuku、保留采集音量/最低非零音量分别检查，尤其 Pixel 6 和采集受音量影响的设备。未验证的独立物理输出/全局麦克风静音不开放。

模拟器/JVM/构建通过不等于上述实机验收已完成。没有发起真实电话、短信或录音。

## 2026-11-08 iPhone 本地安装

- 用户决定保留最低 iOS 16.3，要求先安装真机测试。以 develop `10cdd49` 为基线构建本地开发签名 0.9.8（173），版本号仅由仓库外 xcconfig 覆盖。
- 安装前二进制检查发现新增未接提醒的 Date `>=` 比较再次引入 162 崩溃涉及的运行时符号；已改为等价的时间戳比较，保留相等边界。最终构建、深度签名、12 个 Mach-O 的 Date 导入检查通过。
- iPhone Air 保留数据覆盖安装成功，设备查询确认为 `com.eric3u.airsim / 0.9.8 / 173`，启动命令成功。APNs 为开发环境 sandbox。
- 本次未更新 Android、U30Air 或生产 Worker，未发布 Release/TestFlight。完整通知协同及 Android 输出尾段仍需相应端更新后联测；真实电话由用户手动验收。

## 2026-11-08 联测部署进展

- 用户随后授权更新 Android Standalone 和 Worker，安卓目标为红米无线调试。
- Worker 80 项测试、dry-run、所需 Secret 名称检查通过，部署前版本 `b7820f4f-831b-411c-b433-f2c6a5c19270`。
- `airsim-push.remotepilot.site` 已部署 develop `10cdd49` 的 Worker，版本 `02b98446-59ff-4d25-ba3d-b24a732116b4`，部署列表确认 100% 流量，公网 `/healthz` 返回 `ok:true`。现有 KV/DO 绑定和 Secrets 保留。
- 最新源码重新构建 Standalone Debug 成功，包名 `com.airsim.phonecontrol.standalone`；沿用 0.9.8.23（128）版本字段，因此不能仅凭版本号与之前产物区分。APK SHA-256：`94e958ccd61e6cf27843f716a798ae7b2a760a3bf3fb16fc28b027e8940f1687`。
- 红米无线调试连接恢复后，确认旧 Debug 包构建号 132、证书与本机 Debug 密钥一致。为避免降级，使用仓库外 Manifest 构建 0.9.8.23（133）；包 SHA-256：`ad2f2b831b9ea3f2c8e04cfc8d6c6daeb5c68287f34b4251a505a5c932655356`。
- 已通过 `adb install -r` 在 Redmi 9（M2004J19C）保留数据覆盖安装成功，包版本查询确认为 133，MainActivity 启动成功、应用进程存在。未卸载或清除配对数据，真实双向通话及通知仍由用户联测。
- 未更新 U30Air、独立 AVF Agent 或阿里云 Relay；未发起真实通话、短信或录音，未发布 Release/TestFlight。

## 2026-11-08 阿里云 Relay 同步

用户随后授权阿里云同步更新。实例 `i-bp1gixcvkyfkg57m95w1`（杭州）的 AirSIM Relay 已更新为相同 develop `10cdd49` 业务源码，公网地址仍为 `https://118.178.109.247`。

- 新运行目录：`/opt/airsim-relay/releases/20261108-pr33-10cdd49`；`current` 已切换。保留旧目录 `20261103-2` 可回退。
- 原生 workerd、Node、自托管运行适配器、配置、数据目录及 DO namespace 保持原有版本/路径。同步全部 7 个业务模块并逐一校验 SHA-256，另更新 smoke 脚本；源码传输包 SHA-256：`8603cec0a1d9a40c64ef393c07f715e41a6e7a935353b3b90f1d1f422c1e8525`。
- 仅停止/启动 `airsim-relay.service`。旧进程退出触发既有 15 秒 TimeoutStopSec 后被 systemd 终止，备份在进程完全停止后执行，包含完整 SQLite/WAL 目录和配置，权限 0600：`/opt/airsim-relay/backups/20261108-pr33/state-and-config.tar.gz`。切换期间公网短暂返回 502，随后恢复。
- 配置文件 SHA 校验不变；AirSIM APNs、HTTPS 与 AirSIM Cloud Relay/APNs/HTTPS/TURN 的 PID 均未改变，最终状态均 active。
- 自托管 5 项测试通过；服务器内及 Mac 公网 HTTPS/WSS 合成测试均通过：健康、Dashboard 未授权拒绝、注册、心跳、设备鉴权、拨号命令去重、双向二进制 PCM。两轮合成注册均已清理，未向真实设备拨号或推送。
- Apple production/sandbox TLS 验证及 HTTP/2 协商通过（无认证请求返回预期 405）；这不代表真实 APNs 投递已验收。公网 IP 证书正常有效，到期时间 2026-11-14 23:18:49（北京时间）。
- 既有 Notion 凭据仍缺失，手动反馈上传仍受此限制；未打印或改动秘密。真实通话、锁屏推送、SIM 通知与音频质量待用户测试，两端需使用同一个 Relay。
