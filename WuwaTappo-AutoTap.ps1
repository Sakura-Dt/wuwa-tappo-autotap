[CmdletBinding()]
param(
    [string]$AppPath = '',
    [string]$ConfigPath = '',
    [ValidateRange(1, 200)][int]$Rate = 20,
    [ValidateRange(0, 1000000000)][long]$Count = 0,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This tool requires Windows 10/11 and Windows PowerShell 5.1.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;

namespace TappoAutoTap {
    public class ControlWindow : Form {
        public event Action ToggleRequested;
        public event Action ExitRequested;
        public bool ToggleRegistered { get; private set; }
        public bool ExitRegistered { get; private set; }
        public uint ToggleKey = 0x75, ExitKey = 0x79;
        public uint ToggleModifiers = 0, ExitModifiers = 0;
        [DllImport("user32.dll", SetLastError=true)]
        static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr hwnd, int id);
        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            RegisterCurrent();
        }
        void RegisterCurrent() {
            ToggleRegistered = RegisterHotKey(Handle, 1, 0x4000 | ToggleModifiers, ToggleKey);
            ExitRegistered = RegisterHotKey(Handle, 2, 0x4000 | ExitModifiers, ExitKey);
        }
        public bool SetHotkeys(uint toggleModifiers, uint toggleKey, uint exitModifiers, uint exitKey) {
            if (toggleKey == exitKey && toggleModifiers == exitModifiers) return false;
            uint oldTM = ToggleModifiers, oldTK = ToggleKey, oldEM = ExitModifiers, oldEK = ExitKey;
            if (IsHandleCreated) { UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2); }
            ToggleModifiers = toggleModifiers; ToggleKey = toggleKey;
            ExitModifiers = exitModifiers; ExitKey = exitKey;
            if (!IsHandleCreated) return true;
            RegisterCurrent();
            if (ToggleRegistered && ExitRegistered) return true;
            UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2);
            ToggleModifiers = oldTM; ToggleKey = oldTK; ExitModifiers = oldEM; ExitKey = oldEK;
            RegisterCurrent();
            return false;
        }
        protected override void OnHandleDestroyed(EventArgs e) {
            UnregisterHotKey(Handle, 1);
            UnregisterHotKey(Handle, 2);
            base.OnHandleDestroyed(e);
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) {
                if (m.WParam.ToInt32() == 1 && ToggleRequested != null) ToggleRequested();
                if (m.WParam.ToInt32() == 2 && ExitRequested != null) ExitRequested();
            }
            base.WndProc(ref m);
        }
    }

    // Input runs outside the UI timer so a 5 ms interval can reach 200 taps/sec.
    public sealed class TapEngine : IDisposable {
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        Thread worker;
        readonly Action<bool> emit;
        readonly Func<bool> blocked;
        long sent;
        volatile bool running;
        volatile string error;
        public long Sent { get { return Interlocked.Read(ref sent); } }
        public bool Running { get { return running; } }
        public string Error { get { return error; } }
        public TapEngine() : this(Keyboard.Tap, Keyboard.ModifierDown) { }
        TapEngine(Action<bool> emit, Func<bool> blocked) { this.emit = emit; this.blocked = blocked; }
        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);
        [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint period);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string name, uint flags, uint access);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetWaitableTimer(IntPtr timer, ref long due, int period, IntPtr callback, IntPtr arg, bool resume);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public void Start(int rate, long target) {
            if (rate < 1 || rate > 200 || target < 0) throw new ArgumentOutOfRangeException();
            Pause();
            if (target > 0 && Sent >= target) Interlocked.Exchange(ref sent, 0);
            error = null;
            stop.Reset();
            running = true;
            worker = new Thread(delegate() { Run(rate, target); });
            worker.IsBackground = true;
            worker.Start();
        }
        void Run(int rate, long target) {
            bool fineTimer = false;
            IntPtr precisionTimer = IntPtr.Zero;
            try {
                precisionTimer = CreateWaitableTimerExW(IntPtr.Zero, null, 2, 0x00100002);
                if (precisionTimer == IntPtr.Zero) fineTimer = timeBeginPeriod(1) == 0;
                IntPtr[] waitHandles = { stop.SafeWaitHandle.DangerousGetHandle(), precisionTimer };
                Stopwatch clock = Stopwatch.StartNew();
                double interval = 1000.0 / rate, next = 0;
                while (!stop.WaitOne(0)) {
                    double now = clock.Elapsed.TotalMilliseconds;
                    if (now < next) {
                        if (precisionTimer != IntPtr.Zero) {
                            long due = -Math.Max(1L, (long)Math.Ceiling((next - now) * 10000.0));
                            if (!SetWaitableTimer(precisionTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
                                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                            uint result = WaitForMultipleObjects(2, waitHandles, false, 0xFFFFFFFF);
                            if (result == 0) break;
                            if (result != 1) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                        } else if (stop.WaitOne(Math.Max(1, (int)Math.Ceiling(next - now)))) break;
                        continue;
                    }
                    if (blocked()) {
                        next = now + interval;
                        continue;
                    }
                    emit((Sent % 2) == 1);
                    long total = Interlocked.Increment(ref sent);
                    if (target > 0 && total >= target) break;
                    // Skip missed slots instead of sending a burst after a stall.
                    next += interval;
                    if (next <= clock.Elapsed.TotalMilliseconds) next = clock.Elapsed.TotalMilliseconds + interval;
                }
            } catch (Exception ex) { error = ex.Message; }
            finally {
                if (precisionTimer != IntPtr.Zero) CloseHandle(precisionTimer);
                if (fineTimer) timeEndPeriod(1);
                running = false;
            }
        }
        public void Pause() {
            stop.Set();
            if (worker != null) { worker.Join(); worker = null; }
            running = false;
        }
        public void Reset() { Pause(); Interlocked.Exchange(ref sent, 0); }
        public void Dispose() { Pause(); stop.Dispose(); }
        public static string ValidateScheduler() {
            int calls = 0;
            using (TapEngine test = new TapEngine(delegate(bool alternate) {
                if (alternate != ((calls % 2) == 1)) throw new Exception("Invalid alternation");
                calls++;
            }, delegate() { return false; })) {
                Stopwatch clock = Stopwatch.StartNew();
                test.Start(200, 200);
                while (test.Running && clock.ElapsedMilliseconds < 5000) Thread.Sleep(5);
                test.Pause();
                if (test.Error != null || test.Sent != 200 || calls != 200)
                    throw new Exception("Scheduler target failed: " + test.Error);
                long elapsed = clock.ElapsedMilliseconds;
                if (elapsed < 900) throw new Exception("Scheduler exceeded configured rate");
                calls = 0;
                test.Start(200, 0); // A completed target with limit 0 retains its total.
                Thread.Sleep(40);
                test.Pause();
                long paused = test.Sent;
                Thread.Sleep(30);
                if (test.Sent != paused || test.Running || test.Error != null)
                    throw new Exception("Scheduler pause failed");
                test.Reset();
                if (test.Sent != 0) throw new Exception("Scheduler reset failed");
                return "200 fake taps in " + elapsed + " ms; target/pause/reset passed";
            }
        }
    }

    public static class Keyboard {
        [StructLayout(LayoutKind.Sequential)]
        struct MOUSEINPUT {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public UIntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT {
            public ushort wVk, wScan;
            public uint dwFlags, time;
            public UIntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Explicit)]
        struct INPUTUNION {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct INPUT {
            public uint type;
            public INPUTUNION u;
        }
        [DllImport("user32.dll", SetLastError=true)]
        static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")]
        static extern short GetAsyncKeyState(int key);

        static INPUT[] Pair(ushort key) {
            INPUT[] pair = new INPUT[2];
            pair[0].type = pair[1].type = 1;
            pair[0].u.ki.wVk = pair[1].u.ki.wVk = key;
            pair[1].u.ki.dwFlags = 2;
            return pair;
        }
        static readonly INPUT[] F13 = Pair(0x7C);
        static readonly INPUT[] F14 = Pair(0x7D);
        public static int InputSize { get { return Marshal.SizeOf(typeof(INPUT)); } }
        public static bool ModifierDown() {
            int[] keys = { 0x10, 0x11, 0x12, 0x5B, 0x5C };
            foreach (int key in keys) if ((GetAsyncKeyState(key) & 0x8000) != 0) return true;
            return false;
        }
        public static void Tap(bool alternate) {
            INPUT[] pair = alternate ? F14 : F13;
            uint sent = SendInput(2, pair, InputSize);
            if (sent != 2) {
                int error = Marshal.GetLastWin32Error();
                // If a partial send left a key down, attempt to release it.
                if (sent == 1) SendInput(1, new INPUT[] { pair[1] }, InputSize);
                throw new InvalidOperationException("SendInput: " + sent + "/2, Win32=" + error);
            }
        }
        public static void ValidateLayout() {
            int expected = IntPtr.Size == 8 ? 40 : 28;
            if (InputSize != expected) throw new InvalidOperationException("Invalid INPUT size");
            if (F13[0].u.ki.wVk != 0x7C || F14[1].u.ki.wVk != 0x7D ||
                F13[0].u.ki.dwFlags != 0 || F13[1].u.ki.dwFlags != 2)
                throw new InvalidOperationException("Invalid keyboard event pair");
        }
    }
}
'@

[TappoAutoTap.Keyboard]::ValidateLayout()
if ($SelfTest) {
    Write-Output "Self-test passed: INPUT=$([TappoAutoTap.Keyboard]::InputSize) bytes; F13/F14 down/up pairs valid. No keys sent."
    Write-Output ([TappoAutoTap.TapEngine]::ValidateScheduler())
    return
}

$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\WuwaTappoAutoTapControl', [ref]$created)
if (-not $created) {
    [Windows.Forms.MessageBox]::Show('刷键脚本已经打开，请使用已有窗口。', 'Wuwa Tappo') | Out-Null
    $mutex.Dispose()
    return
}

[Windows.Forms.Application]::EnableVisualStyles()
if (-not $ConfigPath) {
    $ConfigPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WuwaTappoAutoTap\settings.json'
}
$settingsPath = $ConfigPath
$script:settings = @{}
$script:settingsError = ''
$readPath = $settingsPath
if (-not (Test-Path -LiteralPath $readPath) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'settings.json'))) {
    $readPath = Join-Path $PSScriptRoot 'settings.json'
}
if (Test-Path -LiteralPath $readPath) {
    try {
        $loaded = [IO.File]::ReadAllText($readPath) | ConvertFrom-Json
        foreach ($property in $loaded.PSObject.Properties) { $script:settings[$property.Name] = $property.Value }
    } catch { $script:settingsError = '配置读取失败，已使用默认设置。' }
}
function Save-Settings {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($settingsPath))
    $null = [IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText($settingsPath, ($script:settings | ConvertTo-Json), [Text.UTF8Encoding]::new($true))
}
function Resolve-TappoPath([string]$Preferred) {
    $candidates = [Collections.Generic.List[string]]::new()
    if ($Preferred) { $candidates.Add($Preferred) }
    foreach ($process in @(Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue)) {
        try { if ($process.Path) { $candidates.Add($process.Path) } } catch { }
    }
    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Wuwa\s*Tappo' })) {
            if ($entry.InstallLocation) {
                $candidates.Add((Join-Path $entry.InstallLocation 'WuwaTappo.exe'))
                $candidates.Add((Join-Path $entry.InstallLocation 'WuwaTappo\WuwaTappo.exe'))
            }
            if ($entry.DisplayIcon) {
                $icon = ([string]$entry.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"')
                if ($icon -match '\.exe$') { $candidates.Add($icon) }
            }
        }
    }
    $roots = @($PSScriptRoot, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles, ${env:ProgramFiles(x86)})
    $roots += @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' } | ForEach-Object { $_.Root })
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($suffix in @('WuwaTappo.exe', 'WuwaTappo\WuwaTappo.exe', 'Wuwa Tappo\WuwaTappo.exe',
            'Wuwa Tappo\WuwaTappo\WuwaTappo.exe', 'Games\WuwaTappo\WuwaTappo.exe')) {
            $candidates.Add((Join-Path $root $suffix))
        }
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFileName($candidate) -ieq 'WuwaTappo.exe' -and [IO.File]::Exists($candidate)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return ''
}
if (-not $AppPath -and $script:settings.AppPath) { $AppPath = [string]$script:settings.AppPath }
$script:resolvedAppPath = Resolve-TappoPath $AppPath
$form = [TappoAutoTap.ControlWindow]::new()
$form.Text = 'Wuwa Tappo 自动刷键'
$form.ClientSize = [Drawing.Size]::new(550, 610)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)

