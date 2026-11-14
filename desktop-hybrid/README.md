# 电脑控制 · 后台优先

DeepSeek Harness Windows 原生插件，无需 Python 或虚拟机。依赖系统自带 Windows PowerShell 5.1、.NET Framework WPF 和 Windows 10/11 交互桌面。

## 行为

先用 computer_windows / computer_inspect / computer_screenshot 读取目标，再调用 computer_act。操作始终先尝试后台接口。当前后台写入适配传统 Win32 Edit 的 WM_SETTEXT 和 Button 的 BM_CLICK，使用有时限的窗口消息；不支持的软件和操作返回 takeover_required 与短期 ticket，不自动激活窗口。

agent 可用 ticket 调用 computer_takeover begin。Harness 显示目标窗口名、原因和接管时长的确认问题；未选择允许时不会接管。确认后在整个屏幕四周显示淡蓝色渐变灯光：40 像素向内扩散的光晕、轻微呼吸亮度和细亮边线；保留控制标签，直接叠加在用户当前桌面上，不创建独立的操作页面或将应用最大化。使用跟随当前鼠标位置的 32 像素 DeepSeek 官方小鲸鱼系统指针（图像来源：https://www.deepseek.com/favicon.ico），接管期间替换常见系统鼠标形状，不再叠加第二个指针；结束时恢复用户鼠标主题，独立恢复进程负责异常退出后的恢复；不显示移动轨迹、渐隐光点或拖影。灯光覆盖完整虚拟桌面的外边缘，不跟随软件窗口大小；实际输入仍只授权到所选窗口。此显示层属于真实 Windows 桌面，非网页装饰；鼠标穿透，不获取键盘焦点。

接管最长 120 秒，默认60秒，不自动续期。只允许发起会话控制所选窗口。Ctrl+Alt+Esc 紧急停止；computer_stop 可立即停止；computer_takeover release 结束任务。到期、插件卸载、Host退出或视觉进程终止时拒绝后续输入。不要在接管期间继续输入；插件不锁定用户鼠标键盘。用户在 agent 平滑移动鼠标期间移动指针会取消动作；这不等于拦截所有用户输入。

## 工具

保留 computer_apps、computer_windows、computer_inspect、computer_wait、computer_compare、computer_screenshot。截图后台用 PrintWindow；有本会话有效接管时可截取可见窗口像素。GPU、自绘和最小化窗口可能无法后台截图；失败不自动切前台。

computer_act 支持 invoke/set_value/select 和接管后的 click/move/type/key/scroll。x/y 是窗口外框左上角相对物理像素。后台尝试不等于任务完成，应检查返回值并重新读取控件或截图。窗口消息超时会报告状态未知，不应自动重复发送。通用 API、Office COM 和浏览器接口等应用专属适配器尚未内置。

确认接管和确认业务动作是两件事；agent 仍需遵守用户对发送、保存等操作的授权。插件不会自动发送微信消息。

## 使用示例

“优先在后台操作这个软件，无法后台完成时请求接管，完成后释放。”

agent 顺序：发现窗口 → 读取控件 → computer_act 尝试后台 → 如返回 ticket，computer_takeover begin → 用户确认 → computer_act 前台操作 → 截图核对 → computer_takeover release。

后台接口是尽力兼容，软件自身可能改变窗口；要完全隔离所有软件行为仍需独立执行环境。插件不会用驱动注入或修改目标进程。

## 安装与验证

通过 Harness 插件管理器 install_bundle 安装当前目录或 npm pack 生成的 tgz。旧前台版和只读后台版需停用以避免工具重名。包无需 npm依赖或安装脚本。

测试在专用窗口进行，不操作用户微信。图标为项目原创；locale 含中英文插件展示信息。
