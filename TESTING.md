# RemotePU 测试计划

本文件记录已经完成的验证，以及在 Mac 上继续做的集成测试步骤。测试主机都用环境变量表示，真实值写在 gitignore 的 `local/env.sh` 中；密码不写进任何文件。

```sh
# local/env.sh（示例，不入库）
export RPU_HOST_MAC_REMOTE=user@mac-b        # 远程 Apple Silicon Mac（密码登录）
export RPU_HOST_LINUX_GPU=user@gpu-wsl       # WSL2，多张 NVIDIA 卡
export RPU_HOST_LINUX_GB10=user@gpu-gb10     # NVIDIA GB10，统一内存，Arm 大小核
export RPU_MAC_HOST=user@mac-a               # 只有从非 Mac 机器运行 scripts/remote-mac.sh 时才需要
```

## 测试矩阵

| 角色 | 登录方式 | 硬件 / 系统 | 覆盖的场景 |
|---|---|---|---|
| Mac A（本机） | — | M5 Pro（6 Super + 12 Performance），macOS 26.5；只装了 CLT，另有 Xcode.app 但未通过 xcode-select 选中 | App 运行机、本机节点 |
| Mac B（远程） | 密码 | M1 Max（8P + 2E），macOS 26.6；链路很慢（约 15 KB/s） | 远程 Mac、密码认证、采集器自动下发 |
| Linux A | 密钥 | WSL2 Ubuntu 24.04，Ryzen 7 9850X3D，2× RTX PRO 4000 Blackwell | 多卡 NVIDIA；WSL 没有 CPU 温度 |
| Linux B | 密钥 | ASUS GX10，NVIDIA GB10（统一内存），10× Cortex-X925 + 10× Cortex-A725 | 统一内存 GPU、Arm 大小核 |

## 已完成（2026-10-25）

| # | 内容 | 结果 |
|---|---|---|
| 1 | Python 采集器单测：fixtures、假 nvidia-smi、旧驱动字段回退、统一内存、Arm 分簇、从 stdin 运行、管道断开后退出 | 14/14 通过 |
| 2 | 采集器真机：Linux A（双卡、WSL 检测、自动找到 `/usr/lib/wsl/lib/nvidia-smi`）；Linux B（GB10 显存为 `[N/A]` 时用 compute-apps 求和；X925/A725 分簇） | 通过 |
| 3 | ssh 中途断开后，远端没有残留的 python / nvidia-smi 进程 | 通过 |
| 4 | Swift 单测：协议解码、模型、ssh 参数、远端脚本转义、错误分类、SQLite 分层存储/聚合/清理、控制接口、askpass broker、进程流 | 20/20 通过（`scripts/mac.sh test`） |
| 5 | rpu-agent-mac 在 Mac A 上经 ssh 运行（与"远程 Mac"路径相同）：设备树拓扑（M/P 字母）、SMC 温度/风扇/PSTR、IOReport 分项功耗与簇频率、IOAccelerator GPU 占用 | 通过 |
| 6 | rpu-agent-mac 上传到 Mac B（gzip，校验 sha256 后原子安装）并运行：E/P 分簇、ECPU/PCPU/PCPU1 频率、温度、风扇 | 通过 |
| 7 | 发现并修复：① 被截断的上传曾被当成完整文件安装，现在先校验 sha256；② debug 版采集器 968 KB，在慢链路上传超时，现在用 release + strip + gzip，只有 136 KB | 已修复 |
| 8 | `rpu-probe` 端到端（本机 + Linux A + Mac B 密码登录）：master、askpass、探测、下发、流式传输、写入历史 | 通过 |
| 9 | App 冒烟测试（`--data-dir … --no-keychain`）：通过控制接口添加节点、四个节点同时在线、`ui.render` 渲染概览和详情（浅色/深色）、菜单栏标题、菜单面板、设置窗口与编辑表单、`history.flush`、`app.quit` | 通过 |
| 10 | 发现并修复：① 退出时卡死（`.terminateLater` 期间主队列不执行）；② `-N` 模式的 ssh master 在 App 退出后残留。修复后在 `app.quit` 和 `kill -9` 两种情况下，本机和远端都没有残留进程 | 通过 |
| 11 | 菜单面板里 ScrollView 高度塌陷为 0 | 已修复，截图确认 |

## 已完成（2026-10-27）

