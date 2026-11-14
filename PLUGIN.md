# DeepSeek Harness 插件：Windows 电脑控制

此目录是可直接安装的 Cordis Host 插件 bundle，包名 `dsh-computer-use-windows`。插件安装到当前 profile 后持久生效，所有会话的 agent 可发现 `computer_*` 工具，无需手动运行 Python CLI。

## 使用

在 Harness 对话中直接描述任务，例如：

- “查看电脑安装了哪些软件，找一下 Chrome。”
- “查看当前打开的窗口，检查指定窗口有哪些按钮。”
- “截图检查软件界面，点击指定按钮，然后验证操作结果。”

工具：`computer_apps`、`computer_windows`、`computer_inspect`、`computer_launch`、`computer_invoke`、`computer_set_value`、`computer_select`、`computer_wait`、`computer_click`、`computer_screenshot`、`computer_compare`。

推荐顺序：软件/窗口发现 → inspect → 控件操作 → inspect/screenshot 验证。UIA 不可用时截图定位，以窗口外框左上角为原点进行 click。坐标为物理像素。截图自动保存为 Harness 持久图像附件并进入工具结果，支持图像的模型能直接查看；纯文本模型只能检查控件或图片路径。

插件在所有会话之间串行执行自己的桌面动作；用户或其他插件仍可能改变桌面，变化后必须重新检查。操作会立即影响真实桌面，可能激活窗口并移动鼠标。遵循用户任务范围执行。像素变化不代表业务任务已成功。

## 安装

通过 Harness 插件管理工具 `install_bundle` 安装此目录的绝对路径。不要手动编辑 profile 的 package.json 或 cordis.patch.yml。也可 `npm pack` 打包，然后在 Harness 中安装生成的 tgz。插件不含 npm 依赖和安装脚本。

依赖 Windows 10/11、PATH 中的 Python 3.10+ 和系统自带 Windows PowerShell。可在插件配置中提供 `python` 字段指定 Python 可执行文件绝对路径。必须在已登录、未锁屏的桌面运行 Harness。该插件直接控制 Harness 所在的 Windows 主机，不是在隔离桌面或浏览器副本中操作。

## 文件

- index.js：工具注册、串行队列、后端进程和图像附件。
- tool-schemas.json：由 Python describe 生成的工具定义。
- computer_agent.py / windows_backend.ps1：验证参数、调用 Windows UI Automation 和截屏。
- cordis.patch.yml：持久加载插件的 bundle patch。
- locale/en.json / locale/zh.json / icon.svg：插件管理器展示资源，图标为本项目原创。

## 验证

`node --test plugin.test.js` 验证工具注册、清理、软件读取、窗口检查、截图渲染和无效输入。

`python test_computer_agent.py --desktop` 在专用 WPF 窗口验证文字输入、UIA 按钮调用、实际结果文件、截图变化和坐标点击。

本机发现经典 WinForms 控件被 UIA 识别为 Pane，不能保证任意软件都有可编辑的控件接口；必要时截图点击，文字输入等需后续补充适配。当前不提供通用快捷键、拖拽或滚轮，也没有应用业务 API 适配器。软件清单来自卸载注册表，可能遗漏便携软件及部分 Store 软件。超时或取消后先检查实际状态，避免重复动作。

截图未指定路径时使用临时目录中的唯一 PNG，并将图像内容保存到 Harness 附件存储。可显式指定绝对 PNG 路径保留截图；截屏是可见像素，会包含遮挡窗口的内容。