function Add-Label($Text, $X, $Y, $W, $H) {
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.SetBounds($X, $Y, $W, $H)
    $form.Controls.Add($label)
    return $label
}
$null = Add-Label '默认发送 F13 / F14；当前窗口不会因此输入普通文字。' 18 16 515 26
$null = Add-Label '速度（次/秒）' 18 56 130 26
$speed = [Windows.Forms.NumericUpDown]::new()
$speed.SetBounds(150, 54, 95, 28)
$speed.Minimum = 1; $speed.Maximum = 200; $speed.Value = $Rate
$form.Controls.Add($speed)
$null = Add-Label '目标次数' 270 56 90 26
$limit = [Windows.Forms.NumericUpDown]::new()
$limit.SetBounds(360, 54, 165, 28)
$limit.Maximum = 1000000000; $limit.Value = $Count
$limit.ThousandsSeparator = $true
$form.Controls.Add($limit)
$null = Add-Label '目标设为 0 表示持续发送；设置值是期望速度，实际可能较低。' 18 90 515 26

$toggle = [Windows.Forms.Button]::new()
$toggle.Text = '开始'
$toggle.SetBounds(18, 127, 150, 40)
$form.Controls.Add($toggle)
$reset = [Windows.Forms.Button]::new()
$reset.Text = '清零发送次数'
$reset.SetBounds(187, 127, 160, 40)
$form.Controls.Add($reset)
$open = [Windows.Forms.Button]::new()
$open.Text = '打开 Tappo'
$open.SetBounds(366, 127, 160, 40)
$form.Controls.Add($open)

