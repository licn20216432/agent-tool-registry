# tool-doc.ps1 —— 工具说明文档读取器（只读，永不写索引）
# 复杂工具：索引 → 结构化接口清单（随检索注入）→ 完整文档（按需 -Full）→ 可执行文件
# 简单工具：索引 → 可执行文件（无文档、零开销）
# 设计要点：多一层「文档」本身不提速，提速来自把接口清单压进索引命中结果，做到常见任务零跳转。
param(
    [string]$Id,
    [switch]$Full,
    [switch]$InjectPrompt,
    [switch]$Check,
    [switch]$List,
    [int]$MaxInterfaces = 12,
    [int]$WarnAbove = 8
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$ErrorActionPreference = 'Stop'
$rootDir = Split-Path $PSScriptRoot -Parent
$reg = Get-Registry

function Get-Entities {
    $out = @()
    foreach ($t in @($reg.tools           | Where-Object { -not $_.deleted })) { $out += [PSCustomObject]@{ e=$t; kind='tool' } }
    foreach ($q in @($reg.quicker_actions | Where-Object { -not $_.deleted })) { $out += [PSCustomObject]@{ e=$q; kind='quicker' } }
    return $out
}
function Get-DocPath($e) {
    if (-not ($e.PSObject.Properties['usage_page']) -or -not $e.usage_page) { return $null }
    # -Full / -Id 也必须走受管路径校验，不能按 usage_page 直接拼路径读任意文件
    return (Resolve-DocPath $rootDir ([string]$e.usage_page))
}
function Get-Interfaces($e) {
    # interfaces 存在但为 null 时 @($null).Count=1，会虚报「接口 1 条」
    if ($e.PSObject.Properties['interfaces'] -and $e.interfaces) { return @($e.interfaces) } else { return @() }
}
function Get-DocLevel($e) {
    if ($e.PSObject.Properties['doc_level'] -and $e.doc_level) { return [string]$e.doc_level }
    if (Get-DocPath $e) { return 'brief' }
    return 'none'
}
function Get-TierLabel($e) {
    if ($e.PSObject.Properties['tier']) { 'T' + $e.tier } else { 'T-' }
}
function Get-ToolLoc($row) {
    if ($row.kind -eq 'quicker') {
        $st = Resolve-QuickerStarter $row.e
        return $(if ($st) { $st } else { '<启动器未找到>' })
    }
    $p = Resolve-Locator $row.e
    return $(if ($p) { $p } else { '<路径未找到>' })
}
function Get-IfaceField($i, [string]$name) {
    if ($i.PSObject.Properties[$name]) { [string]$i.$name } else { '' }
}

# ===== 一致性体检：只读，用于发现「标了详细文档却没有接口清单 / 文档过期」 =====
if ($Check) {
    Write-Output "=== 工具文档一致性检查（只读） ==="
    $issues = 0
    foreach ($row in @(Get-Entities)) {
        $e = $row.e
        $lvl = Get-DocLevel $e
        $dp  = Get-DocPath $e
        $ifs = @(Get-Interfaces $e)
        $msgs  = @()
        $notes = @()
        $dpSafe = if ($e.PSObject.Properties['usage_page'] -and $e.usage_page) {
            Resolve-DocPath $rootDir ([string]$e.usage_page)
        } else { $null }
        if ($e.usage_page -and -not $dpSafe) { $msgs += 'usage_page 不在 tools 受管范围' }
        if ($lvl -eq 'detailed') {
            if (-not $dpSafe) { $msgs += '标为 detailed 却没有有效 usage_page' }
            elseif (-not (Test-Path -LiteralPath $dpSafe -PathType Leaf)) { $msgs += 'usage_page 指向的文件不存在' }
            # 从简原则：建档时不写接口是正常的，只有「用到时」才补，因此这里只提示不报错
            if ($ifs.Count -eq 0) { $notes += '暂无已用接口（符合从简原则，用到时再补写）' }
        }
        if ($ifs.Count -gt $WarnAbove) {
            $msgs += "接口清单 $($ifs.Count) 条 > $WarnAbove，按从简原则精简：只留用过/常用的，其余用到再补"
        }
        if ($dpSafe -and (Test-Path -LiteralPath $dpSafe -PathType Leaf)) {
            $txt = [System.IO.File]::ReadAllText($dpSafe, [System.Text.Encoding]::UTF8)
            if ($e.PSObject.Properties['version_info'] -and $e.version_info.product_version) {
                $m = [regex]::Match($txt, 'tool_version:\s*([^\s|]+)')
                if ($m.Success -and $m.Groups[1].Value -ne [string]$e.version_info.product_version) {
                    $msgs += "文档头 tool_version=$($m.Groups[1].Value) 与索引版本 $($e.version_info.product_version) 不一致"
                }
            }
            # 文档受管区块 vs 索引 interfaces：两边接口名集合应一致
            $s = $txt.IndexOf('<!-- interfaces:start -->', [System.StringComparison]::Ordinal)
            $t2 = $txt.IndexOf('<!-- interfaces:end -->', [System.StringComparison]::Ordinal)
            if ($s -ge 0 -and $t2 -gt $s) {
                $block = $txt.Substring($s, $t2 - $s)
                $docNames = @([regex]::Matches($block, '(?m)^\|\s*`([^`]+)`\s*\|') |
                              ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notlike '_*' })
                $idxNames = @($ifs | ForEach-Object { [string]$_.name })
                $diff = @($docNames | Where-Object { $_ -notin $idxNames }) +
                        @($idxNames | Where-Object { $_ -notin $docNames })
                if ($diff.Count -gt 0) {
                    $msgs += "文档接口表与索引不一致（差异: $((@($diff | Select-Object -Unique) -join ', '))）"
                }
            }
        }
        if ($msgs.Count -gt 0) {
            $issues += $msgs.Count
            Write-Output ("  ⚠️ [$($e.id)] $lvl : " + ($msgs -join ' ; '))
        } else {
            $tail = if ($dpSafe) { "文档OK | 接口 $($ifs.Count) 条" } else { '无文档（简单工具，直接调 exe）' }
            Write-Output ("  ✅ [$($e.id)] $lvl | $tail")
        }
        foreach ($n in $notes) { Write-Output ("     ℹ️ $n") }
    }
    # 软删条目仍持有文档：设计上保留（可重新激活），只提示不判错
    foreach ($e in @(@($reg.tools) + @($reg.quicker_actions))) {
        if (-not $e) { continue }
        if ($e.deleted -and $e.PSObject.Properties['usage_page'] -and $e.usage_page) {
            Write-Output ("     ℹ️ 软删条目 [$($e.id)] 仍持有文档 $($e.usage_page)（可恢复；彻底清理用 unregister.ps1 -Id $($e.id) -Hard）")
        }
    }
    # 孤儿文档：tools 根目录下没有任何条目引用的 .md
    foreach ($p in @(Get-OrphanDocs $reg $rootDir)) {
        $issues++
        Write-Output ("  ⚠️ 孤儿文档（无条目引用）: " + (Split-Path $p -Leaf) + " → 确认无用可手工删除，或 unregister.ps1 -Hard 清理对应条目")
    }
    Write-Output "汇总: 问题 $issues 项；本脚本只读，未写索引。"
    Write-Output "补接口（从简原则，用到再写）: record-interface.ps1 -Id <id> -Name <接口> -Syntax '<调用>' -Note '<一句话>'"
    Write-Output "补整份文档: update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocLevel detailed -InterfacesFile <清单.json>"
    if ($issues -gt 0) { $global:LASTEXITCODE = 1 }
    return
}

