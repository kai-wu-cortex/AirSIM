---
name: "F50 Pro Wi-Fi 配置页"
description: "iPhone 上使用的本地 Wi-Fi 设置界面"
colors:
  canvas: "#f3f5f9"
  surface: "#fff"
  text: "#17233b"
  muted: "#526077"
  action: "#1659cc"
  divider: "#d9e0eb"
  error: "#a32525"
  success: "#196446"
  button-soft: "#eaf0fb"
  button-soft-hover: "#dde7fa"
  action-hover: "#124db2"
  field-border: "#a4b1c5"
  placeholder: "#5f6d82"
  notice-bg: "#eef4ff"
  notice-border: "#b9cdef"
  notice-text: "#194b91"
  notice-error-bg: "#fff3f2"
  notice-error-border: "#e9b9b4"
  scan-hover: "#f5f7fc"
typography:
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "26px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  status:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "21px"
    fontWeight: 650
    lineHeight: 1.55
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "18px"
    fontWeight: 700
    lineHeight: 1.3
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "16px"
    fontWeight: 550
    lineHeight: 1.55
  button:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.55
  hint:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.55
  detail:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  control: "8px"
  surface: "12px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "16px"
  panel: "20px"
  lg: "24px"
  xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.action}"
    textColor: "{colors.surface}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "10px 16px"
    width: "100%"
  button-primary-hover:
    backgroundColor: "{colors.action-hover}"
  button-secondary:
    backgroundColor: "{colors.button-soft}"
    textColor: "{colors.action}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "10px 16px"
  button-secondary-hover:
    backgroundColor: "{colors.button-soft-hover}"
  button-text:
    backgroundColor: "transparent"
    textColor: "{colors.action}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "8px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.error}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "8px"
  field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "10px 12px"
    width: "100%"
  surface:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    rounded: "{rounded.surface}"
    padding: "20px"
  network-row:
    textColor: "{colors.text}"
    padding: "14px 0"
  notice:
    backgroundColor: "{colors.notice-bg}"
    textColor: "{colors.notice-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "14px 16px"
  notice-error:
    backgroundColor: "{colors.notice-error-bg}"
    textColor: "{colors.error}"
  checkbox-label:
    typography: "{typography.body}"
    padding: "6px 0"
---

# Design System: F50 Pro Wi-Fi 配置页

## Overview

**Creative North Star: "手机设置页"**

本规范仅适用于 F50 Pro 的独立本地 Wi-Fi 配置页，不替代 AirSIM 其他界面的设计规范。沿用既定 Operate 方向：白色阅读面、浅蓝灰背景、深色文字与蓝色操作，使用系统字体和原生表单，让 iPhone 用户能直接识别设备状态并完成设置。

文档依据当前 web/index.html 提取，合并原有方向约定。界面优先保证状态、输入、操作反馈和恢复入口清楚可见；没有装饰图像、渐变、外部字体或阴影。它记录界面实现，不构成重启后仅连接指定网络、失败恢复并保持热点或 USB ADB 保持可用的真机验收结论。

**Key Characteristics:**

- 单列信息顺序与内联表单，保持本地设置的熟悉感。
- 蓝色用于操作，绿色与红色用于明确的状态语义。
- 长网络名称换行，触控目标至少 44px，主要控件与复选框标签至少 48px。
- 主动操作的反馈可滚动并聚焦显示；后台轮询更新不抢占滚动位置。

## Colors

颜色原值由 frontmatter 管理。操作蓝克制地集中于按钮、焦点和链接，白色表面承载内容，浅蓝灰背景区分页面与分组。

### Primary

- **操作蓝**（action / action-hover）：主要操作、链接、焦点与原生复选框强调色。
- **浅蓝操作面**（button-soft / button-soft-hover）：次要按钮的静态与悬停状态。

### Neutral

- **浅蓝灰画布**（canvas）与 **白色阅读面**（surface）：页面背景与各设置分组。
- **深色正文**（text）与 **次要说明**（muted）：名称、标题与帮助文字。
- **分隔线**（divider）与 **输入边线**（field-border）：列表分隔、容器及字段轮廓。
- **占位提示**（placeholder）与 **扫描悬停面**（scan-hover）：输入辅助与整行选中反馈。

### Status

- **连接绿**（success）：设备报告连接成功时的状态行。
- **错误红**（error）：错误说明与移除操作。
- **通知蓝组**（notice-bg / notice-border / notice-text）与 **错误通知组**（notice-error-bg / notice-error-border）：内联反馈的底色、边框和文字。

**The Action and State Rule.** 蓝色标识可执行操作；连接状态与错误同时提供文字，不只依赖颜色。

## Typography

采用 frontmatter 中的系统 UI 字体栈，无下载字体和独立品牌展示字体。中文操作文案以自然语序呈现；输入框继承正文大小，保持 iPhone 输入时可读。

### Hierarchy

- **Headline**：页面标题，26px、700、1.2 行高，轻微收紧字距。
- **Status**：当前网络名称，21px、650，允许任意位置换行。
- **Title**：分组标题，18px、700、1.3 行高。
- **Body / Label / Button**：16px，分别使用 400 / 550 / 600 字重；默认行高 1.55。
- **Hint**：14px 帮助文案；行内操作同为 14px，但保持按钮字重。
- **Detail**：13px 网络详情、设备事实与页尾入口。

**The Native Reading Rule.** 系统字体用于操作界面的阅读与输入，不延伸为品牌展示字体；表单文字保持 16px。

## Layout

主区域为居中单列，最大宽度 640px（含内边距），默认上边距 32px、左右 20px，底部 32px 加设备安全区。标题区下留 28px。白色分组内边距 20px、组间距 20px；分组标题与动作同排，网络列表按行分隔。

