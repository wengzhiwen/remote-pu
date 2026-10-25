# RemotePU — macOS 本地/远程 CPU·GPU 监控工具 计划 v3

> 最后更新：2026-10-25
> - v2：加入远程 Mac；改为自研 Mac 采集器；不依赖 Xcode 和 Homebrew。
> - v3：v1 功能已全部编码完成并经过真机冒烟测试；新增密码登录、控制接口（供自动化测试）、GB10 统一内存主机、节点图标、实时反馈效果。
> - 测试清单见 [TESTING.md](TESTING.md)，控制接口见 [docs/CONTROL_API.md](docs/CONTROL_API.md)。

## 1. 已对齐的决策

| 项 | 决定 |
|---|---|
| 形态 | 原生 macOS App（SwiftUI）：菜单栏常驻 + 主窗口 dashboard + 设置 |
| 运行位置 | 开发者自己的 Apple Silicon Mac = "本机" |
| 远程方式 | 调用系统 `/usr/bin/ssh`；远端不手动安装、不开端口；每个节点一个 ControlMaster |
| 认证 | ① 密钥 / agent / `~/.ssh/config`（BatchMode，从不弹窗）② **密码**：存在钥匙串（或只存内存），通过私有 askpass 辅助程序交给 ssh |
| 远程平台 v1 | Linux + NVIDIA（含多卡、统一内存 GB10）；远程 Apple Silicon Mac |
| WSL 范围 | 只看 WSL 内部；CPU 温度显示"不可用" |
| v1 功能 | 基础指标 + 历史持久化 + 进阶指标（功耗/频率/风扇/P-state/降频原因） |
| 标注与反馈 | 每个节点可选图标（菜单栏、面板、侧栏、卡片、详情页统一显示）；在线脉冲点、"N 秒前更新"、数值滚动、实时曲线的最新点 |
| 菜单栏 | 默认"每台机器：图标 + 数值"（数值可选：自动/CPU/GPU/温度，可按节点隐藏）；也可显示"最忙 GPU/CPU + 所在机器图标" |
| 不在 v1 | GPU 进程列表、告警通知 |
| 规模 | ≤5 台节点，单机 ≤4 卡 |
| 使用范围 | 自用：ad-hoc 签名，在 Mac 上用 CLT 编译 |
| 语言 | 中英双语，跟随系统（`Resources/*.lproj/Localizable.strings`） |
| 测试接口 | App 内置控制接口（Unix socket + `rpuctl`），可增删节点、读数据、操作界面、离屏渲染和截图 |

## 2. 测试矩阵（2026-10-25 实测；主机名已脱敏）

| | Mac A（本机） | Mac B（远程） | Linux A（WSL2） | Linux B（GB10） |
|---|---|---|---|---|
| 系统 | macOS 26.5.1 | macOS 26.6.2 | Ubuntu 24.04（WSL2） | Ubuntu 24.04（kernel 7.0 nvidia） |
| CPU | M5 Pro：6 Super + 12 Performance（设备树类型 P/M） | M1 Max：8P + 2E（P/E） | Ryzen 7 9850X3D ×16 | 10× Cortex-X925 + 10× Cortex-A725 |
| GPU | Apple 20 核 | Apple 32 核 | 2× RTX PRO 4000 Blackwell 24 GB | GB10（统一内存，显存字段为 N/A） |
| 特点 | 只有 CLT（另有 Xcode.app 未 select）；无 brew | 只能密码登录；链路约 15 KB/s | nvidia-smi 在 `/usr/lib/wsl/lib`；无温度传感器 | `memory.used` 为 N/A，进程显存可查 |

## 3. 架构

```
┌─────────────────────── RemotePU.app (本机 Mac) ─────────────────────────┐
│ SwiftUI: MenuBarExtra(模板图标题) + 主窗口 + 设置    ← rpuctl / 控制接口 │
│        ▲ AppModel (ObservableObject) / NodeLive（每节点，1s 环形缓冲 30 min）│
│ NodeManager → NodeRunner（actor，每节点一个；状态机 + 退避重连）          │
│   ├ 本机 Mac : Contents/Helpers/rpu-agent-mac                           │
│   ├ 远程 Mac : ssh -S master … ~/.cache/remotepu/agents/<hash>/rpu-agent-mac │
│   └ 远程Linux: ssh -S master … python3 -  (stdin 注入 rpu_collector.py)   │
│ AskpassBroker（Unix socket）← rpu-askpass ← ssh（SSH_ASKPASS）            │
│ HistoryStore（SQLite：5s 7 天 / 1min 90 天）                             │
└────────────────────────────────────────────────────────────────────────┘
```

