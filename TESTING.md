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
| D6 | 在系统设置里开启"减弱动态效果" | 脉冲点停止动画 |
| D7 | 系统语言在 English 和简体中文之间切换 | 界面文案跟着切换 |
| D8 | 执行 `scripts/mac.sh install` 后，打开"设置 → 通用 → 登录时启动" | 注销再登录后 App 自动启动 |
| D9 | `r ui.requestScreenCapture`，在系统设置里授权后执行 `r ui.screenshot window=main` | 结果为 `method=screencapture`，截图内容完整 |

## 已知限制

- 未授予"屏幕录制"权限时，`ui.screenshot` 截不到 NavigationSplitView 和 ScrollView 里的内容。检查页面内容请用 `ui.render`。
- App 只做了 ad-hoc 签名：每次重新编译后，钥匙串和屏幕录制授权可能都要重新确认。
- WSL2：读不到 CPU 温度和频率；nvidia-smi 能看到进程 PID，但进程名显示为 `[Not Found]`。
- Intel Mac、没有 python3 的 Linux 主机暂不支持，界面会给出明确的原因。
- App 还没有图标（.icns）。
