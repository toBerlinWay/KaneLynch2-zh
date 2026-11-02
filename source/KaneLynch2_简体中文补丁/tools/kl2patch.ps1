# Kane & Lynch 2: Dog Days 中文補丁 — 安裝／移除引擎
# 由 安裝*.bat / 移除*.bat 呼叫：kl2patch.ps1 install|uninstall [-GameDir <遊戲資料夾>]
# 原理：關卡等大封包只在檔尾「追加」新資料，原始位元組完全不動；移除時截回原長度並核對 SHA-256。
param(
    [ValidateSet('install', 'uninstall')][string]$Mode = 'install',
    [string]$GameDir = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Data = Join-Path $Root 'data'
$M = Get-Content -LiteralPath (Join-Path $Data 'manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$BackupName = 'KL2_zh_backup'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Text;
using System.Security.Cryptography;

namespace KL2 {
public static class Engine {
    static readonly uint[] T = MakeTable();
    static uint[] MakeTable() {
        uint[] t = new uint[256];
        for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1); t[n] = c; }
        return t;
    }
    public static uint Crc32(byte[] d, long len) {
        uint c = 0xFFFFFFFFu;
        for (long i = 0; i < len; i++) c = T[(c ^ d[i]) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
    static void ReadFull(Stream s, byte[] b, long off, long n) {
        while (n > 0) {
            int k = s.Read(b, (int)off, (int)Math.Min(n, 1 << 24));
            if (k <= 0) throw new IOException("資料提前結束");
            off += k; n -= k;
        }
    }
    static void Put16(byte[] b, int p, int v) { b[p] = (byte)v; b[p + 1] = (byte)(v >> 8); }
    static void Put32(byte[] b, int p, uint v) { b[p] = (byte)v; b[p + 1] = (byte)(v >> 8); b[p + 2] = (byte)(v >> 16); b[p + 3] = (byte)(v >> 24); }

    public static string Sha256Prefix(string path, long len) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
        using (SHA256 sha = new SHA256CryptoServiceProvider()) {
            byte[] buf = new byte[1 << 22]; long left = len;
            while (left > 0) {
                int n = f.Read(buf, 0, (int)Math.Min(buf.Length, left));
                if (n <= 0) throw new IOException("檔案比預期短：" + path);
                sha.TransformBlock(buf, 0, n, null, 0); left -= n;
            }
            sha.TransformFinalBlock(buf, 0, 0);
            return BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
        }
    }

    // 0 = 原版；1 = 已裝過補丁（前段是原版）；-1 = 不是支援的版本
    public static int CheckOriginal(string path, long origSize, string origSha) {
        long size = new FileInfo(path).Length;
        if (size < origSize) return -1;
        if (Sha256Prefix(path, origSize) != origSha) return -1;
        return size > origSize ? 1 : 0;
    }

    public static void Truncate(string path, long size) {
        using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None)) f.SetLength(size);
    }

    class Cd { public byte[] Raw; public List<int> Pos = new List<int>(); public List<string> Names = new List<string>(); public int Count; }

    static Cd ReadCd(FileStream f) {
        long len = f.Length; int n = (int)Math.Min(len, 70000);
        byte[] buf = new byte[n]; f.Seek(len - n, SeekOrigin.Begin); ReadFull(f, buf, 0, n);
        int i = -1;
        for (int p = n - 22; p >= 0; p--) if (buf[p] == 0x50 && buf[p + 1] == 0x4b && buf[p + 2] == 5 && buf[p + 3] == 6) { i = p; break; }
        if (i < 0) throw new Exception("找不到 zip 目錄");
        Cd cd = new Cd();
        cd.Count = BitConverter.ToUInt16(buf, i + 10);
        uint size = BitConverter.ToUInt32(buf, i + 12); uint off = BitConverter.ToUInt32(buf, i + 16);
        cd.Raw = new byte[size]; f.Seek(off, SeekOrigin.Begin); ReadFull(f, cd.Raw, 0, size);
        int q = 0;
        for (int k = 0; k < cd.Count; k++) {
            if (BitConverter.ToUInt32(cd.Raw, q) != 0x02014b50u) throw new Exception("zip 目錄損壞");
            int nl = BitConverter.ToUInt16(cd.Raw, q + 28), el = BitConverter.ToUInt16(cd.Raw, q + 30), cl = BitConverter.ToUInt16(cd.Raw, q + 32);
            cd.Pos.Add(q); cd.Names.Add(Encoding.ASCII.GetString(cd.Raw, q + 46, nl));
            q += 46 + nl + el + cl;
        }
        return cd;
    }

    static byte[] ReadEntry(FileStream f, Cd cd, string name, long minCap, out long usize) {
        int k = cd.Names.IndexOf(name);
        if (k < 0) throw new Exception("zip 內找不到 " + name);
        int q = cd.Pos[k];
        int method = BitConverter.ToUInt16(cd.Raw, q + 10);
        usize = BitConverter.ToUInt32(cd.Raw, q + 24);
        uint lo = BitConverter.ToUInt32(cd.Raw, q + 42);
        byte[] lh = new byte[30]; f.Seek(lo, SeekOrigin.Begin); ReadFull(f, lh, 0, 30);
        if (BitConverter.ToUInt32(lh, 0) != 0x04034b50u) throw new Exception("zip 記錄損壞：" + name);
        int nl = BitConverter.ToUInt16(lh, 26), el = BitConverter.ToUInt16(lh, 28);
        f.Seek(lo + 30 + nl + el, SeekOrigin.Begin);
        byte[] buf = new byte[Math.Max(usize, minCap)];
        if (method == 0) ReadFull(f, buf, 0, usize);
        else if (method == 8) { using (DeflateStream ds = new DeflateStream(f, CompressionMode.Decompress, true)) ReadFull(ds, buf, 0, usize); }
        else throw new Exception("不支援的壓縮方式：" + name);
        return buf;
    }

    static byte[] Gunzip(string path) {
        using (FileStream fs = File.OpenRead(path))
        using (GZipStream gz = new GZipStream(fs, CompressionMode.Decompress))
        using (MemoryStream ms = new MemoryStream()) { gz.CopyTo(ms); return ms.ToArray(); }
    }

    // 差異檔：gzip( "KL2D" u32 版本, u64 原長, u32 原CRC, u64 新長, u32 新CRC, u32 筆數, {u64 位置, u32 長度, 資料}* )
    static byte[] ApplyDelta(string deltaPath, FileStream srcZip, Cd srcCd, string srcEntry, out long len, out uint crc) {
        using (FileStream fs = File.OpenRead(deltaPath))
        using (GZipStream gz = new GZipStream(fs, CompressionMode.Decompress))
        using (BinaryReader br = new BinaryReader(gz)) {
            if (Encoding.ASCII.GetString(br.ReadBytes(4)) != "KL2D") throw new Exception("差異檔格式錯誤：" + deltaPath);
            br.ReadInt32();
            long srcLen = br.ReadInt64(); uint srcCrc = br.ReadUInt32();
            long dstLen = br.ReadInt64(); uint dstCrc = br.ReadUInt32(); int nrec = br.ReadInt32();
            long usize;
            byte[] buf = ReadEntry(srcZip, srcCd, srcEntry, dstLen, out usize);
            if (usize != srcLen || Crc32(buf, usize) != srcCrc) throw new Exception("原始資料與補丁不符：" + srcEntry);
            for (int i = 0; i < nrec; i++) {
                long off = br.ReadInt64(); int n = br.ReadInt32();
                ReadFull(gz, buf, off, n);
            }
            len = dstLen; crc = Crc32(buf, len);
            if (crc != dstCrc) throw new Exception("補丁結果校驗失敗：" + srcEntry);
            return buf;
        }
    }

    // names[i]：要寫進 zip 的檔名；srcZips[i] 空字串 = 來源在同一個 zip；deltas[i] / fulls[i] 二擇一
    public static void PatchZip(string zipPath, long origSize, string origSha, bool ioiTail, string gameDir, string dataDir,
                                string[] names, string[] srcZips, string[] srcEntries, string[] deltas, string[] fulls, bool alreadyChecked) {
        int st = alreadyChecked ? (new FileInfo(zipPath).Length > origSize ? 1 : 0) : CheckOriginal(zipPath, origSize, origSha);
        if (st < 0) throw new Exception("檔案和支援的版本不符：" + zipPath);
        if (st == 1) Truncate(zipPath, origSize);
        bool ok = false;
        try {
            using (FileStream f = new FileStream(zipPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None, 1 << 20)) {
                Cd cd = ReadCd(f);
                long pos = f.Length;
                List<byte[]> extra = new List<byte[]>();
                for (int i = 0; i < names.Length; i++) {
                    byte[] data; long len; uint crc;
                    if (!string.IsNullOrEmpty(deltas[i])) {
                        if (string.IsNullOrEmpty(srcZips[i])) data = ApplyDelta(Path.Combine(dataDir, deltas[i]), f, cd, srcEntries[i], out len, out crc);
                        else {
                            using (FileStream sf = new FileStream(Path.Combine(gameDir, srcZips[i]), FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
                                data = ApplyDelta(Path.Combine(dataDir, deltas[i]), sf, ReadCd(sf), srcEntries[i], out len, out crc);
                        }
                    } else {
                        data = Gunzip(Path.Combine(dataDir, fulls[i])); len = data.Length; crc = Crc32(data, len);
                    }
                    int k = cd.Names.IndexOf(names[i]);
                    ushort time = 0x9000, date = 0x3CE6;
                    if (k >= 0) { time = BitConverter.ToUInt16(cd.Raw, cd.Pos[k] + 12); date = BitConverter.ToUInt16(cd.Raw, cd.Pos[k] + 14); }
                    byte[] fn = Encoding.ASCII.GetBytes(names[i]);
                    byte[] lh = new byte[30 + fn.Length];
                    Put32(lh, 0, 0x04034b50u); Put16(lh, 4, 20); Put16(lh, 6, 0); Put16(lh, 8, 8); Put16(lh, 10, time); Put16(lh, 12, date);
                    Put32(lh, 14, crc); Put32(lh, 18, 0); Put32(lh, 22, (uint)len); Put16(lh, 26, fn.Length); Put16(lh, 28, 0);
                    Array.Copy(fn, 0, lh, 30, fn.Length);
                    f.Seek(pos, SeekOrigin.Begin); f.Write(lh, 0, lh.Length);
                    long dataStart = f.Position;
                    using (DeflateStream ds = new DeflateStream(f, CompressionLevel.Fastest, true)) ds.Write(data, 0, (int)len);
                    long csize = f.Position - dataStart;
                    f.Seek(pos + 18, SeekOrigin.Begin); f.Write(BitConverter.GetBytes((uint)csize), 0, 4);
                    if (k >= 0) {
                        int q = cd.Pos[k];
                        Put16(cd.Raw, q + 8, 0); Put16(cd.Raw, q + 10, 8);
                        Put32(cd.Raw, q + 16, crc); Put32(cd.Raw, q + 20, (uint)csize); Put32(cd.Raw, q + 24, (uint)len); Put32(cd.Raw, q + 42, (uint)pos);
                    } else {
                        byte[] r = new byte[46 + fn.Length];
                        Put32(r, 0, 0x02014b50u); Put16(r, 4, 20); Put16(r, 6, 20); Put16(r, 8, 0); Put16(r, 10, 8); Put16(r, 12, time); Put16(r, 14, date);
                        Put32(r, 16, crc); Put32(r, 20, (uint)csize); Put32(r, 24, (uint)len); Put16(r, 28, fn.Length);
                        Put32(r, 42, (uint)pos); Array.Copy(fn, 0, r, 46, fn.Length);
                        extra.Add(r);
                    }
                    Console.WriteLine("    " + names[i] + "  " + (len >> 10) + " KB");
                    pos = dataStart + csize;
                }
                f.Seek(pos, SeekOrigin.Begin);
                long cdOff = pos, cdSize = cd.Raw.Length;
                f.Write(cd.Raw, 0, cd.Raw.Length);
                foreach (byte[] r in extra) { f.Write(r, 0, r.Length); cdSize += r.Length; }
                int count = cd.Count + extra.Count;
                byte[] eocd = new byte[22];
                Put32(eocd, 0, 0x06054b50u); Put16(eocd, 8, count); Put16(eocd, 10, count); Put32(eocd, 12, (uint)cdSize); Put32(eocd, 16, (uint)cdOff);
                f.Write(eocd, 0, 22);
                if (ioiTail) {
                    byte[] tail = new byte[22];
                    tail[0] = (byte)'e'; tail[1] = (byte)'n'; tail[2] = (byte)'u'; tail[3] = (byte)'R'; Put32(tail, 16, (uint)cdOff);
                    f.Write(tail, 0, 22);
                }
                f.SetLength(f.Position);
            }
            ok = true;
        } finally {
            if (!ok) { try { Truncate(zipPath, origSize); } catch { } }
        }
    }
}
}
'@

$GogId = '2057392130'
$GogFolder = 'Kane & Lynch 2 Dog Days'

function Get-Kind([string]$d) {
    if (Test-Path -LiteralPath (Join-Path $d 'Galaxy.dll')) { return 'GOG' }
    if (Test-Path -LiteralPath (Join-Path $d 'steam_api.dll')) { return 'Steam' }
    return '?'
}

# 找遊戲時只用字串組路徑：Join-Path 遇到不存在的磁碟機（例如 Steam 遊戲庫或 GOG 安裝路徑在已拔掉的硬碟上）會丟 DriveNotFoundException，
# 在 $ErrorActionPreference = 'Stop' 下會讓後面的 Steam 遊戲庫被略過，或讓整支腳本中止。[IO.Path]::Combine 只拼字串，不檢查磁碟機。
function Join-PathSafe([string]$a, [string]$b) { [System.IO.Path]::Combine($a, $b) }

function Get-GameCandidates {
    $c = New-Object System.Collections.Generic.List[string]
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath -replace '/', '\'
        $libs = @($steam)
        $vdf = Join-PathSafe $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($mt in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($mt.Groups[1].Value -replace '\\\\', '\') }
        }
        foreach ($l in $libs) { $c.Add((Join-PathSafe $l ('steamapps\common\' + $M.game_folder))) }
    } catch { }
    foreach ($k in ('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\' + $GogId), ('HKLM:\SOFTWARE\GOG.com\Games\' + $GogId), ('HKCU:\SOFTWARE\GOG.com\Games\' + $GogId)) {
        try { $gp = (Get-ItemProperty -Path $k -ErrorAction Stop).path; if ($gp) { $c.Add($gp) } } catch { }
    }
    foreach ($dr in [IO.DriveInfo]::GetDrives()) {
        if ($dr.DriveType -ne 'Fixed' -or -not $dr.IsReady) { continue }
        $r = $dr.RootDirectory.FullName
        foreach ($sub in $GogFolder, ('GOG Games\' + $GogFolder), ('GOG Galaxy\Games\' + $GogFolder), ('Program Files (x86)\GOG Galaxy\Games\' + $GogFolder)) { $c.Add((Join-PathSafe $r $sub)) }
    }
    $seen = @{}
    foreach ($d in $c) {
        if (-not (Test-Path -LiteralPath (Join-PathSafe $d 'kl2.exe'))) { continue }
        $full = (Resolve-Path -LiteralPath $d).Path.TrimEnd('\')
        if (-not $seen.ContainsKey($full.ToLowerInvariant())) { $seen[$full.ToLowerInvariant()] = 1; $full }
    }
}

function Find-GameDir {
    if ($GameDir) {
        if (Test-Path -LiteralPath (Join-PathSafe $GameDir 'kl2.exe')) { return (Resolve-Path -LiteralPath $GameDir).Path }
        throw '指定的資料夾裡沒有 kl2.exe。'
    }
    $up = Split-Path -Parent $Root
    if ($up -and (Test-Path -LiteralPath (Join-PathSafe $up 'kl2.exe'))) { return $up }
    $list = @(Get-GameCandidates)
    if ($list.Count -eq 1) { return $list[0] }
    if ($list.Count -gt 1) {
        Write-Host '找到多個遊戲資料夾：'
        for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('  {0}) [{1}] {2}' -f ($i + 1), (Get-Kind $list[$i]), $list[$i]) }
        $n = 0
        if ([int]::TryParse((Read-Host '請輸入要安裝的編號').Trim(), [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { return $list[$n - 1] }
        throw '沒有選擇遊戲資料夾。'
    }
    $p = (Read-Host '找不到遊戲資料夾，請貼上路徑（裡面要有 kl2.exe）').Trim('"', ' ')
    if (Test-Path -LiteralPath (Join-PathSafe $p 'kl2.exe')) { return $p }
    throw '這個資料夾裡沒有 kl2.exe。'
}

function Get-Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
$VerifyHint = '請先用 Steam「驗證遊戲檔案完整性」或 GOG Galaxy「管理安裝 → 驗證／修復」把遊戲還原成原版，再重新安裝。'

# 找出這個 zip 符合哪一組原檔（Steam／GOG）。回傳 @{ o = 原檔資料; st = 0 原版／1 已裝過 }，都不符回傳 $null
function Find-Orig([string]$p, $z) {
    foreach ($o in $z.origs) {
        $st = [KL2.Engine]::CheckOriginal($p, [long]$o.size, [string]$o.sha256)
        if ($st -ge 0) { return @{ o = $o; st = $st } }
    }
    return $null
}

try {
    Write-Host ("《Kane & Lynch 2: Dog Days》" + $M.name + " v" + $M.version + "（Steam／GOG 通用）")
    $game = Find-GameDir
    Write-Host ("遊戲資料夾：" + $game + "（" + (Get-Kind $game) + " 版）")
    if (Get-Process kl2 -ErrorAction SilentlyContinue) { throw '遊戲正在執行，請先關閉。' }
    $bk = Join-Path $game $BackupName
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($Mode -eq 'install') {
        Write-Host '檢查遊戲檔案…'
        $match = @{}
        foreach ($z in $M.zips) {
            $p = Join-Path $game $z.rel
            if (-not (Test-Path -LiteralPath $p)) { throw ("找不到 " + $z.rel + "。" + $VerifyHint) }
            $f = Find-Orig $p $z
            if (-not $f) { throw ("檔案和支援的版本（Steam／GOG）不符：" + $z.rel + "。" + $VerifyHint) }
            $match[$z.rel] = $f
        }
        foreach ($s in $M.sources) {
            if (@($s.sha256s) -notcontains (Get-Sha (Join-Path $game $s.rel))) { throw ("檔案和支援的版本（Steam／GOG）不符：" + $s.rel + "。" + $VerifyHint) }
        }
        foreach ($h in $M.files) {
            $p = Join-Path $game $h.rel; $b = Join-Path $bk $h.rel
            $cur = Get-Sha $p
            $okBackup = (Test-Path -LiteralPath $b) -and (@($h.orig_sha256s) -contains (Get-Sha $b))
            if ((@($h.orig_sha256s) -notcontains $cur) -and $cur -ne $h.new_sha256 -and -not $okBackup) {
                throw ("檔案和支援的版本（Steam／GOG）不符：" + $h.rel + "。" + $VerifyHint)
            }
        }
        $i = 0
        foreach ($z in $M.zips) {
            $i++
            $f = $match[$z.rel]; $o = $f.o
            Write-Host ("[{0}/{1}] {2}" -f $i, $M.zips.Count, $z.rel)
            $ents = if ($o.entries) { $o.entries } else { $z.entries }
            $names = @($ents | ForEach-Object { [string]$_.name })
            $srcz = @($ents | ForEach-Object { if ($_.source_zip) { [string]$_.source_zip } else { '' } })
            $srce = @($ents | ForEach-Object { if ($_.source_entry) { [string]$_.source_entry } else { [string]$_.name } })
            $dl = @($ents | ForEach-Object { if ($_.delta) { [string]$_.delta } else { '' } })
            $fl = @($ents | ForEach-Object { if ($_.full) { [string]$_.full } else { '' } })
            [KL2.Engine]::PatchZip((Join-Path $game $z.rel), [long]$o.size, [string]$o.sha256, [bool]$o.ioi_tail, $game, $Data,
                [string[]]$names, [string[]]$srcz, [string[]]$srce, [string[]]$dl, [string[]]$fl, $true)
        }
        Write-Host '更新字型尺寸表…'
        foreach ($h in $M.files) {
            $p = Join-Path $game $h.rel; $b = Join-Path $bk $h.rel
            if ((@($h.orig_sha256s) -contains (Get-Sha $p)) -and -not (Test-Path -LiteralPath $b)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null
                Copy-Item -LiteralPath $p -Destination $b
            }
            Copy-Item -LiteralPath (Join-Path $Data $h.new) -Destination $p -Force
            if ((Get-Sha $p) -ne $h.new_sha256) { throw ("寫入失敗：" + $h.rel) }
        }
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Set-Content -LiteralPath (Join-Path $bk 'installed.txt') -Value ($M.name + " v" + $M.version) -Encoding UTF8
        Write-Host ("安裝完成（{0:N0} 秒）。移除請執行「移除」那個 bat。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        $i = 0
        foreach ($z in $M.zips) {
            $i++
            $p = Join-Path $game $z.rel
            $f = Find-Orig $p $z
            if (-not $f) { Write-Warning ("無法辨識，略過：" + $z.rel) }
            elseif ($f.st -eq 1) { [KL2.Engine]::Truncate($p, [long]$f.o.size); Write-Host ("[{0}/{1}] 已還原 {2}" -f $i, $M.zips.Count, $z.rel) }
        }
        foreach ($h in $M.files) {
            $p = Join-Path $game $h.rel; $b = Join-Path $bk $h.rel
            if ((Test-Path -LiteralPath $b) -and (@($h.orig_sha256s) -contains (Get-Sha $b))) {
                Copy-Item -LiteralPath $b -Destination $p -Force
                Remove-Item -LiteralPath $b
            } elseif (@($h.orig_sha256s) -notcontains (Get-Sha $p)) { Write-Warning ("沒有備份，無法還原：" + $h.rel) }
        }
        if (Test-Path -LiteralPath $bk) {
            Remove-Item -LiteralPath (Join-Path $bk 'installed.txt') -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $bk -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
                Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item
            if (-not (Get-ChildItem -LiteralPath $bk -Force)) { Remove-Item -LiteralPath $bk }
        }
        Write-Host ("已移除中文補丁，遊戲檔案恢復原狀（{0:N0} 秒）。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    }
} catch {
    Write-Host ("錯誤：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
