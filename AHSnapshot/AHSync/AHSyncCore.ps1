# AH Snapshot 同步核心（不含介面，可單獨載入測試）
# Windows PowerShell 5.1；檔案讀寫一律用不帶 BOM 的 UTF-8。
#
# 交換方式：
#   插件登出時把自己的掃描寫成存檔裡的字串 AHSnapshotOutbox（紀錄以 ~ 分隔、欄位以 ^ 分隔）。
#   這裡把它上傳成雲端資料夾的 <自己名字>.txt（一行一筆）。
#   別人的 <名字>.txt 合併成 AHSnapshotInbox 寫回存檔（只在遊戲關著時寫），插件下次登入時匯入。

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-AHDefaultConfigDir {
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AHSnapshotSync'
}

function Initialize-AHConfigDir([string]$ConfigDir) {
    if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
}

# ---- 日誌 ----
function Write-AHLog([string]$ConfigDir, [string]$Message, [string]$Level = 'INFO') {
    try {
        Initialize-AHConfigDir $ConfigDir
        $path = Join-Path $ConfigDir 'AHSync.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) {
            Move-Item -LiteralPath $path -Destination ($path + '.old') -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        [IO.File]::AppendAllText($path, $line + "`r`n", $script:Utf8NoBom)
    } catch { }
}

# ---- 檔案 ----
function Read-AHText([string]$Path) {
    [IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

# 先寫暫存檔再取代，避免雲端硬碟或遊戲讀到寫一半的檔案
function Write-AHTextAtomic([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($Path) + '.tmp')
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- 設定 ----
function Get-AHConfig([string]$ConfigDir) {
    $path = Join-Path $ConfigDir 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $c = (Read-AHText $path) | ConvertFrom-Json
    if (-not $c.GameProcessName) { $c | Add-Member -NotePropertyName GameProcessName -NotePropertyValue 'Wow' -Force }
    if ($null -eq $c.GamePathFilter) { $c | Add-Member -NotePropertyName GamePathFilter -NotePropertyValue '_forever_' -Force }
    return $c
}

function Save-AHConfig([string]$ConfigDir, $Config) {
    Initialize-AHConfigDir $ConfigDir
    Write-AHTextAtomic (Join-Path $ConfigDir 'config.json') ($Config | ConvertTo-Json)
}

function Get-AHState([string]$ConfigDir) {
    $path = Join-Path $ConfigDir 'state.json'
    if (Test-Path -LiteralPath $path) {
        try { return (Read-AHText $path) | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ LastSync = $null; LastInboxHash = ''; FriendCount = 0; Friends = @() }
}

function Save-AHState([string]$ConfigDir, $State) {
    Initialize-AHConfigDir $ConfigDir
    Write-AHTextAtomic (Join-Path $ConfigDir 'state.json') ($State | ConvertTo-Json)
}

# 名字會變成雲端的檔名，也會寫進交換格式，所以不能有這些字元
function Test-AHName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 24) { return $false }
    return -not ($Name -match '[\^~%"\\/:*?<>|\x00-\x1f]' -or $Name.StartsWith('.') -or $Name.StartsWith('_'))
}

# ---- 找路徑 ----
function Get-AHWowRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                     'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($p) { $roots.Add((Split-Path -Parent $p.TrimEnd('\'))); $roots.Add($p.TrimEnd('\')) }
        } catch { }
    }
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
        foreach ($sub in 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'World of Warcraft', 'Games\World of Warcraft') {
            $roots.Add((Join-Path $d.RootDirectory.FullName $sub))
        }
    }
    $roots | Select-Object -Unique
}

# 回傳每個帳號的 AHSnapshot.lua 路徑（檔案可能還不存在：插件還沒存過檔）
function Find-AHSavedVars {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in Get-AHWowRoots) {
        $acct = Join-Path $root '_forever_\WTF\Account'
        if (-not (Test-Path -LiteralPath $acct)) { continue }
        foreach ($a in Get-ChildItem -LiteralPath $acct -Directory -ErrorAction SilentlyContinue) {
            if ($a.Name -eq 'SavedVariables') { continue }
            $sv = Join-Path $a.FullName 'SavedVariables'
            if (Test-Path -LiteralPath $sv) { $found.Add((Join-Path $sv 'AHSnapshot.lua')) }
        }
    }
    $found | Select-Object -Unique
}

function Find-AHBattleNet {
    foreach ($p in "${env:ProgramFiles(x86)}\Battle.net\Battle.net.exe", "$env:ProgramFiles\Battle.net\Battle.net.exe") {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net') {
        try {
            $loc = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
            $exe = Join-Path $loc 'Battle.net.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        } catch { }
    }
    return $null
}

# ---- 遊戲是否執行中 ----
function Test-AHGameRunning($Config) {
    $name = if ($Config.GameProcessName) { $Config.GameProcessName } else { 'Wow' }
    $filter = $Config.GamePathFilter
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        if (-not $filter) { return $true }
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path -like "*$filter*") { return $true }
    }
    return $false
}

