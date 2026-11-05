# Root / 自动模式的 PCM 反复重启修复

2026-11-03，VoBLE 工作树未发布改动。保留同一工作树中的 Agent 自动检测功能。

## 已确认原因

Redmi 9 的只读进程与日志检查发现两个 `RootBridgeMain` 服务同时存活，各自维护 PCM 子进程。约每 1.3 秒出现 `stopping stale PCM bridge` → 对方 `PCM bridge exited code=137 restart=true` → 重新启动。不是单纯页面显示闪动，也不能据此认定 MediaTek 音频接口不兼容。

旧实现存在四个相互叠加的问题：

1. 关闭 Root 传输只结束启动它的 `su` 进程，不能保证其 shell / `app_process` 子进程退出。
2. Root 服务没有绑定 App 的生命周期，App 重启后旧服务仍会自动重启 PCM。
3. 从 Shizuku 切换 Root 只清除客户端引用，旧 Shizuku daemon 仍可能维护自己的桥。
4. “清理旧 PCM”只按本应用与端口识别，没有跨进程所有权保护；两个服务把对方的桥都当作旧进程清除。

## 修改行为

- Root 增加带现有 token 认证的 shutdown，请求完成前停止自己的 PCM 子进程。应用私有租约文件用于关闭请求失败时的退出信号。
- Root 监视所属 App 的 PID **与进程启动时间**，防止 PID 被复用；App 退出或租约移除后停止服务。租约位于应用私有、不参与备份的目录，避免缓存清理导致通道意外退出；正常退出清理文件。
- 新 Root 启动时只迁移同包名、同用户缓存路径、精确旧参数格式的旧版 Root supervisor。先停止 supervisor，再由获得 PCM 所有权的服务清理剩余 PCM；不选择新协议 helper、Shizuku 或其他应用。
- Root 与 Shizuku 在清理或启动 PCM 前必须取得同一应用的抽象本地 socket 所有权；占用时失败，不杀另一持有者的桥。
- 退出设置不可逆停止状态，阻止迟到的进程退出回调重新启动 PCM。子进程停止、音量恢复后才释放所有权。
- Root 已连接或正在启动时不重复启动。自动模式启动阶段优先 Root，失败后回退 Shizuku；仅 Root 不静默回退。
- 权限选项在注册 Shizuku sticky 回调前初始化；连接结果和通道切换在同一 worker 串行处理，并通过代数拒绝旧选择的迟到结果。
- 切换 Root 会真正移除本应用的 Shizuku 用户服务；切换 Shizuku 会先关闭 Root。短暂释放所有权期间的 Root 启动进行有界重试。

这次不改变 PCM 采样格式、拨号、配对密钥或 Relay 配置，也不宣称修复了 Redmi 9 的实际双向语音兼容性。

## 验证

新增自动化测试：

- Root 生命周期与选择策略：精确旧 helper 识别、其他用户 / 应用排除、新协议 helper 不被迁移、进程启动时间与 PID 复用、重复启动、Root-only、Auto 回退与迟到结果。
- 直接测试 `ShizukuBridgeUserService` 的所有权与关闭：第二个 supervisor 无法进入 PCM 清理 / 启动；关闭只结束自己的子进程一次；释放后允许新 owner；迟到退出回调不能复活旧桥。使用模拟 OS socket / 进程，不进行电话或录音。
- 完整 `sh android-standalone/test.sh` 包括原有音频、权限、短信、纯本地模式及 Standalone APK 编译；保留已有弃用 API 警告。

实际结果：完整 Standalone 回归通过；Root 识别 / 选择策略 26 项断言通过；最终补充的所有权和排队重启竞态共 9 项断言通过。最后再次构建 Standalone Debug APK 通过，`git diff --check` 通过。测试包不是正式签名发布包，未覆盖手机中的 Release 安装。

本轮尚未安装修复包或改变手机当前权限选择。实机待验收：

1. 空闲时从仅 Shizuku 切到仅 Root，观察至少 60 秒，只保留一个 PCM supervisor / 桥进程，日志无交替 kill / restart。
2. 切到自动，Root 正常时不重复创建；Root 不可用时回退 Shizuku。
3. 快速切换三种选项，最终通道与最后一次选择一致。
4. 结束并重新打开 App，旧 Root 服务退出，新服务稳定接管；首次升级旧版本残留服务可被限定范围的迁移清理。
5. 用户手动测试通话、挂断和音量恢复；不把模拟测试通过当作真机通话已修好。


## 2026-11-04 实机补充与 Debug 128

Debug 127 已按用户授权卸载原正式包后安装。实机日志确认 Root 授权后成功启动 PCM，两个旧 Root supervisor 被迁移清除。用户随后选择仅 Shizuku，Root 正常退出，PCM 退出记录为 `restart=false`；此时不应继续显示 Root 已连接，也不需要两个权限通道同时在线。

Shizuku 主服务在线（v13、UID 0），但其 AirSIM 用户服务在 30 秒内未启动，未收到连接回调。原界面因没有等待期限而一直显示正在启动。当前没有足够证据认定其底层启动失败原因。

Debug 128 增加 35 秒绑定期限、明确失败提示和手动重试；超时不循环创建服务。移除用户服务时同时清除 Shizuku SDK 的客户端连接缓存，避免重试复用旧回调；通道切换、旧定时器、迟到连接通过尝试编号与通道代数隔离。首页权限通道按实际 Root / Shizuku 连接显示，设置页持续刷新。

完整 `sh android-standalone/test.sh` 通过，新增绑定期限测试 12 项断言通过，`git diff --check` 通过。Debug 128 已通过 `adb install -r --no-incremental` 覆盖 127，保留数据；核对版本 `0.9.8.21-redmi9-debug (128)`，冷启动成功。实机新进程记录 `shizuku_user_service_bind_timeout`，证明等待期限生效，但 Shizuku 用户服务仍未启动。此次保留用户选择的仅 Shizuku，没有擅自更改为 Root。

建议此机暂用已成功启动的仅 Root；尚需用户手动验证 MTK 双向通话。此次未拨号、接听或录音，未发布 Release。


## 后续根因确认

2026-11-04 已证实本机 Shizuku 13.6.0 的 `LoadedApk.makeApplication` 空指针发生在 AirSIM 服务构造之前。按用户授权原位降级官方 13.5.4 并重启后，实际 Shizuku 连接及 PCM 启动成功；无需切换 Root。Debug 129 已覆盖安装。此前“底层原因未明 / Shizuku 仍未启动”的记录由本次结果更新，详见 [Redmi 9 实机记录](android-redmi9-pcm-adaptation.md#2026-11-04-shizuku-启动根因与-debug-129)。双向通话仍需人工验收。
