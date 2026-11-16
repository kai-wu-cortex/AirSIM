# F50 Pro 本地 Wi-Fi 配置页

为已安装 B28 Wi-Fi 客户端修复的 MU3356 提供独立于 AirSIM 的本地配网页面。iPhone 在 Safari 中添加、选择或移除网络，Android 保存密码，开机尝试上次选择的网络，再尝试其他已保存网络。无须云端、Tailscale 或 Mac 转发。

## 使用

1. iPhone 与设备连接同一 Wi-Fi，打开 `http://f50wifi.local:8088`。也可用路由器分配给设备的 IP 加 `:8088`。
2. 没有可用网络时，等待设备恢复原热点，iPhone 连上该热点，打开 `http://192.168.0.1:8088`。
3. 输入**此页面独立的管理密码**。首次启动生成随机密码，保存在设备 `/data/local/f50-wifi/initial-access-code`，可通过已授权的 USB ADB 读取。登录后可以更改密码。
4. 在“连接新网络”扫描或手动填写名称、加密方式和密码，点击“保存并连接”。设备会关闭自己的 Wi-Fi 热点并加入目标网络；让 iPhone 也连接目标网络，再打开本页。
5. 保持“重启后自动连接已保存网络”开启。网络凭据由 Android Wi-Fi 服务持久保存；选择按 SSID 与加密方式识别，避免 Android 重启后网络编号变化。这个选项和上次选择保存在 `/data/local/f50-wifi/settings.json`。

支持 WPA2 Personal、WPA3 Personal 和开放网络。企业 802.1X、WEP、酒店网页认证不由此页面完成。路由器客户端隔离或阻断 mDNS 时，本地名称可能不可用；使用设备 IP，或原热点入口。页面使用本地 HTTP，应在自己的加密热点或可信局域网访问，不要将 8088 映射到公网。

## 自动连接与恢复

- 开机等待系统运行至少 160 秒，保留已验证的 B28 热点优先启动顺序和 USB 初始化时间。
- 优先尝试上次选择的网络，35 秒后允许其他已保存网络，90 秒仍未取得客户端 IPv4 和默认路由则恢复原热点。
- 连接掉线超过 20 秒时尝试已保存网络；热点状态至少保持 5 分钟，且最近 2 分钟没有已登录页面活动时再重试。
- “切换到原热点”可恢复原厂热点名称和密码；不切换 USB 模式。
- 服务崩溃由 init 重启。网络操作只调用 Wi-Fi tethering 类型，不停止 USB tethering。
- 配置服务以 shell 用户运行。已有 root 命令保护继续阻止原厂 netd 清空 STA 地址，守护循环保持运行以支持反复 AP/STA 切换。未替换 netd 二进制。

这并不保证电话卡语音、云端通话或任意酒店网络可用。界面“Wi-Fi 已连接”表示本地地址和路由就绪，不代表蜂窝语音或互联网已通过测试。

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
