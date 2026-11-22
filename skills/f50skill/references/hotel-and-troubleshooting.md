# iPhone 酒店配网与踩坑

## 操作

原热点配网页通常 `http://192.168.0.1:8088`；已连 Wi-Fi 时用实际 IP 加8088。f50wifi.local 取决于路由器多播，不能保证。**8088 是配网页，不是 AirSIM 动态配对端口。**

保存酒店网并勾网页登录，或指定已有网络后勾选。记下临时热点名称、密码，重启后不要先登录原热点页（会暂停自动切网）。酒店连接但 HTTPS 未放行时自动打开 DIRECT-F5-F50-…，iPhone 作为普通 Wi-Fi 客户端加入，访问页面实际给出的地址，通常 `http://192.168.49.1:8088`。

步骤：登录 → 允许此iPhone → 热点信息/配置代理/自动填本窗口 PAC URL → Safari 酒店入口 → 用户自行填写酒店认证信息 → 回页检查F50联网 → 关闭iPhone代理 → 结束临时热点 → 4G/5G测云端。

窗口20分钟，PAC每次变化，不收藏旧URL。认证结束F50保持上游。酒店会话过期需再认证。网段重叠、非80/443端口、企业802.1X、只能专用App认证不属已支持路径；不绕过酒店授权或TLS错误。

管理密码与热点密码独立。修改 hotel_hotspot_password：备份、暂停目标配网进程、只改字段、原子写入、让init重载；当前对象密码是final，仅改文件不会改变当前会话。管理密码走认证API，不明文覆盖PBKDF2。输入通过私有文件/stdin，避免shell参数和日志。iPhone需忽略旧网络再用新密码真连，读回配置不能替代连接测试。

## 技术边界

B28普通AP+STA HAL组合不可用，成功路径是P2P Group Owner+STA。查询DIRECT接口、只读内核能力后再实测，不能根据芯片宣传硬开普通AP。正式认证服务运行时不要并行跑P2pProbe。

代理仅P2P地址8089、一个已授权热点客户端IP，PAC另带令牌；解析和socket明确用wlan0 Network，不借iPhone蜂窝兜底。HTTPS CONNECT不解密。F50 HTTPS检查不跟随重定向，默认204，或私有hotel-probe-url使用自有Relay healthz及JSON身份。DHCP、ping、Safari单独可用、缓存云端在线都不等于完整认证。

## 故障分层

| 表现 | 检查与避免 |
| --- | --- |
| USB不见/三秒重枚举 | 先查供电、数据线、配件许可、USB树和占用进程；未枚举不刷镜像。 |
| USB有但ADB掉 | adb_enabled、组合、密钥、启动日志；不靠常亮或关闭认证。 |
| IP拿到又掉 | wlan0仍在br0？ifconfig guard就绪？不整体换netd或循环补IP。 |
| Mac正常、充电器失败 | 启动脚本是否依赖USB组合；仅更新DEX不够。 |
| 重启保持原热点 | 是否登录过页面、目标是否可达；登录暂停切网，保存再重启。 |
| SIM无服务/未识别 | 内置CU与实体卡、原厂卡槽/Android slot差异、注册及IMS；同卡普通手机对照再换槽，必要时验证LTE与5G漫游差异。 |
| Relay显示registered但没服务 | 旧Agent曾固定上报registered/at_ok；用真机Telephony和实际通话判定。 |
| 三星/默认电话提示 | 看F50 Telecom默认绑定与启动恢复，不是改iPhone系统电话。 |
| Telecom invocation timeout | 控制锁修复、角色及桥健康，不先归咎SIM。 |
| 远端挂断后等Agent | 真实ended、完整通话身份、APK摘要；相同140可能是旧包。 |
| 配对已存/网关认证失败 | 默认电话、PCM桥、绑定和网络隔离；临时Mac转接完成后关闭。 |
| Relay 429/1027 | 核验当前服务/限额；自有部署用GCloud，不误回DMIT。 |
| 注册HTTP400 | 正确App、Bundle ID、团队与production APNs；两App并存易打开错。 |
| 密码改后热点仍旧 | 服务final缓存、旧P2P组和iPhone保存密码；重载后忘记旧网实连。 |
| app_process无stderr退出 | Android API实际兼容性；曾将Files.readString改为readAllBytes，宿主编译成功不够。 |

恢复调查时改过的显示尺寸、动画、常亮、锁、临时转发与工具。完整Magisk管理APK不证明shell root授权；酒店方案不需新root，不为无头界面故障反复刷启动或点环境修复。
