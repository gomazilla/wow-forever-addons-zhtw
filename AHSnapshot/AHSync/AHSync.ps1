# AH Snapshot 同步：系統匣常駐程式
# 由 AHSync.vbs 以隱藏視窗啟動。參數：
#   -SyncOnce   不開介面，只同步一次後結束（輸出 JSON，排查用）
#   -SelfTest   建立圖示、選單、設定視窗後立即結束（測試用）
#   -ConfigDir  設定／日誌／備份的資料夾（預設 %APPDATA%\AHSnapshotSync）
param(
    [string]$ConfigDir = '',
    [switch]$SyncOnce,
    [switch]$SelfTest,
    [string]$SelfTestOut = '',
    [string]$GameProcessName = '',
    [string]$GamePathFilter = ''
)

$ErrorActionPreference = 'Stop'
$script:OverrideFilter = $PSBoundParameters.ContainsKey('GamePathFilter')
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'AHSyncCore.ps1')
if (-not $ConfigDir) { $ConfigDir = Get-AHDefaultConfigDir }
Initialize-AHConfigDir $ConfigDir

function Get-EffectiveConfig {
    $c = Get-AHConfig $ConfigDir
    if ($c) {
        if ($GameProcessName) { $c.GameProcessName = $GameProcessName }
        if ($script:OverrideFilter) { $c.GamePathFilter = $GamePathFilter }
    }
    return $c
}

if ($SyncOnce) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $cfg = Get-EffectiveConfig
    if (-not $cfg) { Write-Output '{"Error":"尚未設定"}'; exit 2 }
    $r = Invoke-AHSync $ConfigDir $cfg
    $r | ConvertTo-Json -Compress
    if ($r.Error) { exit 1 } else { exit 0 }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- 只允許一份 ----
$mutexName = if ($SelfTest) { 'Local\AHSnapshotSync_SelfTest' } else { 'Local\AHSnapshotSync' }
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

# ---- 圖示：程式畫的圓點 ----
function New-DotIcon([System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 30, 30, 30)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$Icons = @{
    Idle    = New-DotIcon ([System.Drawing.Color]::FromArgb(60, 200, 80))    # 綠：待命
    Syncing = New-DotIcon ([System.Drawing.Color]::FromArgb(70, 140, 240))   # 藍：同步中
    Game    = New-DotIcon ([System.Drawing.Color]::FromArgb(240, 180, 40))   # 黃：遊戲進行中
    Error   = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 50, 50))    # 紅：錯誤
    Setup   = New-DotIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))  # 灰：尚未設定
}
$StateText = @{ Idle = '待命'; Syncing = '同步中'; Game = '遊戲進行中'; Error = '錯誤'; Setup = '尚未設定' }

$script:status = 'Setup'
$script:lastError = $null
$script:lastNotifiedError = $null
$script:wasRunning = $false
$script:lastSyncText = '-'
$script:friendCount = 0

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

function Update-Tray {
    $tray.Icon = $Icons[$script:status]
    $t = 'AH 同步：' + $StateText[$script:status] + "`n上次同步 " + $script:lastSyncText + "｜朋友 " + $script:friendCount + ' 位'
    if ($script:status -eq 'Error' -and $script:lastError) { $t += "`n" + $script:lastError }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 62) + '…' }   # NotifyIcon 提示最多 63 字
    $tray.Text = $t
}

function Show-Balloon([string]$Text, [System.Windows.Forms.ToolTipIcon]$Kind = 'Info') {
    $tray.ShowBalloonTip(5000, 'AH Snapshot 同步', $Text, $Kind)
}

function Set-Status([string]$s) { $script:status = $s; Update-Tray }

