# scripts/

GachimuchiSampling 仓库的辅助脚本。所有脚本都用 **PowerShell**（`pwsh`）写，macOS / Linux / Windows 通用。

## 安装 pwsh

| 平台 | 命令 |
|---|---|
| macOS | `brew install powershell` |
| Linux | 见 https://learn.microsoft.com/powershell/scripting/install/installing-powershell |
| Windows | 已内置（Windows 10+）或 `winget install Microsoft.PowerShell` |

跑通后 `pwsh --version` 能出版本即可。

---

## check_samplerate.ps1 — 检查 WAV 采样率

检查 WAV 文件采样率是否合规（默认 48000 Hz）。**正确处理变体 WAV**——遍历 chunks 找 `fmt `，不会被 `JUNK`/`fact` 等辅助 chunk 挡住（FL Studio Edison、各大宿主导出的 WAV 常有这种结构）。

### 用法

```pwsh
# 默认：递归扫当前目录下所有 .wav，目标 48kHz
pwsh scripts/check_samplerate.ps1

# 指定目录 + 不同目标采样率
pwsh scripts/check_samplerate.ps1 -Path "D:\Samples" -TargetRate 44100

# 只查指定文件（不再递归扫目录），逗号分隔或数组都行
pwsh scripts/check_samplerate.ps1 -Files "a.wav,b.wav"
pwsh scripts/check_samplerate.ps1 -Files @("a.wav","b.wav")

# 不符合的文件导出 CSV
pwsh scripts/check_samplerate.ps1 -Csv "bad.csv"
```

### 输出模式

默认人类可读 banner：

```
=== 采样率检查报告 ===
检查路径 : /Users/user2/Documents/Code.localized/GachimuchiSampling
目标采样率: 48000 Hz
总检查文件: 75
符合要求  : 75
不符合    : 0
```

### agent 模式

给 agent / CI 用，不带 banner：

```pwsh
# 紧凑机器行：RESULT 一行总结 + 每个不符合一行 BAD
pwsh scripts/check_samplerate.ps1 -AsAgent
# 输出：
# RESULT ok=75 bad=0 total=75 target=48000
# BAD <rate> <abs_path> <note>     ← 只有不符合时才有
```

```pwsh
# JSON 模式：单行 JSON，可直接 ConvertFrom-Json
pwsh scripts/check_samplerate.ps1 -Json
# 输出：
# {"ok":75,"bad":0,"total":75,"target":48000,"files":[]}
```

JSON 字段：

| 字段 | 含义 |
|---|---|
| `ok` | 符合目标采样率的文件数 |
| `bad` | 不符合的文件数 |
| `total` | 总检查文件数 |
| `target` | 目标采样率（Hz） |
| `files` | 不符合文件数组，每项 `{file, rate, note}`，路径为绝对路径 |

### 退出码

agent 可不 parse 输出，只靠退出码判定：

| exit | 含义 |
|---|---|
| `0` | 全合规 |
| `1` | 有不符合（采样率不对 / 文件不存在 / 不是有效 WAV） |
| `2` | 没查到任何 wav（路径下没文件，或 `-Files` 列表全空） |

### agent 调用示例

快速 pass/fail 判定（不看输出）：

```pwsh
pwsh scripts/check_samplerate.ps1 -AsAgent
if ($LASTEXITCODE -eq 0) { "all good" }
elseif ($LASTEXITCODE -eq 1) { "has bad" }
else { "no wav" }
```

拿不符合文件列表做后续处理：

```pwsh
pwsh scripts/check_samplerate.ps1 -Json |
  ConvertFrom-Json | Select-Object -ExpandProperty files
```

只查一批文件并按结果分类：

```pwsh
$r = pwsh scripts/check_samplerate.ps1 -Json | ConvertFrom-Json
$r.files | Where-Object { $_.rate -eq "MISSING" }   # 不存在的
$r.files | Where-Object { $_.rate -ne "MISSING" }   # 采样率不对的
```

### 参数一览

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `-Path` | string | 当前目录 | 递归扫的根目录（仅 `-Files` 未指定时用） |
| `-Files` | string[] | 空 | 只查这些文件，不再递归扫目录。逗号分隔或数组都行 |
| `-TargetRate` | int | 48000 | 目标采样率 |
| `-Csv` | string | 空 | 不符合文件导出 CSV 路径 |
| `-AsAgent` | switch | — | 紧凑机器行输出 |
| `-Json` | switch | — | 单行 JSON 输出 |

---

## 给 agent 的提示

如果你是 agent，被叫来"修某个 wav 的采样率"或"检查仓库采样率合规性"：

1. **先跑** `pwsh scripts/check_samplerate.ps1 -AsAgent` 看仓库整体情况
2. 退出码 `0` 就合规，`1` 就看 BAD 行——每行一个绝对路径，拿来直接操作就行
3. 操作完具体文件后，**只查那几个文件**省时间：`-Files "path1,path2"`
4. `-Json` 模式输出 parse 更稳，`-AsAgent` 行模式 grep 更快——按需选
5. 变体 WAV（JUNK/fact chunk 前置）脚本已正确处理，别再当 bug 报告
