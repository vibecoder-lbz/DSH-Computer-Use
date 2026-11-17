# 电脑控制 · 后台优先（自动接管）0.2.0

Windows DeepSeek Harness 插件，无需 Python、虚拟机或额外服务，使用系统 Windows PowerShell 5.1 与 WPF。

原生后端是常驻进程：PowerShell 启动与 C# 编译只发生一次，之后每次调用通过目录握手传递请求。实测冷启动约 1.7 秒，后续调用约 0.08–0.2 秒；空闲约 10 分钟自动退出，插件卸载时立即结束，单次请求超过 35 秒会终止工作进程。

## 控制优先级

1. **后台控件接口**：标准 Win32 `Edit` 用 `WM_SETTEXT`，`Button` 用 `BM_CLICK`。
2. **后台消息输入**：按控件选择器或坐标向控件投递鼠标消息、`WM_CHAR` 和按键消息，不改变系统焦点；按钮类控件用 `BM_CLICK`。被其他窗口遮挡时仍然有效。
3. **自动接管**：消息被目标忽略时返回 `takeover_required`，插件随即在当前桌面显示接管效果、聚焦目标窗口并执行同一个动作，不逐次提问。

现代自绘界面（Qt、WPF、Electron、游戏画面）通常忽略投递消息，会转入前台。`Ctrl+` 组合键、拖拽和真实指针移动始终需要前台。已确认没有后台适配的控件能力在本次运行期间缓存，避免重复探测。

## 坐标

截图使用 PrintWindow，并裁剪到**可见窗口区域**（DWM 扩展边框），因此图像像素与点击坐标一一对应。使用 `selector` 点击时，直接取 UI Automation 控件矩形的中心，不依赖像素估算。返回结果包含实际点击的屏幕坐标、命中控件类名与控件矩形，便于核对。进程声明 DPI 感知，坐标统一为物理像素。

## 接管显示

直接叠加在当前桌面：屏幕外缘深蓝，向内渐浅并透明，55 像素内凹光晕与细边高光；约 120 颗浅蓝粒子从四边向内收拢并在 90 像素内消散，不覆盖中央。DeepSeek 官方小鲸鱼替代普通鼠标（素材来源 https://www.deepseek.com/favicon.ico），无鼠标轨迹。结束后恢复 Windows 鼠标主题，独立恢复进程处理异常退出。

## 工具

- `computer_apps` / `windows` / `inspect` / `wait` / `compare` / `screenshot`：检查。
- `computer_act`：`invoke`、`set_value`、`select`、`click`、`move`、`type`、`key`、`scroll`。`click` 可传 `selector` 或 `x`/`y`。
- `computer_takeover`：仅 `status`、`release`；自动接管由 `computer_act` 内部启动。
- `computer_stop`：立即停止。

窗口消息超时表示状态未知，不自动重试或接管重发。

## 安全边界

接管 120 秒后自动结束，不自动续期；同一时间一个会话控制一个窗口；不锁住用户输入，检测到鼠标移动冲突、前台窗口变化、目标移动或按住修饰键时停止动作。`Ctrl+Alt+Esc` 紧急停止。自动接管会占用鼠标键盘，用户可随时停止。实际业务操作仍以用户任务授权为准。

后台截图可能为空或陈旧；有本会话接管时截取可见像素。只读截图失败不会自行切前台。操作后应检查结果，发消息等授权不由视觉效果替代。

## 安装与测试

通过 `plugin_manager` 的 `install_bundle` 安装此目录或 `npm pack` 生成的 tgz；停用旧版避免工具重名。目录链接会读取新的原生脚本，但运行中的 JavaScript 模块有缓存，更新后需重启 Harness 完整加载。无需 npm 依赖或安装脚本。

```powershell
node integration.test.js   # 自动接管、实际输入、截图附件、会话隔离、紧急停止
node background.test.js    # 后台输入、按控件点击、后台按键、焦点不变
```

两个测试都只操作自己创建的专用测试窗口。

所有软件在同一桌面运行，后台接口尽力兼容，无法保证目标软件自身永不弹窗。当前未内置 Office COM、浏览器 API 等专属适配器。