# ---- 同步 ----
function Invoke-TraySync([switch]$Quiet) {
    $cfg = Get-EffectiveConfig
    if (-not $cfg) { Set-Status 'Setup'; return }
    $prev = $script:status
    Set-Status 'Syncing'
    [System.Windows.Forms.Application]::DoEvents()
    $r = Invoke-AHSync $ConfigDir $cfg
    $script:friendCount = @($r.Friends).Count
    if ($r.Error) {
        $script:lastError = $r.Error
        Set-Status 'Error'
        if ($script:lastNotifiedError -ne $r.Error) {
            Show-Balloon ('同步失敗：' + $r.Error) 'Error'
            $script:lastNotifiedError = $r.Error
        }
        return $r
    }
    $script:lastError = $null
    $script:lastNotifiedError = $null
    $script:lastSyncText = (Get-Date).ToString('MM/dd HH:mm')
    if ($r.GameRunning) { Set-Status 'Game' } else { Set-Status 'Idle' }
    if ($r.NewData -and -not $Quiet) {
        Show-Balloon ('收到 ' + @($r.Friends).Count + ' 位朋友的資料，下次進遊戲就看得到。')
    }
    return $r
}

# ---- 設定視窗 ----
function New-SettingsForm($cfg) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AH Snapshot 同步設定'
    $form.Size = New-Object System.Drawing.Size(560, 330)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9)

    $y = 18
    function Add-Label($text, $top) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point(16, ($top + 3)); $l.AutoSize = $true
        $form.Controls.Add($l)
    }

    Add-Label '你的名字' $y
    $name = New-Object System.Windows.Forms.TextBox
    $name.Name = 'name'
    $name.Location = New-Object System.Drawing.Point(140, $y); $name.Width = 200
    $form.Controls.Add($name)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '朋友會看到這個名字'; $hint.ForeColor = [System.Drawing.Color]::Gray
    $hint.Location = New-Object System.Drawing.Point(350, ($y + 3)); $hint.AutoSize = $true
    $form.Controls.Add($hint)

    $y += 40
    Add-Label '雲端共用資料夾' $y
    $cloud = New-Object System.Windows.Forms.TextBox
    $cloud.Name = 'cloud'
    $cloud.Location = New-Object System.Drawing.Point(140, $y); $cloud.Width = 300
    $form.Controls.Add($cloud)
    $bCloud = New-Object System.Windows.Forms.Button
    $bCloud.Text = '瀏覽…'; $bCloud.Location = New-Object System.Drawing.Point(450, ($y - 1)); $bCloud.Width = 75
    $bCloud.Add_Click({
        $cloud = $this.FindForm().Controls['cloud']
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = '選擇 Google 雲端硬碟裡和朋友共用的資料夾'
        if ($cloud.Text) { $d.SelectedPath = $cloud.Text }
        if ($d.ShowDialog() -eq 'OK') { $cloud.Text = $d.SelectedPath }
    })
    $form.Controls.Add($bCloud)

    $y += 40
    Add-Label 'WoW 存檔' $y
    $sv = New-Object System.Windows.Forms.ComboBox
    $sv.Name = 'sv'
    $sv.Location = New-Object System.Drawing.Point(140, $y); $sv.Width = 385
    $sv.DropDownStyle = 'DropDown'
    foreach ($p in @(Find-AHSavedVars)) { [void]$sv.Items.Add($p) }
    $form.Controls.Add($sv)
    $svHint = New-Object System.Windows.Forms.Label
    $svHint.Text = '自動找到的帳號存檔；有多個帳號請選你玩的那個'
    $svHint.ForeColor = [System.Drawing.Color]::Gray
    $svHint.Location = New-Object System.Drawing.Point(140, ($y + 26)); $svHint.AutoSize = $true
    $form.Controls.Add($svHint)

    $y += 62
    Add-Label 'Battle.net' $y
    $bnet = New-Object System.Windows.Forms.TextBox
    $bnet.Name = 'bnet'
    $bnet.Location = New-Object System.Drawing.Point(140, $y); $bnet.Width = 300
    $form.Controls.Add($bnet)
    $bBnet = New-Object System.Windows.Forms.Button
    $bBnet.Text = '瀏覽…'; $bBnet.Location = New-Object System.Drawing.Point(450, ($y - 1)); $bBnet.Width = 75
    $bBnet.Add_Click({
        $bnet = $this.FindForm().Controls['bnet']
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Battle.net.exe|Battle.net.exe'
        if ($d.ShowDialog() -eq 'OK') { $bnet.Text = $d.FileName }
    })
    $form.Controls.Add($bBnet)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '儲存'; $ok.Location = New-Object System.Drawing.Point(360, 245); $ok.Width = 80
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.Location = New-Object System.Drawing.Point(445, 245); $cancel.Width = 80
    $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($ok); $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    # 帶入現有設定或預設值
    if ($cfg) {
        $name.Text = $cfg.Name; $cloud.Text = $cfg.CloudDir; $sv.Text = $cfg.SavedVarsPath; $bnet.Text = $cfg.BattleNetPath
    } else {
        if ($sv.Items.Count -gt 0) { $sv.SelectedIndex = 0 }
        $found = Find-AHBattleNet
        if ($found) { $bnet.Text = $found }
    }

    $ok.Add_Click({
        $form = $this.FindForm()
        $name = $form.Controls['name']; $cloud = $form.Controls['cloud']
        $sv = $form.Controls['sv']; $bnet = $form.Controls['bnet']
        $msg = $null
        if (-not (Test-AHName $name.Text.Trim())) { $msg = '名字不能空白、最多 24 字，也不能有 ^ ~ % " \ / : * ? < > | 這些符號。' }
        elseif (-not $cloud.Text -or -not (Test-Path -LiteralPath $cloud.Text)) { $msg = '找不到雲端共用資料夾，請用「瀏覽…」選一個。' }
        elseif (-not $sv.Text -or -not (Test-Path -LiteralPath (Split-Path -Parent $sv.Text))) { $msg = '找不到 WoW 存檔的資料夾。請確認已經在 WoW Forever 登入過一次。' }
        if ($msg) { [void][System.Windows.Forms.MessageBox]::Show($form, $msg, 'AH Snapshot 同步', 'OK', 'Warning'); return }
        $form.Tag = [pscustomobject]@{
            Name = $name.Text.Trim(); CloudDir = $cloud.Text.TrimEnd('\'); SavedVarsPath = $sv.Text
            BattleNetPath = $bnet.Text; GameProcessName = 'Wow'; GamePathFilter = '_forever_'
        }
        $form.DialogResult = 'OK'
        $form.Close()
    })
    return $form
}