- `scripts/mac.sh test`：20 项 Swift 测试、14 项 Python 采集器测试通过；普通包和恢复包均构建、签名验证通过。
- 节点选择 GPU 时，菜单栏按 GPU 编号并列显示全部占用率；单卡、双卡、自动 GPU、CPU 和温度模式经隔离数据验证。
- 恢复版使用独立应用标识，四个现有节点重新上线；节点配置和设置文件的 SHA-256 在切换前后保持一致，继续使用原历史目录。
- 真机双 GPU 菜单数值已与同一采样的 GPU0、GPU1 对照，用户确认顶部节点图标、百分比及双卡数字显示正常。
- 现场发现 ControlCenter 将原应用标识的显示错误关联到另一个应用开关。重新开关、重启和重置控制中心布局未清除异常；恢复包绕开该记录，未声称修复原系统记录。验证结束后另一个应用的开关已还原。

## 已完成（2026-10-31）

- 修复仪表盘（尤其节点详情页）滚轮滚动不顺畅：隔离实例（`--demo`，本机 + 两个 demo 节点全部 1 s 间隔）空闲流式时主线程忙时从 ~70% 降到 ~12%（`sample` 前后对比；Overview ~9%，窗口全关 ~2%）。三个原因各有修复：`PulseDot` 的 `repeatForever` 动画改为 CALayer 上的 CABasicAnimation（渲染服务进程执行）；数值文本的 `numericText`+`.snappy` 过渡每秒重启导致渲染循环永不停，已移除；`MetricChart` 不再观察 `NodeLive`/`AppModel`，改由 task 定时拉取（实时 2 s、历史 15 s），实时序列点数上限 450→150。另外关闭的主窗口与菜单面板现在会卸载 SwiftUI 内容，不再隐藏时持续按采样重绘。
- 回归：Swift 20 项、Python 14 项测试通过；`ui.render` 概览 / 节点详情 / 菜单面板（深色）渲染正常（离屏渲染中状态圆点为实心、无光晕，属预期）；菜单面板开合正常。
- 仪表盘顶栏重构：时间范围与监测状态移入侧栏顶部的抽屉（状态行常显，范围可折叠、当前项带勾选）。放弃 SwiftUI `.toolbar` 与 `NavigationSplitView`（macOS 26 下同步进手建 NSWindow 的系统工具栏有两个毛病：详情页滚动内容会盖住标题栏，系统侧栏按钮点击后会在标题栏左右大幅迁移），改为窗口内自绘控制栏（侧栏开关 + 页面标题 + 全部重连），侧栏为自绘列（固定宽 + 毛玻璃材质，Option+Cmd+S 开关）；详情页内容宽度上限 950 pt 居中，侧栏开合与宽窗口缩放不再引起图表/KPI 重排换行（只平移）。`ui.range`、`ui.select` 回归正常，Swift 20 项 + Python 14 项测试通过。
- 15 分钟实时视图跨重启续接：数据一直在 SQLite 里持久化（`history.query` 可查到上次运行），但实时视图只读内存环形缓冲，重启后上半段空白。现在 `MetricChart` 启动时先同步画本次运行的环形数据，再从数据库"接种"上次运行的部分（`historySeed`，截止本次启动时刻），与本轮实时流拼接后统一抽稀到 150 点。用 `/tmp` 数据目录复现验证：两次运行共约 3 分钟数据，重启后 `history.query` 返回全部 71 行；离屏 `ui.render` 因 ImageRenderer 不执行 `.task`，增加 `renderPreviewMode` 环境标志同步读环形数据（修复了图表解耦后离屏节点详情一直空图的问题）。概览卡片上的迷你趋势线仍只读内存（重启后随新数据重新生长）。thinSeries 抽稀逻辑新增单测，Swift 21 项 + Python 14 项通过。
- 修复接种数据导致的绘图溢出：接种点是静态的，应用运行超过 15 分钟后时间窗滑过它们，落在 x 域之外的点 Swift Charts 不裁剪，数据线从 y 轴左侧溢出（用户截图确认）。每次刷新时按当前窗口过滤（`t >= since`）。不用 `chartPlotStyle` + `clipped`，因为会裁掉绘图区上方的悬停提示框。
- AetherSwitch 集成（v1）：节点配置新增"启用 AetherSwitch + mgr 目录"（`aetherDir`，默认 `~/server_mgr`），详情页头部下方新增 AetherSwitch 卡片（当前模式 + 各模式状态/切换按钮 + 全部停止，经节点自己的 ssh master 复用连接执行 `mgr`，5 秒轮询 `mgr status --json`，切换期间显示 operation 阶段）。控制接口新增 `nodes.aether`。单测 +6 项（脚本构造/目录含空格与特殊字符转义/解析/配置往返）。真机（部署了 AetherSwitch 的 GPU Linux 主机，密钥登录）：状态与模式列表正确（含中文模式名、服务 URL）；`switch` 到当前模式走 `unchanged` 无副作用分支成功；错误目录返回清晰错误；`aetherDir=off` 关闭再开启正常；`ui.render` 浅色/深色详情页渲染正常。真实跨模式切换见 E 类。

