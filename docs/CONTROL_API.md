# RemotePU 控制接口（Control API）

App 运行时在数据目录下监听一个 Unix socket（权限 0600，仅本用户可访问），用于自动化测试和外部工具（包括 Claude 通过 ssh 驱动集成测试）：

- 默认：`~/Library/Application Support/RemotePU/control.sock`
- 用 `--data-dir DIR` 启动时：`DIR/control.sock`
- `--no-control` 关闭

协议：每个连接发送一行 JSON 请求，返回一行 JSON 响应。

```
→ {"id":"1","cmd":"state","args":{}}
← {"id":"1","ok":true,"result":{...}}      或   {"id":"1","ok":false,"error":"..."}
```

## rpuctl

`RemotePU.app/Contents/Helpers/rpuctl` 是命令行客户端：

```sh
rpuctl [--socket PATH] [--timeout SEC] <cmd> [key=value ...] [key:=<json> ...]
```

- `key=value` 自动识别 true/false/null/数字，其余按字符串处理；`key:=[...]` 传原始 JSON。
- 默认 socket：`$RPU_CONTROL_SOCKET`，否则为标准路径。
- 退出码：0 成功；1 命令报错；2 用法错误；3 连不上 App。
- 在 zsh 里建议定义函数，不要用 `$C` 变量拼接命令：
  `r() { ~/Applications/RemotePU.app/Contents/Helpers/rpuctl --socket /tmp/rpu-test/control.sock "$@"; }`

## 隔离的测试实例

```sh
open -n dist/RemotePU.app --args --data-dir /tmp/rpu-test --no-keychain [--demo] [--open-main] [--appearance dark]
```

| 参数 | 作用 |
|---|---|
| `--data-dir DIR` | 节点配置、历史库、日志、socket 全部放在 DIR（不影响正式实例） |
| `--no-keychain` | 不读写钥匙串（ad-hoc 签名每次重编译都会触发钥匙串授权弹窗）；密码只能用 `persist=false` 放内存 |
| `--demo` | 加入两个合成节点（2×GPU Linux + Mac） |
| `--open-main` | 启动即打开主窗口 |
| `--appearance light\|dark` | 固定外观，便于截图对比 |

## 命令

| 命令 | 参数 | 说明 |
|---|---|---|
| `help` | | 列出全部命令 |
| `ping` | | 版本、pid、数据目录、helper 路径 |
| `state` | | 所有节点（配置、状态、最新指标摘要）+ UI 状态 + 菜单栏汇总 |
| `nodes.list` | | 节点配置（含 demo） |
| `nodes.add` | `name target [kind=ssh\|local] [auth=system\|password] [password] [persist=true] [port] [identityFile] [interval] [enabled] [sshOptions:=[..]] [id]` | 添加节点；带 password 时默认 auth=password |
| `nodes.update` | `id` + 同上字段 | 修改节点 |
| `nodes.remove` | `id` | 删除节点（同时删除钥匙串密码） |
| `nodes.setPassword` | `id password [persist=true]` | 设置密码；`persist=false` 只存内存 |
| `nodes.reconnect` | `[id]` | 立即重连（无 id = 全部）；也用于认证失败后的手动重试 |
| `nodes.sample` | `id` | 采集器原始 hello + 最新 sample（NDJSON v1 字段） |
| `nodes.wait` | `id [phase=online] [timeout=60]` | 阻塞直到节点进入某状态，超时报错并给出当前状态/原因 |
| `history.query` | `id metric [range=1h\|秒数] [points=200]` | 从 SQLite 读序列，返回 `[[ts, avg, max], ...]`；metric 如 `cpu_util`、`gpu:<key>:util`（key 见 `state` 的 gpuKeys） |
| `history.flush` | | 立即落盘 + 聚合，返回各表行数 |
| `demo.set` | `enabled=true\|false` | 开关演示节点 |
| `settings.get` / `settings.set` | `<字段>=<值>` | 读写设置（menuBarMode、retention5sDays…） |
| `ui.state` | | 当前选中项、时间范围、可见窗口、外观 |
| `ui.open` | `window=main\|settings [tab=general\|nodes\|about]` | 打开窗口 |
| `ui.close` | `window=main\|settings` | 关闭窗口 |
| `ui.select` | `node=<id>\|overview` | 选中侧栏项（会打开主窗口） |
| `ui.range` | `value=15m\|1h\|6h\|24h\|7d\|30d` | 切换图表时间范围 |
| `ui.menu` | `[open=true\|false]` | 打开/关闭菜单栏面板 |
| `ui.menubar` | `[path] [appearance=light\|dark]` | 渲染菜单栏标题并返回各节点数值及状态项诊断；`requestedVisible` 和 `anchorOnMenuBar` 不代表系统实际显示，需结合真实菜单栏及 ControlCenter 日志核验 |
| `ui.editor` | `id=<node>\|new\|none` | 打开/关闭设置里的节点编辑表单 |
| `ui.appearance` | `value=light\|dark\|system` | 强制外观 |
| `ui.windows` | | 所有窗口（类名、identifier、frame、可见性） |
| `ui.screenshot` | `window=main\|settings\|menu\|<编号> [path] [method=auto\|screencapture\|layer\|cache]` | 截取 App 自己的窗口，见下文 |
| `ui.requestScreenCapture` | | 请求“屏幕录制”权限（系统弹窗一次） |
| `ui.render` | `page=overview\|menu\|<node id> [width=1100] [appearance=light\|dark] [path]` | 用 ImageRenderer 离屏渲染整页；menu 按面板固定宽度渲染 |
| `log.tail` | `[n=100] [filter]` | 最近日志（如 `filter=node:mac-b`） |
| `app.quit` | | 退出 App（会停止 ssh 并把历史落盘） |

### 截图说明

- **`ui.render` 是验证页面内容的首选**：无需任何权限，输出完整页面（概览或某节点详情），可指定深浅色。
- `ui.screenshot method=auto`：已授予“屏幕录制”权限时调用 `screencapture -l <窗口号>` 得到真实像素；否则退化为 `layer`（CALayer 渲染）——菜单栏面板等普通 SwiftUI 内容能截到，但 NavigationSplitView/ScrollView 内的内容是空白。结果中 `method` 与 `screenRecordingGranted` 字段说明实际使用的方式。
- 需要真实窗口截图时：`rpuctl ui.requestScreenCapture`，然后在“系统设置 → 隐私与安全性 → 屏幕录制”中允许 RemotePU。ad-hoc 签名重编译后可能需要重新授权。

## 示例：完整冒烟测试

```sh
APP=dist/RemotePU.app
r() { $APP/Contents/Helpers/rpuctl --socket /tmp/rpu-test/control.sock "$@"; }
rm -rf /tmp/rpu-test && open -n $APP --args --data-dir /tmp/rpu-test --no-keychain --open-main
sleep 4 && r ping
r nodes.add name=gpu-wsl target=user@gpu-wsl
r nodes.add name=gpu-gb10 target=user@gpu-gb10
read -rs PW; r nodes.add name=mac-b target=user@mac-b password="$PW" persist=false; unset PW
for n in gpu-wsl gpu-gb10 mac-b; do r nodes.wait id=$n timeout=90; done
r ui.render page=overview path=/tmp/rpu-test/overview.png
r ui.render page=gpu-gb10 appearance=dark path=/tmp/rpu-test/gpu-gb10-dark.png
r ui.menu open=true && r ui.screenshot window=menu path=/tmp/rpu-test/menu.png
r history.flush && r history.query id=gpu-wsl metric=cpu_util range=900
r app.quit
```
