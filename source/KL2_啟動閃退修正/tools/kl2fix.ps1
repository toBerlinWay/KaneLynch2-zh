# Kane & Lynch 2: Dog Days 啟動閃退＋存檔修正
# 1) 閃退：遊戲會讀系統代理設定（ProxyEnable），經代理連線已關閉的 Eidos 伺服器，遊戲內建的 TLS 程式就會崩潰。
#    修法：kl2.exe 把 "ProxyEnable" 改成 "ProxyEnablX"（1 個位元組），再在 hosts 把該伺服器指到本機。
# 2) 存檔：遊戲用舊式 ANSI 函式 SHGetFolderPathA 取「文件」資料夾。路徑裡有中文（例如 OneDrive\文档），
#    而 Windows 的「非 Unicode 程式語言」不是中文時，路徑會變成 ??，存檔資料夾建不起來，每次都顯示「找不到存檔」。
#    修法：只在這種情況下，把 kl2.exe 要的資料夾從「文件」(CSIDL 5) 改成 AppData\Local (CSIDL 0x1C)，
#    或在使用者名稱也有中文時改成 C:\ProgramData (CSIDL 0x23)。存檔會放在該處的 Square Enix 資料夾。
# 用法：kl2fix.ps1 install|uninstall [-GameDir <遊戲資料夾>] [-NoHosts]
param(
    [ValidateSet('install', 'uninstall', 'hosts-add', 'hosts-remove')][string]$Mode = 'install',
    [string]$GameDir = '',
    [switch]$NoHosts
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ORIG = '9fceef967752070fe98755b52c8f8475b631c92531eaa5d43f7fa3c09c176c6f'   # Steam 版原始 kl2.exe
$Domain = 'kl2-pc-game-content.eidos.co.uk'
$HostLine = "127.0.0.1 $Domain"
$Hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Folder = 'Kane & Lynch 2 - Dog Days'
$L1 = [Text.Encoding]::GetEncoding(28591)                                   # 1 byte = 1 char, string index = file offset
function Sig([int]$csidl) { $L1.GetString([byte[]](0x6a,0,0x6a,0,0x6a,$csidl,0x6a,0,0xc7,0x44,0x24,0x20,0,0,0,0,0xff,0x15,0x48,0x05,0xb1,0)) }

function Find-GameDir {
    if ($GameDir -and (Test-Path -LiteralPath (Join-Path $GameDir 'kl2.exe'))) { return (Resolve-Path -LiteralPath $GameDir).Path }
    $up = Split-Path -Parent $Root
    if ($up -and (Test-Path -LiteralPath (Join-Path $up 'kl2.exe'))) { return $up }
    $libs = @()
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath -replace '/', '\'
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($mt in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($mt.Groups[1].Value -replace '\\\\', '\') }
        }
    } catch { }
    foreach ($l in $libs | Select-Object -Unique) {
        $p = Join-Path $l ('steamapps\common\' + $Folder)
        if (Test-Path -LiteralPath (Join-Path $p 'kl2.exe')) { return $p }
    }
    $p = (Read-Host '找不到遊戲資料夾，請貼上路徑（裡面要有 kl2.exe）').Trim('"', ' ')
    if (Test-Path -LiteralPath (Join-Path $p 'kl2.exe')) { return $p }
    throw '這個資料夾裡沒有 kl2.exe。'
}
function Get-Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-ShaBytes([byte[]]$b) { $h = [Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
function Test-Ansi([string]$s) { $e = [Text.Encoding]::Default; $e.GetString($e.GetBytes($s)) -eq $s }
function Test-HostLine { (Test-Path -LiteralPath $Hosts) -and (Select-String -LiteralPath $Hosts -Pattern ('^\s*127\.0\.0\.1\s+' + [regex]::Escape($Domain) + '\s*$') -Quiet) }
function Invoke-Elevated([string]$m) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, $m
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}
function Find-One([string]$s, [string]$pat) {
    $i = $s.IndexOf($pat, [StringComparison]::Ordinal)
    if ($i -ge 0 -and $s.IndexOf($pat, $i + 1, [StringComparison]::Ordinal) -ge 0) { return -2 }   # more than once
    return $i
}

try {
    if ($Mode -eq 'hosts-add') {
        $txt = if (Test-Path -LiteralPath $Hosts) { [IO.File]::ReadAllText($Hosts) } else { '' }
        if (-not (Test-HostLine)) {
            $add = $(if ($txt.Length -and -not $txt.EndsWith("`n")) { "`r`n" } else { '' }) + $HostLine + "`r`n"
            [IO.File]::AppendAllText($Hosts, $add, [Text.Encoding]::ASCII)
        }
        exit 0
    }
    if ($Mode -eq 'hosts-remove') {
        $lines = [IO.File]::ReadAllLines($Hosts) | Where-Object { $_ -notmatch ('^\s*127\.0\.0\.1\s+' + [regex]::Escape($Domain) + '\s*$') }
        [IO.File]::WriteAllLines($Hosts, [string[]]$lines, [Text.Encoding]::ASCII)
        exit 0
    }

    Write-Host '《Kane & Lynch 2: Dog Days》啟動閃退＋存檔修正'
    $game = Find-GameDir
    Write-Host ('遊戲資料夾：' + $game)
    if (Get-Process kl2 -ErrorAction SilentlyContinue) { throw '遊戲正在執行，請先關閉。' }
    $exe = Join-Path $game 'kl2.exe'
    $bk = Join-Path $game 'KL2_fix_backup\kl2.exe'
    $b = [IO.File]::ReadAllBytes($exe)
    $s = $L1.GetString($b)
    $pOld = Find-One $s "ProxyEnable`0"; $pNew = Find-One $s "ProxyEnablX`0"
    $sv = @{}; foreach ($c in 0x05, 0x1c, 0x23) { $sv[$c] = Find-One $s (Sig $c) }
    $svPos = -1; $svCur = 0
    foreach ($c in 0x05, 0x1c, 0x23) { if ($sv[$c] -ge 0) { $svPos = $sv[$c] + 5; $svCur = $c } }
    if (($pOld -lt 0 -and $pNew -lt 0) -or $pOld -eq -2 -or $pNew -eq -2) { throw 'kl2.exe 版本無法辨識，沒有修改。' }

    if ($Mode -eq 'install') {
        # 原檔備份（只做一次）。若 exe 已被修過，先把已知的修改還原回去再備份
        if (-not (Test-Path -LiteralPath $bk)) {
            $o = [byte[]]$b.Clone()
            if ($pNew -ge 0) { $o[$pNew + 10] = [byte][char]'e' }
            if ($svPos -ge 0) { $o[$svPos] = 0x05 }
            if ((Get-ShaBytes $o) -ne $ORIG) { Write-Warning 'kl2.exe 不是已知的 Steam 版，仍嘗試修正（已備份目前的檔案）。'; $o = $b }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bk) | Out-Null
            [IO.File]::WriteAllBytes($bk, $o)
        }
        $changed = $false
        if ($pNew -ge 0) { Write-Host '1) 閃退：kl2.exe 已經修正過。' }
        else { $b[$pOld + 10] = [byte][char]'X'; $changed = $true; Write-Host '1) 閃退：kl2.exe 已修正，不再讀系統代理。' }

        $docs = [Environment]::GetFolderPath('MyDocuments')
        if ($svPos -lt 0) { Write-Warning '2) 存檔：找不到要修改的位置，略過。' }
        elseif (Test-Ansi $docs) {
            if ($svCur -ne 0x05) { $b[$svPos] = 0x05; $changed = $true }
            Write-Host ('2) 存檔：「文件」路徑正常（' + $docs + '），不需修正。')
        } else {
            $lad = [Environment]::GetFolderPath('LocalApplicationData')
            $want = if (Test-Ansi $lad) { 0x1c } else { 0x23 }
            $where = if ($want -eq 0x1c) { $lad } else { [Environment]::GetFolderPath('CommonApplicationData') }
            if ($svCur -ne $want) { $b[$svPos] = [byte]$want; $changed = $true }
            Write-Host ('2) 存檔：「文件」路徑有中文（' + $docs + '），遊戲讀不到。')
            Write-Host ('   已改成存到 ' + (Join-Path $where 'Square Enix'))
        }
        if ($changed) { [IO.File]::WriteAllBytes($exe, $b) }
        Write-Host '   kl2.exe 原檔備份在 KL2_fix_backup。'

        if ($NoHosts) { Write-Host '3) 略過 hosts。' }
        elseif (Test-HostLine) { Write-Host '3) hosts 已經有那一行。' }
        else {
            Write-Host '3) 要在 hosts 加一行，接下來 Windows 會詢問管理員權限，請按「是」。'
            [void](Invoke-Elevated 'hosts-add')
            if (Test-HostLine) { Write-Host '   hosts 已加入。' } else { Write-Warning ('hosts 沒有加成功。可手動用管理員身分在 hosts 檔最後加上：' + $HostLine) }
        }
        Write-Host '完成，可以啟動遊戲了。' -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath $bk) {
            Copy-Item -LiteralPath $bk -Destination $exe -Force
            Remove-Item -LiteralPath $bk
            $d = Split-Path -Parent $bk
            if (-not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d }
        } else {
            if ($pNew -ge 0) { $b[$pNew + 10] = [byte][char]'e' }
            if ($svPos -ge 0) { $b[$svPos] = 0x05 }
            [IO.File]::WriteAllBytes($exe, $b)
        }
        Write-Host ('1) kl2.exe 已還原' + $(if ((Get-Sha $exe) -eq $ORIG) { '成 Steam 原版。' } else { '。' }))
        if ($NoHosts) { Write-Host '2) 略過 hosts。' }
        elseif (Test-HostLine) {
            Write-Host '2) 要從 hosts 移除那一行，接下來 Windows 會詢問管理員權限，請按「是」。'
            [void](Invoke-Elevated 'hosts-remove')
            if (-not (Test-HostLine)) { Write-Host '   hosts 已移除。' } else { Write-Warning 'hosts 沒有改成功。' }
        } else { Write-Host '2) hosts 裡沒有那一行。' }
        Write-Host '已移除修正。存檔資料夾（Square Enix）不會刪除。' -ForegroundColor Green
    }
} catch {
    Write-Host ('錯誤：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