## 集成测试

准备：

```sh
. local/env.sh
scripts/mac.sh test            # Swift + Python 单测
scripts/mac.sh bundle          # 生成 dist/RemotePU.app
r() { dist/RemotePU.app/Contents/Helpers/rpuctl --socket /tmp/rpu-it/control.sock "$@"; }
rm -rf /tmp/rpu-it && open -n dist/RemotePU.app --args --data-dir /tmp/rpu-it --no-keychain --open-main
```

### A. 连接与认证

| # | 步骤 | 期望 |
|---|---|---|
| A1 | `r nodes.add name=linux-a target=$RPU_HOST_LINUX_GPU`，然后 `r nodes.wait id=linux-a` | 进入 online；`r nodes.sample id=linux-a` 显示两张卡、`caps.cpu_temp=false` |
| A2 | `r nodes.add name=linux-b target=$RPU_HOST_LINUX_GB10` | 进入 online；GPU 的 `unified=true`，`mem_used` 是各进程之和 |
| A3 | `read -rs PW; r nodes.add name=mac-b target=$RPU_HOST_MAC_REMOTE password="$PW" persist=false` | 进入 online；首次连接要上传采集器，可能需要 20–60 秒 |
| A4 | `r nodes.setPassword id=mac-b password=wrong persist=false` | 进入 `authFailed`，且**不自动重试**：`r log.tail filter=node:mac-b` 只看到一次尝试 |
| A5 | 改回正确密码，然后 `r nodes.reconnect id=mac-b` | 恢复 online |
| A6 | `r nodes.add name=bogus target=nobody@does-not-exist` | 进入 `offline`，原因显示 "Could not resolve hostname"；按 1→2→4…30 秒退避重试 |
| A7 | 在正式实例（不带 `--no-keychain`）里用设置界面添加远程 Mac，勾选"保存到钥匙串"，然后重启 App | 自动重连；ad-hoc 签名重新编译后，第一次读取会弹出钥匙串授权，属于预期行为 |

### B. 稳定性

| # | 步骤 | 期望 |
|---|---|---|
| B1 | 连续运行 ≥ 2 小时 | 内存稳定（每 30 分钟记一次 `ps -o rss= -p $(pgrep -x RemotePU)`）；ssh master 数量等于远程节点数 |
| B2 | 断开本机网络 30 秒后恢复 | 节点依次变为 stale → offline，之后自动恢复 online |
| B3 | 让远程 Mac 合盖/睡眠，或让 Windows 进入睡眠 | 显示 offline，唤醒后自动恢复 |
| B4 | 分别执行 `r app.quit` 和 `kill -9 $(pgrep -x RemotePU)` | 本机 `pgrep -f "<数据目录>/cm/"` 为空；远端没有残留的 `python3 -u -`、`rpu-agent-mac` 或 `cat` 进程 |

### C. 数据准确性

| # | 步骤 | 期望 |
|---|---|---|
| C1 | 在 Linux A / Linux B 上跑 GPU 负载 | 占用、功耗、频率曲线跟着变化；触发功耗墙时出现"功耗墙"徽标 |
| C2 | 在本机执行 `for i in 1 2 3 4 5 6; do yes > /dev/null & done; sleep 30; killall yes` | 各簇的占用和频率上升，CPU 功耗和温度上升 |
| C3 | 对照 macmon：把官方 release 下载到临时目录，和采集器同时运行，比较两边的数值 | CPU/GPU 功耗、温度、簇频率相差在 ±10% 以内 |

C3 命令：

