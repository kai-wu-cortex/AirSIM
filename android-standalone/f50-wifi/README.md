# F50 Pro 本地 Wi-Fi 配置页

为已安装 B28 Wi-Fi 客户端修复的 MU3356 提供独立于 AirSIM 的本地配网页面。iPhone 先连接 F50 原热点，在 Safari 中填写目标网络，Android 保存密码；点击“保存并重启”后，设备重启、关闭热点，只连接指定网络。无须云端、Tailscale 或 Mac 转发。

## 使用

1. iPhone 先连接 F50 Pro 原热点，在 Safari 打开 `http://192.168.0.1:8088`。热点名称和密码沿用原设置。首次无目标配置、或开机无法连接指定网络时，设备保持/恢复这个热点；后者需等待启动准备及最多 90 秒的连接尝试。
2. 输入**此页面独立的管理密码**。首次启动生成随机密码，保存在设备 `/data/local/f50-wifi/initial-access-code`，可通过已授权 USB ADB 读取。登录后可以更改密码。
3. 在“配置新 Wi-Fi”输入名称、加密方式和密码。热点模式不关闭热点去扫描，请手动输入；客户端模式才可扫描附近网络。
4. 点击“保存并重启”：先保存目标，再重启；系统运行满 60 秒且就绪后关闭热点连接目标；按下重启至联网还包含关机、引导和获取 IP 的时间。“仅保存，暂不重启”保持当前热点/连接，之后点击“重启并连接指定网络”或手动重启。选择已保存网络的“指定”也只保存目标，不立即切网。
5. 连接成功后，已配置的 AirSIM 云端功能可通过该网络联网。要再打开配置页，让 iPhone 连接同一 Wi-Fi，使用路由器分配给 F50 的 IP 加 `:8088`；支持 mDNS 的网络也可尝试 `http://f50wifi.local:8088`。
6. 目标网络不存在、密码不正确或未取得 IP/默认路由时，设备恢复原热点并一直等待重新配置；不会偷偷改连其他已保存网络，也不会因热点空闲自行关闭它。
7. “开机连接指定网络”默认开启。关闭后，下一次普通启动保留原热点；显式点击“保存并重启”或“重启并连接指定网络”会重新开启此选项。网络凭据由 Android 保存；目标按 SSID 与加密方式识别，避免重启后网络编号变化。

已经联网时，可在本页点击“切换到原热点”进入配网。带到陌生地点无法访问旧 Wi-Fi 时，重新开机，等待连接失败自动恢复热点，即可使用第 1 步入口。
支持 WPA2 Personal、WPA3 Personal 和开放网络。企业 802.1X、WEP、酒店网页认证不由此页面完成。路由器客户端隔离或阻断 mDNS 时，本地名称可能不可用；使用设备 IP，或原热点入口。页面使用本地 HTTP，应在自己的加密热点或可信局域网访问，不要将 8088 映射到公网。

## 自动连接与恢复

- 系统与地址保护就绪后显式开启原热点，避免原厂记住上次 STA 状态而跳过热点。开机至少等待系统运行 60 秒，且系统启动完成、地址保护已安装后才切换。地址保护只等待系统启动，不以 USB 配置或主机连接为前提，USB ADB 初始化脚本保持不变；条件未满足则延后，系统运行满 180 秒仍未就绪就保留热点。期间登录热点配置页就会暂停本轮自动切换，避免填写到一半断开；保存后需显式重启。
- 只启用指定的 Android Wi-Fi 配置，其他已保存配置保留但不参与自动选择。连接尝试 90 秒仍未取得 IPv4 和默认路由则恢复原热点。
- 已连接目标掉线超过 20 秒后只重试指定网络；重试失败同样回到热点，不循环抢走配网入口。
- 保存/恢复热点时记录当前启动 ID；同一次开机内配置服务重启仍保持配网，真正重启设备后才再次尝试目标。
- “切换到原热点”沿用原热点名称和密码，不切换 USB 模式。页面重启使用当前 shell 已有的 REBOOT 权限，不扩大权限；USB 会随整机重启短暂断开，启动后恢复。
- 服务崩溃由 init 重启。Wi-Fi 操作仅调用 Wi-Fi tethering 类型；不停止 USB tethering。
- 配置服务以 shell 用户运行。已有 root 命令保护阻止原厂 netd 清空 STA 地址；守护循环继续支持 AP/STA 切换，未替换 netd 二进制。

这并不保证电话卡语音、云端通话或任意酒店网络可用。界面“Wi-Fi 已连接”表示本地地址和路由就绪，不代表蜂窝语音或互联网已通过测试。

## AirSIM 控制桥的可选自启动

已安装 AirSIM 的 `BootReceiver` 启动 Standalone 云端前台服务；该 APK 的固定 loopback 控制桥之前需要额外启动。对所有者明确启用的设备，本组件可用同一 shell 身份自动启动这个既有桥接程序，避免每次重启通过 Mac 执行启动命令。不会安装/替换 APK、变更配对身份、请求新的 root 权限，或把内部端口开放到 Wi-Fi。

启用需要在私有数据目录同时提供：

