# update-tool.ps1 —— 原地更新已注册条目（普通工具 / Quicker 动作）
# register 只新增；本脚本保留 id、added_at、version 历史，不产生重复条目。
# 两类实体共用本入口：tools 改 locator.primary，quicker_actions 改 action_code / starter。
# 分类元数据 category_path / tags / keywords 为可选字段，缺字段的旧条目也能平滑补上。
param(
    [Parameter(Mandatory=$true)][string]$Id,
    [string]$Path,
    [string]$Functions,
    [string]$WhenToUse,
    [string]$WhenNotToUse,
    [string]$Example,
    [string]$UsagePage,
    [string]$CommonPaths,
    [string]$Name,
    [string]$ActionCode,
    [string]$InvokeTemplate,
    [string]$Tags,
    [string]$Keywords,
    [string]$CategoryPath,
    [ValidateRange(0,4)][int]$Tier = 0,
    [string]$DocLevel = "",
    [string]$InterfacesFile = "",
    [switch]$DocChecked,
    [switch]$AddTags,
    [switch]$RefreshVersion,
    [switch]$Show
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-fields.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$rootDir = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

# 元数据按逗号或斜杠切分（CategoryPath 常用 file_operation/archive 写法）
function Split-Meta([string]$s) {
    if (-not $s) { return @() }
    return @($s.Split([char[]]@(',','/')) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$reg = Get-Registry
$inTools   = @($reg.tools           | Where-Object { [string]$_.id -eq $Id -and -not $_.deleted })
$inQuicker = @($reg.quicker_actions | Where-Object { [string]$_.id -eq $Id -and -not $_.deleted })
if ($inTools.Count -gt 0 -and $inQuicker.Count -gt 0) {
    Write-Output "❌ id '$Id' 同时存在于 tools 与 quicker_actions，索引数据异常，请人工核对"
    exit 1
}
$kind  = if ($inQuicker.Count -gt 0) { 'quicker' } else { 'tool' }
$found = if ($kind -eq 'quicker') { $inQuicker } else { $inTools }
if ($found.Count -eq 0) {
    Write-Output "❌ 未找到启用中的条目: $Id（软删除的条目请用 unregister.ps1 -Hard 清理，或用 register.ps1 -Quicker 重新激活）"
    exit 1
}
if ($found.Count -gt 1) { Write-Output "❌ id 重复($($found.Count))，索引数据异常，请先人工核对"; exit 1 }
$t = $found[0]

# 采样可执行文件版本指纹：产品版本 + 大小 + 修改时间
function Get-FileFingerprint([string]$file) {
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $f = Get-Item -LiteralPath $file
    $pv = $f.VersionInfo.ProductVersion
    $ver = if ($pv) { ([string]$pv).Trim() } else { $null }
    return [PSCustomObject]@{
        product_version = $ver
        file_size       = [long]$f.Length
        modified        = $f.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
        checked_at      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    }
}

$primary = if ($kind -eq 'quicker') { [string]$t.starter } else { [string]$t.locator.primary }

if ($Show) {
    Write-Output "=== $Id 当前记录（$(if($kind -eq 'quicker'){'Quicker 动作'}else{'普通工具'})） ==="
    Write-Output ("  name            : " + $t.name)
    Write-Output ("  functions       : " + (@($t.functions) -join ', '))
    Write-Output ("  tier            : " + $(if ($t.PSObject.Properties['tier']) { 'T' + $t.tier } else { '<无（检索时排在同分条目之后）>' }))
    Write-Output ("  category_path   : " + $(if ($t.PSObject.Properties['category_path']) { @($t.category_path) -join ' > ' } else { '<无>' }))
    Write-Output ("  tags            : " + $(if ($t.PSObject.Properties['tags']) { @($t.tags) -join ', ' } else { '<无>' }))
    Write-Output ("  keywords        : " + $(if ($t.PSObject.Properties['keywords']) { @($t.keywords) -join ', ' } else { '<无>' }))
    if ($kind -eq 'quicker') {
        Write-Output ("  action_code     : " + $t.action_code)
        Write-Output ("  starter         : " + $t.starter)
        Write-Output ("  invoke_template : " + $t.invoke_template)
        Write-Output ("  requires_gui    : " + $t.requires_gui)
        $st = Resolve-QuickerStarter $t
        Write-Output ("  启动器可用      : " + $(if($st){$st}else{'<否>'}))
    } else {
        Write-Output ("  primary         : " + $t.locator.primary)
        Write-Output ("  common_paths    : " + (@($t.locator.fallback.common_paths) -join ', '))
    }
    Write-Output ("  verified        : " + $t.verified + " | last_checked: " + $(if($t.last_checked){$t.last_checked}else{'<null>'}))
    Write-Output ("  deleted         : " + $t.deleted)
    Write-Output ("  usage_page      : " + $(if($t.PSObject.Properties['usage_page'] -and $t.usage_page){$t.usage_page}else{'<null>'}))
    $dl = if ($t.PSObject.Properties['doc_level'] -and $t.doc_level) { $t.doc_level }
          elseif ($t.PSObject.Properties['usage_page'] -and $t.usage_page) { 'brief（老条目推断）' }
          else { 'none（简单工具，直接调 exe）' }
    Write-Output ("  doc_level       : " + $dl)
    $ic = if ($t.PSObject.Properties['interfaces']) { @($t.interfaces).Count } else { 0 }
    Write-Output ("  interfaces      : " + $ic + " 条结构化接口")
    if ($t.PSObject.Properties['doc_checked_at'] -and $t.doc_checked_at) {
        Write-Output ("  doc_checked_at  : " + $t.doc_checked_at)
    }
    if ($t.PSObject.Properties['usage_page'] -and $t.usage_page) {
        $dp = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$t.usage_page)
        Write-Output ("  文档文件存在    : " + $(if (Test-Path -LiteralPath $dp -PathType Leaf) { '是' } else { '❌ 否' }))
    }
    Write-Output ("  when_to_use     : " + $t.when_to_use)
    $old = $t.PSObject.Properties['version_info']
    if ($old) { Write-Output ("  索引版本指纹    : " + ($t.version_info | ConvertTo-Json -Compress)) }
    else { Write-Output "  索引版本指纹    : <无（旧条目）>" }
    $fp = Get-FileFingerprint $primary
    if ($fp) {
        Write-Output ("  磁盘当前指纹    : " + ($fp | ConvertTo-Json -Compress))
        if ($old -and $t.version_info.product_version -and $fp.product_version -and
            [string]$fp.product_version -ne [string]$t.version_info.product_version) {
            Write-Output ("  🔄 版本已变化   : " + $t.version_info.product_version + " → " + $fp.product_version)
        }
    } else { Write-Output "  磁盘当前指纹    : <文件不存在>" }
    exit 0
}

$changes = @()
$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$oldUsagePage = ''
$ifaceChanged = $false

# 1) 主路径变更
#    tools: -Path 是工具文件；quicker_actions: -Path 视作启动器 QuickerStarter.exe
if ($Path) {
    $rp = Resolve-Path -LiteralPath $Path -ErrorAction Ignore
    if (-not $rp) { Write-Output "❌ 路径不存在: $Path"; exit 1 }
    $newPath = [string]$rp
    if (-not (Test-Path -LiteralPath $newPath -PathType Leaf)) { Write-Output "❌ 不是文件: $newPath"; exit 1 }
    if ([string]$primary -ne $newPath) {
        if ($kind -eq 'quicker') {
            $oldStarter = [string]$t.starter
            Set-RegistryField $t 'starter' $newPath
            if ($t.invoke_template -and $oldStarter -and ([string]$t.invoke_template).Contains($oldStarter)) {
                Set-RegistryField $t 'invoke_template' ([string]$t.invoke_template).Replace($oldStarter, $newPath)
                $changes += "invoke_template 同步替换启动器路径"
            }
            $changes += "starter → $newPath"
        } else {
            Set-RegistryField $t.locator 'primary' $newPath
            $changes += "primary → $newPath"
            $leaf = Split-Path $newPath -Leaf
            if ([string]$t.name -ne $leaf) { Set-RegistryField $t 'name' $leaf; $changes += "name → $leaf" }
        }
        $primary = $newPath
        $RefreshVersion = $true
    }
}

# 1b) 显示名
if ($Name -and [string]$t.name -ne $Name) {
    Set-RegistryField $t 'name' $Name
    $changes += "name → $Name"
}

# 1c) Quicker 动作码：改码时同步 id 与 invoke_template，避免 id 与码脱节
if ($ActionCode) {
    if ($kind -ne 'quicker') { Write-Output "❌ -ActionCode 只适用于 Quicker 动作"; exit 1 }
    $newId = "quicker-$ActionCode"
    if ($newId -ne [string]$t.id) {
        if (@($reg.quicker_actions | Where-Object { [string]$_.id -eq $newId }).Count -gt 0) {
            Write-Output "❌ 目标 id 已被占用: $newId"; exit 1
        }
        $oldCode = [string]$t.action_code
        $tpl = [string]$t.invoke_template
        if ($tpl -and $oldCode) { $tpl = $tpl.Replace($oldCode, $ActionCode) }
        else { $tpl = "`"$($t.starter)`" -c `"runaction:$ActionCode {args}`"" }
        Set-RegistryField $t 'action_code' $ActionCode
        Set-RegistryField $t 'invoke_template' $tpl
        Set-RegistryField $t 'id' $newId
        $changes += "action_code → $ActionCode（id → $newId，invoke_template 已同步）"
    }
}
if ($InvokeTemplate) {
    if ($kind -ne 'quicker') { Write-Output "❌ -InvokeTemplate 只适用于 Quicker 动作"; exit 1 }
    if ([string]$t.invoke_template -ne $InvokeTemplate) {
        Set-RegistryField $t 'invoke_template' $InvokeTemplate
        $changes += "invoke_template 已更新"
    }
}

# 2) 通用字段：功能标签 / 说明 / 示例 / 用法页
if ($Functions) {
    $funcs = @($Functions.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($funcs -join ',') -ne (@($t.functions) -join ',')) {
        Set-RegistryField $t 'functions' $funcs
        $changes += "functions → $($funcs -join ',')"
    }
}
foreach ($pair in @(
    [PSCustomObject]@{ N='WhenToUse';    V=$WhenToUse },
    [PSCustomObject]@{ N='WhenNotToUse'; V=$WhenNotToUse },
    [PSCustomObject]@{ N='Example';      V=$Example },
    [PSCustomObject]@{ N='UsagePage';    V=$UsagePage }
)) {
    $field = switch ($pair.N) {
        'WhenToUse'    {'when_to_use'}
        'WhenNotToUse' {'when_not_to_use'}
        'Example'      {'example'}
        'UsagePage'    {'usage_page'}
    }
    if ($pair.V) {
        # usage_page 统一归一化成 tools\<id>.md 形式，避免索引里出现裸文件名导致文档定位失败
        $val = if ($field -eq 'usage_page') { Normalize-UsagePage $pair.V $Id } else { [string]$pair.V }
        # 归一化拒绝越界路径时返回空，不能拿它把原有 usage_page 清空
        if ($field -eq 'usage_page' -and -not $val) { continue }
        $curRaw = if ($t.PSObject.Properties[$field]) { [string]$t.$field } else { '' }
        # 旧值也归一化再比较：tools\bz.md 与 tools/bz.md 是同一个文件，不能误判成「换文档」
        $cur = if ($field -eq 'usage_page' -and $curRaw) { Normalize-UsagePage $curRaw $Id } else { $curRaw }
        if ($cur -ne $val) {
            if ($field -eq 'usage_page') { $oldUsagePage = $cur }
            Set-RegistryField $t $field $val
            $changes += "$field → $val"
        }
    }
}

# 2a) 分类元数据：用 Set-RegistryField 安全补字段（PS 5.1 的 ConvertFrom-Json 对象属性是固定的）
#     -AddTags 对 tags / keywords 走追加去重；category_path 总是覆盖。
if ($Tags) {
    $list = @(Split-Meta $Tags)
    $cur  = if ($t.PSObject.Properties['tags']) { @($t.tags) } else { @() }
    # 追加时保持原有顺序，只补真正的新项；排序去重会重排旧标签造成无谓 version bump
    $new  = if ($AddTags) { @($cur + @($list | Where-Object { $_ -notin $cur })) } else { $list }
    if (($new -join '|') -ne ($cur -join '|')) {
        Set-RegistryField $t 'tags' $new
        $changes += "tags → $($new -join ',')"
    }
}
if ($Keywords) {
    $list = @(Split-Meta $Keywords)
    $cur  = if ($t.PSObject.Properties['keywords']) { @($t.keywords) } else { @() }
    # 同 tags：追加保持顺序，不重排旧关键词
    $new  = if ($AddTags) { @($cur + @($list | Where-Object { $_ -notin $cur })) } else { $list }
    if (($new -join '|') -ne ($cur -join '|')) {
        Set-RegistryField $t 'keywords' $new
        $changes += "keywords → $($new -join ',')"
    }
}
if ($CategoryPath) {
    $list = @(Split-Meta $CategoryPath)
    $cur  = if ($t.PSObject.Properties['category_path']) { @($t.category_path) } else { @() }
    if (($list -join '|') -ne ($cur -join '|')) {
        Set-RegistryField $t 'category_path' $list
        $changes += "category_path → $($list -join ' > ')"
    }
}

# 2a-2) 层级：1 编译器 / 3 已注册软件 / 4 其它；T2 系统命令不入库，故不设 2
if ($Tier -gt 0) {
    $curTier = if ($t.PSObject.Properties['tier']) { [int]$t.tier } else { 0 }
    if ($curTier -ne $Tier) {
        Set-RegistryField $t 'tier' $Tier
        $changes += "tier → T$Tier"
    }
}

# 2a-3) 文档层：doc_level / interfaces / doc_checked_at（可选字段，缺省不影响任何旧脚本）
if ($DocLevel) {
    if (-not (Test-DocLevelValue $DocLevel)) { Write-Output "❌ -DocLevel 只能是 none / brief / detailed"; exit 1 }
    $cur = if ($t.PSObject.Properties['doc_level']) { [string]$t.doc_level } else { '' }
    if ($cur -ne $DocLevel) {
        Set-RegistryField $t 'doc_level' $DocLevel
        $changes += "doc_level → $DocLevel"
    }
}
$docCheckedChanged = $false
if ($InterfacesFile) {
    try { $list = @(Read-InterfaceList $InterfacesFile) }
    catch { Write-Output ("❌ " + $_.Exception.Message); exit 1 }
    $cur = if ($t.PSObject.Properties['interfaces'] -and $t.interfaces) { @($t.interfaces) } else { @() }
    $fpCur = Get-InterfaceFingerprint $cur   # 必须在改动 $cur 对象之前缓存
    # 以清单为准合并：同名接口复用原对象，保留 used_count / last_used / added_from_task
    $merged = @()
    foreach ($i in $list) {
        $old = @($cur | Where-Object {
            $_ -and $_.PSObject.Properties['name'] -and [string]$_.name -ceq [string]$i.name
        })
        if ($old.Count -gt 0) {
            $o = $old[0]
            Set-RegistryField $o 'syntax' $i.syntax
            Set-RegistryField $o 'note' $i.note
            $merged += $o
        } else { $merged += $i }
    }
    # 从简原则：任务里补写过的接口是「实际用过」的知识，同步清单时不能静默抹掉
    $kept = 0
    foreach ($o in $cur) {
        if (-not $o -or -not $o.PSObject.Properties['name']) { continue }
        $inList = @($list | Where-Object { [string]$_.name -ceq [string]$o.name }).Count -gt 0
        if (-not $inList -and $o.PSObject.Properties['used_count']) { $merged += $o; $kept++ }
    }
    if ((Get-InterfaceFingerprint $merged) -ne $fpCur) {
        Set-RegistryField $t 'interfaces' $merged
        $ifaceChanged = $true
        $keepNote = if ($kept -gt 0) { "（保留 $kept 条已用接口）" } else { '' }
        $changes += "interfaces → $($merged.Count) 条$keepNote"
    }
    if (-not $DocLevel -and $list.Count -gt 0) {
        $curLvl = if ($t.PSObject.Properties['doc_level']) { [string]$t.doc_level } else { '' }
        # 显式 doc_level=none 是用户「不要文档」的意图，不自动升级
        if (-not $curLvl) {
            Set-RegistryField $t 'doc_level' 'detailed'
            $changes += "doc_level → detailed（有接口清单，自动升级文档层级）"
        }
    }
}
if ($DocChecked) {
    $curChecked = if ($t.PSObject.Properties['doc_checked_at']) { [string]$t.doc_checked_at } else { '' }
    # 幂等：已经复核过、且这次没有接口/版本变更时，不重复写盘涨 version
    $needCheck = (-not $curChecked) -or $ifaceChanged -or $fpChanged
    if ($needCheck -and $curChecked -ne $now) {
        Set-RegistryField $t 'doc_checked_at' $now
        $changes += "doc_checked_at → $now"
        $docCheckedChanged = $true
    }
}

# 2b) 备用路径：tools → fallback.common_paths；quicker → starter_fallback
if ($CommonPaths) {
    $cp = @($CommonPaths.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($kind -eq 'quicker') {
        $cur = if ($t.PSObject.Properties['starter_fallback']) { @($t.starter_fallback) } else { @() }
        if (($cp -join '|') -ne ($cur -join '|')) {
            Set-RegistryField $t 'starter_fallback' $cp
            $changes += "starter_fallback → $($cp.Count) 条"
        }
    } else {
        if (($cp -join '|') -ne (@($t.locator.fallback.common_paths) -join '|')) {
            Set-RegistryField $t.locator.fallback 'common_paths' $cp
            $changes += "fallback.common_paths → $($cp.Count) 条"
        }
    }
}

# 3) 版本指纹采样：只有指纹真的变了才写，避免无谓 version bump
$fp = Get-FileFingerprint $primary
$fpOld = if ($t.PSObject.Properties['version_info']) { $t.version_info } else { $null }
if ($fp -and ($RefreshVersion -or -not $fpOld)) {
    $fpChanged = (-not $fpOld) -or
                 ([string]$fpOld.product_version -ne [string]$fp.product_version) -or
                 ([long]$fpOld.file_size -ne [long]$fp.file_size) -or
                 ([string]$fpOld.modified -ne [string]$fp.modified)
    if ($fpChanged) {
        Set-RegistryField $t 'version_info' $fp
        $changes += "version_info → $($fp.product_version) ($($fp.file_size) 字节)"
    }
}

# 4) 只在确有变更、或需要首次验证时顺带刷新 verified / last_checked
#    （否则重复执行同一命令会白白 version +1）
if ($changes.Count -gt 0 -or ($fp -and -not $t.verified)) {
    if ($fp) {
        if (-not $t.verified) { $changes += "verified → true" }
        Set-RegistryField $t 'verified' $true
        Set-RegistryField $t 'last_checked' $now
    } else {
        if ($t.verified) { $changes += "verified → false（当前路径不可用）" }
        Set-RegistryField $t 'verified' $false
    }
}

if ($changes.Count -eq 0) { Write-Output "无变更，索引未改动"; exit 0 }
Save-Registry $reg
Write-Output "✅ 已原地更新 $($t.id)（version → $($reg.version)）"
foreach ($c in $changes) { Write-Output "   - $c" }

# ===== 说明文档联动 =====
# 1) 目标文档不存在 → 补建从简骨架；2) 接口清单变了 → 同步受管表格；
# 3) -DocChecked → 刷新复核头；4) 用法页换掉 → 旧文档移入 _archive（共享文档不动）。
$finalUsage = if ($t.PSObject.Properties['usage_page'] -and $t.usage_page) { [string]$t.usage_page } else { '' }
$finalLvl   = if ($t.PSObject.Properties['doc_level'] -and $t.doc_level) { [string]$t.doc_level } else { 'brief' }
$dp = Resolve-DocPath $rootDir $finalUsage
if ($finalUsage -and $dp -and $finalLvl -ne 'none') {
    if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) {
        New-MinimalDoc $dp $t $rootDir $primary
        Write-Output "   📄 已补建从简说明文档: $finalUsage"
    }
    if ($ifaceChanged -and (Test-Path -LiteralPath $dp -PathType Leaf)) {
        $c = Sync-DocInterfaceBlock $dp @($t.interfaces)
        $tail = if ($c) { '（已写入文档）' } else { '（文档已是最新）' }
        Write-Output "   📄 接口表已同步: $(@($t.interfaces).Count) 条$tail"
    }
    if ($docCheckedChanged -and (Test-Path -LiteralPath $dp -PathType Leaf)) {
        $null = Update-DocHeader $dp $t
        Write-Output "   📄 复核头已刷新（tool_version / checked_at）"
    }
}
$oldFull = Resolve-DocPath $rootDir $oldUsagePage
$sameFile = ($dp -and $oldFull -and ([string]$oldFull -ieq [string]$dp))
if ($oldUsagePage -and ($oldUsagePage -ne $finalUsage) -and -not $sameFile) {
    if (Test-DocShared $reg $oldUsagePage ([string]$t.id)) {
        Write-Output "   📄 旧文档被其它条目共享，已保留: $oldUsagePage"
    } else {
        $res = Remove-DocForTool $rootDir $oldUsagePage ([string]$t.id) $false
        Write-Output "   📄 旧用法页已归档: $res"
    }
}
Write-Output "[Registry] 操作: 更新 | 工具: $($t.id) | 变更: $($changes.Count) 项 | version: $($reg.version)"
