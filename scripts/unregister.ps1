param([string]$Id, [string]$Path, [switch]$Hard, [switch]$PurgeDoc)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$rootDir = Split-Path $PSScriptRoot -Parent
$reg = Get-Registry

if (-not $Id -and -not $Path) {
    Write-Output "用法: unregister.ps1 -Id <id> [-Hard] [-PurgeDoc]  或  -Path <工具文件> [-Hard]"
    Write-Output "     -Id 同时适用于普通工具与 Quicker 动作（动作 id = quicker-<动作码>）"
    Write-Output "     默认软删（保留说明文档）；-Hard 物理移除并把说明文档移入 tools\_archive"
    Write-Output "     -PurgeDoc 仅配合 -Hard：彻底删除说明文档（不可恢复）"
    exit 1
}
if ($PurgeDoc -and -not $Hard) {
    Write-Output "❌ -PurgeDoc 只能配合 -Hard 使用；为避免误以为没删却改了索引，本次未写入任何内容"
    Write-Output "   软删除请去掉 -PurgeDoc；要彻底删文档请加 -Hard"
    exit 2
}
if ($Path) {
    $rp = Resolve-Path -LiteralPath $Path -ErrorAction Ignore
    if (-not $rp) { Write-Output "⚠️ 路径不存在: $Path"; exit 1 }
    $Path = [string]$rp   # PathInfo → string，避免比较失败
}

# tools 与 quicker_actions 是两类实体，按 id 分别查找，删对了数组才算真删掉
$inTools   = @()
$inQuicker = @()
if ($Id) {
    $inTools   = @($reg.tools           | Where-Object { [string]$_.id -eq $Id })
    $inQuicker = @($reg.quicker_actions | Where-Object { [string]$_.id -eq $Id })
} elseif ($Path) {
    $inTools   = @($reg.tools | Where-Object { [string]$_.locator.primary -eq $Path })
}

if ($inTools.Count -gt 0 -and $inQuicker.Count -gt 0) {
    Write-Output "❌ id '$Id' 同时存在于 tools 与 quicker_actions，索引数据异常，请人工核对"
    exit 1
}

$collection = if ($inQuicker.Count -gt 0) { 'quicker_actions' } else { 'tools' }
$label      = if ($collection -eq 'quicker_actions') { 'Quicker 动作' } else { '工具' }
$found      = if ($collection -eq 'quicker_actions') { $inQuicker } else { $inTools }

# 软删除重复操作要跳过；但硬删除允许清理已软删除的条目
if (-not $Hard) { $found = @($found | Where-Object { -not $_.deleted }) }

if ($found.Count -eq 0) { Write-Output "⚠️ 未找到（或已删除）: $Id$Path"; exit 0 }
if ($found.Count -gt 1) {
    Write-Output "⚠️ 匹配到 $($found.Count) 条同 id 记录，为避免误删已中止；请用 -Path 精确指定"
    exit 1
}

$t = $found[0]
$deletedId = [string]$t.id
if ($Hard) {
    if ($collection -eq 'quicker_actions') {
        $reg.quicker_actions = @($reg.quicker_actions | Where-Object { $_ -ne $t })
    } else {
        $reg.tools = @($reg.tools | Where-Object { $_ -ne $t })
    }
    # 标记删除意图：Save-Registry 锁内合并磁盘快照时不要再把这个 id 捡回来
    Mark-RegistryRemoval $collection $deletedId
    Write-Output "🗑️ 硬删除 $label : $deletedId"
} else {
    Set-ToolDeleted $t $true
    Write-Output "🕓 软删除 $label : $deletedId ($($t.name))"
}
Save-Registry $reg
Write-Output "   version → $($reg.version)"

# ===== 说明文档联动 =====
# 硬删：文档移入 tools\_archive（或 -PurgeDoc 彻底删除）；共享文档/模板/越界路径一律不动。
# 软删：文档保留，因为条目可随时重新激活；明确打印提示，避免「删了工具还留着文档」的疑惑。
$usage = if ($t.PSObject.Properties['usage_page'] -and $t.usage_page) { [string]$t.usage_page } else { '' }
if ($usage) {
    if (-not $Hard) {
        Write-Output "   📄 文档保留（软删可恢复）: $usage"
        Write-Output "      要连文档一起清理：unregister.ps1 -Id $deletedId -Hard [-PurgeDoc]"
    } elseif (Test-DocShared $reg $usage $deletedId) {
        Write-Output "   📄 文档被其它条目共享，已保留: $usage"
    } else {
        $res = Remove-DocForTool $rootDir $usage $deletedId ([bool]$PurgeDoc)
        Write-Output "   📄 $res"
    }
} elseif ($Hard) {
    Write-Output "   📄 无说明文档（简单工具，索引直接指向 exe）"
}
Write-Output "[Registry] 操作: $(if($Hard){'硬删除'}else{'软删除'}) | 工具: $deletedId | version: $($reg.version)"
