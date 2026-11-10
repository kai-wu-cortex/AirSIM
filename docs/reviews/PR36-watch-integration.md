# PR #36：选择性整合记录

来源：[PR #36](https://github.com/kai-wu-cortex/AirSIM/pull/36)，
`a5a85b71e016003b43b920539848b97e046d5961`。
整合基线：develop `2ec974d`。不直接合入原稿的 117 个文件。

## 采用内容

1. **Watch 来电状态同步**：保留通话 UUID 身份约束、结束墓碑、迟到媒体回调隔离、其他设备接听后停止 Watch 响铃；接听 ACK 与真正 active 分开。挂断显示“已提交”与“安卓已确认”两种结果。
2. **安全直连 VoWLAN**：重写 PR 的鉴权设计，使用 Watch v2 限权控制密钥、精确 agent/call/UUID/generation、独立每通电话媒体授权。普通 PCM 不接受 Watch 派生密钥；过期、重放、错误身份、取消设备端配对及终态均拒绝/关闭媒体。接听结果不确定时不跨通道重复执行。
3. **Watch 短信**：复用 iPhone 现有消息存储、解密结果和发送 API；按设备与号码组织会话，查看详情/标记已读、选择 SIM 回复。发送意图持久化去重；超时显示结果不确定，不自动重发。通话优先。回复需要对应设备的已认证 VoWLAN API，当前不添加 Watch 独立云端短信发送。
4. **重叠内容核对**：保留 develop 已有短信 E2E、通知扩展、早期媒体、云端缓冲、安卓音频隔离、机型适配、#34 服务启动门控及 #35 HONOR 修复。未引入 PR 的全局麦克风静音、PCM 丢失后永久保留静音、系统铃声接管；未覆盖 iPhone 设置和小组件。移除草稿中强制关闭 Watch 云端媒体的 plist 开关，保留既有云端路径。

协议和固定跨语言测试向量见：
[Watch direct v2](../protocols/watch-direct-v2.md)、
[签名向量](../protocols/watch-direct-v2-vectors.json)。

## 兼容边界

- 新入口仅允许私网 HTTP（含 Tailscale IPv4），原 iPhone API、AIRSIMVWL1、云端、BLE、TLS 和 early media 不变。
- 旧网关不支持 v2，或没有可信通话 tuple 时，在任何直连接听写入前回退 iPhone 协作。
- 当前 Standalone/U30Air 的完整 tuple 来源于来电 push descriptor。纯本地无此 tuple 时仍依赖 iPhone 协作，不能承诺锁屏下必定独立接听。将来支持原生本地 tuple 需要独立协议。
- 已发起 direct answer 后，失败/超时不得改走另一通道重新接听。
- grant 的 60 秒是附着窗口，不是正常通话时长；已建立流最长 4 小时。超过附着窗口后断网重连需要明确的新交接，本次不静默续签。
- 设备端父配对删除/重置可撤销活跃授权。只从 iPhone 移除设备不等于已通知网关删除父密钥；跨端取消配对 UI 不在本次实现范围。
- 查询失败不能被解释为已挂断，也不能将另一通电话的状态用于结束当前电话。

## 自动化验证

- iOS 与 watchOS Simulator 构建通过；iOS 单元/界面测试目标 `build-for-testing` 通过（不是 XCTest 运行结果）。
- Watch 策略/短信/身份/跨语言向量：335 项断言通过。
- 实际 Watch PCM transport 的本机回环：155 项断言通过，包含 v1/v2 握手、迟到/无效/分段 ACK、取消及生产重试预算。时延数据仅代表本机 mock。
- Android Standalone 完整测试与 Debug APK 构建通过，包含旧拨号、云端、短信加密、纯本地、服务启动等回归。
- 新 Watch 网关：68 项检查通过，覆盖用途密钥、tuple、重放、幂等授权、过期、父配对撤销和迟到挂断。
- 实际 Android PCM TCP 入口：18 项检查通过，覆盖双向字节、重复握手、互斥、撤销/终态/tuple 变化关闭、新通话复用，以及普通 PCM 拒绝 Watch 控制密钥。
- `git diff --check` 通过。

未安装、部署、发起真实电话/短信或发布版本。构建版本号保持不变。

## U30Air 协同

用户授权后已通知“修复插件通话无声音”线程同步支持。
该线程在 U30Air 的 `codex/pr36-watch-support` 分支完成本地提交 `c7bdc00`，
未 push/安装/发布。其报告：插件与固定 Agent 基线 race/vet、30 项 Node、
同一组跨语言向量、Linux ARM64 构建通过。详见该仓库
`docs/WATCH_DIRECT_V2.md` 和 `docs/reviews/PR36_WATCH_V2_ASSESSMENT.md`。
设备侧 AT/基带状态采样延迟仍须真机测量，不把轮询间隔等同端到端撤销时延。

## 用户后续真机验收

- 同一私网，iPhone 锁屏，Watch 接听：双方轮流说话，计时仅在确认接通后开始。
- iPhone 先接听：Watch 收起来电，iPhone 通话不被挂断；再测试重复/迟到通知。
- Watch 挂断、对端挂断、连续两通不同电话：无旧提示/音频串入新通话。
- 旧版安卓/旧 U30Air、纯本地无 push tuple：保留协作路径，准确说明不可用原因。
- 通话中断网、设备端撤销配对：旧媒体关闭；普通本机接听/音频恢复不回归。
- iPhone VoWLAN、VoBLE、云端及运营商早期语音分别回归。
- Watch 短信会话、SIM 选择、未读标记、锁屏 iPhone 回复；发送不确定时不自动重发。
