# DSH-Computer-Use

DeepSeek Harness 的 Windows 电脑控制插件。Agent 可以发现软件、读取窗口和控件、点击和输入，并通过截图核对结果。

**推荐安装 `desktop-auto`，当前版本 0.2.0。** 后台接口优先：标准 Win32 控件可以直接读取和操作，不需要把窗口切到前台；无法后台完成时才自动接管当前桌面，显示蓝色内凹边缘、内收粒子与 DeepSeek 鲸鱼光标。PowerShell 辅助进程以隐藏方式常驻，单次调用通常在 0.1 秒量级。

## 环境要求

- Windows 10/11，已登录且未锁屏的交互桌面。
- 已安装并运行 DeepSeek Harness，具有插件管理与工具调用能力。
- 系统自带 Windows PowerShell 5.1、.NET Framework/WPF。
- 从源码克隆需要 Git；运行开发测试、打包需要 Node.js 与 npm。

最新版插件不需要虚拟机、额外 API Key、MCP 服务或单独启动后端。模型由 Harness 配置；需要根据截图操作时，应使用支持图像输入的模型。控制管理员权限运行的软件时，Harness 也可能需要相同权限。

## 安装

### 1. 下载项目

在 PowerShell 中运行：

```powershell
git clone https://github.com/vibecoder-lbz/DSH-Computer-Use.git
Set-Location .\DSH-Computer-Use
Resolve-Path .\desktop-auto
```

记下最后输出的绝对路径。例如克隆到 `D:\project` 后，插件路径为 `D:\project\DSH-Computer-Use\desktop-auto`。

**安装目标必须是 `desktop-auto` 子目录。** 仓库根目录仅提供项目说明，插件入口位于该子目录。

### 2. 在 Harness 中安装

在 Harness 对话中告诉 Agent（把路径换成你自己的）：

> 请使用 plugin_manager 安装本地插件 D:\project\DSH-Computer-Use\desktop-auto，并启用。若已有旧版电脑控制插件，请停用或卸载旧版，保留 dsh-desktop-auto。

Agent 使用的工具参数如下；这是 Harness 工具调用，不是 PowerShell 命令：

```json
{
  "action": "install_bundle",
  "target": "D:\\project\\DSH-Computer-Use\\desktop-auto",
  "enabled": true
}
```

安装影响当前 Harness profile。是否需要用户批准取决于当前权限模式；无需手动编辑 profile 的配置文件或安装依赖。

### 3. 确认安装

在 Harness 的插件页面确认出现并启用 **“电脑控制 · 后台优先”**，描述包含自动接管、内收粒子和鲸鱼图标。包名应为 `dsh-desktop-auto`。

可以让 Agent 执行一次只读检查：

> 请列出当前电脑窗口，并查看电脑接管状态，不进行点击或输入。

正常情况下，Agent 能调用 `computer_windows`，且 `computer_takeover` 的状态为 `active: false`。首次安装是否立即生效以插件管理器返回结果为准；提示需要重启时，重启 Harness。

## 配置与默认行为

**当前没有需要填写的插件配置项，使用默认配置 `{}` 即可。** 不需要填写端口或密钥。

| 项目 | 当前行为 |
| --- | --- |
| 控制方式 | 优先后台接口；不支持时自动前台接管并执行原动作 |
| 后台进程 | PowerShell 常驻进程，编译一次后重复使用；空闲约 10 分钟自动退出 |
| 后台控件操作 | 标准 Win32 Edit 文本设置、Button 点击调用 |
| 后台点击 | 按控件选择器或坐标向控件投递消息，按钮类使用 `BM_CLICK`，其余使用鼠标消息 |
| 后台输入 | 向标准文本控件投递 `WM_CHAR`，不抢系统焦点 |
| 后台按键 | Enter/Tab/Escape/Backspace/Delete/方向键/Home/End/PageUp/PageDown；`Ctrl+` 组合键需要前台 |
| 前台输入 | 自绘界面（Qt、WPF、Electron 等）需要真实鼠标键盘，自动接管后执行 |
| 坐标基准 | 截图裁剪到窗口可见区域，点击坐标与该图像像素一一对应 |
| 精确点击 | 用 `selector` 指定控件时按控件自身矩形中心点击，不需要估算像素 |
| 接管提示 | 当前桌面蓝色边缘、内收粒子和鲸鱼光标，无鼠标轨迹 |
| 辅助进程 | 隐藏启动 PowerShell，接管光效仍然可见 |
| 接管时长 | 每次最多 120 秒，不自动续期 |
| 会话归属 | 同一时间一个会话控制一个目标窗口 |
| 紧急停止 | `Ctrl+Alt+Esc`，也可让 Agent 调用 `computer_stop` |
| 控制结束 | 移除覆盖层，恢复 Windows 鼠标主题 |
| 后台截图 | 使用 PrintWindow，裁剪为可见窗口；可能为空或陈旧，不因截图失败自动切前台 |