# ===== 无 Id / -List：列出全部分层状态 =====
if (-not $Id -or $List) {
    Write-Output "=== 工具文档分层清单（索引 version=$($reg.version)） ==="
    foreach ($row in @(Get-Entities)) {
        $e = $row.e; $lvl = Get-DocLevel $e; $dp = Get-DocPath $e; $ifs = @(Get-Interfaces $e)
        $state = if ($dp) {
            if (Test-Path -LiteralPath $dp -PathType Leaf) { '文档OK' } else { '文档缺失' }
        } else { '无文档' }
        Write-Output ("  [$(Get-TierLabel $e)] [$lvl] $($e.id) | $state | 接口 $($ifs.Count) 条 | $(Get-ToolLoc $row)")
    }
    Write-Output "用法: tool-doc.ps1 -Id <id> [-Full] [-InjectPrompt]；-Check 做一致性体检；本脚本只读。"
    return
}

# ===== 指定 Id =====
$row = @(Get-Entities | Where-Object { [string]$_.e.id -eq $Id })[0]
if (-not $row) { Write-Output "❌ 未找到启用中的条目: $Id"; $global:LASTEXITCODE = 1; return }
$e = $row.e
$lvl = Get-DocLevel $e
$dp  = Get-DocPath $e
$ifs = @(Get-Interfaces $e)