$counter = Add-Label '已发送：0 次' 18 182 515 32
$counter.Font = [Drawing.Font]::new('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
$status = Add-Label '已暂停，点击“开始”发送按键。' 18 222 515 44
$hotkeys = Add-Label 'F6：开始/暂停    F10：退出' 18 268 515 25
$null = Add-Label '修改快捷键（选择主键，可勾选组合键）' 18 302 515 25
$keyNames = @('F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12',
    'Insert','Home','End','PageUp','PageDown','Pause','Scroll')
function Add-HotkeyRow($Text, $Y, $DefaultKey) {
    $null = Add-Label $Text 18 $Y 100 26
    $box = [Windows.Forms.ComboBox]::new()
    $box.DropDownStyle = 'DropDownList'
    $box.SetBounds(125, $Y, 115, 28)
    $box.Items.AddRange([object[]]$keyNames)
    $box.SelectedItem = $DefaultKey
    $form.Controls.Add($box)
    $checks = @()
    foreach ($entry in @(@('Ctrl',255), @('Alt',330), @('Shift',400))) {
        $check = [Windows.Forms.CheckBox]::new()
        $check.Text = $entry[0]
        $check.SetBounds([int]$entry[1], $Y, 75, 28)
        $form.Controls.Add($check)
        $checks += $check
    }
    return @{ Key = $box; Ctrl = $checks[0]; Alt = $checks[1]; Shift = $checks[2] }
}
$toggleKeys = Add-HotkeyRow '开始 / 暂停' 336 'F6'
$exitKeys = Add-HotkeyRow '退出脚本' 372 'F10'
$applyKeys = [Windows.Forms.Button]::new()
$applyKeys.Text = '应用并保存快捷键'
$applyKeys.SetBounds(18, 410, 190, 34)
$form.Controls.Add($applyKeys)
$defaultKeys = [Windows.Forms.Button]::new()
$defaultKeys.Text = '恢复默认快捷键'
$defaultKeys.SetBounds(226, 410, 175, 34)
$form.Controls.Add($defaultKeys)
$null = Add-Label 'Tappo 程序路径（支持任意安装盘和中文目录）' 18 455 515 25
$pathBox = [Windows.Forms.TextBox]::new()
$pathBox.ReadOnly = $true
$pathBox.SetBounds(18, 486, 390, 28)
$pathBox.Text = $script:resolvedAppPath
$form.Controls.Add($pathBox)
$browse = [Windows.Forms.Button]::new()
$browse.Text = '选择程序'
$browse.SetBounds(420, 484, 106, 32)
$form.Controls.Add($browse)
$detect = [Windows.Forms.Button]::new()
$detect.Text = '自动查找路径'
$detect.SetBounds(18, 528, 150, 34)
$form.Controls.Add($detect)
$null = Add-Label '此处为发送次数；Tappo 实际计入次数请在软件内查看。' 18 578 515 25

function Set-TappoPath([string]$Path) {
    $script:resolvedAppPath = $Path
    $pathBox.Text = $Path
    $script:settings.AppPath = $Path
    try { Save-Settings; $status.Text = '程序路径已保存，下次启动自动使用。' }
    catch { $status.Text = '路径已生效，但保存失败：' + $_.Exception.Message }
}
$browse.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = '选择 WuwaTappo.exe'
        $dialog.Filter = 'Wuwa Tappo 程序 (WuwaTappo.exe)|WuwaTappo.exe'
        $dialog.CheckFileExists = $true
        if ($script:resolvedAppPath) { $dialog.InitialDirectory = Split-Path -Parent $script:resolvedAppPath }
        if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
            if ([IO.Path]::GetFileName($dialog.FileName) -ine 'WuwaTappo.exe') {
                $status.Text = '请选择 WuwaTappo.exe。'
            } else { Set-TappoPath $dialog.FileName }
        }
    } finally { $dialog.Dispose() }
})
$detect.Add_Click({
    $found = Resolve-TappoPath $script:resolvedAppPath
    if ($found) { Set-TappoPath $found }
    else { $status.Text = '未自动找到，请点击“选择程序”定位 WuwaTappo.exe。' }
})

