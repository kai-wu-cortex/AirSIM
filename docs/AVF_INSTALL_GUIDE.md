# AirSIM AVF Linux Agent 安装与无损排障

本指南适用于支持 Android AVF Linux Terminal 的三星手机。AirSIM Android App、AVF 中的 `airsim-agent`、独立的 `airsim-installerd` 是三个不同组件；App 能打开 Terminal，并不等于 Agent 已安装。`8575` Agent 健康端点可达，也不等于 `8576` 安装服务和控制令牌已就绪。

当前应用发布是 [`v0.9.3`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.3)，本指南安装的 AVF Agent 是独立版本 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)（Debian 包 `0.4.6-1`）。两条版本线用途不同，不应相互替换。

若 AVF 内已有 DJOneHub，保留其服务和 `7575` 端口。AirSIM 使用独立的 `8575` / `8576`，健康响应还应包含 `"product":"airsim"`；`7575` 返回成功不能当成 AirSIM 已安装。首次安装固定到 v0.4.6。已有 `0.4.4-1` 的设备须先按下文执行一次性签名密钥迁移到 v0.4.5，再通过安装器升级，不能用首次安装命令或 App 的旧 installer 直接跳过迁移。

## 安全边界

- 不要因为 Terminal 报错就立即关闭开发者选项中的 Linux Terminal、清除 Terminal 应用数据或删除 AVF 镜像。这些操作可能删除来宾系统、Agent 配置与配对状态。
- 不要删除 `/var/lib/airsim-installerd/packages/current.deb`；它是后续更新的回滚依据。
- 控制 token 只填入 AirSIM App 私有配置，不放入聊天、截图、日志或仓库。查看日志前先检查是否包含敏感信息。
- 本文中的 IP 与版本仅为示例。AVF 网段会随设备和启动变化；必须验证当前设备地址。

## 1. 确认 Linux Terminal 可用

在 AirSIM 的“设置 → AVF Linux 首次安装”查看 AVF 状态。若 Terminal 已启动，点“打开 Linux Terminal”，确认出现 `droid@localhost` 一类 Debian 提示符。不要反复启动多个 VM runner；`cannot create runner / VM is not in stopped state` 属于 Android Terminal 的启动状态冲突，发生在 Agent 安装之前。先回到已有 Terminal 会话，或关闭错误界面后重新打开现有 Terminal；保留 AVF 数据。只有在确认备份和数据丢失影响后，才考虑系统级重置。

若没有 Terminal 或系统未公开 AVF，普通第三方 App 无法代替 OEM 安装系统组件。需要受支持的系统版本或厂商镜像。

## 2. 首次签名安装

