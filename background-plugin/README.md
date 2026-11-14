# Windows 后台控制（只读）

DeepSeek Harness 插件 `dsh-computer-use-background`。当前按用户选择只提供后台读取和截图，不点击、输入、选择、启动、激活或恢复目标窗口，不移动鼠标，不使用键盘输入，不自动降级到前台操作。

## 工具

- `computer_apps`：读取卸载注册表中的软件列表。
- `computer_windows`：枚举窗口，包括后台和最小化窗口，返回 offscreen/minimized 状态。
- `computer_inspect`：读取窗口 UI Automation 控件树。
- `computer_wait`：只等待读取到指定控件，不执行控件动作。
- `computer_screenshot`：必须提供 hwnd；调用 PrintWindow 请求目标窗口绘制，不激活窗口，不截取当前桌面。截图作为 Harness 图像附件返回。
- `computer_compare`：比较两张本地 PNG 的采样像素变化。

举例：“后台查看微信窗口，不要切换前台，能截图就截图，不支持就停止。”

`computer_click`、`computer_launch`、`computer_invoke`、`computer_set_value`、`computer_select` 不注册；即便绕过工具层直接调用 Python/PowerShell 后端，这些动作也会报错。后台只读版替换当前 profile 中原先启用的前台控制版；旧版保留安装但停用。

## 能力边界

PrintWindow 依赖目标软件配合。GPU、自绘窗口可能返回空白、旧画面或不完整内容。最小化截图会直接报错，不擅自恢复窗口。截图接口返回成功也不能证明图片完整，视觉模型仍需检查内容。UIA 不完整时，控件树可能只有几个 Pane；不使用坐标点击补救。

每次读取返回 background_observation，记录操作前后前台窗口和鼠标位置是否相同。这只是观察值，用户自己的活动和应用自身行为也可能改变它们；不是独立桌面隔离的证明。PrintWindow/控件提供程序超时会返回失败，不重复操作或自动激活窗口。

实测 WPF ValuePattern.SetValue 也可能让应用改变焦点，因此当前禁用全部写入控件操作。要支持微信等软件的完整后台控制且保证不干扰用户，需要独立 Windows 虚拟机或另一台执行电脑；Windows 的 Win+Tab 虚拟桌面不等同于独立输入会话。当前没有部署隔离执行端，也没有发送微信群聊消息。

## 环境及安装

需要 Windows 10/11、Python 3.10+（默认 PATH 中的 python）、系统 Windows PowerShell 5.1。通过 Harness plugin_manager install_bundle 安装此目录或 npm pack 生成的 tgz。无 npm 依赖或安装脚本。

图标为项目原创，中英文元数据在 locale 下。所有桌面任务串行执行；执行器不对外监听端口。

## 验证

`python test_background.py` 使用 ShowActivated=false、屏幕外的专用 WPF 测试窗口验证后台读取、等待、截图，检查前台窗口和鼠标位置观察值，并验证所有写入动作被拒绝。它不操作用户软件，也不测试发消息。
