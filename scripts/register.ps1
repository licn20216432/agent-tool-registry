# register.ps1 —— 注册普通工具 / Quicker 动作；自制脚本受归档审批门禁约束
# 分类元数据（category_path / tags / keywords）为可选字段，旧条目缺这些字段不影响任何脚本。
param(
    [string]$Path,
    [string]$Functions = "",
    [string]$WhenToUse = "",
    [string]$WhenNotToUse = "",
    [switch]$AutoAnalyze,
    [switch]$Quicker,
    [string]$ActionCode,
    [string]$Name,
    [string]$QuickerExe = "",
    [string]$ApprovedBy = "",
    [string]$ApprovalToken = "",
    [switch]$Reusable,
    [string]$Reason = "",
    [string]$Note = "",
    [string]$Tags = "",
    [string]$Keywords = "",
    [string]$CategoryPath = "",
    [ValidateRange(0,4)][int]$Tier = 0,
    [string]$UsagePage = "",
    [string]$DocLevel = "",
    [string]$InterfacesFile = ""
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$rootDir = Split-Path $PSScriptRoot -Parent
if (-not $Path -and -not $ActionCode) {
    Write-Output "用法: register.ps1 -Path <工具> -Functions a,b [-AutoAnalyze]"
    Write-Output "      register.ps1 -Quicker -ActionCode <码> -Functions a,b"
    Write-Output "  可选分类元数据: -Tags a,b -Keywords '解压,压缩' -CategoryPath 'file_operation/archive'"
    Write-Output "  可选层级 -Tier 1..4（1 编译器 / 3 已注册软件 / 4 其它；T2 系统命令不入库）；Quicker 动作默认 T3"
    Write-Output "  可选文档层 -UsagePage 'tools/x.md' -DocLevel none|brief|detailed -InterfacesFile <接口清单.json>（简单工具不传，直接指向 exe）"
    Write-Output "  自制脚本默认需用户同意：见 README「自制脚本与归档审批」"
    exit 1
}

# 元数据统一按逗号或斜杠切分；不传就保持字段缺失（检索脚本会自然忽略）
function Split-Meta([string]$s) {
    if (-not $s) { return @() }
    return @($s.Split([char[]]@(',','/')) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$tagList = @(Split-Meta $Tags)
$kwList  = @(Split-Meta $Keywords)
$catList = @(Split-Meta $CategoryPath)

# 文档层：只有复杂/接口多的工具才传，简单工具保持「索引 → exe」零开销
. (Join-Path $PSScriptRoot "lib\doc-fields.ps1")
if ($DocLevel -and -not (Test-DocLevelValue $DocLevel)) {
    Write-Output "❌ -DocLevel 只能是 none / brief / detailed"; exit 1
}
try { $ifaceList = @(Read-InterfaceList $InterfacesFile) }
catch { Write-Output ("❌ " + $_.Exception.Message); exit 1 }
$docLevelVal = if ($DocLevel) { $DocLevel }
               elseif ($ifaceList.Count -gt 0) { 'detailed' }
               elseif ($UsagePage) { 'brief' }
               else { '' }

# 文档联动：给了文档参数但文件还不存在时，自动生成「从简骨架」并把接口清单同步进受管区块。
# 简单工具（没传任何文档参数）完全不生成文件，保持「索引 → exe」零开销。
function Ensure-NewToolDoc([string]$eid, $entity, [string]$primary, [string]$up) {
    if (-not $up) { return }
    $dp = Resolve-DocPath $rootDir $up
    if (-not $dp) { Write-Output "   ⚠️ usage_page 不在受管范围，跳过文档生成: $up"; return }
    if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) {
        New-MinimalDoc $dp $entity $rootDir $primary
        Write-Output "   📄 已生成从简说明文档: $up"
    } else {
        Write-Output "   📄 沿用已有说明文档: $up"
    }
    if ($ifaceList.Count -gt 0) {
        $changed = Sync-DocInterfaceBlock $dp $ifaceList
        $tail = if ($changed) { '（已写入文档）' } else { '（文档已是最新）' }
        Write-Output "   📄 接口表已同步: $($ifaceList.Count) 条$tail"
    }
}

# 软删条目重新激活时，若新算出的 usage_page 与保留的旧页不同，旧文档不能留在 tools\ 里变孤儿。
# 与 update-tool.ps1 改页的处理保持一致：共享文档保留，其余移入 tools\_archive\ 留档（可回溯）。
function Archive-StaleUsagePage($entity, [string]$oldUsage) {
    $cur = [string]$entity.usage_page
    if (-not $oldUsage -or $oldUsage -eq $cur) { return }
    $oldFull = Resolve-DocPath $rootDir $oldUsage
    $newFull = Resolve-DocPath $rootDir $cur
    if ($oldFull -and $newFull -and ([string]$oldFull -ieq [string]$newFull)) { return }
    if (Test-DocShared $reg $oldUsage ([string]$entity.id)) {
        Write-Output "   📄 旧文档被其它条目共享，已保留: $oldUsage"
        return
    }
    $res = Remove-DocForTool $rootDir $oldUsage ([string]$entity.id) $false
    Write-Output "   📄 旧用法页已归档: $res"
}

$reg = Get-Registry
$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
# Quicker 动作属于第 3 层（系统已注册的工具类软件）；普通工具不指定 -Tier 就不写该字段
$quickerTier = if ($Tier -gt 0) { $Tier } else { 3 }

if ($Quicker -or $ActionCode) {
    # 跨设备适配：启动器默认位置从 ProgramFiles 环境变量推导，不写死盘符；找不到时仍可由 PATH 自愈
    if (-not $QuickerExe) {
        $pf = [Environment]::GetEnvironmentVariable('ProgramFiles')
        $QuickerExe = if ($pf) { Join-Path $pf 'Quicker\QuickerStarter.exe' } else { 'QuickerStarter.exe' }
    }
    if (-not $ActionCode) { Write-Output "❌ 注册 Quicker 动作必须给 -ActionCode <动作码>"; exit 1 }
    $id = "quicker-$ActionCode"
    $existing = @($reg.quicker_actions | Where-Object { [string]$_.id -eq $id })
    if ($existing.Count -gt 1) {
        Write-Output "❌ 索引里有 $($existing.Count) 条同 id 的 Quicker 动作，数据异常，请人工核对"; exit 1
    }
    if ($existing.Count -gt 0) {
        $q = $existing[0]
        if (-not $q.deleted) {
            Write-Output "⚠️ 已存在: $id（要改字段请用 update-tool.ps1 -Id $id ...，不要重复注册）"
            exit 0
        }
        # 软删过的同一动作码：原地恢复，不产生重复条目、不丢 added_at
        $oldUsageQ = [string]$q.usage_page
        $upQ = Get-NewUsagePage $UsagePage $id $ifaceList.Count $docLevelVal
        Set-ToolDeleted $q $false
        if ($Name)         { Set-RegistryField $q 'name' $Name }
        if ($Functions)    { Set-RegistryField $q 'functions' @($Functions.Split(',')) }
        if ($WhenToUse)    { Set-RegistryField $q 'when_to_use' $WhenToUse }
        if ($WhenNotToUse) { Set-RegistryField $q 'when_not_to_use' $WhenNotToUse }
        if ($tagList.Count -gt 0) { Set-RegistryField $q 'tags' $tagList }
        if ($kwList.Count  -gt 0) { Set-RegistryField $q 'keywords' $kwList }
        if ($catList.Count -gt 0) { Set-RegistryField $q 'category_path' $catList }
        # 只有显式传了 -QuickerExe 才覆盖；否则保留该动作原来的自定义启动器
        $starter = if ($PSBoundParameters.ContainsKey('QuickerExe')) { $QuickerExe }
                   elseif ($q.PSObject.Properties['starter'] -and $q.starter) { [string]$q.starter }
                   else { $QuickerExe }
        Set-RegistryField $q 'starter' $starter
        Set-RegistryField $q 'invoke_template' ("`"$starter`" -c `"runaction:$ActionCode {args}`"")
        Set-RegistryField $q 'tier' $quickerTier
        if ($upQ)                     { Set-RegistryField $q 'usage_page' $upQ }
        if ($docLevelVal)             { Set-RegistryField $q 'doc_level' $docLevelVal }
        if ($ifaceList.Count -gt 0)   { Set-RegistryField $q 'interfaces' $ifaceList }
        Set-RegistryField $q 'verified' $false
        Save-Registry $reg
        Write-Output "♻️ 已重新激活 Quicker 动作 $id (version → $($reg.version))"
        Archive-StaleUsagePage $q $oldUsageQ
        Ensure-NewToolDoc $id $q $starter $upQ
        exit 0
    }
    if (-not (Test-Path -LiteralPath $QuickerExe -PathType Leaf)) {
        Write-Output "⚠️ 启动器路径不存在: $QuickerExe（仍会登记；用 -QuickerExe 指定或用 validate-registry.ps1 定位）"
    }
    $upQ = Get-NewUsagePage $UsagePage $id $ifaceList.Count $docLevelVal
    $reg.quicker_actions = @($reg.quicker_actions) + [PSCustomObject]@{
        id=$id; name=if($Name){$Name}else{"Quicker 动作 $ActionCode"}
        type="quicker_action"; tier=$quickerTier; functions=if($Functions){@($Functions.Split(","))}else{@()}
        tags=$tagList; keywords=$kwList; category_path=$catList
        action_code=$ActionCode; starter=$QuickerExe
        invoke_template="`"$QuickerExe`" -c `"runaction:$ActionCode {args}`""
        when_to_use=$WhenToUse; when_not_to_use=$WhenNotToUse
        requires_gui=$true; verified=$false
        deleted=$false; deleted_at=$null; last_checked=$null
        added_by=$env:USERNAME; added_at=$now
    }
    $newQ = $reg.quicker_actions[-1]
    if ($upQ)                   { Add-Member -InputObject $newQ -NotePropertyName 'usage_page' -NotePropertyValue $upQ -Force }
    if ($docLevelVal)           { Add-Member -InputObject $newQ -NotePropertyName 'doc_level' -NotePropertyValue $docLevelVal -Force }
    if ($ifaceList.Count -gt 0) { Add-Member -InputObject $newQ -NotePropertyName 'interfaces' -NotePropertyValue $ifaceList -Force }
    Save-Registry $reg
    Write-Output "✅ 已注册 Quicker 动作 $id (version → $($reg.version))"
    Ensure-NewToolDoc $id $newQ $QuickerExe $upQ
    exit 0
}

$realPath = Resolve-Path -LiteralPath $Path -ErrorAction Ignore
if (-not $realPath) { Write-Output "❌ 路径不存在: $Path"; exit 1 }
$realPath = [string]$realPath
if (-not (Test-Path -LiteralPath $realPath -PathType Leaf)) { Write-Output "❌ 不是文件: $realPath"; exit 1 }
if ($reg.tools | Where-Object { [string]$_.locator.primary -eq $realPath -and -not $_.deleted }) {
    Write-Output "⚠️ 该路径已存在索引，跳过"; exit 0
}

$funcs = @()
if ($AutoAnalyze) {
    try { $help = & $realPath --help 2>&1 | Select-Object -First 30 } catch { $help = $null }
    try { if (-not $help) { $help = & $realPath -h 2>&1 | Select-Object -First 30 } } catch { $help = $null }
    $helpText = ($help | Out-String)
    if ($helpText -match "compress|extract|zip|tar|rar") { $funcs += "compress" }
    if ($helpText -match "rename|move") { $funcs += "rename" }
    if ($helpText -match "convert|transform|encode|decode") { $funcs += "convert" }
    if ($helpText -match "build|compile|make") { $funcs += "build" }
    if ($helpText -match "hash|checksum|sha") { $funcs += "hash" }
}
if ($Functions) { $funcs = @($Functions.Split(",")) }
if ($funcs.Count -eq 0) { Write-Output "❌ 无法推断功能，请用 -Functions 指定"; exit 1 }

# ===== 自制脚本归档审批门禁 =====
# 复杂/无通用复用性的脚本不能由 Agent 自行塞进索引：默认只生成待审提案，
# 必须用户明确同意后由 approve-tool.ps1 转正。二进制工具与 Quicker 动作不受影响。
$isScript = $realPath -match '\.(ps1|psm1|psd1|py|pyw|sh|bat|cmd|js|mjs|cjs|ts|vbs|rb|pl|lua|ahk|php)$'
$approval = $null
if ($isScript) {
    if ($ApprovedBy) {
        # 治理约束：-ApprovedBy 只是「记录谁同意」，不能自己证明用户同意。
        # 必须持有 approve-tool.ps1 写入 pending 队列的一次性凭证，否则一律只生成待审提案。
        . (Join-Path $PSScriptRoot "lib\pending-store.ps1")
        $credPath = Get-PendingFilePath $PSScriptRoot
        $cred = Read-Pending $credPath
        $tok = if ($ApprovalToken) { $ApprovalToken } else { $env:AGENT_TOOLS_APPROVAL_TOKEN }
        $grant = @()
        if ($tok) {
            $grant = @($cred.items | Where-Object {
                [string]$_.path -eq $realPath -and
                $_.PSObject.Properties['approval_token'] -and
                [string]$_.approval_token -ceq $tok
            })
        }
        if ($grant.Count -eq 0) {
            Write-Output "🛑 -ApprovedBy 不能单独使用：自制脚本必须先由 approve-tool.ps1 记录用户同意"
            Write-Output "   正确路径：register.ps1 生成提案 → approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'"
            $global:LASTEXITCODE = 2
            return
        }
        $approval = [PSCustomObject]@{
            mode = 'user_approved'; approved_by = $ApprovedBy; approved_at = $now
            note = $Note; reusable = $false
        }
        Write-Output "✅ 用户已同意登记（$ApprovedBy，凭证已核验），写入索引并在条目上留痕"
    } elseif ($Reusable -and $Reason) {
        $approval = [PSCustomObject]@{
            mode = 'declared_reusable'; declared_by = $env:USERNAME; declared_at = $now
            reason = $Reason; reusable = $true
        }
        Write-Output "✅ 已声明为通用可复用脚本，写入索引（复用理由已记录）"
    } else {
        . (Join-Path $PSScriptRoot "lib\pending-store.ps1")
        $pendingPath = Get-PendingFilePath $PSScriptRoot
        $p = Read-Pending $pendingPath
        $dup = @($p.items | Where-Object {
            [string]$_.path -eq $realPath -and [string]$_.status -eq 'pending_user_approval'
        })
        if ($dup.Count -gt 0) {
            $item = $dup[0]
            $propId = [string]$item.id
            Set-RegistryField $item 'functions' @($funcs)
            Set-RegistryField $item 'reason' $(if ($Note) { $Note } else { [string]$item.reason })
            Set-RegistryField $item 'proposed_at' $now
            if ($tagList.Count -gt 0) { Set-RegistryField $item 'tags' $tagList }
            if ($kwList.Count  -gt 0) { Set-RegistryField $item 'keywords' $kwList }
            if ($catList.Count -gt 0) { Set-RegistryField $item 'category_path' $catList }
            if ($Tier -gt 0)          { Set-RegistryField $item 'tier' $Tier }
            Write-Output "ℹ️ 该脚本已有待审提案，已更新（不重复建单）: $propId"
        } else {
            $propId = New-ProposalId $realPath
            $item = [PSCustomObject]@{
                id=$propId; path=$realPath; name=(Split-Path $realPath -Leaf)
                functions=@($funcs); when_to_use=$WhenToUse; when_not_to_use=$WhenNotToUse
                tags=$tagList; keywords=$kwList; category_path=$catList
                tier=$(if ($Tier -gt 0) { $Tier } else { 4 })
                classification='complex_or_nonreusable'; reusable=$false
                status='pending_user_approval'; reason=$Note
                proposed_by=$env:USERNAME; proposed_at=$now; source='register.ps1'
            }
            $p.items = @($p.items) + $item
        }
        Save-Pending $pendingPath $p
        Write-Output "🛑 自制脚本未获用户同意，未写入 registry.json（索引 version 不变）"
        Write-Output "   提案: $propId → $pendingPath"
        Write-Output "   请用户明确同意后执行："
        Write-Output "     .\scripts\approve-tool.ps1 -List"
        Write-Output "     .\scripts\approve-tool.ps1 -Id $propId -ApprovedBy '<用户标识>'"
        Write-Output "   通用、可参数化复用的脚本可改走 -Reusable -Reason '<复用场景>'"
        # 用 return 而非 exit：拦截是正常路径，不能终止调用方所在的 PowerShell 会话
        $global:LASTEXITCODE = 2
        return
    }
}

# 软删过的同一路径重新注册：原地重新激活，复用 id / added_at，不生成 xxx-2 重复条目。
# 放在审批门禁之后，脚本仍然必须先拿到用户同意才能走到这里。
$restored = Restore-SoftDeletedTool $reg $realPath
if ($restored) {
    $oldUsageR = [string]$restored.usage_page
    Set-RegistryField $restored 'name' (Split-Path $realPath -Leaf)
    Set-RegistryField $restored 'functions' @($funcs)
    if ($WhenToUse)    { Set-RegistryField $restored 'when_to_use' $WhenToUse }
    if ($WhenNotToUse) { Set-RegistryField $restored 'when_not_to_use' $WhenNotToUse }
    if ($tagList.Count -gt 0) { Set-RegistryField $restored 'tags' $tagList }
    if ($kwList.Count  -gt 0) { Set-RegistryField $restored 'keywords' $kwList }
    if ($catList.Count -gt 0) { Set-RegistryField $restored 'category_path' $catList }
    if ($Tier -gt 0)          { Set-RegistryField $restored 'tier' $Tier }
    if ($docLevelVal)         { Set-RegistryField $restored 'doc_level' $docLevelVal }
    if ($ifaceList.Count -gt 0) { Set-RegistryField $restored 'interfaces' $ifaceList }
    if ($approval)            { Set-RegistryField $restored 'approval' $approval }
    $upR = Get-NewUsagePage $UsagePage ([string]$restored.id) $ifaceList.Count $docLevelVal
    if ($upR) { Set-RegistryField $restored 'usage_page' $upR }
    Save-Registry $reg
    Write-Output "♻️ 已重新激活: $(Split-Path $realPath -Leaf) (ID: $($restored.id)，version → $($reg.version))"
    Archive-StaleUsagePage $restored $oldUsageR
    Ensure-NewToolDoc ([string]$restored.id) $restored $realPath $upR
    exit 0
}

$baseId = [System.IO.Path]::GetFileNameWithoutExtension($realPath).ToLower()
$newId = New-UniqueToolId $baseId $reg
$upT = Get-NewUsagePage $UsagePage $newId $ifaceList.Count $docLevelVal
$entry = [PSCustomObject]@{
    id=$newId
    name=Split-Path $realPath -Leaf
    type=if($isScript){"script"}else{"binary"}
    functions=@($funcs); platform=@("windows")
    tags=$tagList; keywords=$kwList; category_path=$catList
    locator=[PSCustomObject]@{
        primary=$realPath
        fallback=[PSCustomObject]@{ registry=$null; common_paths=@(); search_path_env=$true }
    }
    example=""; when_to_use=$WhenToUse; when_not_to_use=$WhenNotToUse
    verified=$false; deleted=$false; deleted_at=$null; last_checked=$null
    added_by=$env:USERNAME; added_at=$now; usage_page=$(if($upT){$upT}else{$null})
}
# 自制脚本默认归 T4（其它工具与脚本）；二进制工具不指定 -Tier 时留空，不臆测层级
$entryTier = if ($Tier -gt 0) { $Tier } elseif ($isScript) { 4 } else { 0 }
if ($entryTier -gt 0) { Add-Member -InputObject $entry -NotePropertyName 'tier' -NotePropertyValue $entryTier -Force }
if ($approval) { Add-Member -InputObject $entry -NotePropertyName 'approval' -NotePropertyValue $approval -Force }
# 简单工具不写文档字段（doc_level/interfaces 缺省，索引直接指向 exe，零开销）
if ($docLevelVal)           { Add-Member -InputObject $entry -NotePropertyName 'doc_level' -NotePropertyValue $docLevelVal -Force }
if ($ifaceList.Count -gt 0) { Add-Member -InputObject $entry -NotePropertyName 'interfaces' -NotePropertyValue $ifaceList -Force }
$reg.tools += $entry
Save-Registry $reg
Write-Output "✅ 已注册: $(Split-Path $realPath -Leaf) (ID: $newId)"
Write-Output "   功能: $($funcs -join ', ')  | version → $($reg.version)"
if ($tagList.Count -gt 0 -or $kwList.Count -gt 0 -or $catList.Count -gt 0) {
    Write-Output "   分类: $($catList -join ' > ') | 标签: $($tagList -join ', ') | 关键词: $($kwList -join ', ')"
}
Ensure-NewToolDoc $newId $entry $realPath $upT
