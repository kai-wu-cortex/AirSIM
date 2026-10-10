# AirSIM AVF Agent Debian 发布

AirSIM 对 Android AVF Linux 来宾只发布一个 `arm64` Debian 包：

当前 Agent 发布为 [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)（包版本 `0.4.6-1`）；Android/iOS 应用的独立发布版本是 [`v0.9.5`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.5)。不要用应用版本号覆盖 Debian 包版本。

```text
airsim-avf-agent_<version>-<release>_arm64.deb
```

三星、Qualcomm 与 MediaTek 设备不使用不同的 Agent 包。Android App 在运行时探测 AVF 私网、Terminal、Shizuku、音频桥和系统权限；Debian 包只包含与 SoC 厂商无关的 Linux 服务。

## 包内布局

```text
/usr/bin/airsim-agent
/usr/bin/airsim-avf-pair
/usr/lib/airsim/airsim-installerd
/usr/lib/airsim/agent.env.default
/usr/lib/systemd/system/airsim-agent.service
/usr/lib/systemd/system/airsim-installerd.service
```

持久状态分别位于 `/var/lib/airsim` 和 `/var/lib/airsim-installerd`。用户配置位于 `/etc/airsim/agent.env`，升级时不会被覆盖。服务日志默认进入 journald。

## 构建与签名

测试包结构：

```sh
./module/packaging/test.sh
```

构建正式包时，将 Ed25519 私钥保存在仓库之外，并把对应的 32 字节原始公钥以 Base64 注入 installer：

```sh
AIRSIM_PACKAGE_VERSION=0.4.6 \
AIRSIM_PACKAGE_RELEASE=1 \
AIRSIM_RELEASE_PUBLIC_KEY_BASE64='<base64-raw-public-key>' \
AIRSIM_RELEASE_PRIVATE_KEY='/secure/path/release-ed25519.pem' \
./module/packaging/build-avf-deb.sh
```

输出目录默认为 `dist/`，包含 `.deb`、`.sha256` 和 Base64 编码的 `.sig`。没有提供私钥时仅生成开发包与摘要，不能通过 installerd 的发布签名校验。

v0.4.5 起使用的 Ed25519 发布公钥为：

```text
Base64 raw key: QQPJXjO2mcx13qhv74lXen8ytjJZ2hMCz+ERlz6w5qg=
DER SHA-256:    4c39d5afdca2dddd8d22c0a5e02da18e7f07db789baac04bce4cfcd57491b3f4
```

私钥保存在仓库外的本机受限目录，并备份为 GitHub Actions 仓库 Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`；不得提交、打印或添加到 Release。旧 v0.4.4 公钥为 `7fGe7k6ZJ5xhU5Uljm97EPKRzfSJUULVnaHpUBT8Gho=`，其私钥已无法找到。旧 installerd 不能接受新签名，已安装 `0.4.4-1` 的设备须通过[一次性密钥迁移](../../docs/AVF_INSTALL_GUIDE.md)重建信任，不能只上传新签名包。

发布到 GitHub Release 时必须上传构建目录中的全部发布文件。Android App 的“一键更新/修复”使用版本化 `.deb` 与同名 `.sig`；首次安装命令使用稳定名称 `airsim-avf-agent_arm64.deb`、`airsim-avf-agent_arm64.deb.sig` 和 `install-avf.sh`。首次安装器由构建脚本写入同一个发行公钥，不从网络下载或信任替代公钥。

## 首次引导

首次进入 AVF Linux Terminal 后，确认 Debian 提示符可用，再执行。此命令只用于首次安装或恢复已有包的服务，不负责旧签名根迁移：

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
```

`pipefail` 确保 GitHub 下载失败不会被 `sudo sh` 的空输入掩盖。脚本检查 arm64、下载稳定名称包、用内置 Ed25519 公钥验签并核对 Debian 包身份。安装后保留首个回滚包，等待 `airsim-agent`、`airsim-installerd` 与 Agent 健康端点就绪；任一失败都以非零状态退出并打印无损排障命令，不再报告“安装完成”。成功后可运行 `sudo airsim-avf-pair` 查看配对信息，将当前动态 AVF 来宾地址和 token 保存到 Android App。完整步骤见[AVF 安装与无损排障指南](../../docs/AVF_INSTALL_GUIDE.md)。

