<#
.SYNOPSIS
    检查 WAV 文件采样率，报告不符合 48kHz 的文件。支持全仓扫或只查指定文件。

.DESCRIPTION
    默认递归扫 -Path 下所有 .wav；指定 -Files 则只查这些文件（不再递归扫目录）。
    读取 WAV 文件头中的采样率（遍历 chunks 找 fmt，正确处理 JUNK/fact 等变体），
    与目标采样率（默认 48000 Hz）对比，输出统计报告。

    默认为人类可读报告（带颜色 banner）。
    开 -AsAgent 输出紧凑机器可读行；开 -Json 直接吐 JSON。
    退出码（agent 用）：0 = 全合规；1 = 有不符合；2 = 没查到任何 wav。

.PARAMETER Path
    要检查的根目录，默认当前目录。仅 -Files 未指定时才用（递归扫）。

.PARAMETER Files
    只查这些 WAV 文件，不再递归扫目录。接受字符串数组：
        -Files "a.wav","b.wav"
        -Files (Get-ChildItem -Filter *.wav)
    路径相对/绝对都行，输出时一律转绝对路径。

.PARAMETER TargetRate
    目标采样率，默认为 48000。

.PARAMETER Csv
    可选：将不符合的文件列表导出为 CSV 文件路径。

.PARAMETER AsAgent
    agent 模式：不输出 banner / 颜色，输出紧凑单行机器可读格式：
        RESULT ok=<n> bad=<n> total=<n> target=<rate>
        BAD <rate> <abs_path> [<note>]        （每个不符合文件一行）
    所有路径一律绝对路径。

.PARAMETER Json
    agent 模式：直接吐 JSON 到 stdout，无 banner / 颜色：
        { "ok": n, "bad": n, "total": n, "target": rate,
          "files": [ { "file": abs, "rate": n, "note": str } ] }

.EXAMPLE
    ./scripts/check_samplerate.ps1

.EXAMPLE
    ./scripts/check_samplerate.ps1 -Path "D:\Samples" -TargetRate 44100 -Csv "report.csv"

.EXAMPLE
    # 只查指定文件
    pwsh scripts/check_samplerate.ps1 -Files "a.wav","b.wav"

.EXAMPLE
    # agent 调用
    pwsh scripts/check_samplerate.ps1 -AsAgent
    pwsh scripts/check_samplerate.ps1 -Json | ConvertFrom-Json
#>

param(
    [string]$Path = (Get-Location),
    [string[]]$Files = @(),
    [int]$TargetRate = 48000,
    [string]$Csv = "",
    [switch]$AsAgent,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$agentMode = $AsAgent -or $Json

# ---------- 收集 WAV 文件 ----------
# -Files 可 能以数组传入，也可能因命令行解析成单个 "a,b" 字符串，这里统一拆平
$flatFiles = @()
foreach ($f in $Files) {
    if ($null -eq $f) { continue }
    # 含逗号且不是绝对路径里的逗号时，按逗号拆（容错命令行传参）
    $flatFiles += ($f -split ',')
}
$flatFiles = $flatFiles | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($flatFiles.Count -gt 0) {
    # 只查指定文件：Resolve-Path 转绝对路径并校验存在
    $wavs = $flatFiles | ForEach-Object {
        try {
            $rp = Resolve-Path -LiteralPath $_
            [PSCustomObject]@{ FullName = $rp.Path }
        } catch {
            [PSCustomObject]@{ FullName = $_ ; _Missing = $true }
        }
    }
} else {
    $wavs = Get-ChildItem -Path $Path -Recurse -Filter *.wav | ForEach-Object {
        [PSCustomObject]@{ FullName = $_.FullName }
    }
}
if ($wavs.Count -eq 0) {
    if ($Json) { Write-Output '{"ok":0,"bad":0,"total":0,"target":' + $TargetRate + ',"files":[]}' }
    elseif ($AsAgent) { Write-Output "RESULT ok=0 bad=0 total=0 target=$TargetRate" }
    else { Write-Host "未找到 .wav 文件。" -ForegroundColor Yellow }
    exit 2
}

# ---------- 逐文件检查 ----------
$ok = 0
$bad = @()

foreach ($f in $wavs) {
    # -Files 指定但文件不存在的：直接记 bad，跳过读字节
    if ($f._Missing) {
        $bad += [PSCustomObject]@{
            File = $f.FullName
            Rate = "MISSING"
            Note = "文件不存在"
        }
        continue
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -lt 44) {
            # 文件太短，不是有效 WAV
            $bad += [PSCustomObject]@{
                File       = $f.FullName
                Rate       = "N/A"
                Note       = "文件过短 (< 44 bytes)"
            }
            continue
        }

        # WAV 格式：RIFF(12) 后跟若干 chunk，每个 chunk = 4 字节 ID + 4 字节 size + 数据
        # 采样率在 fmt chunk 内偏移 8（fmt 数据起始 + 8），4 字节小端序
        # 不能用固定偏移 24 —— 前面可能插入 JUNK/fact/other chunk（FL Studio Edison、宿主导出常见）
        $rate = 0
        $note = ""
        $pos = 12  # 跳过 "RIFF"+size+"WAVE"
        $foundFmt = $false
        while ($pos + 8 -le $bytes.Length) {
            $chunkId = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 4)
            $chunkSize = [BitConverter]::ToUInt32($bytes, $pos + 4)
            if ($chunkId -eq "fmt ") {
                if ($pos + 8 + 4 -le $bytes.Length) {
                    # fmt 数据起始在 pos+8，采样率在其 +4（跳过 format(2) + channels(2))
                    $rate = [BitConverter]::ToUInt32($bytes, $pos + 8 + 4)
                }
                $foundFmt = $true
                break
            }
            # chunk 数据按偶数对齐，往前推到下一个 chunk
            $advance = 8 + $chunkSize
            if ($chunkSize % 2 -ne 0) { $advance++ }
            $pos += $advance
        }

        if (-not $foundFmt) {
            $bad += [PSCustomObject]@{
                File = $f.FullName
                Rate = "N/A"
                Note = "未找到 fmt chunk，可能不是标准 WAV"
            }
            continue
        }

        if ($rate -eq $TargetRate) {
            $ok++
        }
        else {
            $bad += [PSCustomObject]@{
                File = $f.FullName
                Rate = "$rate Hz"
                Note = $note
            }
        }
    }
    catch {
        $bad += [PSCustomObject]@{
            File = $f.FullName
            Rate = "ERROR"
            Note = $_.Exception.Message
        }
    }
}

