# AirSIM AVF Agent Debian 发布

AirSIM 对 Android AVF Linux 来宾只发布一个 `arm64` Debian 包：

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
AIRSIM_PACKAGE_VERSION=0.4.3 \
AIRSIM_PACKAGE_RELEASE=1 \
AIRSIM_RELEASE_PUBLIC_KEY_BASE64='<base64-raw-public-key>' \
AIRSIM_RELEASE_PRIVATE_KEY='/secure/path/release-ed25519.pem' \
./module/packaging/build-avf-deb.sh
```

输出目录默认为 `dist/`，包含 `.deb`、`.sha256` 和 Base64 编码的 `.sig`。没有提供私钥时仅生成开发包与摘要，不能通过 installerd 的发布签名校验。

首个正式 Release 使用的 Ed25519 发布公钥为：

```text
Base64 raw key: 7fGe7k6ZJ5xhU5Uljm97EPKRzfSJUULVnaHpUBT8Gho=
DER SHA-256:    a7f6696ec806e5f7500b8526fe6a82f18931fd910ebad8124ee4ef1da823a2e6
```

私钥必须长期保存在仓库之外并单独备份。丢失私钥后不能为已安装的 installerd 生成可信升级；替换公钥属于密钥轮换，必须设计受信任的迁移流程，不能只上传一个使用新密钥签名的包。

发布到 GitHub Release 时必须上传构建目录中的全部发布文件。Android App 的“一键更新/修复”使用版本化 `.deb` 与同名 `.sig`；首次安装命令使用稳定名称 `airsim-avf-agent_arm64.deb`、`airsim-avf-agent_arm64.deb.sig` 和 `install-avf.sh`。首次安装器由构建脚本写入同一个发行公钥，不从网络下载或信任替代公钥。

## 首次引导

首次进入 AVF Linux Terminal 后，只需执行：

```sh
curl -fsSL --proto '=https' --tlsv1.2 \
  https://github.com/kai-wu-cortex/AirSIM/releases/latest/download/install-avf.sh \
  | sudo sh
```

脚本会检查当前系统为 arm64，下载最新稳定名称包，使用脚本内置的 Ed25519 发行公钥验签，再检查 Debian 包名和架构。验证通过后才安装服务、保留首个回滚包，并显示配对所需的 AVF 地址说明与控制 token。把 Agent 地址和 token 保存到 AirSIM Android App 后，后续检查、安装和回滚均通过 `airsim-installerd` 完成。

该入口仅用于首次安装；检测到已保留的 `current.deb` 时会拒绝重复执行，并提示用户改用 Android App 更新。AVF 镜像需要预装 `curl`、`openssl`、`base64`、`dpkg-deb`、`apt-get` 和 `install`。如果镜像缺少其中任一命令，脚本会在改动系统前停止并报告缺失项。

如果需要离线安装，仍可使用 release 中的 `airsim-avf-bootstrap.sh`、版本化 `.deb`、`.sig` 和 `.public.pem` 三个参数模式。发布公钥指纹应通过独立可信渠道核对。

## Android 管理协议

- `GET http://<AVF>:7576/v1/status`
- `POST http://<AVF>:7576/v1/packages/install`
- `POST http://<AVF>:7576/v1/packages/rollback`

所有请求必须来自 AVF 私网或 loopback，并携带共享 bearer token。安装请求必须使用 `application/vnd.debian.binary-package`，在 `X-AirSIM-Signature` 中携带 `.deb` 的 Ed25519 签名，并通过 `X-AirSIM-Install-Mode` 选择 `normal` 或 `repair`。`normal` 只接受更高版本，`repair` 只接受当前相同版本；降级只能使用服务器保留包的 rollback 接口。installerd 只接受包名 `airsim-avf-agent`、架构 `arm64` 的包，不提供任意 shell 执行接口。

安装器保留当前包和上一包。缺少首次回滚包时会拒绝升级并要求重新执行引导。新版本经 `dpkg` 安装、Agent 重启和版本健康检查后才提交；健康检查失败时自动恢复上一包并再次验证。主 Agent 的旧自更新入口返回 `410 Gone`，避免两个更新器同时写入系统。

## 卸载语义

普通 `apt remove` 停止服务但保留配置、设备身份与回滚数据。只有明确执行 `apt purge airsim-avf-agent` 才清除 `/etc/airsim`、`/var/lib/airsim` 和 `/var/lib/airsim-installerd`。
