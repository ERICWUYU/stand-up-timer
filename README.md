# 番茄钟（Pomodoro Timer）

一个专为 macOS 设计的轻量菜单栏番茄钟。它在专注时间结束时提醒用户站起来、走动和休息，并在休息结束后提示继续工作。

## 下载安装

从 [Releases](https://github.com/ERICWUYU/stand-up-timer/releases) 下载 `StandUpTimer-0.5.0-macos-universal.zip`，解压后将 `StandUpTimer.app` 拖入“应用程序”文件夹。

- 通用二进制，支持 Apple Silicon 与 Intel Mac。
- 最低系统版本：macOS 13。
- 当前版本使用 ad-hoc 签名，未经 Apple 公证。首次打开若被 macOS 阻止，请前往“系统设置 → 隐私与安全性”，点击“仍要打开”。
- 源码当前按 0.5.0（build 5）准备发布；正式公开版本、附件文件名与校验和一律以 Releases 页面实际发布内容为准，在 v0.5.0 Release 公布前不假定该附件已经存在。

## 当前状态

- 已完成：产品范围、技术选择、验收标准、分步实施计划和 Xcode/SwiftUI 环境验证。
- 已完成阶段 1：纯计时核心位于 `Sources/StandUpTimerCore`；在项目目录运行 `swift test`。
- 已完成阶段 2：原生菜单栏界面、计时操作和图标状态已经通过人工视觉验收。
- 已完成阶段 3：专注结束和休息结束通知、系统提示音选择、中英文切换和通知排程均已通过人工验收。
- 已完成阶段 4：可调专注/休息时长、持久化声音开关，以及按绝对截止时间保存和恢复运行、暂停、空闲状态。
- 已完成阶段 4B：一键四轮连续模式；4 次专注与 3 次短休交替，第 4 次专注后进入长休，长休结束回到普通空闲专注。
- 已完成阶段 5A：普通计时器与 Focus Cycle 的时长相互独立；旧设置自动迁移，修改时长只影响后续阶段，运行中当前阶段保持不变。
- 已完成 0.4.0：修复通知横幅显示空白图标的问题；应用启用新的 bundle id，首次启动自动迁移旧设置，通知权限需要重新授权一次。
- 已完成阶段 6（本地活动历史）：每次阶段转换以带版本号的 JSON 写入本机 `Application Support/StandUpTimer/activity-history.json`；记录自然完成、跳过、取消三种结果；启动时追赶休眠期间错过的转换，并按稳定 id 确定性去重，重放不会产生重复记录。
- 已完成阶段 6（统计仪表盘）：单实例本地统计窗口提供 Today、Last 7 Days、Last 30 Days、This Year 四个区间；卡片展示专注时长、专注次数、最长专注、休息遵守率；日/月柱状图按日历零填充，This Year 只覆盖 1 月至当前月、不出现未来月份；“最近 20 条”活动独立于所选区间。
- 阶段 6 人工 UI 验收已通过：英文浅色、英文深色、中文深色三组核对，区间切换、月度柱状图、最近 20 条不变量、双语与 Light/Dark 实时切换、统计窗口复用同一窗口均正常。
- 自动化测试 220/220 通过（StandUpTimerCore 149 + StandUpTimerApp 71）；签名 `.app` 构建检查通过。
- 已通过人工验收：完整四轮流程、短休与长休切换、计时恢复、通知与提示音、中英文界面，以及底部控件单行无换行或截断的紧凑布局。
- 阶段 5A 人工验收已通过：普通计时器与 Focus Cycle 的独立时长设置界面及四轮运行行为正常；设置窗口能正确置前、复用同一窗口，并遵循正常窗口层级。
- 当前源码按 0.5.0（build 5）准备发布；正式标签、GitHub Release 与附件以 Releases 页面为准，发布前仍需执行干净 macOS 用户人工验收（见 `docs/acceptance.md` 的 v0.5.0 小节）。
- 本次 0.5.0 发布准备环境：Xcode 27.2；最低支持 macOS 13。

## MVP 功能

- 菜单栏显示紧凑状态图标，展开面板显示当前阶段和剩余时间。
- 默认 25 分钟专注、5 分钟走动休息；普通计时器与 Focus Cycle 分别保存时长，可在设置中独立调整（专注 1–180 分钟，休息与长休 1–60 分钟）。
- 可一键开始四轮连续模式：三次短休间隔四次专注，第 4 次专注后进入长休（默认 15 分钟，可调整）；运行中显示当前轮次，并可随时结束循环。
- 开始、暂停、继续、重置、跳过。
- 专注和休息结束时发送系统通知；通知声音可开关，开启时可选择 8 种 macOS 系统提示音。
- 计时基于绝对截止时间，电脑休眠或延迟刷新不会造成累计误差；重新打开应用时恢复运行或暂停状态。
- 本地活动历史与统计：阶段转换保存在本机 `activity-history.json`，统计窗口按 Today、Last 7 Days、Last 30 Days、This Year 回顾专注时长、专注次数、最长专注、休息遵守率、日/月柱状图与最近 20 条活动。
- 中英文界面切换。
- 完全离线，不需要账号，不收集个人数据，不上传任何活动历史或统计数据。

## 技术方向

- Swift + SwiftUI 原生 macOS 应用。
- `MenuBarExtra` 提供菜单栏入口。
- `UserNotifications` 发送本地系统通知。
- `UserDefaults` 保存用户设置，并用带版本号的快照保存计时状态；损坏或未知版本的数据安全回退到默认空闲专注。
- 活动历史采用带信封与记录 schema 版本号的本地 JSON 文件（`activity-history.json`）；无法解析的文件隔离为 `activity-history.corrupt-*` 副本，不影响应用启动与计时。
- 统计区间基于 `Calendar` 半开区间与零填充日/月桶，DST、闰年与跨月跨年边界安全，不产生未来时间桶。
- 使用“结束时间点”计算剩余时间，避免睡眠、锁屏或界面卡顿造成累计误差。
- 未来提醒由纯逻辑 `ReminderTimeline` 一次算出绝对时间线，通知框架只负责写入系统。

验收条件见 [docs/acceptance.md](docs/acceptance.md)。

## 开发

在项目目录运行：

```bash
swift test
Scripts/build-app.sh
```

`swift test` 运行全部核心测试；`Scripts/build-app.sh` 生成 `.build/StandUpTimer.app`。

发布时运行 `Scripts/release.sh`：以 release 配置生成 arm64 + x86_64 通用二进制，产出 `dist/StandUpTimer-<版本>-macos-universal.zip` 和 `SHA256SUMS.txt`。

打包图标资源需要 Xcode 提供的 `actool`（用于把 `Support/Assets.xcassets` 编译成 `Assets.car`）；只安装 Command Line Tools 时 `swift test` 仍可运行，但无法完成 app 打包。
