param([string]$Path=".", [string]$Pattern, [string]$Replace, [switch]$Recurse, [switch]$WhatIf)
if (-not $Pattern) {
    Write-Output "用法: rename.ps1 -Path <dir> -Pattern <regex> -Replace <str> [-Recurse] [-WhatIf]"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Output "❌ 目录不存在: $Path"; exit 1 }
$files = if ($Recurse) { Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Ignore }
         else { Get-ChildItem -LiteralPath $Path -File -ErrorAction Ignore }
$n = 0; $skipped = 0
foreach ($f in $files) {
    $new = $f.Name -replace $Pattern, $Replace
    if ($new -eq $f.Name) { continue }
    $dest = Join-Path (Split-Path $f.FullName -Parent) $new
    if (Test-Path -LiteralPath $dest) {
        Write-Output "⏭ 目标已存在，跳过: $($f.Name) → $new"
        $skipped++
        continue
    }
    if ($WhatIf) { Write-Output "[WhatIf] $($f.Name) → $new"; $n++; continue }
    try {
        Rename-Item -LiteralPath $f.FullName -NewName $new -ErrorAction Stop
        $n++
        Write-Output "$($f.Name) → $new"
    } catch {
        Write-Output "❌ 失败: $($f.Name) → $new : $($_.Exception.Message)"
        $skipped++
    }
}
$mode = if ($WhatIf) { "（模拟，未实际改动）" } else { "" }
Write-Output "完成: 处理 $n 个，跳过 $skipped 个$mode"
