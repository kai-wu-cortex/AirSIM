# 验证记录

本组件只针对一台已经安装 Wi-Fi 客户端和 USB ADB 修复的 MU3356 B28。以下结果不外推到原厂固件或其他型号。

## 本地构建与界面

- JDK 21、Android SDK 35、D8 min-api 34：编译成功；PortalRulesTest 通过。只见 javac 模块路径和已弃用 API 提示。
- 真机 HTTP 服务：登录、未登录拒绝、Host/Origin/CSRF、非法 SSID、密码不回传、扫描均通过；重复请求头和无效 JSON 返回错误而不结束服务。
- 真实设备页面在内置 WebKit 浏览器的 390px 手机视口和 1280px 桌面视口检查通过，无横向溢出。扫描、登录、超长名称错误反馈经过交互验证。
- 独立界面 reviewer 对“显式动作反馈可见”和“触控区域”两项修正均评为 resolved；该 verdict 不包含硬件行为。checkbox 标签实测 48px，窄屏行按钮至少 44px。
- 用户 iPhone 真机 Safari 的亲手操作尚未确认；手机视口不冒充实体 iPhone 验收。

## 设备结果

- 已在设备安装：`init_boot_a` 每次写入前完整备份，写后 8 MiB 逐字节回读一致，83 项分区表前后一致。最终启动镜像 SHA-256 为 `a53bbab13fcbe5d7fd5696268c3c4838ff7b55150ad6d42077b27295b9eae4b6`；最终 USB runtime SHA-256 为 `96160a0137f00da59ee23a9af1fc3776b94eb6f303413ba019bc6edc7009d1f1`。
- 保存并连接第二个 WPA2 测试网络，取得不同 IPv4；公网 4/4 ping 成功。修正后的一次启动在系统运行约 170 秒自动连接该测试网络并取得地址和默认路由。
- 随后执行普通 `adb reboot`：USB ADB 约 49 秒恢复，配置服务自动加载数据目录校验通过的 runtime。它先尝试上次选择的测试网络，该轮未及时取得 DHCP 地址，随后自动改连另一已保存网络，在约 4 分钟内恢复地址和路由。不能将这轮写成测试网络 DHCP 始终稳定。
- 手动恢复原热点后 hostapd 已运行，本地配置入口 HTTP 200；随后可重新加入已保存网络。全过程未切换 USB 模式，ADB 可读写。
- 临时路由器测试 AP 已关闭，原无线配置逐字节恢复；仅移除了本轮新增的测试网络配置。
- 当前网络已通过 `/system/bin/ifconfig wlan0 0.0.0.0` 命令保护回归：返回成功、地址保持不变。局域网配置页 HTTP 200，管理密码与自动连接选择在重启后保留。AirSIM 云端心跳重新在线，未测试真实电话。
- 最后绑定 wlan0 连续探测公网 120 次，120/120 成功、0% 丢包，覆盖约 119 秒。该有限时间窗口不代表全天稳定性。

## 发现并修正的问题

- B28 的 shell Context 仍保留 `android` AppOps 身份：显式使用 shell 的 op package 和 AttributionSource。
- 无头进程通过 Settings ContentResolver 写 `wifi_on` 被拒绝：改用设备已支持的 `settings put global wifi_on 0`，不在命令参数里传 Wi-Fi 密码。
- Android 重启会重排 networkId：持久选择改为 SSID 和加密方式，在开机连接时重新解析编号。
- PSK/SAE 过渡网络重复返回同一编号：列表按 networkId 去重。
- Android API 只移除 SSID/密码的外层引号：保留内部引号和反斜线，不套用 shell 转义。对应 [AOSP NativeUtil](https://android.googlesource.com/platform/packages/modules/Wifi/+/refs/heads/android15-release/service/java/com/android/server/wifi/util/NativeUtil.java) 的字符串契约。

## 验证边界

尚未验证 WPA3-only、企业网络、酒店网页认证、全部已保存网络都不存在时的真实 90 秒超时流程、全天运行、断电后恢复或 DHCP 长租约。恢复热点函数已由实际手动切换验证；不能把它写成上述所有场景均已验证。

mDNS 响应已分别通过 USB 与 Wi-Fi 的单播查询；实际路由器路径上的多播查询超时，不能保证每个路由器允许本地发现。设备 IP 加 8088 是直接访问入口。该页没有云端访问接口。

无本组件公开 release；CI 状态以对应 PR 实际结果为准。未发起真实电话或短信。