宽度不大于 380px 时，主区域改为上下 24px、左右 14px，分组内边距 16px；已保存网络的行内动作竖排，仍保持至少 44px 高度。实际窄屏规则覆盖了主区域默认安全区补偿；这里仅记录实现，不据此推广到其他界面。长名称允许换行，行内容可收缩，设备事实可换行。桌面继续使用同一列宽，不扩大为仪表盘。

基础间距取自 frontmatter；组件内部同时保留实现中的 6px 标签间距、10px 复选框间距、14px 列表内边距和 18px 字段上间距，不强行改成等距栅格。

## Elevation & Depth

页面不使用阴影或浮层装饰。白色分组与浅色画布通过 1px 分隔边框区分，通知以轻微底色变化表达状态，浏览器原生确认框负责破坏性操作确认。

**The Flat Surface Rule.** 用白色表面、分隔线和信息间距建立层次，不为分组增加阴影。

## Shapes

设置分组使用 surface 圆角；按钮、输入框、选择框与通知使用 control 圆角。状态点是 9px 实心圆，只辅助对应文字。列表保持矩形行与细分隔线，没有额外胶囊标签或图标容器。

## Components

### Buttons

用户先连接设备原热点进行配置。表单主要操作为“保存并重启”，次要操作为“仅保存，暂不重启”：仅保存会指定目标网络，保留当前网络，不触发切换；保存并重启会在重启后只连接指定网络，失败时恢复并保持原热点。已保存网络区域另有“重启并连接指定网络”按钮；未具备重启条件或设备正在重启时禁用。

主要按钮通栏，次要按钮使用浅蓝底，文字按钮保持透明背景；移除文字使用错误红。普通按钮最小高度 48px，文字按钮最小高度 44px，内边距见 frontmatter。按钮按下仅下移 1px，禁用时透明度 0.55 并使用等待光标；reduced-motion 下取消位移，不引入过渡动画。主要与次要按钮有对应悬停色；文字按钮继续保持透明。

所有可聚焦元素使用 3px 操作蓝外轮廓与 3px 偏移。行内按钮为 14px，窄屏时内边距 6px、最小高度仍为 44px。

### Inputs / Fields

输入框与选择框保留原生交互、1px 输入边线、白底与至少 48px 高度。字段标签在上，输入框在下；密码显示按钮与输入框同排。密码可显示或隐藏，开放网络隐藏密码字段。复选框本体为 20px，整个标签行至少 48px 高、上下 6px 内边距，整行可点按。

### Cards / Containers

白色设置分组以 1px 分隔边框、surface 圆角和内边距组织内容，不做可点击卡片。登录、读取状态和已登录内容分开显示，隐藏内容使用原生 hidden 语义。

### Network Rows

已保存网络显示名称、文字状态与“指定”／“移除”操作。目标项显示“已指定”并禁用指定操作；不支持的认证类型也禁用指定；当前连接项禁用移除，但当前连接与重启目标分别标示。指定只改变下次重启的目标，当前网络保持不变；目标说明显示“重启后连接”，其他保存项显示“已保存，待选择”，不表示会轮流尝试。

可扫描网络以整行按钮选择，选择后填入表单并聚焦相应字段；不支持的认证类型保留文字说明且禁止选择。热点模式提示直接输入网络名称；扫描不可用时说明热点保持开启。空列表用 14px 次要文字说明下一步。移除操作使用原生确认框。

### Notices and Connection State

通知为可聚焦的 polite live region。用户主动提交后的重启说明、设置结果或错误会滚动到通知并聚焦；后台状态轮询更新不改变滚动和焦点。保存或指定成功时说明当前网络保持不变，并指向单独的重启按钮或手动重启。

重启反馈说明系统启动满 1 分钟且就绪后关闭热点并连接指定 Wi-Fi；重新访问本页需让 iPhone 连接同一 Wi-Fi，使用设备获分配的 IP 加 :8088。连接失败时说明重新加入原热点并使用 192.168.0.1:8088，热点将保持开启等待配置。已配置的 AirSIM 云端入口与本地页面访问方式分别说明。连接状态行同时保留状态文字、网络名称、地址与 USB ADB 事实，不以绿色或单个点替代可读结论。

### Recovery and Secondary Settings

“开机连接指定网络”复选框只控制开机行为，修改时不切换当前网络；仅指定目标参与重启后的连接，失败恢复热点后等待重新配置。原热点恢复入口保持独立可见，并在切换前使用原生确认框；管理密码修改使用原生 details 展开，summary 最小高度 44px。页尾显示本地与热点入口，并说明本页不能完成酒店网页认证。

## Do's and Don'ts

### Do:

- Do 保留状态、已保存网络、新网络表单和原热点恢复入口的单列阅读顺序。
- Do 保持原生 label、input、select、button 和 details 语义，给键盘焦点清晰的蓝色轮廓。
- Do 为长 SSID 和设备状态允许换行，保留 48px 主要触控目标与 44px 行内按钮。
- Do 在用户提交操作后显示可见反馈，区分仅保存／指定与重启联网，说明重启等待和失败后返回热点的下一步；让后台轮询保持滚动位置。
- Do 使用设备返回的状态，分别说明 Wi-Fi、USB ADB 与待完成的真机验证。

### Don't:

- Don't 为本地设置页引入外部字体、CDN、装饰图像或渐变。
- Don't 把蓝色操作、绿色连接状态和红色错误变成无语义的装饰色。
- Don't 显示已保存网络的密码，或让恢复热点入口依赖隐藏导航。
- Don't 将仅保存或指定描述为立即切网，也不把其他保存项描述为连接失败后的自动候选。
- Don't 将设置页截图或本地构建通过表述为重启后连接指定网络、失败恢复并保持热点和 USB ADB 的真机验证通过。