function Show-Settings {
    $cfg = Get-AHConfig $ConfigDir
    $form = New-SettingsForm $cfg
    if ($form.ShowDialog() -eq 'OK' -and $form.Tag) {
        Save-AHConfig $ConfigDir $form.Tag
        Write-AHLog $ConfigDir ('已儲存設定：' + $form.Tag.Name)
        Invoke-TraySync | Out-Null
    } elseif (-not $cfg) {
        Set-Status 'Setup'
    }
    $form.Dispose()
}

# ---- 右鍵選單 ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miGame = $menu.Items.Add('開遊戲')
$miSync = $menu.Items.Add('立即同步')
$miCloud = $menu.Items.Add('開啟雲端資料夾')
$miSettings = $menu.Items.Add('設定…')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem '開機時自動啟動'
$miAuto.CheckOnClick = $true
$miAuto.Checked = Test-Path -LiteralPath (Get-AHStartupShortcutPath)
[void]$menu.Items.Add($miAuto)
$miLog = $menu.Items.Add('開啟日誌')
$miExit = $menu.Items.Add('結束')
$tray.ContextMenuStrip = $menu

$vbsPath = Join-Path $here 'AHSync.vbs'

$miGame.Add_Click({
    try {
        $cfg = Get-EffectiveConfig
        if (-not $cfg) { Show-Settings; return }
        if (Test-AHGameRunning $cfg) { Show-Balloon '遊戲已經開著了。'; return }
        Invoke-TraySync -Quiet | Out-Null
        Start-AHGame $cfg
    } catch {
        Write-AHLog $ConfigDir ('開遊戲失敗：' + $_.Exception.Message) 'ERROR'
        Show-Balloon ('開遊戲失敗：' + $_.Exception.Message) 'Error'
    }
})
$miSync.Add_Click({ Invoke-TraySync | Out-Null })
$miCloud.Add_Click({
    $cfg = Get-AHConfig $ConfigDir
    if ($cfg -and (Test-Path -LiteralPath $cfg.CloudDir)) { Start-Process explorer.exe $cfg.CloudDir }
    else { Show-Settings }
})
$miSettings.Add_Click({ Show-Settings })
$miAuto.Add_Click({
    try { Set-AHAutoStart $miAuto.Checked $vbsPath }
    catch {
        Write-AHLog $ConfigDir ('設定開機啟動失敗：' + $_.Exception.Message) 'ERROR'
        $miAuto.Checked = -not $miAuto.Checked
    }
})
$miLog.Add_Click({
    $log = Join-Path $ConfigDir 'AHSync.log'
    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe $log } else { Show-Balloon '目前沒有日誌。' }
})
$miExit.Add_Click({
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$tray.Add_DoubleClick({ Invoke-TraySync | Out-Null })

# ---- 監看遊戲＋定時同步 ----
$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 5000
$watch.Add_Tick({
    try {
        $cfg = Get-EffectiveConfig
        if (-not $cfg) { return }
        $running = Test-AHGameRunning $cfg
        if ($running -and -not $script:wasRunning) {
            Write-AHLog $ConfigDir '偵測到遊戲啟動'
            if ($script:status -ne 'Error') { Set-Status 'Game' }
        }
        if (-not $running -and $script:wasRunning) {
            Write-AHLog $ConfigDir '偵測到遊戲關閉，開始同步'
            $script:wasRunning = $false
            Start-Sleep -Seconds 3   # 讓遊戲把存檔寫完
            Invoke-TraySync | Out-Null
        }
        $script:wasRunning = $running
    } catch { Write-AHLog $ConfigDir ('監看錯誤：' + $_.Exception.Message) 'ERROR' }
})

$periodic = New-Object System.Windows.Forms.Timer
$periodic.Interval = 10 * 60 * 1000
$periodic.Add_Tick({ try { Invoke-TraySync | Out-Null } catch { Write-AHLog $ConfigDir ('定時同步錯誤：' + $_.Exception.Message) 'ERROR' } })

# ---- 啟動 ----
if ($SelfTest) {
    # 不顯示任何視窗：建好介面後列出狀態就結束
    $form = New-SettingsForm (Get-AHConfig $ConfigDir)
    $controls = @($form.Controls | ForEach-Object { $_.GetType().Name }) -join ','
    $out = [ordered]@{
        Menu = @($menu.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] } | ForEach-Object { $_.Text })
        Icons = @($Icons.Keys | Sort-Object)
        TrayText = $null
        SettingsControls = $controls
        ConfigLoaded = [bool](Get-AHConfig $ConfigDir)
    }
    Update-Tray
    $out.TrayText = $tray.Text
    if ($out.ConfigLoaded) { $r = Invoke-TraySync -Quiet; $out.SyncError = $r.Error; $out.Status = $script:status }
    # 模擬使用者：視窗建好之後（函式已結束）才填欄位、按「儲存」——2026-11-18 實機錯誤就是在這一步
    try {
        $form.Controls['name'].Text = '測試者'
        $form.Controls['cloud'].Text = $env:TEMP
        $form.Controls['sv'].Text = (Join-Path $env:TEMP 'AHSnapshot.lua')
        $okBtn = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq '儲存' })[0]
        $onClick = [System.Windows.Forms.Button].GetMethod('OnClick', [System.Reflection.BindingFlags]'NonPublic,Instance')
        [void]$onClick.Invoke($okBtn, @([EventArgs]::Empty))
        $out.SaveClick = if ($form.Tag) { $form.Tag.Name } else { '沒有結果' }
    } catch {
        $out.SaveClick = '錯誤：' + $_.Exception.InnerException.Message + ' ' + $_.Exception.Message
    }
    $form.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    $json = $out | ConvertTo-Json -Compress
    if ($SelfTestOut) { [IO.File]::WriteAllText($SelfTestOut, $json, (New-Object System.Text.UTF8Encoding($false))) } else { $json }
    $mutex.ReleaseMutex()
    exit 0
}

Update-Tray
if (-not (Get-AHConfig $ConfigDir)) {
    Show-Settings
} else {
    $cfg = Get-EffectiveConfig
    $script:wasRunning = Test-AHGameRunning $cfg
    Invoke-TraySync -Quiet | Out-Null
}
$watch.Start()
$periodic.Start()
Write-AHLog $ConfigDir '同步程式已啟動'

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

$watch.Stop(); $periodic.Stop()
$tray.Dispose()
$mutex.ReleaseMutex()
Write-AHLog $ConfigDir '同步程式已結束'
