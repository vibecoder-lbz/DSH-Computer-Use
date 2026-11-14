# DSH-Computer-Use

DeepSeek Harness Windows 电脑控制插件。

当前使用的原生 Harness 插件是 [desktop-auto](./desktop-auto/README.md)：后台优先，不支持时自动接管，带蓝色内凹边缘、内收粒子和鲸鱼光标。安装后 agent 直接调用 `computer_*` 工具，截图以图像附件返回。

本页以下内容是早期 Python 后端的调试说明；旧版插件接入说明见 [PLUGIN.md](./PLUGIN.md)。旧实现保留作历史参考，不是当前插件的运行依赖。

供用户或 agent 查看安装软件、检查窗口、通过 Windows UI Automation 操作控件，并用截图验证结果。使用 Python 标准库与系统自带 Windows PowerShell 5.1，无需 pip 安装。

需要 Windows 10/11、Python 3.10+、已登录且未锁屏的交互桌面。推荐 64 位 Python。控制管理员软件时，进程也可能需要管理员权限。

## 快速开始

在项目目录运行：

```powershell
python computer_agent.py apps
python computer_agent.py windows
python computer_agent.py describe
python computer_agent.py screenshot
```

截图默认保存到 `artifacts/screenshot.png`，再次调用会覆盖。需要保留历史时指定不同路径。

带参数推荐使用 UTF-8 JSON 文件，避免 Windows PowerShell 5.1 对原生程序 JSON 引号的处理差异：

```powershell
@{query='Chrome'; limit=20} | ConvertTo-Json | Set-Content -Encoding UTF8 params.json
python computer_agent.py apps --params-file params.json
```

也支持 `--params` 直接接收 JSON，适合程序调用或能正确保留引号的 shell。

## 操作流程与接口

1. 用 `windows` 获取目标窗口的 `hwnd`。
2. 用 `inspect` 获取控件树，确认名称、类型、`automation_id`、`ref` 和支持的 patterns。
3. 优先用 `invoke`、`set_value`、`select`；没有控件接口时先截图，再用 `click`。
4. 操作后重新检查控件或截图，核对预期结果。界面变化后应重新获取控件引用。

表中句柄 `123456` 需要替换成实际返回值。将 params 示例写入 JSON 文件，再用 `--params-file` 传入。

| action | params 示例 | 用途 |
| --- | --- | --- |
| `apps` | `{"query":"Chrome","limit":20}` | 软件名过滤、版本、发布者、安装目录、图标来源 |
| `windows` | `{}` | 可见桌面窗口 |
| `inspect` | `{"hwnd":123456,"limit":150,"depth":5}` | 有上限的控件树；truncated 表示省略 |
| `launch` | `{"path":"C:\\Windows\\System32\\notepad.exe","args":[]}` | 启动完整路径 exe，之后确认窗口就绪 |
| `invoke` | `{"hwnd":123456,"selector":{"name":"确定","control_type":"ControlType.Button"}}` | InvokePattern 操作 |
| `set_value` | `{"hwnd":123456,"selector":{"automation_id":"AgentInput"},"value":"你好"}` | ValuePattern 设置编辑框 |
| `select` | `{"hwnd":123456,"selector":{"ref":"inspect 返回的 ref"}}` | SelectionItemPattern 选择 |
| `wait` | `{"hwnd":123456,"selector":{"name":"完成"},"timeout_ms":5000}` | 等待控件出现，最长 30 秒 |
| `click` | `{"hwnd":123456,"x":100,"y":80}` | 激活窗口后点击窗口内坐标 |
| `screenshot` | `{"hwnd":123456,"path":"artifacts/before.png"}` | 窗口区域 PNG；省略 hwnd 则截取整个虚拟桌面 |
| `compare` | `{"before":"artifacts/before.png","after":"artifacts/after.png","threshold":20,"stride":4}` | 相同尺寸图片的采样像素变化率 |

