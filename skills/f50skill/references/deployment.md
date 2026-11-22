# ADB 已通：保留数据部署

所有源码路径相对已核验 AirSIM checkout。读组件 README、VALIDATION.md 和修改涉及的源码。

## 候选与备份

记录 APK 路径、版本、SHA-256、证书。旧机备份 APK、配网目录及能读取的配对 shared_prefs；run-as 被拒绝时不能宣称已备份，也不清数据/换包来取得权限。签名、密钥、token 留在受限目录。主 APK 同号修订仍以摘要区分。

不要直接跑旧 `install-f50pro.sh` 做成品升级：它默认 TCP 5555、可能杀桥接和重生成 token，且不安装全部自启动/酒店路径。逐项使用已核验的 USB 目标，老机沿用身份。

## Wi-Fi 与独立电源

B28 原厂限制客户端且 netd 清 wlan0 IP。仅 cmd wifi connect-network、循环补 IP 不是最终修复；核对 Wi-Fi 框架补丁、定向 ifconfig guard、wlan0/br0 解绑和 init 服务，不整体替换 netd。

旧 `codex-f50-wlan-bridge.sh` 等待 USB ncm,mtp,adb 导致充电器启动失败。已验证方案等待系统启动完成、保留 USB 初始化；仅更新 DEX 无法修复旧 boot 脚本。框架、netd、guard 摘要保护必须保持。

首次安装 boot 组件走 bootstrap 路线。已有完整组件只更新覆盖 DEX：JDK 17+（验证用21）、SDK35、D8 构建 f50-wifi/build.sh 并运行测试；备份旧 runtime.dex/sha256，写 `.next`、读回，清单为 `SHA256  runtime.dex`，匹配后原子更名；空闲时只结束目标 airsim-wifi-config 让 init 恢复。错误摘要会回退内嵌版本，确认真正加载路径，不顺带重启主 App。

## AirSIM、默认电话与 PCM

F50Pro-AirSIM 兼容 Standalone 与音频桥按仓库构建。已有 APK 核对同证书后 install -r，不卸载或清数据；新机确定自己的签名并保留。

F50 可能缺 ROLE_DIALER，用设备支持的 `cmd telecom set-default-dialer com.airsim.phonecontrol.standalone` 并读回。它是运行态 override，会在重启丢失，所以还需默认电话监督。iPhone 弹“三星默认电话”可能是安卓端角色缺失，不是要求改 iPhone 电话设置。

App BootReceiver/START_STICKY 与 shell 127.0.0.1:27580 PCM 控制桥是两个启动环节。新机独立生成 token，旧机沿用；不要暴露内部端口。根据安装证书写 airsim-package-signer.sha256，再开启私有目录里的 airsim-autostart.enabled、airsim-default-dialer.enabled。默认电话监督保留用户其他默认应用。桥 token 与私有持久副本一致，不把启动成功等同于声音正常。

核对 VoLTE 属性、每卡 IMS 和真实语音，设置属性不是运营商授权。候选应包含 Telecom 锁反转、去电媒体确认、远端挂断带 call_id/call_uuid/generation 的 ended 修复，不能把普通断网当对方挂断。

## 双卡

独立构建/签名 dsds-helper（包 com.airsim.f50dsds），不替换主 APK。按组件文档 grant WRITE_SECURE_SETTINGS，先只读 `content call --uri content://com.airsim.f50dsds --method status`。支持固件、实际证书 pin 匹配且用户要求保持双卡时，写 dsds-helper-signer.sha256 与 dsds-keep-enabled。

监督器空闲时 shell 写 car_mode_dual_sim_switch=1，再由 Provider 通知原厂观察器，延后副卡无服务约60秒关闭；不循环写0或关闭重开。源码默认关闭不构成对已授权用户反复询问理由。

核对两个实体卡，不把内置 CU 46006 当用户实体卡。Android slot/subId 与原厂 SIM1/SIM2 不可机械对应，使用脱敏身份和原厂选卡对照。保持、识别、注册、IMS、实际语音分开验收。

## 云端与配对

使用用户当前自有 Relay/签名 App；家庭现有服务在 GCloud，不自动改回 DMIT/作者 Relay 或加 Tailscale。以当前私有配置核验域名、Team、Bundle ID、production APNs，不能借作者签名凭据完成自有推送。

iPhone 确认打开正确 App，关纯本地、开云端通知、选云端及正确 Relay。HTTP400 先检查 App/Bundle ID，不放宽服务器身份限制。注册通过但无 Agent 常需重新加密配对传递云端身份。

手机准备好才触发 request-pairing.flag，读取实际端口、六位码与到期时间，马上交付；不沿用旧码、不写摘要文档。若直连网关受限，可以按授权用受限 Mac 临时转接配对，结束关闭。保存配对与网关验证是两回事；最终 iPhone 4G/5G 云端验收时必须无 Mac 转发。

每新机独立 Agent ID、配对密钥、显示名；云端查询匹配目标，不用另一台在线替代。自动模式可能保留旧本地选卡，日常按当前用户要求用云端模式。自检和真实拨号/SMS分开报告。