# ---- 存檔裡的字串變數 ----
# 只處理我們自己的兩個字串；內容不會有雙引號、反斜線、換行（插件已轉成 %XX）。
function Find-AHVarLine([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + ' = ')
    if (-not $m.Success) { return $null }
    $end = $Text.IndexOf("`n", $m.Index)
    if ($end -lt 0) { $end = $Text.Length } else { $end = $end + 1 }
    return @{ Start = $m.Index; End = $end; ValueStart = $m.Index + $m.Length }
}

function Get-AHLuaString([string]$Text, [string]$Name) {
    $line = Find-AHVarLine $Text $Name
    if (-not $line) { return $null }
    $vs = $line.ValueStart
    if ($vs -ge $Text.Length -or $Text[$vs] -ne '"') { return $null }   # nil 或其他
    $close = $Text.IndexOf('"', $vs + 1)
    if ($close -lt 0) { throw "$Name 的字串沒有結尾" }
    $value = $Text.Substring($vs + 1, $close - $vs - 1)
    if ($value.Contains('\')) { throw "$Name 含有跳脫字元，格式不對" }
    return $value
}

function Set-AHLuaString([string]$Text, [string]$Name, [string]$Value) {
    if ($Value -match '["\\\r\n]') { throw "要寫入的 $Name 含有不允許的字元" }
    $newLine = "$Name = `"$Value`"`r`n"
    $line = Find-AHVarLine $Text $Name
    if ($line) {
        return $Text.Substring(0, $line.Start) + $newLine + $Text.Substring($line.End)
    }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`r`n" }
    return $Text + $newLine
}

# ---- 上傳自己的 ----
function Export-AHOwn($Config) {
    $sv = $Config.SavedVarsPath
    if (-not (Test-Path -LiteralPath $sv)) {
        return @{ Uploaded = $false; Reason = '存檔還不存在（進遊戲登入一次、掃描後登出就會產生）' }
    }
    $outbox = Get-AHLuaString (Read-AHText $sv) 'AHSnapshotOutbox'
    if ([string]::IsNullOrEmpty($outbox)) {
        return @{ Uploaded = $false; Reason = '還沒有可分享的掃描（掃描後要登出或 /reload）' }
    }
    $records = $outbox.Split('~')
    if (-not $records[0].StartsWith('V^')) { throw '分享資料開頭不對' }
    $head = $records[0].Split('^')
    while ($head.Count -lt 4) { $head += '' }
    $head[2] = $Config.Name
    $records[0] = $head -join '^'
    $content = ($records -join "`r`n") + "`r`n"
    $target = Join-Path $Config.CloudDir ($Config.Name + '.txt')
    if ((Test-Path -LiteralPath $target) -and ((Read-AHText $target) -eq $content)) {
        return @{ Uploaded = $false; Reason = '沒有新資料'; Unchanged = $true }
    }
    Write-AHTextAtomic $target $content
    $scans = @($records | Where-Object { $_.StartsWith('S^') }).Count
    return @{ Uploaded = $true; Scans = $scans; Path = $target }
}

# ---- 合併朋友的 ----
function Get-AHFriendFiles($Config) {
    if (-not (Test-Path -LiteralPath $Config.CloudDir)) { return @() }
    @(Get-ChildItem -LiteralPath $Config.CloudDir -Filter '*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ne $Config.Name -and -not $_.Name.StartsWith('.') -and -not $_.Name.StartsWith('_') -and
                       (Test-AHName $_.BaseName) -and (Test-AHFriendFile $_.FullName) })
}

# 只讀第一行：AH Snapshot 的資料檔一定以 V^ 開頭
function Test-AHFriendFile([string]$Path) {
    try {
        $sr = New-Object System.IO.StreamReader($Path, $script:Utf8NoBom)
        try { $first = $sr.ReadLine() } finally { $sr.Dispose() }
        return ($first -and $first.StartsWith('V^'))
    } catch { return $false }
}

# 回傳 @{ Text = inbox 字串; Friends = 名字清單; Skipped = 丟掉的行數 }
function Build-AHInbox($Config) {
    $parts = New-Object System.Collections.Generic.List[string]
    $friends = New-Object System.Collections.Generic.List[string]
    $skipped = 0
    foreach ($f in Get-AHFriendFiles $Config) {
        $lines = @((Read-AHText $f.FullName) -split "`r?`n" | Where-Object { $_ -ne '' })
        if ($lines.Count -eq 0 -or -not $lines[0].StartsWith('V^')) { $skipped += $lines.Count; continue }
        $good = New-Object System.Collections.Generic.List[string]
        foreach ($l in $lines) {
            if ($l -match '["\\~\x00-\x1f]') { $skipped++; continue }
            $good.Add($l)
        }
        # 來源名字以檔名為準
        $head = $good[0].Split('^')
        while ($head.Count -lt 4) { $head += '' }
        $head[2] = $f.BaseName
        $good[0] = $head -join '^'
        $parts.Add(($good -join '~'))
        $friends.Add($f.BaseName)
    }
    return @{ Text = ($parts -join '~'); Friends = @($friends); Skipped = $skipped }
}

function Get-AHHash([string]$Text) {
    $sha = [Security.Cryptography.SHA1]::Create()
    ([BitConverter]::ToString($sha.ComputeHash($script:Utf8NoBom.GetBytes($Text)))).Replace('-', '')
}

function Backup-AHSavedVars([string]$ConfigDir, [string]$Path, [int]$Keep = 5) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $dir = Join-Path $ConfigDir 'backups'
    Initialize-AHConfigDir $dir
    Copy-Item -LiteralPath $Path -Destination (Join-Path $dir ('AHSnapshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.lua')) -Force
    Get-ChildItem -LiteralPath $dir -Filter 'AHSnapshot-*.lua' | Sort-Object Name -Descending | Select-Object -Skip $Keep |
        Remove-Item -Force
}

# 把朋友的資料寫進存檔（呼叫前要確定遊戲沒開）
function Import-AHFriends([string]$ConfigDir, $Config, $State) {
    $inbox = Build-AHInbox $Config
    $hash = Get-AHHash $inbox.Text
    $result = @{ Written = $false; Friends = $inbox.Friends; NewData = $false; Skipped = $inbox.Skipped }
    if ($inbox.Friends.Count -eq 0) { return $result }
    if ($hash -eq $State.LastInboxHash) { return $result }   # 朋友的檔案沒變，插件已經匯入過
    $sv = $Config.SavedVarsPath
    $svDir = Split-Path -Parent $sv
    if (-not (Test-Path -LiteralPath $svDir)) { throw "找不到存檔資料夾：$svDir" }
    $text = ''
    if (Test-Path -LiteralPath $sv) {
        Backup-AHSavedVars $ConfigDir $sv
        $text = Read-AHText $sv
    }
    $new = Set-AHLuaString $text 'AHSnapshotInbox' $inbox.Text
    Write-AHTextAtomic $sv $new
    $State.LastInboxHash = $hash
    $result.Written = $true
    $result.NewData = $true
    return $result
}

# 一次完整同步：上傳自己的；遊戲沒開才把朋友的寫進存檔
function Invoke-AHSync([string]$ConfigDir, $Config, [switch]$NoImport) {
    $state = Get-AHState $ConfigDir
    $r = [ordered]@{ Uploaded = $false; UploadReason = ''; Written = $false; NewData = $false; Friends = @();
                     GameRunning = $false; Error = $null; Time = (Get-Date) }
    try {
        if (-not (Test-Path -LiteralPath $Config.CloudDir)) { throw "找不到雲端資料夾：$($Config.CloudDir)" }
        $up = Export-AHOwn $Config
        $r.Uploaded = [bool]$up.Uploaded
        $r.UploadReason = $up.Reason
        if ($up.Uploaded) { Write-AHLog $ConfigDir "已上傳 $($up.Scans) 次掃描" }
        $r.GameRunning = Test-AHGameRunning $Config
        $r.Friends = @((Get-AHFriendFiles $Config) | ForEach-Object { $_.BaseName })
        if (-not $NoImport -and -not $r.GameRunning) {
            $im = Import-AHFriends $ConfigDir $Config $state
            $r.Written = $im.Written
            $r.NewData = $im.NewData
            if ($im.Written) { Write-AHLog $ConfigDir ("已把朋友資料寫進存檔：" + ($im.Friends -join '、')) }
            if ($im.Skipped -gt 0) { Write-AHLog $ConfigDir "朋友檔案中有 $($im.Skipped) 行格式不對，已略過" 'WARN' }
        }
        $state.LastSync = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $state.FriendCount = $r.Friends.Count
        $state.Friends = $r.Friends
        Save-AHState $ConfigDir $state
    } catch {
        $r.Error = $_.Exception.Message
        Write-AHLog $ConfigDir ("同步失敗：" + $r.Error) 'ERROR'
    }
    return [pscustomobject]$r
}

function Start-AHGame($Config) {
    $bnet = $Config.BattleNetPath
    if (-not $bnet -or -not (Test-Path -LiteralPath $bnet)) { $bnet = Find-AHBattleNet }
    if (-not $bnet) { throw '找不到 Battle.net，請在設定裡指定 Battle.net.exe 的位置' }
    Start-Process -FilePath $bnet -ArgumentList '--exec="launch wowf"'
}

# ---- 開機自動啟動（「啟動」資料夾捷徑）----
function Get-AHStartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'AH Snapshot 同步.lnk'
}

function Set-AHAutoStart([bool]$Enabled, [string]$VbsPath, [string]$ShortcutPath = (Get-AHStartupShortcutPath)) {
    if ($Enabled) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($ShortcutPath)
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = '"' + $VbsPath + '"'
        $lnk.WorkingDirectory = Split-Path -Parent $VbsPath
        $lnk.Description = 'AH Snapshot 拍賣場資料同步'
        $lnk.Save()
    } elseif (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
}