selector 字段同时满足，字符串区分大小写。空 selector、多个匹配、没有匹配均报错。控件必须支持对应 UIA pattern。

截图是实际屏幕像素，包含覆盖窗口的内容。最小化窗口不能截图。坐标单位是物理像素，click 相对窗口外框左上角。桌面截图原点见 screen_origin，多屏原点可能为负。窗口移动、调整大小或 DPI 改变后需要重新定位。

`compare.changed_ratio > 0` 只证明画面变化，不能证明任务成功。应核对目标文字、控件状态或让有视觉能力的模型查看 PNG。本工具不包含 OCR、图像语义理解或模型 API。

## 给 agent 调用

这是独立的工具层，提供 JSON Lines 协议，不内置大模型或自然语言规划器，也未自动注册到 DSH/MCP。agent 可启动为子进程，按行写入请求、按行读取结果：

```powershell
python computer_agent.py serve
```

每行一个完整 JSON：

```json
{"id":"discover","action":"describe"}
{"id":"list","action":"windows","params":{}}
{"id":"read","action":"inspect","params":{"hwnd":123456}}
{"id":"press","action":"invoke","params":{"hwnd":123456,"selector":{"name":"确定"}}}
```

响应回显 id。成功返回 `{"id":"list","ok":true,"result":{...}}`，失败返回 `{"id":"list","ok":false,"error":"..."}`。describe 返回所有工具的参数 JSON Schema 和调用顺序。标准输出只含 JSON 响应，逐行 flush。应等待上一条结果，再发下一条桌面操作。

接入 function calling：调用 describe 获取 tools，将 name、description、input_schema 转换成模型提供商的工具格式。把模型返回的工具名与参数转成 action 和 params，将 result/error 回传模型。截图返回本地路径，调用方需要读取 PNG 并作为图像输入发送给视觉模型。

也可以 Python 直接调用，失败抛异常：

```python
from computer_agent import execute

windows = execute("windows", {})
# 依据用户任务选择目标 hwnd：
# tree = execute("inspect", {"hwnd": hwnd})
# execute("invoke", {"hwnd": hwnd, "selector": {"ref": control_ref}})
```

建议给 agent 的简短指令：

> 先发现窗口并读取控件，优先使用控件接口。操作后重新检查控件或截图，核对用户要求的结果。界面变化时重新检查。超时后先检查实际状态，再决定是否重试。只操作用户任务涉及的软件与内容。

启动、点击和控件操作会立即执行，调用方应按用户授权范围选择动作。没有开放任意 shell 执行或网络端口。

## 验证与限制

```powershell
python -m unittest -v test_computer_agent
python test_computer_agent.py --desktop
```

第一条验证协议和参数约束。第二条打开专用 WPF 测试窗口，枚举控件、设置文本、UIA 点击按钮并核对按钮写出的真实结果、保存并对比截图、验证同图零变化、测试窗口内坐标点击，最后关闭测试窗口。测试会短暂占用鼠标与前台焦点。

软件清单来自当前用户及系统 32/64 位卸载注册表；便携软件和部分 Store 软件可能缺失。display_icon 可能带图标索引或指向卸载程序，不能直接当作启动路径。应用专属业务 API 可在上层追加适配器，这里提供通用 Windows UIA 接口。

在 DSH 等沙箱内，临时目录、进程启动、注册表或桌面访问可能需要宿主授权。可在普通本地 PowerShell 运行。后端超时表示动作状态可能未知，应先检查。本工具不支持锁屏、UAC 安全桌面或 Windows 服务会话。不同软件的 UIA 支持程度不同，自绘画布可能只能截图定位点击。当前机器的经典 WinForms 测试控件被 UIA 识别为 Pane，未暴露编辑和按钮接口；此类控件需要截图点击或后续补充 Win32 适配器。WPF 控件接口使用专用窗口验证。相关兼容性现象也见[公开案例](https://cloud.tencent.com/developer/ask/sof/114060301?from=16139)。当前未实现通用键盘快捷键、拖拽或滚轮。