if ($InjectPrompt) {
    $names = @()
    foreach ($i in (@($ifs) | Select-Object -First $MaxInterfaces)) {
        $n = Get-IfaceField $i 'name'
        $d = Get-IfaceField $i 'note'
        if (-not $n) { continue }
        $names += if ($d) { "$n($d)" } else { $n }
    }
    $dig = ''
    if ($names.Count -gt 0) {
        $dig = ' | 接口: ' + ($names -join ', ')
        if ($dig.Length -gt 260) { $dig = $dig.Substring(0, 260) + '…' }
    }
    Write-Output ("- [$(Get-TierLabel $e)] **$($e.id)** ($($e.name)) [文档:$lvl]: $(@($e.functions) -join ',') | 位置: $(Get-ToolLoc $row)$dig")
    if ($lvl -eq 'detailed') {
        Write-Output "  需要完整参数、开关与坑位时再读: .\scripts\tool-doc.ps1 -Id $Id -Full"
    }
    return
}

Write-Output "=== 工具文档: $Id [$(Get-TierLabel $e)] ==="
Write-Output ("  类型 / 名称  : $(if($e.PSObject.Properties['type']){$e.type}else{'<无>'}) / $($e.name)")
Write-Output ("  文档层级     : $lvl" + $(if($lvl -eq 'none'){'（简单工具：索引直接指向可执行文件，无需文档）'}else{''}))
Write-Output ("  工具位置     : $(Get-ToolLoc $row)")
Write-Output ("  功能标签     : $(@($e.functions) -join ', ')")
if ($dp) {
    $ok = Test-Path -LiteralPath $dp -PathType Leaf
    Write-Output ("  文档路径     : $dp" + $(if($ok){'（存在）'}else{'（❌ 文件不存在）'}))
} else {
    Write-Output "  文档路径     : <无>"
}
if ($ifs.Count -gt 0) {
    Write-Output ("  接口清单     : $($ifs.Count) 条（已随检索注入，常见任务无需再读文档）")
    foreach ($i in (@($ifs) | Select-Object -First $MaxInterfaces)) {
        $line = Get-IfaceField $i 'name'
        $s = Get-IfaceField $i 'syntax'
        $d = Get-IfaceField $i 'note'
        if ($s) { $line += ' | ' + $s }
        if ($d) { $line += ' | ' + $d }
        Write-Output ("    - $line")
    }
    if ($ifs.Count -gt $MaxInterfaces) { Write-Output "    … 其余 $(($ifs.Count - $MaxInterfaces)) 条用 -MaxInterfaces 放宽" }
} else {
    Write-Output "  接口清单     : <无>" + $(if($lvl -eq 'detailed'){'（⚠️ 详细文档却没有接口清单，Agent 仍会试探）'}else{''})
}
if ($e.PSObject.Properties['example'] -and $e.example) { Write-Output ("  典型调用     : " + [string]$e.example) }
if ($e.when_to_use)     { Write-Output ("  适用         : " + $e.when_to_use) }
if ($e.when_not_to_use) { Write-Output ("  不适用       : " + $e.when_not_to_use) }
if ($e.PSObject.Properties['doc_checked_at'] -and $e.doc_checked_at) {
    Write-Output ("  文档复核时间 : " + $e.doc_checked_at)
}
if ($e.PSObject.Properties['version_info'] -and $e.version_info.product_version) {
    Write-Output ("  工具版本     : " + $e.version_info.product_version + "（升级后请复核文档接口）")
}
if ($Full) {
    if ($dp -and (Test-Path -LiteralPath $dp -PathType Leaf)) {
        Write-Output ""
        Write-Output "=== 完整说明文档: $dp ==="
        Write-Output ([System.IO.File]::ReadAllText($dp, [System.Text.Encoding]::UTF8))
    } else {
        Write-Output "（无文档可展开；简单工具直接按上面的位置调用即可）"
    }
} elseif ($lvl -ne 'none') {
    Write-Output "提示: 需要完整参数/坑位时加 -Full；本脚本只读，不修改索引。"
}
