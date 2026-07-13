<#
.SYNOPSIS
    检查仓库中所有 WAV 文件的采样率，报告不符合 48kHz 的文件。

.DESCRIPTION
    遍历指定目录（默认当前目录）下所有 .wav 文件，读取 WAV 文件头中的采样率，
    与目标采样率（默认 48000 Hz）对比，输出统计报告。

.PARAMETER Path
    要检查的根目录，默认为脚本所在目录。

.PARAMETER TargetRate
    目标采样率，默认为 48000。

.PARAMETER Csv
    可选：将不符合的文件列表导出为 CSV 文件路径。

.EXAMPLE
    ./scripts/check_samplerate.ps1

.EXAMPLE
    ./scripts/check_samplerate.ps1 -Path "D:\Samples" -TargetRate 44100 -Csv "report.csv"
#>

param(
    [string]$Path = (Get-Location),
    [int]$TargetRate = 48000,
    [string]$Csv = ""
)

$ErrorActionPreference = "Stop"

# ---------- 收集 WAV 文件 ----------
$wavs = Get-ChildItem -Path $Path -Recurse -Filter *.wav
if ($wavs.Count -eq 0) {
    Write-Host "未找到 .wav 文件。" -ForegroundColor Yellow
    exit 0
}

# ---------- 逐文件检查 ----------
$ok = 0
$bad = @()

foreach ($f in $wavs) {
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

# ---------- 导出 CSV ----------
if ($Csv -and $bad.Count -gt 0) {
    $bad | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "已导出 CSV: $Csv" -ForegroundColor Green
}

# 返回退出码（方便 CI 使用）
exit ($bad.Count -gt 0 ? 1 : 0)
