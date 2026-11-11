# record-interface.ps1 —— 任务之余补写接口（从简原则的渐进式入口）
# 场景：完成某个任务时第一次用到某接口，才把它写进索引 interfaces 与说明文档的受管表格。
# 没用过的功能/接口不要预先写详细参数；本命令让「用到 → 顺手沉淀」成为一步可执行的动作。
param(
    [Parameter(Mandatory=$true)][string]$Id,
    [string]$Name,
    [string]$Syntax = "",
    [string]$Note = "",
    [string]$Task = "",
    [switch]$Force
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-fields.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$rootDir = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

if (-not $Name) {
    Write-Output "用法: record-interface.ps1 -Id <id> -Name <接口名> [-Syntax '<调用语法>'] [-Note '<一句话>'] [-Task '<触发任务>'] [-Force]"
    Write-Output "  只补写真正用到过的接口；重复补写同一接口是幂等的，不会重复入库或涨 version。"
    exit 1
}

# 文档文件联动：缺则生成从简骨架，再把接口表同步进受管区块
function Sync-RecordDoc($entity, [string]$usage, [string]$primary) {
    $dp = Resolve-DocPath $rootDir $usage
    if (-not $dp) {
        Write-Output "   ⚠️ usage_page 不在受管范围，文档未生成: $usage"
        return
    }
    if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) {
        New-MinimalDoc $dp $entity $rootDir $primary
        Write-Output "   📄 已生成从简说明文档: $usage"
    }
    $c = Sync-DocInterfaceBlock $dp @($entity.interfaces)
    $tail = if ($c) { '（已写入文档）' } else { '（文档已是最新）' }
    Write-Output "   📄 接口表已同步: $(@($entity.interfaces).Count) 条$tail"
}

$reg = Get-Registry
$inTools   = @($reg.tools           | Where-Object { [string]$_.id -eq $Id -and -not $_.deleted })
$inQuicker = @($reg.quicker_actions | Where-Object { [string]$_.id -eq $Id -and -not $_.deleted })
if ($inTools.Count -gt 0 -and $inQuicker.Count -gt 0) {
    Write-Output "❌ id '$Id' 同时存在于 tools 与 quicker_actions，索引数据异常"; exit 1
}
$kind  = if ($inQuicker.Count -gt 0) { 'quicker' } else { 'tool' }
$found = if ($kind -eq 'quicker') { $inQuicker } else { $inTools }
if ($found.Count -eq 0) { Write-Output "❌ 未找到启用中的条目: $Id"; exit 1 }
$t = $found[0]
$primary = if ($kind -eq 'quicker') { [string]$t.starter } else { [string]$t.locator.primary }

$now  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$cur  = if ($t.PSObject.Properties['interfaces']) { @($t.interfaces) } else { @() }
$hit  = @($cur | Where-Object { $_.PSObject.Properties['name'] -and [string]$_.name -eq $Name })

if ($hit.Count -gt 0) {
    $old = $hit[0]
    $oldSyntax = if ($old.PSObject.Properties['syntax']) { [string]$old.syntax } else { '' }
    $oldNote   = if ($old.PSObject.Properties['note'])   { [string]$old.note }   else { '' }
    $same = ($oldSyntax -ceq $Syntax) -and ($oldNote -ceq $Note)
    if ($same -and -not $Force) {
        # 幂等路径必须完全不写盘：以前这里会顺手重建被删掉的文档，导致「version 不变但文件变了」
        Write-Output "ℹ️ 接口 '$Name' 已在索引中且内容相同，无需重复补写（version 不变）"
        Write-Output "   文档缺失是独立问题，用 tool-doc.ps1 -Check 检查，必要时用 update-tool.ps1 -UsagePage 补建"
        exit 0
    }
    if (-not $Force) {
        Write-Output "⚠️ 接口 '$Name' 已存在但内容不同；确认要覆盖请加 -Force（默认不覆盖，避免抹掉已验证用法）"
        $global:LASTEXITCODE = 1
        return
    }
    Set-RegistryField $old 'syntax' $Syntax
    Set-RegistryField $old 'note'   $Note
    $uses = 1
    if ($old.PSObject.Properties['used_count']) { $uses = [int]$old.used_count + 1 }
    Set-RegistryField $old 'used_count' $uses
    Set-RegistryField $old 'last_used'  $now
    Write-Output "♻️ 已覆盖接口 '$Name'（-Force），使用次数 $uses"
} else {
    $item = [PSCustomObject]@{
        name            = $Name
        syntax          = $Syntax
        note            = $Note
        used_count      = 1
        last_used       = $now
        added_from_task = $Task
    }
    Set-RegistryField $t 'interfaces' @($cur + $item)
    Write-Output "➕ 补写接口 '$Name'（第 $(@($cur).Count + 1) 条）"
}

# 无文档时按从简原则自动建最小骨架；显式 doc_level=none 是「不要文档」的用户意图，绝不覆盖
$explicitNone = ($t.PSObject.Properties['doc_level'] -and [string]$t.doc_level -eq 'none')
if (-not $explicitNone) {
    if (-not ($t.PSObject.Properties['usage_page']) -or -not $t.usage_page) {
        Set-RegistryField $t 'usage_page' "tools/$Id.md"
        Set-RegistryField $t 'doc_level' 'brief'
        Write-Output "   📄 自动分配说明文档: tools/$Id.md（从简骨架）"
    }
    $curLvl = if ($t.PSObject.Properties['doc_level'] -and $t.doc_level) { [string]$t.doc_level } else { 'none' }
    if ($curLvl -eq 'none') { Set-RegistryField $t 'doc_level' 'brief' }
}

Save-Registry $reg
Write-Output "   version → $($reg.version)"
Sync-RecordDoc $t ([string]$t.usage_page) $primary
Write-Output "[Registry] 操作: 补写接口 | 工具: $Id | 接口: $Name | version: $($reg.version)"
