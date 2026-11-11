param([string]$Package, [string]$ExtractDir=".\extracted", [string]$Out="output.zip")
# 三段流水线示例：解压 → 批量重命名 → 重新打包
# 全程使用系统自带命令（不依赖任何外部工具 / 索引条目），符合 AGENT_INIT_PROMPT 的「系统命令优先」。
# 若以后注册了 7z 兼容语法的压缩工具，可把第 1/3 步替换为索引路由到的可执行文件。

if (-not $Package) {
    Write-Output "用法: pipeline-example.ps1 -Package <zip包> [-ExtractDir <目录>] [-Out <输出.zip>]"
    Write-Output "  示例: .\examples\pipeline-example.ps1 -Package .\sample.zip"
    exit 1
}
if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) { Write-Output "❌ 压缩包不存在: $Package"; exit 1 }
if ($Package -notmatch "\.zip$") {
    Write-Output "❌ 系统 Expand-Archive 只支持 .zip：$Package"
    Write-Output "   其他格式请先注册外部工具（如 Bandizip / 7-Zip）并改用对应的命令行参数"
    exit 1
}
if (Test-Path -LiteralPath $Out) { Write-Output "❌ 输出文件已存在，避免覆盖: $Out"; exit 1 }

Write-Output "[1/3] 解压 → $ExtractDir"
try { Expand-Archive -LiteralPath $Package -DestinationPath $ExtractDir -Force -ErrorAction Stop }
catch { Write-Output "❌ 解压失败: $($_.Exception.Message)"; exit 1 }

Write-Output "[2/3] 批量重命名（复用 rename.ps1）"
& (Join-Path $PSScriptRoot "..\scripts\rename\rename.ps1") -Path $ExtractDir -Pattern "\.old$" -Replace ".new"

Write-Output "[3/3] 打包 → $Out"
try { Compress-Archive -Path (Join-Path $ExtractDir "*") -DestinationPath $Out -Force -ErrorAction Stop }
catch { Write-Output "❌ 打包失败: $($_.Exception.Message)"; exit 1 }
Write-Output "✅ 流水线完成 → $Out（发送步骤交 GUI Agent）"
