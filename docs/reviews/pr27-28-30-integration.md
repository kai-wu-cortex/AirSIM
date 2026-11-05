# PR #27 / #28 / #30 集成评审（2026-11-05）

目标：在独立分支 `codex/pr27-28-30-integration` 处理冲突并合入 `develop`，不修改 `main`，不安装、发布或部署生产服务。

## 固定输入与已有工作

| PR | 评审时 head | 原目标 | 内容 |
| --- | --- | --- | --- |
| #27 | b36ed01059e3d2e26a648c1f0d4195e62bdf2957 | develop | Standalone 云端接收短信加密、注册字段白名单 |
| #28 | ec45fdaf81d9052be95c1a22e1e3b9ecd0e57908 | develop | iOS 配对协商、解密与 Notification Service Extension |
| #30 | fddc1fc0d1c6a2612069db75c37a8353f37200b6 | main（Draft） | 双卡信息、通话历史、推送身份、短信与最近通话交互 |

远程 develop 起点为 `ead7bf8`。原 develop 工作树的 Issue #20 / #26 音频与 VoBLE 生命周期修改先保存为 `518a8e4`，再建立独立集成工作树。原主工作树的未提交修改没有改动。

#30 基于较旧的 main，部分 API / 通话归属逻辑已随 #29 进入 develop，不能把整个 PR diff 当作新功能再次覆盖。保留当前设置页分层、已移除的冗余入口、固定展开的 Tab、字号、滚动优化和音频恢复逻辑。保留当前版本号，不采用贡献者本地 184 / 133 的构建号和历史验收声明。`docs-pr184.md` 是贡献分支原始记录，不代表本次集成的实机结果。

## 评审中修正的行为