在 Debian 提示符中执行以下一行；`pipefail` 让下载错误以非零退出码传递，而不是让空输入的 `sudo sh` 假装成功：

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
```

App 的按钮**只复制命令**，不能直接在 Android 宿主执行 Linux 命令；请在 Debian Terminal 提示符中粘贴并按回车。安装脚本先校验 Ed25519 签名、Debian 包名与 `arm64` 架构，再安装并保留 `current.deb`。修复版脚本要求 `airsim-agent`、`airsim-installerd` 和 Agent 健康端点均就绪；任何一项失败都不能算安装成功。若已有 `current.deb`，它会优先恢复现有服务；必要时用保留包重装服务文件，不删除回滚包，也不重新下载或擅自升级 Agent。

如果命令长时间没有输出，先单独执行 `curl -I --connect-timeout 10 --max-time 20 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh`，检查 AVF Debian 自身是否能连接 GitHub。Android 宿主联网不代表 Linux 来宾联网。`curl` 超时、`sudo` 缺失、Debian 提示符未出现和已有安装拒绝重跑是四类不同故障，需记录终端原文与退出码，不能统称“安装失败”。

安装脚本属于 GitHub Release 资产。修改仓库中的 `install-avf.sh.in` 不会自动改变已发布的 Release；需要新的签名包与 Release 才能让其他用户获得修复。若当前线上版本仍提示“首次安装已完成；后续更新请使用 AirSIM Android App”，说明使用的是旧安装脚本；请按第 4 节恢复服务，**不要删除 `current.deb` 来绕过它**。

### 已安装 0.4.4-1：一次性迁移发行签名密钥

v0.4.4 的发行私钥未留存；旧 `airsim-installerd` 无法验证 v0.4.5 的新签名。不能通过重复点击 App“更新到最新版”、复用旧 `.sig` 或跳过验签解决。请在已有 AirSIM Agent 的同一 AVF Linux Terminal 中运行：

```sh
curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 -o /tmp/airsim-rotate-v0.4.5.sh https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.5/rotate-avf-key.sh
printf '%s  %s\n' '9ae6b8c69d5d9877638a50240282a67d06b73d807dba444c816c5efb9c5ec04d' /tmp/airsim-rotate-v0.4.5.sh | sha256sum -c - && sudo sh /tmp/airsim-rotate-v0.4.5.sh
```

此命令只接受已安装 `airsim-avf-agent 0.4.4-1`、且保留包 SHA-256 与已发布 v0.4.4 完全一致的来宾；已有其它回滚包时也会停下，不覆盖。脚本从固定 GitHub Release 下载 v0.4.5 包与签名，以内置新 Ed25519 公钥验证，再保留旧包、安装、重启 AirSIM 两项服务并检查健康；失败时尝试用旧包回滚。它不清除 AVF 数据、AirSIM 控制 token 或 DJOneHub。v0.4.5 公钥 DER SHA-256 为 `4c39d5afdca2dddd8d22c0a5e02da18e7f07db789baac04bce4cfcd57491b3f4`；脚本 SHA-256 见 [0.4.5 发布说明](releases/0.4.5.md)。下载脚本使用 GitHub HTTPS；旧密钥已丢失，无法对迁移脚本做旧密钥交叉签名，务必核对域名与上述指纹。

迁移成功后，`0.4.4-1` 保存在 `previous.deb` 可供 installerd 回滚；之后新版本可再次使用 App 内的签名更新。若下载、版本、旧包摘要或 Debian 依赖预检失败，脚本不会开始安装。不要删除 `current.deb` 或改用 `dpkg --force` 来绕过检查。

## 3. 配对 Android App

在 Debian Terminal 执行：

```sh
sudo airsim-avf-pair
```

将输出的控制 token 填入 AirSIM“设置 → Linux Agent → 控制令牌”，并保存。Agent 地址应使用当前 AVF 来宾地址加端口 `8575`。App 目前根据 `avf_tap_fixed` 所在私网段推断来宾的 `.25` 地址；应以当前设备实测可达的地址为准，不要固定复制 `10.185.5.25`。在 Mac 上可用以下只读检查确认宿主接口与连通性（替换设备序列号和实际来宾地址）：

```sh
adb -s DEVICE shell ip -o -4 addr show dev avf_tap_fixed
adb -s DEVICE shell ping -c 1 -W 1 AVF_GUEST_IP
adb -s DEVICE shell 'printf "GET /api/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" | toybox nc -w 3 AVF_GUEST_IP 8575'
adb -s DEVICE shell toybox nc -z -w 2 AVF_GUEST_IP 8576
```

`/api/health` 返回 `ok: true` 仅说明 Agent 进程可达。App 显示“可达 · 尚未配对控制令牌”时，先完成本节配对，不要直接点更新。`8576` 可连通、App 能读取 installerd 状态后，才能通过 App 更新、修复或回滚。

## 4. Agent 可达但 installerd 不可用

例如 `8575` 返回 Agent 版本，而 `8576` 提示 `Connection refused`：这不是 AVF 断网，也不能靠重复点击 App 更新解决。先在 Debian Terminal 执行只读检查：

```sh
sudo systemctl status airsim-agent airsim-installerd --no-pager
sudo journalctl -u airsim-installerd -n 80 --no-pager
dpkg-query -W airsim-avf-agent
```

若 `airsim-installerd.service` 单元存在但未运行，执行：

```sh
sudo systemctl enable --now airsim-installerd.service
sudo systemctl is-active airsim-installerd.service
sudo airsim-avf-pair
```

如果单元不存在，说明当前 Agent 安装不完整或来自旧布局：先确认 `current.deb` 是否存在。修复版引导程序会校验保留包的 Debian 身份，并在启动服务失败时用它重装服务文件；若尚未发布修复版或重装后仍失败，**保留当前包和数据**，记录 `systemctl`/`journalctl` 错误并让维护者准备签名的修复包；不要通过删除 `current.deb` 绕过回滚保护。若服务启动后立即退出，日志比端口探测更能说明缺少 token、权限或二进制文件等原因。

### `udev` / `libudev1` 版本不一致

如果安装时报 `udev depends libudev1 (= 252.39-1~deb12u2) but 252.38-1~deb12u1 is installed`，问题在 AVF Debian 的系统包状态，不是 AirSIM Agent 自身缺少 `libudev1`：`udev` 对 `libudev1` 要求完全相同的版本。先在来宾系统运行只读检查：

```sh
apt-cache policy udev libudev1
sudo apt-get -s -f install
```

检查模拟操作中的 `Inst`、`Conf`、`Remv`。若出现 `Remv`、系统包降级、跨发行版包或其它未预期操作，**停止**，不要执行真正的 `apt --fix-broken install`。若仓库确实提供与当前 `udev` 相同版本的 `libudev1`，可先模拟精确版本安装（把示例版本替换为 `apt-cache policy` 中实测版本）：

```sh
sudo apt-get -s --no-remove install 'libudev1=252.39-1~deb12u2'
```

只有确认模拟计划不移除或降级其它包后，才执行相同命令但去掉 `-s`，然后运行 `sudo apt-get check` 并重试 AirSIM 安装。`--no-remove` 能让 APT 在需要移除包时中止；不要为了强行完成而使用 `--allow-remove-essential`、`--allow-downgrades` 或 `dpkg --force`。修复版 AirSIM 引导脚本会在签名包安装前用 `apt-get check` 拦截已有的依赖故障并提示上述只读检查，不自动改动系统包。

## 5. 验收与故障记录

1. Terminal 出现可交互的 Debian 提示符；`avf_tap_fixed` 存在。
2. `airsim-agent` 与 `airsim-installerd` 均为 `active`；`8575` 的 `/api/health` 返回 `ok: true`，`8576` 可连接。
3. `sudo airsim-avf-pair` 能显示地址说明和控制 token；App 保存后显示 Agent 与 installerd 在线。
4. 随后再验证默认电话角色、Shizuku 授权、VoWLAN/Relay、真实通话及双向 PCM。Agent 健康不等于电话链路已经验收。

提交故障报告时记录：手机型号、Android/Terminal 版本、Agent 包版本、两项 `systemctl status`、脱敏 `journalctl`、两个端口的连通性和安装脚本退出码。不要附上控制 token、真实号码、短信或 PCM。