function Get-KeyModifiers($Row) {
    $mods = 0
    if ($Row.Alt.Checked) { $mods = $mods -bor 1 }
    if ($Row.Ctrl.Checked) { $mods = $mods -bor 2 }
    if ($Row.Shift.Checked) { $mods = $mods -bor 4 }
    return [uint32]$mods
}
function Set-KeyRow($Row, [string]$Name, [int]$Modifiers) {
    $Row.Key.SelectedItem = $Name
    $Row.Alt.Checked = ($Modifiers -band 1) -ne 0
    $Row.Ctrl.Checked = ($Modifiers -band 2) -ne 0
    $Row.Shift.Checked = ($Modifiers -band 4) -ne 0
}
function Format-Hotkey([uint32]$Key, [uint32]$Modifiers) {
    $name = ''
    if ($Modifiers -band 2) { $name += 'Ctrl+' }
    if ($Modifiers -band 1) { $name += 'Alt+' }
    if ($Modifiers -band 4) { $name += 'Shift+' }
    return $name + ([Windows.Forms.Keys]$Key).ToString()
}
function Update-HotkeyLabel {
    $hotkeys.Text = '{0}：开始/暂停    {1}：退出' -f (Format-Hotkey $form.ToggleKey $form.ToggleModifiers), (Format-Hotkey $form.ExitKey $form.ExitModifiers)
}
function Apply-Hotkeys([bool]$Save) {
    $tm = Get-KeyModifiers $toggleKeys
    $em = Get-KeyModifiers $exitKeys
    $tk = [uint32][Windows.Forms.Keys]([string]$toggleKeys.Key.SelectedItem)
    $ek = [uint32][Windows.Forms.Keys]([string]$exitKeys.Key.SelectedItem)
    if (-not $form.SetHotkeys($tm, $tk, $em, $ek)) {
        $status.Text = '快捷键重复或已被占用，修改未生效。请换一个键或添加 Ctrl / Alt。'
        Update-HotkeyLabel
        return
    }
    Update-HotkeyLabel
    $status.Text = '快捷键已生效。'
    if ($Save) {
        try {
            $script:settings.ToggleKey = [string]$toggleKeys.Key.SelectedItem
            $script:settings.ToggleModifiers = $tm
            $script:settings.ExitKey = [string]$exitKeys.Key.SelectedItem
            $script:settings.ExitModifiers = $em
            $script:settings.AppPath = $script:resolvedAppPath
            Save-Settings
            $status.Text = '快捷键已应用并保存，下次启动自动使用。'
        } catch { $status.Text = '快捷键已生效，但保存失败：' + $_.Exception.Message }
    }
}
if ($script:settings.ContainsKey('ToggleKey')) {
    try {
        $saved = [pscustomobject]$script:settings
        if ($saved.ToggleKey -notin $keyNames -or $saved.ExitKey -notin $keyNames -or
            [int]$saved.ToggleModifiers -lt 0 -or [int]$saved.ToggleModifiers -gt 7 -or
            [int]$saved.ExitModifiers -lt 0 -or [int]$saved.ExitModifiers -gt 7) { throw 'Invalid hotkeys' }
        Set-KeyRow $toggleKeys $saved.ToggleKey $saved.ToggleModifiers
        Set-KeyRow $exitKeys $saved.ExitKey $saved.ExitModifiers
        Apply-Hotkeys $false
    } catch { $status.Text = '快捷键配置读取失败，使用默认 F6 / F10。' }
}
$applyKeys.Add_Click({ Apply-Hotkeys $true })
$defaultKeys.Add_Click({
    Set-KeyRow $toggleKeys 'F6' 0
    Set-KeyRow $exitKeys 'F10' 0
    Apply-Hotkeys $true
})