- **唯一协议 NDJSON v1**（`Sources/RPUProtocol/Messages.swift`）：`hello` / `s`（sample）/ `err`，所有字段可空，snake_case。
- **SSH**：每个节点一个前台 master（stderr 可读，便于诊断），远端只运行 `cat`，它的 stdin 由 App 一直持有，所以 App 退出或崩溃时 master 必然随之退出。探测、下发、数据流都通过 `-S` 复用这个 master；密码只在 master 认证时用一次，随后立即注销 token。认证失败或主机密钥不符时不自动重试，避免账号被锁。
- **退出**：在协作线程池里停止所有节点并落盘历史，最多等 5 秒，再给残留的子进程发 SIGTERM。不使用 `.terminateLater`，因为它期间主队列不执行。
- **远程 Mac 下发**：先检查 sha256；需要时上传 gzip 后的 release 采集器（约 136 KB），远端解压、校验 sha256 后原子替换；压缩包过期时回退为上传未压缩文件。
- **Linux 采集器**：Python 3.6+ 纯标准库。nvidia-smi 以 `-lms` 长驻输出（没有输出时改为轮询）；字段按驱动支持情况自动降级；统一内存 GPU 的已用内存取进程显存之和；Intel 大小核和 Arm 大小核（MIDR）自动分簇。
- **Mac 采集器**：公开接口（逐核 ticks、内存、IOAccelerator）+ SMC（按前缀枚举温度键、风扇、PSTR）+ IOReport（dlopen；分项功耗、簇与 GPU 频率；DVFS 表按"有效状态数"匹配）+ IOHID 兜底；簇名称来自 `hw.perflevelN.name`，并按设备树的类型字母与 IOReport 通道关联。

## 4. 仓库结构

```
collector/rpu_collector.py, tests/        Linux 采集器 + 单测（假 nvidia-smi）
Sources/RPUProtocol/                      NDJSON v1 消息
Sources/RPUIPC/                           Unix socket 服务端/客户端、JSONValue、控制接口与 askpass 协议
Sources/RemotePUCore/                     ManagedProcess、SSH、Secrets/Askpass、NodeRunner/Manager、HistoryStore、配置、Demo
Sources/RemotePUCore/Generated/           CollectorScript.swift（scripts/gen-collector.sh 生成）
Sources/rpu-agent-mac/                    Mac 采集器（CPU/Memory/GPU/SMC/IOReport/HID）
Sources/rpu-askpass/  Sources/rpuctl/  Sources/rpu-probe/
Sources/RemotePU/                         App：AppModel、AppControl（控制接口）、Theme、Views/
Resources/                                Info.plist、en/zh-Hans 本地化
scripts/mac.sh                            build / bundle / install / run / test / agent
scripts/remote-mac.sh                     从非 Mac 机器同步代码并在 Mac 上执行
```

## 5. 里程碑状态

| # | 内容 | 状态 |
|---|---|---|
| M0 | 环境确认 | ✅ |
| M1 | 采集器（Linux / Mac） | ✅ 四台真机验证 |
| M2 | Core + CLI（ssh master、askpass、下发、状态机、rpu-probe） | ✅ 端到端验证 |
| M3 | App MVP（菜单栏/主窗口/设置/中英文/图标/实时反馈） | ✅ 冒烟测试通过；交互细节待人工验证 |
| M4 | 历史（SQLite 分层、清理、时间范围） | ✅ 单测通过；长时间运行待验证 |
| M5 | 进阶指标与打磨 | ✅ 大部分完成；App 图标未做 |
| IT | 集成测试 | ⏳ 按 TESTING.md 在 Mac 上进行 |

## 6. Backlog

- GPU 进程列表（WSL 下进程名为 `[Not Found]`；GB10 能拿到进程名和显存）
- 告警通知（高温、显存将满、训练结束导致 GPU 空闲、节点掉线）
- WSL 节点的 Windows 整机 CPU/内存/温度（`powershell.exe` + LibreHardwareMonitor）
- 用 NVML（ctypes）替代 nvidia-smi；为没有 python3 的主机提供 sh/awk 兜底
- App 图标、Developer ID 签名（解决钥匙串和屏幕录制授权在重编译后失效的问题）
- AMD / Intel GPU

## 7. 风险

1. Mac 采集器依赖私有接口（IOReport、SMC、IOHID）：每项能力单独探测，失败只关闭对应项；`--dump-*` 用于新芯片的校准。
2. 新芯片的命名可能变化（M5 已出现 Super/Performance、MCPU/PCPU）：靠设备树类型字母加 DVFS 表匹配来适配，不写死名称。
3. 慢链路下首次上传需要 10–60 s，状态显示为"部署采集器"。
4. ad-hoc 签名的授权问题（见 TESTING.md 的已知限制）。