以上是代码中的默认行为，当前未提供通过设置面板修改时长、光效或接管模式的选项。Harness 自身的权限与审批仍然有效；自动接管不代表可以执行用户未授权的业务操作。

## 使用教程

安装后直接向 Harness 描述任务即可，无需自己调用脚本。例如：

> 查看当前打开的软件和窗口。

> 打开记事本，输入“电脑控制测试”，核对文字后停止接管，不保存文件。

> 打开微信，找到名为“示例群”的群聊，发送“测试消息”，发送后核对结果并结束接管。

发送消息类任务请给出准确的目标和完整内容。插件本身没有 `computer_launch` 工具；打开尚未运行的软件时，Agent 需要结合 Harness 的其他已授权工具启动程序，再使用电脑控制工具继续操作。

### 推荐操作顺序

1. 先调用 `computer_windows` 获取目标窗口句柄 `hwnd`。
2. 调用 `computer_inspect` 查看控件，或调用 `computer_screenshot` 查看窗口画面。
3. 优先通过控件执行 `invoke`、`set_value`、`select`；无法后台执行时会自动接管。
4. 需要点击控件时，用 `selector` 让插件按控件自身矩形中心点击；只有没有可用控件时才用截图估算坐标。
5. 操作后重新读取控件或截图核对实际结果；完成后释放接管。

接管期间会占用鼠标键盘。用户移动鼠标造成冲突、切换前台窗口或按住修饰键时，相关输入检查可能取消动作；需要中止时直接按 `Ctrl+Alt+Esc`。

### 为什么坐标有时不准

旧实现按窗口整体外框截图，但点击原点取自窗口外框，两者相差一条不可见的 DWM 边框，像素估算会有几像素偏移。现在：

- 截图裁剪到**可见窗口区域**，图像像素与点击坐标一一对应。
- 用 `selector` 点击时直接取 UI Automation 报告的控件矩形中心，不受窗口边框、缩放或估算误差影响。
- 返回结果包含实际点击的屏幕坐标、命中控件类名和控件矩形，便于核对。

在 125% 或 150% 缩放下，插件进程已声明 DPI 感知，坐标统一使用物理像素；多屏负坐标也按实际桌面原点处理。

### 为什么切换窗口后还能后台操作

后台输入不使用真实鼠标键盘，而是向目标控件投递窗口消息，因此不需要目标窗口位于前台：

- 点击：按钮类控件用 `BM_CLICK`，其他标准控件投递鼠标按下/抬起消息；被其他窗口遮挡时同样有效。
- 输入：向标准文本控件投递 `WM_CHAR`，并用 `WM_SETFOCUS` 维持控件内部焦点，不改变系统焦点。
- 按键：Enter、Tab、Escape、Backspace、Delete、方向键、Home、End、PageUp、PageDown。

适用条件是控件使用**标准窗口过程**：经典 Win32 程序、WinForms，以及大量企业软件的输入框和按钮。现代自绘界面（Qt 的微信、WPF、Electron、游戏界面）会忽略这类消息，插件会明确返回 `takeover_required` 并自动接管，不会假装成功。`Ctrl+` 组合键、拖拽和真实指针移动同样需要前台。

### Agent 工具参考

以下 JSON 是工具参数示例。示例句柄 `123456` 与控件引用需替换成当前检查结果，不能直接照抄。

| 工具 | 用途 | 参数示例 |
| --- | --- | --- |
| `computer_apps` | 查询卸载注册表中的软件 | `{"query":"微信","limit":20}` |
| `computer_windows` | 列出桌面窗口 | `{}` |
| `computer_inspect` | 读取有限深度的控件树 | `{"hwnd":123456,"limit":150,"depth":5}` |
| `computer_wait` | 等待匹配控件出现 | `{"hwnd":123456,"selector":{"name":"完成"},"timeout_ms":5000}` |
| `computer_screenshot` | 截取目标窗口，返回图像附件 | `{"hwnd":123456}` |
| `computer_act` | 控件操作、点击或输入 | `{"hwnd":123456,"operation":"type","text":"你好"}` |
| `computer_compare` | 比较同尺寸 PNG 的像素变化 | `{"before":"D:\\before.png","after":"D:\\after.png"}` |
| `computer_takeover` | 查看状态或释放本会话接管 | `{"action":"status"}` 或 `{"action":"release"}` |
| `computer_stop` | 立即停止插件接管 | `{}` |

`computer_act` 支持 `invoke`、`set_value`、`select`、`click`、`move`、`type`、`key`、`scroll`。例如：

```json
{"hwnd":123456,"operation":"set_value","selector":{"ref":"当前 inspect 返回的引用"},"value":"你好"}
```

```json
{"hwnd":123456,"operation":"click","selector":{"name":"确定"}}
```