$script:running = $false
$script:sentCount = [long]0
$engine = [TappoAutoTap.TapEngine]::new()
$script:lastCheck = [long]0
$watch = [Diagnostics.Stopwatch]::StartNew()
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 50

function Pause-Tapping([string]$Message) {
    $script:running = $false
    $engine.Pause()
    $script:sentCount = $engine.Sent
    $counter.Text = '已发送：{0:N0} 次' -f $script:sentCount
    $timer.Stop()
    $toggle.Text = '开始 / 继续'
    $speed.Enabled = $true; $limit.Enabled = $true; $reset.Enabled = $true
    $status.Text = $Message
}

function Toggle-Tapping {
    if ($script:running) { Pause-Tapping '已暂停。'; return }
    if (-not (Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue)) {
        $status.Text = '未检测到 WuwaTappo，请先点击“打开 Tappo”，等待它启动。'
        return
    }
    $engine.Start([int]$speed.Value, [long]$limit.Value)
    $script:sentCount = $engine.Sent
    $counter.Text = '已发送：{0:N0} 次' -f $script:sentCount
    $script:lastCheck = $watch.ElapsedMilliseconds
    $script:running = $true
    $speed.Enabled = $false; $limit.Enabled = $false; $reset.Enabled = $false
    $toggle.Text = '暂停'
    $status.Text = '正在发送 F13 / F14。按住 Ctrl / Alt / Shift / Win 时暂缓发送。'
    $timer.Start()
}