1. **接听 ACK 不等于接通**：集成评审发现沿用的设备路由会在接听请求成功后直接进入 active。改为保留 connecting；只有认证通话事件确认 active 才计时和启动接通音频。PushKit→VoWLAN 接听分支同样处理。
2. **迟到终态隔离**：Standalone 网关只用对应 android_id 的 ended 结束当前通话。旧通话的终态不能结束新通话或重复写入历史。
3. **双卡与历史不丢字段**：最终展示、owned record、终结记录与生命周期转换保留 slot_index / slot_id / connected_at；缺失接通时间的旧记录不伪造通话时长。
4. **重复 PushKit 报告**：复用当前 CallKit UUID 处理相同会话的重复推送，仍向系统执行 reportNewIncomingCall，不对已有 UUID 补发 ended。单元测试验证报告次数、身份与不误挂断；实际后台 APNs/CallKit 仍需真机验证。参考 [Apple PushKit 要求](https://developer.apple.com/documentation/PushKit/responding-to-voip-notifications-from-pushkit)。
5. **加密失败禁止降级**：安卓已保存密钥损坏时中止云端短信上传；首次加密配对先持久化待完成标记，再发布注册，避免后台线程在注册与保存密钥之间发送明文。iOS 密钥写入失败向上传递错误，保留暂存钥匙供重试，不能显示加密配对成功；损坏/不可读密钥与无共享组的旧构建分开处理。
6. **测试冲突**：保留当前完整 call_id / call_uuid / generation 验证，删除 #30 与 #29 重复的测试类，更新模拟 Telecom 通话注册与真实 active 事件夹具，不放宽生产身份检查来迁就测试。

## 合入后的功能和兼容边界

- 安卓与 iOS 都更新、Relay `/healthz` 声明 `e2e_sms:1`、共享钥匙串可写，并重新完成云端配对后，接收的云端短信发送人、正文、验证码及 SIM 字段进入 AES-GCM 信封。AAD 绑定设备、Agent 和 delivery_id；Relay 只转发信封。
- 本阶段覆盖 **Android → iPhone 云端接收短信**；不代表 iPhone 发送短信、通话媒体、全部元数据或旧配对都已端到端加密。
- 新增 Notification Service Extension；正式签名须创建对应 `.notificationservice` App ID，主程序和扩展共享 `$(AppIdentifierPrefix)airsim.e2e-sms` Keychain Sharing。配置步骤见 `iOS/README.md`。本次无签名模拟器构建不能替代正式 provisioning / APNs 验收。
- 旧 Agent / 未协商加密的配对保留明文兼容；已加密配对异常不会主动降级。重新配对会换钥匙，旧钥匙加密但尚未送达的通知可能需要在 App 通过本地历史补齐。
- 最近通话按号码分组、保留每条源记录，支持未接筛选、分组详情/删除；回拨支持双卡选择且重新检查设备、SIM 与通话状态。短信支持正文搜索、验证码高亮/复制及紧凑操作菜单。
- 号码归属地只做离线号段估计，不改变拨出的号码或按 Apple ID 所在地区推断国家码。资源附来源、哈希和许可证。ls0f/phone 的 README/classifier 声明 MIT，但 setup.py 的独立 license 字段为 BSD；该上游元数据差异明确记录在 THIRD_PARTY_NOTICES，后续正式发布前建议向数据维护方核实。
- 当前 Worker 源码已有 E2E 信封与 mutable-content 转发能力，本次未修改 Worker 实现。`POST /api/calls/resolve`、历史确认接口已在 develop 的 #29 中，不是本次新增加的破坏性接口。新增 connected_at 等为可选字段；U30/其他 Agent 缺失时显示未知或不显示时长，不伪造信息。不要求 U30 同步实现 Standalone 专用的加密配对。

## 自动化验证

- iOS 全量单元回归：575 项通过，0 失败（包含加密协议向量、推送分类、双卡/历史/终态、VoBLE 及已有音频测试）。
- 随后补充密钥写入失败重试测试；LocalDeviceDirectory / E2ESMS 定向回归 58 项通过，0 失败。
- `sh android-standalone/test.sh` 全部通过，包含 Android 核心测试、PCM 桥构建、Standalone Debug 构建、云端通话、网关生命周期、拨号归属、纯本地出口和 E2E 测试。最后一次完整测试包含新配对待完成标记与迟到 ended 保护。
- Worker `npm test`：79 项通过，0 失败。
- iOS 27.2 Duo 模拟器 UI 回归：8 项最终全部通过。首轮 6 项通过、2 项因旧设置入口定位失败；改用当前 `settings.link.preferences` 并滚动到入口后，两项复测通过。覆盖最近通话筛选/详情/分组删除、短信搜索、验证码高亮/长按菜单、短信 SIM 选择、主题设置；未声称完成全部 Duo 折叠姿态测试。
- Notification Service Extension 的 Debug / Release build 号从 PR 的 152 对齐主 App 的 172；复测构建成功。
- 离线号码数据从固定上游源重新生成，`cmp` 与 PR 二进制完全一致；SHA-256：`53759e33d8c3787a89a922b2d1c145bcfebd509c895f7c3d5cf6c40761378131`。
- `git diff --check` 通过，无剩余冲突标记。

## 仍需手动验收

1. 更新两端并重新云端配对；后台/锁屏接收真实双卡短信，核对内容、卡槽、未读数与去重，检查 Relay 不出现正文/号码；重启后首次解锁、钥匙失配也分别验收。
2. 双卡分别拨入；核对 CallKit、应用内、通话详情的 SIM，一次未接、一通已接，检查记录和时长；模拟网络抖动后确认不产生第二个来电界面。
3. VoWLAN、VoBLE、云端分别接听/挂断；ACK 等待期间不提前计时；早期媒体、扬声器/耳机切换和原 Issue #20/#26 的音量取舍单独复测。
4. 多设备回拨、选卡后切换设备、通话中收到另一设备来电，确认不能串线；历史搜索/批量删除和大字体布局复测。

模拟器与 JVM 测试通过不等于上述真机场景已经修复。未发起真实电话、短信或录音，未发布 Release / TestFlight，未安装或部署。
