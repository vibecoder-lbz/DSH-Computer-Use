# 电脑控制 · 后台优先（自动接管）

Windows DeepSeek Harness 插件，无需 Python 或虚拟机，使用系统 Windows PowerShell 5.1 和 WPF。

按用户的持久授权，computer_act 优先后台接口；后台不支持时直接显示接管效果、聚焦目标窗口并执行同一个动作，不再逐次提问。鼠标键盘操作已知需要前台，跳过多余探测；已失败的后台能力在插件本次运行期间缓存，减少重复调用。实际业务操作仍以用户任务授权为准。

接管显示直接叠加在当前桌面：屏幕外缘深蓝色，向内部渐浅并透明，55像素内凹光晕与细边高光；约120颗浅蓝粒子从四边向内收拢并在90像素以内消散，不覆盖中央。DeepSeek官方小鲸鱼替代普通鼠标（素材来源 https://www.deepseek.com/favicon.ico），不显示鼠标轨迹或拖影。结束后恢复Windows鼠标主题，独立恢复进程处理异常退出。

computer_apps/windows/inspect/wait/compare/screenshot 为检查工具。computer_act 支持 invoke/set_value/select/click/move/type/key/scroll。当前后台写入支持标准Win32 Edit WM_SETTEXT与Button BM_CLICK；现代自绘控件通常会转入前台。窗口消息超时表示状态未知，不自动重试或接管重发。

computer_takeover 仅保留 status 查看状态、release释放；自动接管由 computer_act 内部启动，不再使用 begin/ticket/seconds 参数。computer_stop立即停止。Ctrl+Alt+Esc紧急停止。接管120秒后自动结束，同一时间只允许一个会话控制一个窗口；不锁住用户输入，检测到鼠标移动冲突或前台窗口变化时停止动作。自动接管会占用鼠标键盘，用户可随时停止。

后台截图使用PrintWindow，可能为空或陈旧；有本会话接管时截取可见像素。只读截图失败不会自行切前台。操作后应检查结果；发消息等授权不由视觉效果替代。

通过plugin_manager install_bundle安装此目录或npm pack生成的tgz；停用旧版避免工具重名。已安装的目录链接会读取新的原生脚本，但运行中的JavaScript模块有缓存，更新后需重启Harness完整加载。无需npm依赖或安装脚本。测试 node integration.test.js 在专用窗口验证自动接管无提问、实际输入与按钮结果、图像附件和紧急停止。

所有软件在同一桌面运行，后台接口尽力兼容，无法保证目标软件自身永不弹窗。当前未内置Office COM、浏览器API等专属适配器。