该入口也可恢复已有安装：检测到保留的 `current.deb` 时先重载、启用并启动服务；健康检查仍失败才用本地保留包 `apt-get install --reinstall` 修复服务文件，不下载新包、不覆盖回滚包。若仍不能恢复，打印 systemd 排障命令并非零退出。旧 GitHub Release 中的脚本可能仍拒绝重复执行；必须重新发布新的 `install-avf.sh` 才能让手机获得此修复，不能删除 `current.deb` 或清除整个 AVF 数据来绕过保护。AVF 镜像需要预装 `bash`、`curl`、`openssl`、`base64`、`dpkg-deb`、`apt-get`、`systemctl` 和 `install`。如果镜像缺少安装依赖，脚本会在改动系统前停止并报告缺失项。

安装前先用 `apt-get check` 检查 AVF Debian 的现有依赖状态；例如 `udev` 与 `libudev1` 版本不一致时中止，不自动运行可能移除系统组件的 `apt --fix-broken install`。维护者应先看 `apt-cache policy udev libudev1` 与 `sudo apt-get -s -f install` 的模拟计划，再决定是否只升级对应的 `libudev1`；步骤见[安装指南](../../docs/AVF_INSTALL_GUIDE.md)。

与 DJOneHub 共存时，AirSIM Agent 独占 `8575`、installerd 独占 `8576`，不会接管原服务的 `7575`。首次安装器会在写入 Debian 包前检查这两个端口是否被其他进程占用；Agent `/api/health` 还必须返回 `product=airsim`。**旧 GitHub Release 不包含此迁移**，重新构建、签名并发布前，不要在已有 DJOneHub 的 AVF 内运行在线安装命令。

如果需要离线安装，仍可使用 release 中的 `airsim-avf-bootstrap.sh`、版本化 `.deb`、`.sig` 和 `.public.pem` 三个参数模式。发布公钥指纹应通过独立可信渠道核对。

`rotate-avf-key.sh` 是仅限旧 `0.4.4-1` 的一次性在线迁移资产，固定检查旧保留包摘要、新包签名与版本，并在安装失败时尝试恢复旧包。它不是普通更新器；旧私钥丢失意味着无法用旧密钥交叉签名迁移脚本。迁移细节和固定 SHA-256 见 [v0.4.5 发布说明](../../docs/releases/0.4.5.md)。

## Android 管理协议

- `GET http://<AVF>:8576/v1/status`
- `POST http://<AVF>:8576/v1/packages/install`
- `POST http://<AVF>:8576/v1/packages/rollback`

所有请求必须来自 AVF 私网或 loopback，并携带共享 bearer token。安装请求必须使用 `application/vnd.debian.binary-package`，在 `X-AirSIM-Signature` 中携带 `.deb` 的 Ed25519 签名，并通过 `X-AirSIM-Install-Mode` 选择 `normal` 或 `repair`。`normal` 只接受更高版本，`repair` 只接受当前相同版本；降级只能使用服务器保留包的 rollback 接口。installerd 只接受包名 `airsim-avf-agent`、架构 `arm64` 的包，不提供任意 shell 执行接口。

安装器保留当前包和上一包。缺少首次回滚包时会拒绝升级并要求重新执行引导。新版本经 `dpkg` 安装、Agent 重启和版本健康检查后才提交；健康检查失败时自动恢复上一包并再次验证。主 Agent 的旧自更新入口返回 `410 Gone`，避免两个更新器同时写入系统。

## 卸载语义

普通 `apt remove` 停止服务但保留配置、设备身份与回滚数据。只有明确执行 `apt purge airsim-avf-agent` 才清除 `/etc/airsim`、`/var/lib/airsim` 和 `/var/lib/airsim-installerd`。