- `airsim-autostart.enabled`：所有者配置的启用标记；默认没有此文件。
- `airsim-package-signer.sha256`：从当前已核验 APK 签名证书取得的 SHA-256。只允许固定包名 `com.airsim.phonecontrol.standalone` 且签名匹配的已安装 APK；不同签名会停止启动尝试。
- 设备原有的 `/data/local/tmp/airsim-bridge.token`：沿用既有凭据，不生成或轮换。首次启用后保存于私有目录的 `airsim-daemon.token`；若原厂清理 tmp，则以既有 0644 权限恢复同一文件，供原 APK 读取。私有副本保留在 0700 目录中。

监督线程与 Wi-Fi 控制线程分开：每 15 秒通过原 token 认证读取 loopback `127.0.0.1:27580` 状态；桥接进程退出后自动启动，失败重试至少间隔 45 秒。慢响应或现存进程不被强制杀死，不因健康检查中断通话。主 APK 仍通过自己的开机广播和 START_STICKY 服务启动，不依赖网页登录。

已登录的 `/api/status` 提供 `airsim_bridge` 的启用、健康、状态和本次进程启动次数，以及 `uptime_seconds` / `usb_host_state`，便于区分新一次开机、USB 调试配置与真实 USB 主机连接。这里只返回状态，不提供任意命令接口。

删除启用标记会停止后续监督，但不主动结束现有桥接或通话。完整回退时应在空闲状态结束既有桥接进程，再恢复更新前 runtime；保留原 token 和配对资料。升级已有服务时，必须同时核对启动镜像中的地址保护脚本：旧版要求 `sys.usb.state=ncm,mtp,adb`，仅替换 runtime 不能解除这项依赖。修复版等待系统启动完成，并保持原有固件摘要校验与 USB ADB 初始化不变。是否能在指定电源上完成整套启动，仍须实际“只接电源”验收；连接 Mac 时的重启结果不能替代它。

## 构建与部署范围

需要 JDK 17+、Android SDK platform 35 和 build-tools 35.0.0：

```sh
export JAVA_HOME=/path/to/jdk
export ANDROID_HOME=/path/to/android-sdk
./build.sh
```

输出 `build/f50-wifi.dex`，包含 HTML，不依赖 CDN、外部字体、远程脚本或另一个 APK。`build.sh` 同时执行输入校验测试。

`prepare-b28.py` **只生成候选镜像，不刷机**。它要求 SHA-256 严格匹配本次验证的既有 B28 修复镜像，替换三项 Wi-Fi 服务文件、加入一个 DEX，并验证其余 38 个 ramdisk 条目不变，包含 USB ADB 脚本、公钥、原 ifconfig 检查程序和 Wi-Fi 框架补丁。AVB 元数据 blob 保持原样；这是已绕过验证的特定设备环境，不是可签名的通用原厂更新。

```sh
python3 prepare-b28.py \
  --base /private/path/verified-init-boot.raw \
  --repack-tool /path/to/f50pro-MacOS-tools/bin/repack-init-boot.py \
  --out /private/path/candidate.raw
```

系统 PATH 需要 `lz4`。辅助 repack 工具来自 [f50pro-MacOS-tools](https://github.com/joker-skills/f50pro-MacOS-tools)。私人镜像包含设备所有者的 ADB 授权公钥，不应提交或随公开包分发。没有匹配镜像时工具会拒绝工作；不能拿其他型号、其他固件或旧工具箱镜像替代。

现场安装应先备份完整 `init_boot_a`，核对当前 SHA，写入后完整回读逐字节比对，并核对分区表不变。启动未通过时恢复该次写入前镜像。源码不含自动刷机命令，以免将机型限定的实验扩散到未核验设备。

### 已安装服务的 USB 更新

后续更新可将新 DEX 与 `SHA256  runtime.dex` 校验文件先写入 `/data/local/f50-wifi/` 的临时文件，核对摘要后原子更名为 `runtime.dex` 和 `runtime.sha256`，再结束 `airsim-wifi-config` 让 init 重启。只有摘要正确时才加载数据目录的新版，校验失败会使用镜像内版本。此更新路径以 shell 权限执行；不会获得额外 root 权限。回退可移走这两个更新文件并重启服务。首次安装启动服务仍需上述机型限定的镜像处理。

## 本地安全与诊断

- 管理密码使用随机盐的 PBKDF2-SHA256（120,000 次）；登录连续失败会暂时锁定。
- Cookie 为 HttpOnly、SameSite=Strict，8 小时到期；写操作验证 Origin、Host 和 CSRF。读取状态同样需要登录。
- Wi-Fi 密码通过 Android API 保存，不经 shell 参数、日志或状态接口回传。
- 私有配置目录权限 0700，服务日志轮换保留一份。USB ADB 始终是恢复入口。
- `adb shell cat /data/local/f50-wifi/service.log` 可查看服务启动情况。不要在公开报告粘贴凭据文件或 Android 完整 Wi-Fi 配置。
- 暂停下次开机自动服务可使用已有的 `/data/local/tmp/f50-wifi-autostart-disabled` 标记；某些固件开机会清理 tmp，必要时恢复已验证的启动镜像。

设备测试结论与尚未验证项见 [VALIDATION.md](VALIDATION.md)。