```sh
d=$(mktemp -d) && cd "$d"
url=$(curl -s https://api.github.com/repos/vladkens/macmon/releases/latest | grep -o 'https://[^"]*darwin[^"]*\.tar\.gz' | head -1)
curl -sL "$url" | tar xz && ./macmon pipe -s 5 -i 1000 > macmon.jsonl &   # 参数以 macmon --help 为准
<repo>/dist/RemotePU.app/Contents/Helpers/rpu-agent-mac --count 5 > rpu.jsonl; wait
```

### D. 界面（需要人工确认）

| # | 步骤 | 期望 |
|---|---|---|
| D1 | `r ui.render page=overview path=/tmp/o.png`；`r ui.render page=<id> appearance=dark path=/tmp/d.png` | 卡片和图表布局正常，深色配色正确 |
| D2 | `r ui.menubar path=/tmp/m.png`，同时直接看菜单栏 | 每台机器显示"图标 + 数值"；离线节点颜色变淡并带 ⚠︎ |
| D3 | 在"设置 → 节点 → 编辑"里改图标、"在菜单栏显示"、显示的数值 | 菜单栏、侧栏、卡片、详情页的图标同步变化 |
| D4 | 运行超过 10 分钟后，详情页切到 1h / 6h | 曲线从 SQLite 读取；`r history.query id=… metric=cpu_util range=1h` 有数据 |
| D5 | 在图表上悬停 | 出现十字线，提示框里列出所有序列的数值 |

### E. AetherSwitch（GPU 模式切换）

前提：目标主机上部署了 AetherSwitch（`~/server_mgr/mgr`，密钥登录）。用 `r nodes.add name=… target=$RPU_HOST_AETHER aetherDir=~/server_mgr` 添加节点。切换会真实地停止当前 GPU 服务并启动新模式，**测试前确认该机上没有正在进行的任务**。

| # | 步骤 | 期望 |
|---|---|---|
| E1 | `r nodes.aether id=<节点>` | 返回 `modes`（含中文名）和 `status`：`current_mode` 指向运行中的模式，其余 `stopped` |
| E2 | `r --timeout 1200 nodes.aether id=<节点> action=switch mode=<当前模式>` | `ok=true`，`mgr` 走 unchanged 分支，服务不动、状态不变（无副作用的动作路径冒烟） |
| E3 | `r nodes.aether id=<节点> action=status dir=~/no-such-dir` | 明确报错（`cd: can't cd to …`），不是空结果 |
| E4 | `r nodes.update id=<节点> aetherDir=off` 后 `nodes.list`，再改回 | `aetherSwitch` 为 null / 恢复；详情页的 AetherSwitch 卡片随之消失/出现 |
| E5 | 真实切换：`r --timeout 1200 nodes.aether id=<节点> action=switch mode=<另一个模式>`，期间反复 `r nodes.aether id=<节点>` | 卡片显示"正在切换到 …"和 operation 阶段（checking → releasing → starting → ready）；完成后新模式 `ready`、旧模式 `stopped`，GPU 显存曲线随切换变化 |
| E6 | 界面操作（人工）：详情页点击其他模式的"切换"、再点"全部停止" | 按钮在动作期间禁用；切换完成回到新状态；停止后所有模式 `stopped`、"全部停止"变灰 |
| E7 | 断开网络或让主机休眠后再恢复，等节点重新 online | AetherSwitch 卡片自动恢复轮询，不再显示旧错误 |
| D6 | 在系统设置里开启"减弱动态效果" | 脉冲点停止动画 |
| D7 | 系统语言在 English 和简体中文之间切换 | 界面文案跟着切换 |
| D8 | 执行 `scripts/mac.sh install` 后，打开"设置 → 通用 → 登录时启动" | 注销再登录后 App 自动启动 |
| D9 | `r ui.requestScreenCapture`，在系统设置里授权后执行 `r ui.screenshot window=main` | 结果为 `method=screencapture`，截图内容完整 |

## 已知限制

- 未授予"屏幕录制"权限时，`ui.screenshot` 截不到 NavigationSplitView 和 ScrollView 里的内容。检查页面内容请用 `ui.render`。
- App 只做了 ad-hoc 签名：每次重新编译后，钥匙串和屏幕录制授权可能都要重新确认。
- WSL2：读不到 CPU 温度和频率；nvidia-smi 能看到进程 PID，但进程名显示为 `[Not Found]`。
- Intel Mac、没有 python3 的 Linux 主机暂不支持，界面会给出明确的原因。