# ---------- 输出报告 ----------
if ($Json) {
    # JSON 输出：{ ok, bad, total, target, files:[{file,rate,note}] }
    $filesJson = $bad | ForEach-Object {
        $fEsc = $_.File -replace '\\', '\\' -replace '"', '\"'
        $rEsc = $_.Rate -replace '"', '\"'
        $nEsc = $_.Note -replace '\\', '\\' -replace '"', '\"'
        '{"file":"' + $fEsc + '","rate":"' + $rEsc + '","note":"' + $nEsc + '"}'
    }
    $filesStr = if ($filesJson.Count -gt 0) { $filesJson -join ',' } else { '' }
    Write-Output ('{"ok":' + $ok + ',"bad":' + $bad.Count + ',"total":' + $wavs.Count + ',"target":' + $TargetRate + ',"files":[' + $filesStr + ']}')
}
elseif ($AsAgent) {
    # 紧凑机器行：RESULT + 每个不符合一行 BAD
    Write-Output ("RESULT ok=$ok bad=$($bad.Count) total=$($wavs.Count) target=$TargetRate")
    $bad | ForEach-Object {
        $line = "BAD " + $_.Rate + " " + $_.File
        if ($_.Note) { $line += " " + $_.Note }
        Write-Output $line
    }
}
else {
    # 人类可读 banner
    Write-Host "=== 采样率检查报告 ===" -ForegroundColor Cyan
    Write-Host "检查路径 : $Path"
    Write-Host "目标采样率: $TargetRate Hz"
    Write-Host "总检查文件: $($wavs.Count)"
    Write-Host "符合要求  : $ok"
    Write-Host "不符合    : $($bad.Count)"

    if ($bad.Count -gt 0) {
        Write-Host "`n--- 不符合的文件 ---" -ForegroundColor Yellow
        $bad | ForEach-Object {
            Write-Host ("  {0,-8} | {1}" -f $_.Rate, $_.File)
            if ($_.Note) { Write-Host ("          {0}" -f $_.Note) }
        }
    }
}

# ---------- 导出 CSV ----------
if ($Csv -and $bad.Count -gt 0) {
    $bad | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    if (-not $agentMode) { Write-Host "已导出 CSV: $Csv" -ForegroundColor Green }
}

# 退出码：0 全合规；1 有不符合；2 无 wav（agent 用）
if ($wavs.Count -eq 0) { exit 2 }
exit ($bad.Count -gt 0 ? 1 : 0)
