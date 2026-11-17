# Wuwa Tappo AutoTap

用于 Windows 的 Wuwa Tappo 自动刷键工具。双击启动，默认按 **F6** 开始或暂停，按 **F10** 退出；支持自定义快捷键、每秒 1–200 次和达到目标后自动停止。

安装目录不需要与作者相同。工具会尝试自动查找 Wuwa Tappo，也可以通过文件选择窗口指定任意磁盘上的 `WuwaTappo.exe`，包括含空格或中文的路径。

## 运行要求

- Windows 10 / Windows 11 桌面系统。
- Windows 自带的 **Windows PowerShell 5.1** 和 .NET Framework / Windows Forms，通常无需额外安装。
- 已安装、能够正常运行的 Wuwa Tappo。

本项目使用 Windows 系统接口，不支持直接在 macOS、Linux、手机或浏览器中运行。Windows on ARM 尚未验证；受组织策略限制而禁用脚本或动态编译的电脑也可能无法运行。无法保证每个 Tappo 版本都接受模拟输入。

## 下载与启动

1. 在 GitHub 仓库页面点击 **Code → Download ZIP**，将 ZIP **完整解压**到自己的用户目录，例如“文档”或“下载”。不要在压缩包预览窗口中直接运行。
2. 双击解压后的 **Start.cmd**。请保留它和 `WuwaTappo-AutoTap.ps1` 在同一文件夹中。
3. 先启动 Wuwa Tappo。脚本会尝试从已运行进程、安装信息和常见目录查找路径。
4. 未找到时，点击窗口底部的 **选择程序**，定位实际安装目录里的 `WuwaTappo.exe`。以后启动会使用保存的路径；搬迁安装目录后可以重新选择。
5. 先将目标设为 **100**，点击“开始”或按 **F6**。比较 Tappo 内的计数变化，确认有效后再提高速度或持续运行。

如果 Tappo 已运行，即使无法读取其安装路径，也可以直接开始发送；只有从工具中启动 Tappo 时才必须提供正确路径。

## 功能与快捷键

| 项目 | 行为 |
| --- | --- |
| 开始 / 暂停 | 默认 **F6**；暂停后继续保留累计发送次数 |
| 退出 | 默认 **F10**；关闭窗口也会停止发送 |
| 速度 | **1–200 次/秒**，默认 20；暂停后可修改 |
| 目标次数 | `0` 表示持续运行；其他值表示累计发送达到该值后停止 |
| 达到目标后重新开始 | 自动从 0 重新计数 |
| 清零发送次数 | 暂停后可用 |
| 自动暂停 | Tappo 退出后约一秒内暂停 |
| 组合键保护 | 按住 Ctrl、Alt、Shift 或 Win 时暂缓发送 |

修改快捷键：在窗口下方选择主键，可搭配 **Ctrl / Alt / Shift**，点击 **应用并保存快捷键**。两个动作不能使用相同组合；如果被其他程序占用，修改会被拒绝并尝试恢复原绑定。启动时若热键已被占用，请使用窗口按钮重新选择。部分笔记本的功能键需要配合 **Fn**，也可以改用 Insert、Home 等主键。

## 设置保存在哪里

快捷键和程序路径默认保存在当前 Windows 用户的：

```text
%LOCALAPPDATA%\WuwaTappoAutoTap\settings.json
```

不同电脑、不同用户分别保存。程序文件夹可以移动，设置不依赖安装盘符；无需修改脚本源码。旧版本脚本旁的 `settings.json` 会在没有新配置时作为迁移来源，下一次保存写入新的用户配置目录。

设置文件是本地个人配置，不包含在 Git 提交中。若要恢复所有设置，退出脚本后备份并移走上述配置文件；快捷键也可直接点“恢复默认快捷键”。

## 发送次数与实际计数

工具交替发送 **F13 / F14** 的按下和松开事件。这些键不会输入普通文字，但前台软件仍可能收到它们；如果你为 F13 / F14 绑定过其他操作，运行前请先处理相关冲突。

窗口中的数字是 **Windows 接受的模拟按键次数**，不是从 Tappo 读取的实际计数。Tappo 的版本、运行状态和计数规则可能影响实际增量。速度使用独立线程及高精度计时，200 次/秒是期望值，系统负载和软件处理速度可能使实际速度较低。

## 常见问题

**找不到安装路径**：点击“选择程序”手动定位 `WuwaTappo.exe`。自动查找不会扫描整块硬盘；自定义目录可能无法自动识别。

**发送次数增长，但 Tappo 不计数**：先暂停，确认 Tappo 已启动完成且没有阻塞更新；如果它以管理员权限运行，可以右键 `Start.cmd`，选择“以管理员身份运行”后重试。仍无效时，当前 Tappo 版本可能不接受模拟输入，无法保证通过提高速度解决。

**热键无效**：查看窗口内的占用提示，换成其他主键或增加 Ctrl / Alt。笔记本检查 Fn / Fn Lock。按钮和窗口关闭功能始终可用。

**保存失败**：确认当前用户可以写入配置目录。通常不需要管理员权限。命令行可以用 `-ConfigPath` 指定自己可写入的位置。

**下载文件被标记或组织策略禁止执行**：先检查源码并遵守所在组织的设备策略。启动器仅对它启动的 PowerShell 进程指定执行策略参数，不修改系统执行策略；它不能绕过组织强制策略。

## 命令行选项

在项目目录打开 PowerShell：

```powershell
# 以 200 次/秒、目标 1000 次打开界面；仍需点击开始或按 F6
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\WuwaTappo-AutoTap.ps1 -Rate 200 -Count 1000

# 可选：自行指定安装路径（请替换为本机实际路径）
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\WuwaTappo-AutoTap.ps1 -AppPath 'E:\Games\WuwaTappo\WuwaTappo.exe'

# 可选：改用项目目录内的配置文件
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\WuwaTappo-AutoTap.ps1 -ConfigPath '.\settings.json'

# 自检：不会发送真实按键，也不会修改个人设置
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\WuwaTappo-AutoTap.ps1 -SelfTest
```

自检会编译输入模块，检查 Windows 输入结构，以及用模拟回调验证 200 次/秒调度、目标停止、暂停和清零。通过自检不代表 Tappo 实际接受了模拟输入，仍应完成首次 100 次试运行。

## 项目文件

| 文件 | 用途 |
| --- | --- |
| `Start.cmd` | 双击启动入口 |
| `WuwaTappo-AutoTap.ps1` | 窗口、路径查找、设置和输入逻辑 |
| `README.md` | 完整说明 |
| `.gitignore` | 排除本地配置和临时文件 |
| `.gitattributes` | 保持 Windows 脚本的换行格式 |

本工具不包含 Wuwa Tappo 程序，不修改它的程序文件或存档，也不添加开机启动项。它是独立的社区脚本，与 Wuwa Tappo 官方无关联。

## 实现参考

- Microsoft：[SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)、[高精度等待计时器](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)。
- F13/F14 的选择参考 [Wuwa Tappo Linux 输入桥](https://github.com/Alphaproject1998/wuwa-tappo-linux#the-bridge)，其 Wine 环境下的结果不保证适用于所有 Windows 版本。
