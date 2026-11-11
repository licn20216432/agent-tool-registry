# doc-lifecycle.ps1 —— 工具说明文档的生命周期公共库（由 register / update-tool / unregister / record-interface dot-source）
# 职责：索引与 tools\*.md 联动；从简骨架生成；受管接口表同步；删除时归档/清除文档；孤儿文档检测。
# 安全边界：只处理 tools 目录内的 .md，拒绝越界路径、模板文件与共享文档，避免误删用户文件。

$DocStartMark = '<!-- interfaces:start -->'
$DocEndMark   = '<!-- interfaces:end -->'

# usage_page → 绝对路径。返回 $null 表示「空 / 不安全 / 不是受管文档」，调用方应跳过而不是猜测路径。
function Resolve-DocPath($RootDir, [string]$UsagePage) {
    if (-not $UsagePage) { return $null }
    $p = ([string]$UsagePage).Replace('/', '\').Trim()
    if ([System.IO.Path]::IsPathRooted($p)) { return $null }
    if ($p -notmatch '^tools\\') { return $null }
    if ($p -match '\.\.') { return $null }
    if ($p -notmatch '\.md$') { return $null }
    $leaf = Split-Path $p -Leaf
    if ($leaf.StartsWith('_')) { return $null }          # _template*.md / _archive 下的模板不参与删除
    if ($p -match '\\_archive\\') { return $null }
    $full = [System.IO.Path]::GetFullPath((Join-Path $RootDir $p))
    $toolsDir = [System.IO.Path]::GetFullPath((Join-Path $RootDir 'tools'))
    if (-not $full.StartsWith($toolsDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

# 归一化注册/更新时传入的 usage_page：只给文件名自动补 tools\；缺 .md 自动补后缀
function Normalize-UsagePage([string]$raw, [string]$id) {
    if (-not $raw) { return '' }
    $p = ([string]$raw).Replace('/', '\').Trim()
    # 越界路径绝不静默改写成 tools\<leaf>：用户以为写的是 A，索引里却变成 B
    if ([System.IO.Path]::IsPathRooted($p) -or $p -match '\.\.' -or
        ($p -match '\\' -and $p -notmatch '^tools\\')) {
        Write-Warning "usage_page 必须是 tools\ 下的 .md 文件，已忽略: $raw"
        return ''
    }
    if ($p -notmatch '\\') { $p = 'tools\' + $p }
    if ($p -notmatch '\.md$') { $p = $p + '.md' }
    return ($p -replace '\\', '/')
}

# 没有显式给用法页、但确实需要文档时（有接口清单 / 指定 detailed）自动生成 tools\<id>.md
function Get-NewUsagePage([string]$raw, [string]$id, [int]$ifaceCount, [string]$docLevel) {
    if ($raw) { return (Normalize-UsagePage $raw $id) }
    if ($ifaceCount -gt 0 -or $docLevel -eq 'detailed') { return "tools/$id.md" }
    return ''
}

# 该文档是否还被「其它条目」引用（含软删条目）。共享文档绝不删除。
function Test-DocShared($Reg, [string]$UsagePage, [string]$SelfId) {
    if (-not $UsagePage) { return $false }
    $u = ([string]$UsagePage).Replace('/', '\').ToLower()
    foreach ($t in @(@($Reg.tools) + @($Reg.quicker_actions))) {
        if (-not $t) { continue }
        if ($SelfId -and [string]$t.id -eq $SelfId) { continue }
        if ($t.PSObject.Properties['usage_page'] -and $t.usage_page) {
            if (([string]$t.usage_page).Replace('/', '\').ToLower() -eq $u) { return $true }
        }
    }
    return $false
}

function Get-ReferencedUsagePages($Reg) {
    $set = @{}
    foreach ($t in @(@($Reg.tools) + @($Reg.quicker_actions))) {
        if (-not $t) { continue }
        if ($t.PSObject.Properties['usage_page'] -and $t.usage_page) {
            $set[([string]$t.usage_page).Replace('/', '\').ToLower()] = $true
        }
    }
    return $set
}

# tools 根目录下没有任何条目引用的 .md（排除模板与 _archive）
function Get-OrphanDocs($Reg, $RootDir) {
    $ref = Get-ReferencedUsagePages $Reg
    $out = @()
    $toolsDir = Join-Path $RootDir 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir -PathType Container)) { return $out }
    # -Recurse：Resolve-DocPath 允许 tools\sub\x.md，检测范围必须一致，且用相对路径做 key
    foreach ($f in @(Get-ChildItem -LiteralPath $toolsDir -Filter '*.md' -File -Recurse)) {
        if ($f.Name.StartsWith('_')) { continue }
        $relFull = $f.FullName.Substring($toolsDir.Length).TrimStart('\','/')
        $segs = @($relFull -split '[\\/]' | Where-Object { $_ })
        if (@($segs | Where-Object { $_.StartsWith('_') }).Count -gt 0) { continue }
        $rel = ('tools\' + ($relFull -replace '/', '\')).ToLower()
        if (-not $ref.ContainsKey($rel)) { $out += $f.FullName }
    }
    return $out
}

function Format-DocInterfaceRow($i) {
    $name   = if ($i.PSObject.Properties['name'])   { [string]$i.name }   else { '' }
    $syntax = if ($i.PSObject.Properties['syntax']) { [string]$i.syntax } else { '' }
    $note   = if ($i.PSObject.Properties['note'])   { [string]$i.note }   else { '' }
    # 表格里的竖线必须转义，否则 Markdown 表格会被撑坏
    $esc = { param($s) ([string]$s).Replace('|', '\|').Replace("`r", '').Replace("`n", ' ') }
    return ('| `' + (& $esc $name) + '` | `' + (& $esc $syntax) + '` | ' + (& $esc $note) + ' |')
}

function Get-DocInterfaceBlock($interfaces) {
    $lines = @($DocStartMark, '', '| 接口 | 调用语法 | 说明 |', '|---|---|---|')
    foreach ($i in @($interfaces)) {
        if (-not $i) { continue }
        $lines += (Format-DocInterfaceRow $i)
    }
    if (@($interfaces).Count -eq 0) { $lines += '| _（暂无已用接口）_ | | 用到时再补 |' }
    $lines += @('', $DocEndMark)
    return ($lines -join "`n")
}

# 从简骨架：只写基本信息、位置、已用接口、典型调用；未用过的接口不预先罗列参数与开关。
function New-MinimalDoc($DocPath, $Entity, $RootDir, [string]$Primary) {
    $bom = [System.Text.UTF8Encoding]::new($true)
    $now = (Get-Date).ToString('yyyy-MM-dd')
    $ver = ''
    if ($Entity.PSObject.Properties['version_info'] -and $Entity.version_info.product_version) {
        $ver = [string]$Entity.version_info.product_version
    }
    $id   = if ($Entity.PSObject.Properties['id'])   { [string]$Entity.id }   else { '' }
    $name = if ($Entity.PSObject.Properties['name']) { [string]$Entity.name } else { $id }
    $fn   = if ($Entity.PSObject.Properties['functions']) { (@($Entity.functions) -join ', ') } else { '' }
    $wtu  = if ($Entity.PSObject.Properties['when_to_use'] -and $Entity.when_to_use) { [string]$Entity.when_to_use } else { '待补（真正用到时再写）' }
    $ex   = if ($Entity.PSObject.Properties['example'] -and $Entity.example) { [string]$Entity.example } else { '待补（真正用到时再写）' }
    $ifs  = if ($Entity.PSObject.Properties['interfaces']) { @($Entity.interfaces) } else { @() }
    $lvl  = if ($Entity.PSObject.Properties['doc_level'] -and $Entity.doc_level) { [string]$Entity.doc_level } else { 'brief' }
    $txt = @"
# $name 说明文档（从简）

<!-- doc_version: 1 | tool_version: $ver | checked_at: $now | doc_level: $lvl -->
<!-- 从简原则：只写实际用过或常用的接口；没用过的不要预先详细说明，用到时再补 -->
<!-- tool-doc.ps1 -Check 会核对 tool_version 与索引 version_info.product_version -->

## 基本信息
- id / 名称：``$id`` / ``$name``
- 位置：``$Primary``
- 功能标签：$fn
- 适用：$wtu

## 接口清单（受管区块，由脚本同步，不要手改）
$(Get-DocInterfaceBlock $ifs)
> 未用过的接口不要预先写详细参数与开关。任务真正用到时执行
> ``.\scripts\record-interface.ps1 -Id $id -Name <接口> -Syntax '<调用>' -Note '<一句话>' [-Task '<任务>']``，
> 索引 ``interfaces`` 与本节会一起更新。

## 典型调用
``````powershell
$ex
``````

## 坑 / 备注
- 用到时再补，不要预先罗列全部参数、开关与退出码。

## 版本复核
- 升级后：``validate-registry.ps1 -Apply`` → ``tool-doc.ps1 -Check`` → ``update-tool.ps1 -Id $id -DocChecked``
"@
    $dir = Split-Path $DocPath -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [System.IO.File]::WriteAllText($DocPath, $txt + "`n", $bom)
}

# 把索引里的 interfaces 同步进文档：有受管标记则整块替换；老文档无标记则追加一节，不破坏原文。
function Sync-DocInterfaceBlock($DocPath, $interfaces) {
    if (-not $DocPath -or -not (Test-Path -LiteralPath $DocPath -PathType Leaf)) { return $false }
    $txt  = [System.IO.File]::ReadAllText($DocPath, [System.Text.Encoding]::UTF8)
    $bom  = [System.Text.UTF8Encoding]::new($true)
    $blk  = Get-DocInterfaceBlock $interfaces
    # 用位置切片替换，避免正则 replacement 把接口语法里的 $ 当成分组引用
    $start = $txt.IndexOf($DocStartMark, [System.StringComparison]::Ordinal)
    $end   = $txt.IndexOf($DocEndMark,   [System.StringComparison]::Ordinal)
    if ($start -ge 0 -and $end -gt $start) {
        $end += $DocEndMark.Length
        $new = $txt.Substring(0, $start) + $blk + $txt.Substring($end)
    } else {
        $section = "`n## 接口清单（受管区块，由脚本同步，不要手改）`n" + $blk +
                   "`n> 只记录已用过 / 常用的接口；用到新接口时用 record-interface.ps1 补写。`n"
        $new = $txt.TrimEnd() + "`n" + $section
    }
    if ($new -eq $txt) { return $false }
    [System.IO.File]::WriteAllText($DocPath, $new, $bom)
    return $true
}

# 复核头刷新：-DocChecked 时把 tool_version / checked_at 与索引对齐
function Update-DocHeader($DocPath, $Entity) {
    if (-not $DocPath -or -not (Test-Path -LiteralPath $DocPath -PathType Leaf)) { return $false }
    $txt = [System.IO.File]::ReadAllText($DocPath, [System.Text.Encoding]::UTF8)
    $ver = ''
    if ($Entity.PSObject.Properties['version_info'] -and $Entity.version_info.product_version) {
        $ver = [string]$Entity.version_info.product_version
    }
    $date = (Get-Date).ToString('yyyy-MM-dd')
    $new = $txt
    # replacement 里的 $ 会被 .NET 当成替换组引用，产品版本号含 $ 时必须先转义
    if ($ver) { $new = [regex]::Replace($new, '(tool_version:\s*)([^\s|]+)', '${1}' + $ver.Replace('$', '$$')) }
    $new = [regex]::Replace($new, '(checked_at:\s*)([^\s|]+)', '${1}' + $date)
    if ($new -eq $txt) { return $false }
    [System.IO.File]::WriteAllText($DocPath, $new, [System.Text.UTF8Encoding]::new($true))
    return $true
}

# 删除工具时处置说明文档。默认移入 tools\_archive 留档（可回溯），-Purge 才彻底删除。
function Remove-DocForTool($RootDir, [string]$UsagePage, [string]$Id, [bool]$Purge) {
    $p = Resolve-DocPath $RootDir $UsagePage
    if (-not $p) { return '文档不在受管范围（或为空），跳过' }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return '文档不存在，无需处理' }
    if ($Purge) {
        [System.IO.File]::Delete($p)
        return "已彻底删除文档: $UsagePage"
    }
    $archive = Join-Path $RootDir 'tools\_archive'
    if (-not (Test-Path -LiteralPath $archive -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($archive) | Out-Null
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = Join-Path $archive ("$Id-$stamp.md")
    $n = 2
    while (Test-Path -LiteralPath $dest) { $dest = Join-Path $archive ("$Id-$stamp-$n.md"); $n++ }
    [System.IO.File]::Move($p, $dest)
    return "已移出 tools 并归档: $UsagePage → tools\_archive\$(Split-Path $dest -Leaf)"
}