$toggle.Add_Click({ Toggle-Tapping })
$form.Add_ToggleRequested({ Toggle-Tapping })
$form.Add_ExitRequested({ $form.Close() })
$reset.Add_Click({ $engine.Reset(); $script:sentCount = 0; $counter.Text = '已发送：0 次' })
$open.Add_Click({
    try {
        if (Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue) {
            $status.Text = 'WuwaTappo 已在运行。'
        } elseif ($script:resolvedAppPath -and [IO.File]::Exists($script:resolvedAppPath)) {
            Start-Process -FilePath $script:resolvedAppPath -WorkingDirectory (Split-Path -Parent $script:resolvedAppPath)
            $status.Text = '已请求启动 Tappo；等待启动完成后点击“开始”。'
        } else { $status.Text = '找不到 Tappo，请点击“选择程序”定位 WuwaTappo.exe。' }
    } catch { $status.Text = '启动失败：' + $_.Exception.Message }
})
$timer.Add_Tick({
    if (-not $script:running) { return }
    try {
        if ($watch.ElapsedMilliseconds - $script:lastCheck -ge 1000) {
            $script:lastCheck = $watch.ElapsedMilliseconds
            if (-not (Get-Process -Name WuwaTappo -ErrorAction SilentlyContinue)) {
                Pause-Tapping 'Tappo 已退出，自动暂停。'
                return
            }
        }
        $script:sentCount = $engine.Sent
        $counter.Text = '已发送：{0:N0} 次' -f $script:sentCount
        if (-not $engine.Running) {
            if ($engine.Error) { Pause-Tapping ('发送失败。可尝试以管理员身份运行。' + $engine.Error) }
            else { Pause-Tapping '已达到目标，自动停止；再次开始会从 0 重新计数。' }
        }
    } catch {
        Pause-Tapping ('发送失败。请尝试以管理员身份运行启动器。' + $_.Exception.Message)
    }
})
$form.Add_Shown({
    if ($script:settingsError) { $status.Text = $script:settingsError }
    elseif (-not $script:resolvedAppPath) { $status.Text = '请先打开 Tappo，或点击“选择程序”指定安装路径。' }
    if (-not $form.ToggleRegistered -or -not $form.ExitRegistered) {
        $hotkeys.Text = '部分热键注册失败（被占用），请使用窗口按钮或关闭窗口。'
    }
})
$form.Add_FormClosing({ $script:running = $false; $timer.Stop(); $engine.Pause() })
try {
    [Windows.Forms.Application]::Run($form)
} finally {
    $engine.Dispose()
    $timer.Dispose()
    $form.Dispose()
    $watch.Stop()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