```json
{"hwnd":123456,"operation":"click","x":200,"y":150}
```

```json
{"hwnd":123456,"operation":"key","key":"Enter"}
```

只填写该操作需要的参数。控件选择条件必须非空且唯一，多个条件同时满足；界面变化后重新检查。输入文本上限为 2000 个 UTF-16 代码单元。常用按键包括 Enter、Tab、Escape、方向键和 Ctrl+A/C/V/S；不支持任意组合键。截图比较只能说明像素变化，不能替代业务结果核对。

## 更新与卸载

源码安装使用本地目录链接，请保留安装目录。拉取更新：

```powershell
Set-Location D:\project\DSH-Computer-Use
git pull --ff-only
```

**更新后重启 Harness，完整加载新的 JavaScript 模块。** 仅刷新网页不等于重载 Host 插件。若安装器报告 `already-installed`，不要重复安装；目录链接更新通常只需拉取代码并重启。切换到其他安装路径或安装包时，可让 Agent 通过插件管理器卸载旧包，再安装新目标。

卸载时告诉 Agent：

> 请停止电脑接管，并通过 plugin_manager 卸载 dsh-desktop-auto，保留其他插件。

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| 找不到 `computer_*` 工具 | 确认安装的是 `desktop-auto`，在当前 profile 已启用；按安装结果提示重启 |
| 插件页面出现多个电脑控制插件 | 保留 `dsh-desktop-auto`，卸载旧的 `dsh-computer-use-windows`、`dsh-computer-use-background`、`dsh-desktop-hybrid` |
| 后台操作变成桌面接管 | 目标软件缺少适用的后台接口，属于默认行为；现代自绘软件经常需要前台 |
| 截图黑屏、空白或陈旧 | PrintWindow 对部分 GPU 窗口支持有限；不能将空白图当作操作成功 |
| 无法操作最小化窗口 | 部分操作要求窗口可见；需要根据当前状态恢复窗口后重新检查 |
| 输入中途停止 | 检查是否超出 120 秒、焦点改变、用户移动鼠标、目标窗口移动或按住修饰键 |
| 前台坐标点击偏移几像素 | 优先改用 `selector` 点击控件；坐标点击请以插件返回的截图为准，不要使用旧截图 |
| 切换窗口后仍转前台 | 目标控件是自绘界面或 `Ctrl+` 组合键、拖拽、指针移动，这些确实需要前台 |
| 后台操作显示成功但界面没变 | 目标是自绘控件，消息被忽略；查看 `takeover_required` 或改用前台接管后重新核对 |
| 后台点击命中了别的窗口 | 已优先使用 UI Automation 元素句柄；仍异常时改用 `selector` 或先截图确认窗口位置 |
| 操作超时 | 先检查目标实际状态，再决定后续动作，避免重复发送或提交 |
| 控制管理员软件失败 | 检查 Harness 与目标程序的权限等级；UAC 安全桌面不受支持 |
| 仍出现 PowerShell 窗口 | 确认使用 0.2.0 或更新代码并已重启 Harness；插件不会隐藏用户自行打开的终端 |

软件清单来自卸载注册表，可能缺少便携软件和部分 Store 应用。插件不能保证任意软件都能后台操作；不支持锁屏桌面、UAC 安全桌面、通用拖拽和 Office COM 专属适配。

## 开发与验证

修改插件后可在专用测试窗口运行集成测试，测试会短暂占用前台鼠标键盘：

```powershell
Set-Location .\desktop-auto
node --check index.js
node integration.test.js
node background.test.js
```

`integration.test.js` 覆盖自动接管无提问、实际输入和按钮结果、截图附件、会话隔离与紧急停止。`background.test.js` 使用专用经典 Win32 测试窗口，验证后台输入、按控件点击、后台按键和焦点不被改变；测试只操作自己创建的窗口。打包可运行 `npm pack`，生成的 `.tgz` 可作为 Harness 插件安装目标。仓库通过 `.gitignore` 排除桌面截图、缓存和生成的安装包。

### 性能说明

原生后端改为**常驻进程**：PowerShell 与 C# 辅助代码只编译一次，之后每次调用通过目录握手交换请求，实测冷启动约 1.7 秒，后续调用约 0.08–0.2 秒。工作进程空闲约 10 分钟自动退出，插件卸载时立即结束；单次请求超过 35 秒会终止工作进程，避免卡死的窗口消息拖住后续操作。整体耗时仍包含模型推理和窗口自身响应时间，这部分不由插件决定。

## 目录说明

| 目录或文件 | 用途 |
| --- | --- |
| [desktop-auto](./desktop-auto/README.md) | 当前维护的插件，0.2.0 |

鲸鱼光标素材来源：[DeepSeek 官方站点 favicon](https://www.deepseek.com/favicon.ico)。
