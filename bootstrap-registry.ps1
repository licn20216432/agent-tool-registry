# bootstrap-registry.ps1  —— 在任意目录生成 agent-tool-registry v3.1 完整包
# 用法: .\bootstrap-registry.ps1 -Root <目标目录>
#   不传 -Root 时默认生成到脚本所在目录下的 generated\ 子目录，不会覆盖仓库自身。
#   检测到目标已有 registry.json 时拒绝运行，避免误跑清空全部注册记录。
param(
    [string]$Root = "",
    [switch]$Force
)
if (-not $Root) { $Root = Join-Path $PSScriptRoot 'generated' }
$Root = [System.IO.Path]::GetFullPath($Root)
if ((Test-Path -LiteralPath (Join-Path $Root "registry.json") -PathType Leaf) -and -not $Force) {
    Write-Output "⛔ 目标已存在索引文件，已拒绝运行：$Root\registry.json"
    Write-Output "   确需重建请先备份整个目录，再加 -Force；或换一个 -Root 目录。"
    exit 1
}
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$dirs = @("scripts\lib","scripts\rename","tools","tools\_archive","tools\_notes","examples","pending")
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }

function Write-File($rel, $cnt) {
    $full = Join-Path $Root $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    # .ps1/.md 需要 BOM（PowerShell 5.1 中文不乱码）；所有 .json 必须无 BOM（严格 JSON 解析）
    $enc = if ($rel -like '*.json') { [System.Text.UTF8Encoding]::new($false) }
           else { [System.Text.UTF8Encoding]::new($true) }
    [System.IO.File]::WriteAllText($full, $cnt, $enc)
}





# ============ registry.json ============
Write-File "registry.json" @'
{
  "$schema": "agent-registry-v3.1",
  "version": 1,
  "last_updated": "2026-11-09T00:00:00",
  "last_writer": "bootstrap",
  "conflict_resolution": "version-bump + lazy-reload",
  "system_builtins_policy": "direct-use, not indexed",
  "tools": [],
  "quicker_actions": [],
  "rules": {
    "local_first": true,
    "batch_first": true,
    "gui_fallback_only": true,
    "atomic_scripts_only": true,
    "plan_before_execute": ">=3 steps",
    "archive_approval_required": true,
    "system_builtins_priority": true
  }
}
'@
# ============ scripts/lib/registry-core.ps1 ============
Write-File "scripts/lib/registry-core.ps1" @'
# registry-core.ps1 —— 索引读写核心
# 由各脚本 dot-source 引入（非 .psm1 模块），函数自动进入调用者作用域，无需 Export-ModuleMember。

# AGENT_REGISTRY 指向的文件即使还不存在也要保留用户意图，不能用 Resolve-Path 失败就悄悄换路径
$script:RegistryPath = if ($env:AGENT_REGISTRY) {
    [System.IO.Path]::GetFullPath([string]$env:AGENT_REGISTRY)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\registry.json"))
}
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# 硬删除意图（仅本进程有效）：Save-Registry 在锁内合并「他人新增」时必须跳过这些 id，
# 否则刚从内存移除的条目会被磁盘上的旧快照重新捡回来，硬删看似成功实则没删掉。
$script:RemovedIds = @{}
function Mark-RegistryRemoval([string]$collection, [string]$id) {
    if (-not $script:RemovedIds) { $script:RemovedIds = @{} }
    $script:RemovedIds["$($collection):$id"] = $true
}

function Get-Registry {
    param([switch]$Raw)
    if (-not (Test-Path -LiteralPath $script:RegistryPath -PathType Leaf)) {
        throw "索引文件不存在: $($script:RegistryPath)"
    }
    # .NET 读取会自动剥离 BOM，兼容旧版带 BOM 的索引
    $txt = [System.IO.File]::ReadAllText($script:RegistryPath, [System.Text.Encoding]::UTF8)
    if ($Raw) { return $txt }
    $reg = $txt | ConvertFrom-Json
    # 顶层缺字段一律用 Add-Member 补：对 ConvertFrom-Json 对象直接赋值新属性会静默失败
    foreach ($f in @('quicker_actions','tools','last_updated')) {
        if (-not ($reg.PSObject.Properties.Name -contains $f)) {
            $initVal = if ($f -eq 'last_updated') { $null } else { @() }
            Add-Member -InputObject $reg -NotePropertyName $f -NotePropertyValue $initVal -Force
        }
    }
    if ($null -eq $reg.quicker_actions) { Set-RegistryField $reg 'quicker_actions' @() }
    if ($null -eq $reg.tools)           { Set-RegistryField $reg 'tools' @() }
    # 兼容旧索引：补齐字段，保证上层脚本可以直接赋值而不会抛「找不到属性」
    # 用 PSCustomObject 数组，避免 PowerShell 把嵌套 @() 展平
    $schemaFields = @(
        [PSCustomObject]@{ Name = 'deleted';      Value = $false }
        [PSCustomObject]@{ Name = 'deleted_at';   Value = $null }
        [PSCustomObject]@{ Name = 'last_checked'; Value = $null }
        [PSCustomObject]@{ Name = 'verified';     Value = $false }
    )
    # Quicker 动作与 tools 是两类实体：字段不同，但共享同一套生命周期语义
    $quickerFields = @(
        [PSCustomObject]@{ Name = 'deleted';         Value = $false }
        [PSCustomObject]@{ Name = 'deleted_at';      Value = $null }
        [PSCustomObject]@{ Name = 'last_checked';    Value = $null }
        [PSCustomObject]@{ Name = 'verified';        Value = $false }
        [PSCustomObject]@{ Name = 'requires_gui';    Value = $true }
        [PSCustomObject]@{ Name = 'when_to_use';     Value = '' }
        [PSCustomObject]@{ Name = 'when_not_to_use'; Value = '' }
        [PSCustomObject]@{ Name = 'functions';       Value = @() }
    )
    foreach ($t in @($reg.tools)) {
        foreach ($fld in $schemaFields) {
            if (-not ($t.PSObject.Properties.Name -contains $fld.Name)) {
                Add-Member -InputObject $t -NotePropertyName $fld.Name -NotePropertyValue $fld.Value -Force
            }
        }
    }
    foreach ($q in @($reg.quicker_actions)) {
        foreach ($fld in $quickerFields) {
            if (-not ($q.PSObject.Properties.Name -contains $fld.Name)) {
                Add-Member -InputObject $q -NotePropertyName $fld.Name -NotePropertyValue $fld.Value -Force
            }
        }
    }
    return $reg
}

# 安全赋值：属性不存在时先补，避免对 ConvertFrom-Json 对象直接赋值新属性报错
function Set-RegistryField($obj, [string]$name, $value) {
    if ($null -eq $obj) { return }
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { Add-Member -InputObject $obj -NotePropertyName $name -NotePropertyValue $value -Force }
}

function Set-ToolDeleted($tool, [bool]$deleted) {
    Set-RegistryField $tool 'deleted' $deleted
    if ($deleted) { Set-RegistryField $tool 'deleted_at' (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
    else { Set-RegistryField $tool 'deleted_at' $null }
}

# 软删过的同一路径重新出现时，复用原条目（保留 id / added_at），不要生成 xxx-2 重复条目。
# 返回被重新激活的条目；没有唯一匹配时返回 $null，由调用方按「新条目」处理。
function Restore-SoftDeletedTool($reg, [string]$path) {
    if (-not $path) { return $null }
    $soft = @($reg.tools | Where-Object {
        $_.deleted -and [string]$_.locator.primary -eq $path
    })
    if ($soft.Count -ne 1) { return $null }
    $t = $soft[0]
    Set-ToolDeleted $t $false
    Set-RegistryField $t 'verified' $false
    Set-RegistryField $t 'last_checked' $null
    return $t
}

# id 唯一化：同名 exe 出现在多个目录时自动追加 -2 / -3
function New-UniqueToolId([string]$baseId, $reg) {
    $used = @{}
    foreach ($t in @($reg.tools)) { $used[[string]$t.id] = $true }
    if (-not $used.ContainsKey($baseId)) { return $baseId }
    $i = 2
    while ($used.ContainsKey("$baseId-$i")) { $i++ }
    return "$baseId-$i"
}

function Save-Registry($data) {
    $baseVersion = [int]$data.version
    $removed = @{}
    if ($script:RemovedIds) { $removed = $script:RemovedIds }
    $mtx = $null; $owned = $false; $tmp = $null
    try {
        try {
            $mtx = [System.Threading.Mutex]::new($false, 'Local\AgentToolsRegistry_v31')
            try { $owned = $mtx.WaitOne(5000) }
            catch [System.Threading.AbandonedMutexException] { $owned = $true }
        } catch {
            $mtx = $null; $owned = $true
            Write-Warning '索引写锁不可用，已降级为无锁写入（并发时可能丢失变更）'
        }
        if (-not $owned) { throw "索引正被其他进程写入（等待 5 秒仍被占用），请稍后重试" }

        # 关键：version bump 与「读-改-写」必须整体在锁内。
        # 两个进程各拿旧快照时，后写者要把先写者新增的条目合并回来，否则整条工具会丢。
        $diskVersion = $baseVersion
        if (Test-Path -LiteralPath $script:RegistryPath -PathType Leaf) {
            try {
                $diskTxt = [System.IO.File]::ReadAllText($script:RegistryPath, [System.Text.Encoding]::UTF8)
                $disk = $diskTxt | ConvertFrom-Json
                if ($disk -and $disk.PSObject.Properties['version']) {
                    $diskVersion = [Math]::Max($diskVersion, [int]$disk.version)
                }
                foreach ($pair in @(
                    [PSCustomObject]@{ Name = 'tools';           Items = @($disk.tools) }
                    [PSCustomObject]@{ Name = 'quicker_actions'; Items = @($disk.quicker_actions) }
                )) {
                    $mine = @($data.($pair.Name))
                    $ids = @{}
                    foreach ($x in $mine) {
                        if ($x -and $x.PSObject.Properties['id']) { $ids[[string]$x.id] = $true }
                    }
                    $extra = @()
                    foreach ($x in $pair.Items) {
                        if (-not $x -or -not $x.PSObject.Properties['id']) { continue }
                        $xid = [string]$x.id
                        $key = "$($pair.Name):$xid"
                        # 只合并「他人新增」；本进程主动硬删的 id 绝不能从磁盘捡回来
                        if (-not $ids.ContainsKey($xid) -and -not $removed.ContainsKey($key)) { $extra += $x }
                    }
                    if ($extra.Count -gt 0) {
                        Set-RegistryField $data ($pair.Name) @($mine + $extra)
                    }
                }
            } catch {
                Write-Warning ("锁内重读磁盘索引失败，按内存快照写入: " + $_.Exception.Message)
            }
        }

        Set-RegistryField $data 'version'      ($diskVersion + 1)
        Set-RegistryField $data 'last_updated' (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Set-RegistryField $data 'last_writer'  $env:USERNAME
        $json = $data | ConvertTo-Json -Depth 10

        # 唯一 tmp + 原子替换：避免多进程互踩同一个 .tmp，也避免 Copy 覆盖写到一半留下半截 JSON
        $tmp = "$($script:RegistryPath).$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
        if (Test-Path -LiteralPath $script:RegistryPath -PathType Leaf) {
            try { [System.IO.File]::Replace($tmp, $script:RegistryPath, $null) }
            catch {
                [System.IO.File]::Copy($tmp, $script:RegistryPath, $true)
                [System.IO.File]::Delete($tmp)
            }
        } else {
            [System.IO.File]::Copy($tmp, $script:RegistryPath, $true)
            [System.IO.File]::Delete($tmp)
        }
        $tmp = $null

        # 镜像同步也放在临界区内，避免释放锁后读到另一个进程写到一半的 JSON
        $sync = Join-Path $PSScriptRoot "..\registry-sync.ps1"
        if (Test-Path -LiteralPath $sync) {
            try { & $sync -ToMarkdown }
            catch { Write-Warning ("registry.md 同步失败: " + $_.Exception.Message) }
        }
    } finally {
        $script:RemovedIds = @{}   # 一次性意图，不能影响同进程后续写入
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch {}
        }
        if ($mtx) {
            if ($owned) { try { $mtx.ReleaseMutex() } catch {} }
            try { $mtx.Dispose() } catch {}
        }
    }
}

function Resolve-Locator($tool) {
    if (-not $tool -or -not $tool.locator) { return $null }
    $loc = $tool.locator
    $leaf = if ($loc.primary) { Split-Path $loc.primary -Leaf } else { $null }
    if ($loc.primary -and (Test-Path -LiteralPath $loc.primary -PathType Leaf)) { return [string]$loc.primary }

    if ($loc.fallback.registry) {
        $rp = [string]$loc.fallback.registry
        $rp = $rp -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\'
        if (Test-Path -LiteralPath $rp) {
            $r = Get-ItemProperty -LiteralPath $rp -ErrorAction Ignore
            $v = if ($r) { $r.'(default)' } else { $null }
            if (-not $v -and $r -and $r.PSObject.Properties.Name -contains 'Path') { $v = $r.Path }
            if ($v) {
                # 注册表值可能是安装目录，需要拼上可执行文件名再判断
                $cand = if (Test-Path -LiteralPath $v -PathType Container) { Join-Path $v $leaf } else { [string]$v }
                if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { return [string]$cand }
            }
        }
    }
    foreach ($p in @($loc.fallback.common_paths)) {
        if (-not $p) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$p)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) { return [string]$expanded }
    }
    if ($loc.fallback.search_path_env -and $leaf) {
        $cmd = Get-Command $leaf -ErrorAction Ignore |
               Where-Object { $_.CommandType -eq 'Application' -and $_.Source } |
               Select-Object -First 1
        if ($cmd -and $cmd.Source) {
            # 排除 WindowsApps 里的 0 字节应用执行别名
            $item = Get-Item -LiteralPath $cmd.Source -ErrorAction Ignore
            if ($item -and -not $item.PSIsContainer -and $item.Length -gt 0) { return [string]$cmd.Source }
        }
    }
    return $null
}

# Quicker 动作没有 locator，能否调用取决于启动器 QuickerStarter.exe。
# 返回实际可用路径；找不到返回 $null（validate 只报告，绝不自动删 GUI 兜底动作）。
function Resolve-QuickerStarter($action) {
    if (-not $action) { return $null }
    $cands = @()
    if ($action.starter) { $cands += [Environment]::ExpandEnvironmentVariables([string]$action.starter) }
    if ($action.PSObject.Properties['starter_fallback']) {
        foreach ($p in @($action.starter_fallback)) {
            if ($p) { $cands += [Environment]::ExpandEnvironmentVariables([string]$p) }
        }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return [string]$c }
    }
    # Quicker 换了安装目录时靠 PATH 自愈
    $cmd = Get-Command 'QuickerStarter.exe' -ErrorAction Ignore |
           Where-Object { $_.CommandType -eq 'Application' -and $_.Source } |
           Select-Object -First 1
    if ($cmd -and $cmd.Source) {
        $item = Get-Item -LiteralPath $cmd.Source -ErrorAction Ignore
        if ($item -and -not $item.PSIsContainer -and $item.Length -gt 0) { return [string]$cmd.Source }
    }
    return $null
}
'@
# ============ scripts/register.ps1 ============
Write-File "scripts/register.ps1" @'
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
'@
# ============ scripts/unregister.ps1 ============
Write-File "scripts/unregister.ps1" @'
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
'@
# ============ scripts/validate-registry.ps1 ============
Write-File "scripts/validate-registry.ps1" @'
param([switch]$Apply)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
$reg = Get-Registry

$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$updated = $false; $missing = @(); $neverVerified = @(); $relocated = @(); $okList = @(); $upgraded = @(); $checked = 0
$qChecked = 0; $qOk = @(); $qMissing = @(); $qRelocated = @(); $qUpgraded = @(); $qBadCode = @()

foreach ($t in @($reg.tools)) {
    if ($t.deleted) { continue }
    $checked++
    $resolved = Resolve-Locator $t
    # last_checked 不在这里单独改：否则纯体检也会写盘涨 version。
    # 统一在确有其它变更、准备 Save-Registry 时一并刷新（见文件末尾）。

    # 软件升级检测：索引记录过版本指纹时，对比磁盘上的当前文件
    $fpOld = if ($t.PSObject.Properties['version_info']) { $t.version_info } else { $null }
    if ($resolved -and $fpOld -and $fpOld.product_version) {
        $fi = Get-Item -LiteralPath $resolved -ErrorAction Ignore
        if ($fi) {
            $curVer = if ($fi.VersionInfo.ProductVersion) { ([string]$fi.VersionInfo.ProductVersion).Trim() } else { $null }
            $curSize = [long]$fi.Length
            $curMod = $fi.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
            $why = $null
            if ($curVer -and [string]$curVer -ne [string]$fpOld.product_version) {
                $why = "版本 $($fpOld.product_version) → $curVer"
            } elseif ($curSize -ne [long]$fpOld.file_size -or [string]$curMod -ne [string]$fpOld.modified) {
                $why = "版本未变但文件已更新（$curSize 字节 / $curMod）"
            }
            if ($why) {
                $upgraded += "$($t.id): $why"
                if ($Apply) {
                    $newFp = [PSCustomObject]@{
                        product_version = $curVer
                        file_size       = $curSize
                        modified        = $curMod
                        checked_at      = $now
                    }
                    Set-RegistryField $t 'version_info' $newFp
                    $updated = $true
                }
            }
        }
    }

    if (-not $resolved) {
        # 从未验证通过的工具（如未安装的 7-Zip）只报告，绝不自动软删除
        if ($t.verified -eq $true) {
            $missing += $t.id
            if ($Apply) { Set-ToolDeleted $t $true; $updated = $true }
        } else {
            $neverVerified += $t.id
        }
    } elseif ([string]$resolved -ne [string]$t.locator.primary) {
        $relocated += "$($t.id) → $resolved"
        if ($Apply) {
            Set-RegistryField $t.locator 'primary' ([string]$resolved)
            $updated = $true
        }
    } else {
        $okList += $t.id
    }
}

# ===== Quicker 动作体检 =====
# GUI 兜底动作没有文件路径可删：启动器失效只报告，绝不自动软删除
foreach ($q in @($reg.quicker_actions)) {
    if ($q.deleted) { continue }
    $qChecked++
    $resolved = Resolve-QuickerStarter $q

    # 动作码与调用模板必须一致，否则 runaction 会打到一个不存在的码
    $codeOk = $q.action_code -and $q.invoke_template -and
              ([string]$q.invoke_template).Contains([string]$q.action_code)
    if (-not $codeOk) { $qBadCode += "$($q.id)（码=$($q.action_code)）" }

    # Quicker 主程序升级检测（启动器文件的版本指纹）
    $fpOld = if ($q.PSObject.Properties['version_info']) { $q.version_info } else { $null }
    if ($resolved -and $fpOld -and $fpOld.product_version) {
        $fi = Get-Item -LiteralPath $resolved -ErrorAction Ignore
        if ($fi) {
            $curVer = if ($fi.VersionInfo.ProductVersion) { ([string]$fi.VersionInfo.ProductVersion).Trim() } else { $null }
            $curSize = [long]$fi.Length
            $curMod  = $fi.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
            $why = $null
            if ($curVer -and [string]$curVer -ne [string]$fpOld.product_version) {
                $why = "Quicker $($fpOld.product_version) → $curVer"
            } elseif ($curSize -ne [long]$fpOld.file_size -or [string]$curMod -ne [string]$fpOld.modified) {
                $why = "Quicker 版本未变但启动器已更新（$curSize 字节）"
            }
            if ($why) {
                $qUpgraded += "$($q.id): $why"
                if ($Apply) {
                    Set-RegistryField $q 'version_info' ([PSCustomObject]@{
                        product_version = $curVer; file_size = $curSize
                        modified = $curMod; checked_at = $now
                    })
                    $updated = $true
                }
            }
        }
    }

    if (-not $resolved) {
        # 启动器失效只报告：翻转 verified 会让「体检 → 写盘 → 恢复 → 再写盘」反复 version bump
        $qMissing += "$($q.id)（starter=$($q.starter)）"
    } elseif ([string]$resolved -ne [string]$q.starter) {
        $qRelocated += "$($q.id) → $resolved"
        if ($Apply) { Set-RegistryField $q 'starter' $resolved; $updated = $true }
    } else {
        $qOk += $q.id
        if ($Apply -and $q.verified -ne $true) { Set-RegistryField $q 'verified' $true; $updated = $true }
    }
}

Write-Output "=== 索引校验：启用工具 $checked 个 / Quicker 动作 $qChecked 个 ==="
if ($okList.Count -gt 0) { Write-Output "✅ 路径有效: $($okList -join ', ')" }
if ($relocated.Count -gt 0) { Write-Output "🔧 路径可修正: $($relocated -join '; ')" }
if ($upgraded.Count -gt 0) { Write-Output "🔄 软件已更新: $($upgraded -join '; ')" }
if ($missing.Count -gt 0) { Write-Output "⚠️ 已验证工具路径失效: $($missing -join ', ')" }
if ($neverVerified.Count -gt 0) { Write-Output "ℹ️ 尚未验证/未安装（不自动删除）: $($neverVerified -join ', ')" }

Write-Output "--- Quicker 动作 ---"
if ($qChecked -eq 0) { Write-Output "（未注册启用中的 Quicker 动作）" }
if ($qOk.Count -gt 0) { Write-Output "✅ 启动器有效: $($qOk -join ', ')" }
if ($qRelocated.Count -gt 0) { Write-Output "🔧 启动器可修正: $($qRelocated -join '; ')" }
if ($qUpgraded.Count -gt 0) { Write-Output "🔄 Quicker 已升级: $($qUpgraded -join '; ')" }
if ($qBadCode.Count -gt 0) { Write-Output "⚠️ 动作码与调用模板不一致: $($qBadCode -join '; ')" }
if ($qMissing.Count -gt 0) { Write-Output "⚠️ 启动器不可用（GUI 动作只报告，不自动删除）: $($qMissing -join '; ')" }

if (-not $Apply) {
    Write-Output "--- 仅检查，未写入索引。确认无误后加 -Apply 才会落盘 ---"
    Write-Output "    用法: .\scripts\validate-registry.ps1 -Apply"
    if ($upgraded.Count -gt 0) { Write-Output "    软件更新时 -Apply 会自动刷新版本指纹（也可手动跑 update-tool.ps1 -Id <id> -RefreshVersion）" }
} else {
    if ($updated) {
        # 体检时间随真正的变更一起落盘，不单独制造一次 version bump
        foreach ($t in @($reg.tools | Where-Object { -not $_.deleted })) {
            Set-RegistryField $t 'last_checked' $now
        }
        foreach ($q in @($reg.quicker_actions | Where-Object { -not $_.deleted })) {
            Set-RegistryField $q 'last_checked' $now
        }
        Save-Registry $reg
        Write-Output "--- 已写入索引 → version $($reg.version) ---"
    } else {
        Write-Output "--- 无需变更，索引未改动 ---"
    }
}
'@
# ============ scripts/registry-sync.ps1 ============
Write-File "scripts/registry-sync.ps1" @'
param([switch]$ToMarkdown)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
$reg = Get-Registry
# 镜像必须跟着 AGENT_REGISTRY 走：json 在别的目录时，md 也要写到同一个目录
$RootDir = Split-Path ([string]$script:RegistryPath) -Parent
if ($ToMarkdown) {
    $md = "# Agent Tool Registry (人读镜像)`n`n> 自动生成，勿手写。版本 v$($reg.version)`n`n## 工具`n`n| ID | 名称 | 类型 | 功能 | 路径 | 状态 |`n|---|---|---|---|---|---|`n"
    foreach ($t in @($reg.tools)) {
        $st = if ($t.deleted) { "已删" } elseif ($t.verified) { "已验" } else { "待验" }
        $md += "| $($t.id) | $($t.name) | $($t.type) | $($t.functions -join '/') | ``$($t.locator.primary)`` | $st |`n"
    }
    $md += "`n## Quicker 动作（GUI 兜底）`n`n| ID | 名称 | 码 | 功能 | 调用 | 状态 |`n|---|---|---|---|---|---|`n"
    foreach ($q in @($reg.quicker_actions)) {
        $st = if ($q.deleted) { "已删" } elseif ($q.verified) { "已验" } else { "待验" }
        $md += "| $($q.id) | $($q.name) | $($q.action_code) | $($q.functions -join '/') | ``$($q.invoke_template)`` | $st |`n"
    }
    $md += "`n## 系统自带命令（不入库，优先直用）`n- certutil(Get-FileHash) 哈希 / fc,comp 对比 / robocopy 同步 / ren 重命名 / Get-ChildItem 遍历`n"
    # .md 按项目编码约定带 BOM（PowerShell 5.1 读中文不乱码）；.json 才必须无 BOM
    [System.IO.File]::WriteAllText((Join-Path $RootDir "registry.md"), $md, [System.Text.UTF8Encoding]::new($true))
    Write-Output "已同步 registry.md"
}
'@
# ============ scripts/route_task.ps1 ============
Write-File "scripts/route_task.ps1" @'
param([string]$Task)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
if (-not $Task) { Write-Output "用法: route_task.ps1 -Task '<描述>'"; exit 1 }
$reg = Get-Registry
Write-Output "=== 路由: $Task ==="
# 值用数组：同一任务可能对应多个功能标签。
# 编译类必须同时查 build 与 compile —— 扫描器给 gcc/g++/javac/go/rustc 打的是 compile，
# 而 dotnet 打的是 build，只查 build 会漏掉绝大多数编译器。
$map = @{
    "解压|解压缩|extract"=@("extract"); "压缩|打包|compress"=@("compress")
    "编译|compile|build"=@("build","compile"); "重命名|rename"=@("rename")
    "转换|convert|编码|转码"=@("convert"); "哈希|校验|hash"=@("hash")
    "截图|screen"=@("screenshot"); "键鼠|鼠标|键盘|模拟"=@("automation")
    "浏览器|网页|browser"=@("browser")
}
# 同一功能可能对应多个工具，全部保留（值用数组）
function Add-Candidate($table, $entity) {
    foreach ($f in @($entity.functions)) {
        if (-not $f) { continue }
        if (-not $table.ContainsKey($f)) { $table[$f] = @() }
        $table[$f] = @($table[$f]) + $entity
    }
}
$all  = @{}
$qAll = @{}
foreach ($t in @($reg.tools))           { if (-not $t.deleted) { Add-Candidate $all  $t } }
foreach ($q in @($reg.quicker_actions)) { if (-not $q.deleted) { Add-Candidate $qAll $q } }

foreach ($pat in $map.Keys) {
    if ($Task -match $pat) {
        $fns = @($map[$pat])
        $cands = @(); $qCands = @(); $seen = @{}; $qSeen = @{}
        foreach ($fn in $fns) {
            if ($all.ContainsKey($fn)) {
                foreach ($t in @($all[$fn])) {
                    $key = [string]$t.id
                    if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $cands += $t }
                }
            }
            if ($qAll.ContainsKey($fn)) {
                foreach ($q in @($qAll[$fn])) {
                    $key = [string]$q.id
                    if (-not $qSeen.ContainsKey($key)) { $qSeen[$key] = $true; $qCands += $q }
                }
            }
        }
        $label = $fns -join '/'
        if ($cands.Count -eq 0 -and $qCands.Count -eq 0) {
            Write-Output "[$label] → 索引无，先看系统命令/需注册"
        } else {
            foreach ($t in $cands) {
                $resolved = Resolve-Locator $t
                if ($resolved) { Write-Output "[$label] → $($t.id) $($t.name) ($resolved)" }
                else { Write-Output "[$label] → $($t.id) $($t.name) [路径未找到，跑 validate-registry.ps1 检查]" }
            }
            # GUI 兜底排在普通工具之后，符合 gui_fallback_only 原则
            foreach ($q in $qCands) {
                $st = Resolve-QuickerStarter $q
                if ($st) { Write-Output "[$label] → $($q.id) $($q.name) [GUI 兜底 · 动作码 $($q.action_code)]" }
                else { Write-Output "[$label] → $($q.id) $($q.name) [GUI 兜底 · 启动器未找到]" }
            }
        }
    }
}
# 显式查 Quicker：列出全部启用动作（不看功能标签）
if ($Task -match "Quicker|动作码|动作") {
    $qs = @($reg.quicker_actions | Where-Object { -not $_.deleted })
    if ($qs.Count -eq 0) { Write-Output "[quicker] → 索引无动作" }
    else {
        foreach ($q in $qs) {
            $st = Resolve-QuickerStarter $q
            Write-Output "[quicker] → $($q.id) ($($q.name) / $($q.action_code)) $(if($st){'启动器可用'}else{'启动器未找到'})"
        }
    }
}
Write-Output "建议：先出计划，GUI 步骤排最后。"
'@
# ============ scripts/route_task_v2.ps1 ============
Write-File "scripts/route_task_v2.ps1" @'
# route_task_v2.ps1 —— 检索前置路由（只读，永不写索引）
# 与 route_task.ps1 并存：旧脚本按 functions 硬匹配列出全部候选；v2 用分类元数据打分、取 TopN。
# 渐进式迁移：先并行跑两者对比效果，确认后再把 Init Prompt 的默认入口切到 v2。
# 覆盖两类实体：tools（按 locator 定位）与 quicker_actions（GUI 兜底，永远排在普通工具之后）。
param(
    [Parameter(Mandatory=$true)][string]$Task,
    [int]$TopN = 5,
    [switch]$InjectPrompt,
    [switch]$All
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\doc-lifecycle.ps1")
$ErrorActionPreference = 'Stop'
$reg = Get-Registry
$taskLower = $Task.ToLower()

# ===== 第一层：用户描述 → 标签（纯字符串匹配，不走 LLM，毫秒级）=====
# 编译类必须同时给 build 与 compile：扫描器给 gcc/g++/javac 打 compile，dotnet 打 build。
$keywordToTag = @{
    '解压|解压缩|extract|unzip|zip|rar|7z|压缩|打包|归档' = @('compress','extract','archive','zip','7z','rar')
    '编译|compile|build|gcc|g\+\+|make|cmake|链接|link'   = @('compile','build','c','cpp','gcc','link')
    'git|版本|提交|commit|推送|push|克隆|clone|分支'       = @('git','vcs','version_control','diff')
    '重命名|rename|批量改名'                              = @('rename','file_operation')
    '截图|screen|screenshot|capture'                      = @('screenshot','capture','gui')
    '键鼠|mouse|keyboard|点击|输入|模拟'                  = @('automation','mouse','keyboard')
    '浏览器|网页|browser|selenium|chrome'                 = @('browser','web','selenium')
    '哈希|hash|校验|checksum|md5|sha'                     = @('hash','checksum')
    '同步|sync|backup|备份|robocopy'                      = @('sync','backup','copy')
    '搜索|search|find|grep|目录遍历'                      = @('search','find','list')
    '转换|convert|编码|转码'                              = @('convert')
    '测试|test|校验压缩包'                                = @('test','archive')
}
$matchedTags = @()
foreach ($pat in $keywordToTag.Keys) {
    if ($taskLower -match $pat) { $matchedTags += $keywordToTag[$pat] }
}
$matchedTags = @($matchedTags | Sort-Object -Unique)

# ===== 收集两类实体（软删除的排除）=====
$entities = @()
foreach ($t in @($reg.tools           | Where-Object { -not $_.deleted })) { $entities += [PSCustomObject]@{ e=$t; kind='tool' } }
foreach ($q in @($reg.quicker_actions | Where-Object { -not $_.deleted })) { $entities += [PSCustomObject]@{ e=$q; kind='quicker' } }

# tier（1 编译器 / 3 已注册软件 / 4 其它）只作同分时的次级排序：
# 任务相关性由分数主导，不能让不相关的编译器压过真正匹配的压缩工具。缺字段记作 9（排最后）。
function Get-Tier($e) {
    # tier 为 null 时 [int]$null 会变 0（排到最前），必须显式判空
    if ($e.PSObject.Properties['tier'] -and $e.tier) { [int]$e.tier } else { 9 }
}
function Get-TierLabel($row) {
    if ($row.tier -lt 9) { "T$($row.tier)" } else { 'T-' }
}

# ===== 第二层：打分（functions 3 / tags 2 / keywords 1 / category_path 1）=====
# 没有匹配标签、或 -All、或打分后一个都没命中 → 回退全量，绝不返回空清单让人误判「没工具」。
function Get-Score($e, [string[]]$tags) {
    $s = 0
    foreach ($fn in @($e.functions)) { if ($fn -in $tags) { $s += 3 } }
    if ($e.PSObject.Properties['tags']) {
        foreach ($tag in @($e.tags)) { if ($tag -in $tags) { $s += 2 } }
    }
    if ($e.PSObject.Properties['keywords']) {
        foreach ($kw in @($e.keywords)) {
            if ($kw -and $taskLower -match [regex]::Escape([string]$kw)) { $s += 1 }
        }
    }
    # init-discovery 写的是 "file_operation/archive" 单串，手工登记写的是 ["file_operation","archive"]；
    # 两边都要能拿到分类分，统一按分隔符拆段再比较
    if ($e.PSObject.Properties['category_path'] -and $e.category_path) {
        foreach ($c in @($e.category_path)) {
            if (-not $c) { continue }
            foreach ($one in @(([string]$c) -split '[\\/,]' | Select-Object -Unique)) {
                if ($one -and $one -in $tags) { $s += 1 }
            }
        }
    }
    return $s
}

$scored = @()
foreach ($x in $entities) {
    $s = if ($matchedTags.Count -eq 0) { 0 } else { Get-Score $x.e $matchedTags }
    if ($All -or $matchedTags.Count -eq 0 -or $s -gt 0) {
        $scored += [PSCustomObject]@{ e=$x.e; kind=$x.kind; score=$s; tier=(Get-Tier $x.e) }
    }
}
$fallback = ($All -or $matchedTags.Count -eq 0 -or $scored.Count -eq 0)
if ($fallback -and $scored.Count -eq 0) {
    foreach ($x in $entities) { $scored += [PSCustomObject]@{ e=$x.e; kind=$x.kind; score=0; tier=(Get-Tier $x.e) } }
}

# 普通工具与 GUI 动作分开排序：Quicker 永远排在普通工具之后（gui_fallback_only）
$byScore = @{ Expression='score'; Descending=$true }
$byTier  = @{ Expression='tier';  Ascending=$true }
# -All 与「无命中回退全量」都必须是真·全量，不能被默认 TopN=5 悄悄截断
$limit = if ($All -or $fallback) { 999999 } else { $TopN }
$tools   = @($scored | Where-Object { $_.kind -eq 'tool' }    | Sort-Object $byScore, $byTier | Select-Object -First $limit)
$quicker = @($scored | Where-Object { $_.kind -eq 'quicker' } | Sort-Object $byScore, $byTier | Select-Object -First $limit)

function Get-LocString($row) {
    if ($row.kind -eq 'quicker') {
        $st = Resolve-QuickerStarter $row.e
        return $(if ($st) { "启动器 $st" } else { '启动器未找到' })
    }
    $p = Resolve-Locator $row.e
    return $(if ($p) { $p } else { '路径未找到（跑 validate-registry.ps1）' })
}
# 文档层级：none=简单工具直接指向 exe；brief=只有用法页；detailed=用法页 + 结构化接口清单
function Get-DocLabel($e) {
    if ($e.PSObject.Properties['doc_level'] -and $e.doc_level) { return [string]$e.doc_level }
    if ($e.PSObject.Properties['usage_page'] -and $e.usage_page) { return 'brief' }
    return 'none'
}
# 复杂工具把接口清单压成一行随命中结果注入：常见任务不必再读文档（零跳转）
# 限长 260 字，避免把整本文档塞进每次 prompt 造成上下文膨胀
function Get-InterfaceDigest($e, [int]$max) {
    if (-not ($e.PSObject.Properties['interfaces'])) { return '' }
    $parts = @()
    foreach ($i in (@($e.interfaces) | Select-Object -First $max)) {
        $n = if ($i.PSObject.Properties['name']) { [string]$i.name } else { '' }
        $d = if ($i.PSObject.Properties['note']) { [string]$i.note } else { '' }
        if (-not $n) { continue }
        $parts += if ($d) { "$n($d)" } else { $n }
    }
    if ($parts.Count -eq 0) { return '' }
    $s = ' | 接口: ' + ($parts -join ', ')
    if ($s.Length -gt 260) { $s = $s.Substring(0, 260) + '…' }
    return $s
}
function Get-MetaString($e) {
    $bits = @()
    # @($null).Count 是 1，必须先把空值过滤掉，否则会输出「分类: 」这种空段
    foreach ($p in @(
        [PSCustomObject]@{ F='category_path'; L='分类: '; J=' > ' }
        [PSCustomObject]@{ F='tags';          L='标签: '; J=',' }
        [PSCustomObject]@{ F='keywords';      L='关键词: '; J=',' }
    )) {
        if (-not $e.PSObject.Properties[$p.F]) { continue }
        $vals = @($e.($p.F) | Where-Object { $_ })
        if ($vals.Count -gt 0) { $bits += $p.L + ($vals -join $p.J) }
    }
    return $(if ($bits.Count -gt 0) { $bits -join ' | ' } else { '（无分类元数据，按 functions 匹配）' })
}

# ===== 输出 =====
Write-Output "=== 检索前置 v2: $Task ==="
Write-Output ("匹配标签: " + $(if ($matchedTags.Count -gt 0) { $matchedTags -join ', ' } else { '<无 → 回退全量>' }))
Write-Output "层级: 同分时 T1 编译器 > T3 已注册软件 > T4 其它 > T- 未分层；T2 系统命令直接调用、不入库"
if ($All) { Write-Output "ℹ️ -All 已显式请求全量清单（跳过打分过滤）" }
elseif ($fallback) { Write-Output "ℹ️ 未命中标签或候选为空，已回退全量清单" }
$modeLabel = if ($All -or $fallback) { '全量' } else { "TopN=$TopN" }
Write-Output ("候选: 工具 $($tools.Count) 个 / GUI 兜底动作 $($quicker.Count) 个（$modeLabel）")
foreach ($r in $tools) {
    $e = $r.e
    $vTag = if ($e.PSObject.Properties['verified'] -and $e.verified -eq $false) { ' [未验证]' } else { '' }
    Write-Output ("  [$(Get-TierLabel $r)] [$($e.id)] $($e.name) | 分数 $($r.score) | 功能: $(@($e.functions) -join '/') | 文档: $(Get-DocLabel $e)$vTag")
    Write-Output ("      $(Get-MetaString $e)")
    Write-Output ("      $(Get-LocString $r)")
}
foreach ($r in $quicker) {
    $e = $r.e
    Write-Output ("  [GUI 兜底] [$(Get-TierLabel $r)] [$($e.id)] $($e.name) | 分数 $($r.score) | 动作码 $($e.action_code)")
    Write-Output ("      $(Get-MetaString $e)")
    Write-Output ("      $(Get-LocString $r)")
}
if ($tools.Count -eq 0 -and $quicker.Count -eq 0) {
    Write-Output "  索引为空或全部软删：先看系统自带命令，必要时 register.ps1 / scan-directory.ps1 -Quick"
}

# ===== 系统命令优先提示（不入库，直接调）=====
$builtins = @(
    [PSCustomObject]@{ P='哈希|hash|校验|checksum|md5|sha'; C='Get-FileHash / certutil -hashfile' },
    [PSCustomObject]@{ P='对比|比较|diff|fc';              C='fc / comp / Compare-Object' },
    [PSCustomObject]@{ P='重命名|rename|批量改名';          C='ren / Rename-Item' },
    [PSCustomObject]@{ P='同步|备份|backup|robocopy';       C='robocopy / xcopy' },
    [PSCustomObject]@{ P='zip|打包|解压';                   C='Compress-Archive / Expand-Archive / tar.exe（轻量 zip 优先）' }
)
$hits = @($builtins | Where-Object { $taskLower -match $_.P } | ForEach-Object { $_.C })
if ($hits.Count -gt 0) { Write-Output ("系统命令优先: " + ($hits -join ' ; ')) }

# ===== 可选：输出可直接注入 Agent 的 prompt 片段 =====
if ($InjectPrompt) {
    Write-Output ""
    Write-Output "=== 以下注入 Agent Prompt ==="
    if ($tools.Count -eq 0 -and $quicker.Count -eq 0) {
        Write-Output "当前索引没有可用工具：优先用系统自带命令；确需外部工具时再 register.ps1 / scan-directory.ps1 -Quick"
    } elseif ($All -or $fallback) {
        Write-Output "你有以下工具可用（全量清单）："
    } else {
        Write-Output "你有以下工具可用（已从全量索引按匹配度检索过滤，非全量清单）："
    }
    foreach ($r in $tools) {
        $e = $r.e
        $usage = ''
        # 复杂工具优先注入结构化接口清单（一次拿到，不必再跳去读文档）
        if ((Get-DocLabel $e) -eq 'detailed') { $usage = Get-InterfaceDigest $e 12 }
        # 只有简短用法页时退回「首行摘要」，简单工具则完全不注入额外内容
        if (-not $usage -and $e.PSObject.Properties['usage_page'] -and $e.usage_page) {
            # 与 -Check 一致：走受管路径校验，绝不按 usage_page 直接拼路径读任意文件
            $up = Resolve-DocPath (Split-Path $PSScriptRoot -Parent) ([string]$e.usage_page)
            if ($up -and (Test-Path -LiteralPath $up -PathType Leaf)) {
                $txt = [System.IO.File]::ReadAllText($up, [System.Text.Encoding]::UTF8)
                $first = @($txt -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.StartsWith('#') -and -not $_.StartsWith('<!--') } | Select-Object -First 1)
                if ($first.Count -gt 0) { $usage = ' | 用法: ' + ([string]$first[0]).Substring(0, [Math]::Min(120, ([string]$first[0]).Length)) }
            }
        }
        # 再带一条可复制的典型调用，让常见任务真正「零跳转」（不用再读文档、不用 --help 试探）
        if ($usage -and $e.PSObject.Properties['example'] -and $e.example) {
            $ex = [string]$e.example
            if ($ex.Length -gt 140) { $ex = $ex.Substring(0, 140) + '…' }
            $usage += ' | 示例: ' + $ex
        }
        Write-Output ("- [$(Get-TierLabel $r)] **$($e.id)** ($($e.name)) [文档:$(Get-DocLabel $e)]: $(@($e.functions) -join ',') | 路径: $(Get-LocString $r)$usage")
    }
    foreach ($r in $quicker) {
        $e = $r.e
        Write-Output ("- [$(Get-TierLabel $r)] **$($e.id)** ($($e.name)) [GUI 兜底]: 动作码 $($e.action_code) | $(Get-LocString $r)")
    }
    Write-Output ""
    Write-Output "请从中选择最合适的工具执行任务: '$Task'"
    Write-Output '若候选都不合适，读 $env:AGENT_REGISTRY 全量兜底；系统自带命令优先直用。'
    Write-Output '复杂工具的完整参数/坑位按需读: .\scripts\tool-doc.ps1 -Id <id> -Full（默认不注入全文，避免上下文膨胀）'
}
Write-Output "建议：先出计划，GUI 步骤排最后；本脚本只读，不修改索引。"
'@
# ============ scripts/scan-directory.ps1 ============
Write-File "scripts/scan-directory.ps1" @'
param([string[]]$Dirs=@(), [switch]$Quick, [switch]$Full, [switch]$ProbeVersion)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
$reg = Get-Registry

$priorityRuntimes = @(
    "python.exe","pythonw.exe","python3.exe","dotnet.exe","csc.exe",
    "gcc.exe","g++.exe","clang.exe","clang++.exe",
    "java.exe","javac.exe","lua.exe","luajit.exe","node.exe","pwsh.exe","powershell.exe",
    "ruby.exe","perl.exe","php.exe","go.exe","rustc.exe"
)
$autoLibs = @("pyautogui","pywinauto","selenium","playwright","puppeteer","opencv")
# 只有脚本/可执行文件才算「自动化能力」：selenium-notes.md / opencv_logo.png 不能登记成工具
$autoExt  = @(".ps1",".psm1",".py",".pyw",".js",".mjs",".cjs",".exe",".bat",".cmd",".vbs",".rb",".pl",".lua")
# 只排除缓存/依赖目录。编译器的 bin 是安装目录（mingw64\bin、Git\bin），绝不能排除
$excludeDirs = @("node_modules",".git","__pycache__",".venv","venv","obj",'$recycle.bin',"system volume information")

# 仅判断「扫描根内部」的目录段，避免路径前缀（如 ...\AppData\Local\Temp）误伤整个扫描目标
function Test-ExcludedPath([string]$full, [string]$root) {
    $rel = if ($full.Length -gt $root.Length) { $full.Substring($root.Length) } else { $full }
    $segs = @(($rel.ToLower() -split '[\\/]') | Where-Object { $_ })
    foreach ($s in $segs) { if ($excludeDirs -contains $s) { return $true } }
    return $false
}

$defaultTargets = @("$env:USERPROFILE\Tools", "$env:USERPROFILE\Scripts", "$env:USERPROFILE\Work",
      "C:\Program Files\7-Zip", "C:\Program Files\Git\bin", "C:\Program Files\dotnet",
      "C:\Program Files\nodejs", "C:\Program Files\Go\bin", "C:\Program Files\LLVM\bin",
      "C:\mingw64\bin", "C:\msys64\mingw64\bin", "C:\TDM-GCC-64\bin",
      "$env:LOCALAPPDATA\Programs", "C:\Program Files\Python*",
      "$env:LOCALAPPDATA\Programs\Python*", "$env:LOCALAPPDATA\Microsoft\WindowsApps")
# 跨设备适配：本机专属目录由 AGENT_SCAN_DIRS（分号分隔）或 -Dirs 提供，不写死任何盘符
if ($env:AGENT_SCAN_DIRS) {
    $defaultTargets += @($env:AGENT_SCAN_DIRS -split [IO.Path]::PathSeparator | Where-Object { $_ })
}
$targets = if ($Dirs.Count -gt 0) { $Dirs } else { $defaultTargets }
$expanded = @()
foreach ($t in $targets) {
    $r = Resolve-Path -Path $t -ErrorAction Ignore
    if ($r) { foreach ($x in @($r)) { $expanded += [string]$x } }
    else { Write-Output "  ⏭ 跳过不存在的扫描目标: $t" }
}
$expanded = @($expanded | Select-Object -Unique)

Write-Output "=== 积极扫描（编译器/运行时优先）==="
# -Quick 至少要能进一层子目录：运行时通常在 Python311\python.exe 这类位置
$depth = if($Quick){2}elseif($Full){5}else{2}
$foundRun=@(); $foundAuto=@(); $added=0
$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

foreach ($dir in $expanded) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    # 过滤 0 字节文件：WindowsApps 下的 python.exe / node.exe 是应用执行别名，不是真工具
    $files = Get-ChildItem -LiteralPath $dir -Recurse -Depth ($depth-1) -File -ErrorAction Ignore |
        Where-Object { $_.Length -gt 0 -and -not (Test-ExcludedPath $_.FullName ([string]$dir)) }
    foreach ($f in $files) {
        $n = $f.Name.ToLower()
        # 1) 运行时/编译器
        foreach ($pr in $priorityRuntimes) {
            if ($n -ne $pr) { continue }
            $foundRun += $f.FullName
            $ver = "未探测（加 -ProbeVersion 才会执行程序）"
            if ($ProbeVersion) {
                if ($n -in @("powershell.exe","pwsh.exe","cmd.exe")) {
                    $ver = "跳过（宿主 shell，避免 --version 进入交互挂起）"
                } else {
                    $before = $Error.Count
                    try { $ver = (& $f.FullName --version 2>&1 | Select-Object -First 1 | Out-String).Trim() } catch { $ver = "探测失败" }
                    if (-not $ver) { try { $ver = (& $f.FullName -v 2>&1 | Select-Object -First 1 | Out-String).Trim() } catch { $ver = "探测失败" } }
                    while ($Error.Count -gt $before) { $Error.RemoveAt(0) }
                    if (-not $ver) { $ver = "无输出" }
                }
            }
            # 路径已存在（含软删除）就跳过，避免重复条目
            if (@($reg.tools | Where-Object { [string]$_.locator.primary -eq $f.FullName }).Count -eq 0) {
                $funcs = switch -Wildcard($n){
                    "python*" {@("script","python","run")}
                    "dotnet*" {@("build","run","dotnet")}
                    "gcc*" {@("compile","c")}; "g++*" {@("compile","cpp")}
                    "java*" {@("java","run")}; "javac*" {@("compile","java")}
                    "lua*" {@("script","lua","run")}; "node*" {@("script","js","run")}
                    "powershell*" {@("script","automation","shell")}
                    "go*" {@("compile","go")}; "rustc*" {@("compile","rust")}
                    default {@("runtime")}
                }
                $newId = New-UniqueToolId ([System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLower()) $reg
                $reg.tools += [PSCustomObject]@{
                    id=$newId
                    name=$f.Name; type="binary"; functions=@($funcs); platform=@("windows")
                    locator=[PSCustomObject]@{primary=$f.FullName;fallback=[PSCustomObject]@{registry=$null;common_paths=@();search_path_env=$true}}
                    example="$n --version"; when_to_use="运行/编译 $($funcs -join '/')"; when_not_to_use="无"
                    verified=$true; deleted=$false; deleted_at=$null; last_checked=$now
                    added_by="scan-directory"; added_at=$now; usage_page=$null
                }
                $added++
                Write-Output "  [运行时] $($f.FullName) | $ver | id=$newId"
            }
            break
        }
        # 2) 自动化能力（脚本/库目录）
        foreach ($al in $autoLibs) {
            if ($n -notlike "*$al*") { continue }
            if ($autoExt -notcontains $f.Extension.ToLower()) { break }
            $foundAuto += $f.FullName
            if (@($reg.tools | Where-Object { [string]$_.locator.primary -eq $f.FullName }).Count -eq 0) {
                $newId = New-UniqueToolId ("auto-" + [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLower()) $reg
                $reg.tools += [PSCustomObject]@{
                    id=$newId
                    name=$f.Name; type=if($f.Extension -match "\.(ps1|py|js)$"){"script"}else{"binary"}
                    functions=@("automation","gui","screenshot","mouse","keyboard","browser")
                    platform=@("windows")
                    locator=[PSCustomObject]@{primary=$f.FullName;fallback=[PSCustomObject]@{registry=$null;common_paths=@();search_path_env=$true}}
                    example=""; when_to_use="GUI自动化/键鼠/截图/浏览器"; when_not_to_use="无头环境"
                    requires_gui=$true; verified=$false
                    deleted=$false; deleted_at=$null; last_checked=$now
                    added_by="scan-directory"; added_at=$now; usage_page=$null
                }
                $added++
                Write-Output "  [自动化] $($f.FullName) | id=$newId"
            }
            break
        }
    }
}

# 3) 系统自带能力（不入库，仅提示）
$builtins = @("certutil","robocopy","comp","fc","ren","where","xcopy","makecab","cipher")
$hit = @()
foreach ($b in $builtins) { if (Get-Command $b -ErrorAction Ignore) { $hit += $b } }

if ($added -gt 0) { Save-Registry $reg; Write-Output "`n索引已更新：新增 $added 条 → version $($reg.version)" }
else { Write-Output "`n未发现新工具，索引未改动" }
Write-Output "`n=== 系统自带命令（优先直用，不入库）==="
Write-Output "  $($hit -join ', ')"
Write-Output "  覆盖: 哈希/对比/同步/重命名/遍历/分卷加密"
Write-Output "`n扫描完成: 运行时 $($foundRun.Count) | 自动化 $($foundAuto.Count) | 新增索引 $added"
'@
# ============ scripts/rename/rename.ps1 ============
Write-File "scripts/rename/rename.ps1" @'
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
'@
# ============ examples/pipeline-example.ps1 ============
Write-File "examples/pipeline-example.ps1" @'
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
'@
# ============ tools/_template.md ============
Write-File "tools/_template.md" @'
# {工具名} 用法页（brief，从简）

<!-- doc_version: 1 | tool_version: {产品版本} | checked_at: {YYYY-MM-DD} | doc_level: brief -->
<!-- 从简原则：只写实际用过的功能；没用过的不预先详细写，用到时再用 record-interface.ps1 补 -->

## 基本信息
- id / 位置：`{id}` / `{locator.primary}`
- 功能标签：{functions}
- 适用：{when_to_use}

## 接口清单（受管区块，由脚本同步，不要手改）
<!-- interfaces:start -->
| 接口 | 调用语法 | 说明 |
|---|---|---|
| `{已用接口}` | `{syntax}` | {一句话} |
<!-- interfaces:end -->

## 典型调用
```
{example}
```

## 坑 / 备注
- 踩到再写。
'@
# ============ pending/pending-tools.json ============
Write-File "pending/pending-tools.json" @'
{
  "note": "复杂/无通用复用性的自制脚本提案队列；只有用户明确同意后才允许进入 registry.json",
  "policy": "archive_approval_required: register.ps1 intercepts script files, writes a proposal with status=pending_user_approval, and exits 2 without touching registry.json",
  "items": []
}
'@
# ============ AGENT_INIT_PROMPT.md ============
Write-File "AGENT_INIT_PROMPT.md" @'
# Agent 初始化指令（永久规则）

读 `$env:AGENT_REGISTRY` 作为工具索引；**未设置时默认读本仓库根目录的 `registry.json`**（相对脚本位置解析，所以整个文件夹放在任意盘符 / 路径都能用，换设备不需要改配置）。

## 交互契约：用户只说意图，Agent 负责执行命令（强制）

**用户永远不需要自己写或粘贴 PowerShell 命令。** 本文档所有 `.\scripts\*.ps1` 代码块都是给 Agent 看的**内部动作清单**，不是交给用户的作业；用户用自然语言说出意图 + 必要信息（工具名 / 路径 / 改什么）即可。Agent 必须自己解析意图 → 选脚本 → 拼参数 → 执行 → 核对结果 → 用一句话回报。

| 用户怎么说（示例） | Agent 自动做什么 | 背后执行的动作（用户不用管） |
|---|---|---|
| 「把 Bandizip 加进索引，位置 `<本机实际路径>`，用来解压/压缩」 | 查重 → 判断简单/复杂工具 → 注册 → 回报 id 与 version | `register.ps1 -Path ... -Functions extract,compress -Tags ... -Keywords ... -CategoryPath ... -Tier 3` |
| 「把 bz 的路径改成 …」/「给 bz 补个标签」/「bz 升级了」 | 定位 id → **原地改**，保留 id 与 added_at | `update-tool.ps1 -Id bz -Path ...` / `-Tags ... -AddTags` / `-RefreshVersion` |
| 「删掉 xx 工具」 | 默认软删（可恢复）；明说「彻底删」才硬删；`-PurgeDoc` 单独确认 | `unregister.ps1 -Id xx [-Hard [-PurgeDoc]]`，说明文档由脚本自动联动 |
| 「加个 Quicker 动作，码是 SHOT」 | 写入 `quicker_actions` | `register.ps1 -Quicker -ActionCode SHOT -Functions ...` |
| 「这个任务里用到了 bz 的 a 接口，记一下」 | 任务之余按**从简原则**补写一条 | `record-interface.ps1 -Id bz -Name a -Syntax ... -Note ...` |
| 「有哪些工具能用」/「本机有什么编译器」 | 只读检索并汇报 | `init-discovery.ps1 -InjectPrompt` / `route_task_v2.ps1 -Task ...` / `tool-doc.ps1 -List` |
| 「初始化」+ 给出 `AGENT_INIT_PROMPT.md`（贴全文或给路径） | 自己读规则、确认索引位置、跑只读自检与分层检索 | 见下节「新会话初始化」的五步 |

执行要求：
1. **先读盘再动手**：每次任务从磁盘取最新 version（`route_task_v2.ps1` / `Get-Registry`），不背清单、不用旧记忆里的路径。
2. **缺信息只问一句**：没给路径、id 不明确、判断不了软删/硬删时先问清，不猜路径、不拿相似 id 凑数。用户只给了路径没说用途时，从工具名 / 对话上下文补 1–3 个 `functions` 和 `tags / keywords`（`-AutoAnalyze` 可辅助读 `--help`），**别留空**，否则以后 `route_task_v2.ps1` 检索不到；确实推不出才问。补写接口仍遵守从简原则，不预先抄全量参数。
3. **不可逆动作要用户点头**：`-Hard -PurgeDoc`（彻底删文档）、批量 `-Apply` 登记、自制脚本转正，都必须有用户明确指令；常规增删默认走可恢复方式（软删 / 归档）。
4. **自制脚本审批不因「说话」而绕过**：用户在对话里明确同意后，Agent 可代为执行 `approve-tool.ps1`，但 `-ApprovedBy` 必须是可确认的**用户标识**，不得填 Agent 自己、不得默认取当前用户名、不得手工改索引绕过。`approve-tool.ps1` 会生成一次性凭证并传给 `register.ps1`；直接给 `register.ps1` 塞 `-ApprovedBy` 会被拒绝，转正唯一入口是 `approve-tool.ps1`。
5. **写完必须回报**：输出 `[Registry] 操作: <动作> | 工具: <id> | 变更: <字段> | version: <新版本号>`，再用自然语言说明「索引现在变成什么样」；失败要说原因和下一步，不静默吞错。
6. **不要把命令甩给用户**：除非用户明确说「给我命令我自己跑」，否则别把脚本代码块复制进回复让用户执行。

用户提到「软件更新了 / 卸载了 / 换目录了」时，同样由 Agent 自己跑 `validate-registry.ps1`（先只读）或 `update-tool.ps1` / `unregister.ps1` 落地；**不需要通知其它会话刷新**，它们下次任务会懒加载新 version。

## 8 条核心原则
1. 本地优先　2. 批量优先　3. GUI 兜底　4. 积极发现
5. 粒度约束（一脚本一件事）　6. 复用检查（先参数化）
7. 先规划后执行（≥3步）　8. 归档审批（复杂/无复用脚本须用户同意）

## 系统自带命令优先（不入库，直接调）
- 哈希: `certutil -hashfile` / `Get-FileHash`
- 文件对比: `fc` / `comp` / `robocopy /L`
- 查重/重命名: `ren` / `Rename-Item`
- 编码/换行/BOM: PowerShell `.NET` 读写
- 目录遍历/筛选: `Get-ChildItem` / `dir /s`
- 磁盘分析: `Get-ChildItem | Measure-Object`
- 同步备份: `robocopy` / `xcopy`
- 分卷加密: `makecab` / `cipher`
- 轻量 zip: `Compress-Archive` / `Expand-Archive` / `tar.exe`
规则：遇到上面需求优先系统命令，不满足才写脚本或注册外部工具。
这些属于初始化分层检索的 **T2（零级/一级）**：`init-discovery.ps1` 只报告、绝不写入索引。

## 二次处理（GUI/外设/浏览器）
- 截图: .NET / `pyautogui.screenshot()`
- 键鼠: Win32 API / `pyautogui` / `pywinauto`
- 浏览器: Selenium / Playwright / CDP（浏览器本体路径由初始化检索 T3 发现，不靠猜）
- 兜底: Quicker 动作 → `QuickerStarter.exe -c "runaction:动作码 参数"` 
- 标记 `requires_gui=true`，无头环境不调

## 新会话初始化：自动分层检索（每次开会话自动跑，只读）

**用户侧只做两件事**：说一句「初始化」，并把本文件交给 Agent（贴全文，或给出仓库内 `AGENT_INIT_PROMPT.md` 的路径）。下面全部由 Agent 自己执行，不要求用户敲任何命令：

1. 读入本文件，作为本会话的永久规则
2. 确认索引可用：优先读 `$env:AGENT_REGISTRY`；未设置时脚本自动定位仓库根目录的 `registry.json`，**无需配置环境变量**。只有要把索引放到仓库外时才需要设置 `AGENT_REGISTRY`
3. 跑只读体检：`validate-registry.ps1` 与 `route_task_v2.ps1 -Task "<示例任务>"`
4. 跑 `init-discovery.ps1 -InjectPrompt`，把四级可用工具清单摘要给用户
5. **不自动 `-Apply`**；只有用户明确说「登记 / 加入索引」时才写盘

上面第 4 步的命令，**每个新会话开始时也要先跑一次**（只读、不写索引、不需要用户批准）：

```powershell
.\scripts\init-discovery.ps1 -InjectPrompt      # 分层清单 + 可直接注入的片段
```

它按四级优先级报告本机可用工具并交给 Agent 使用；**自动的是「检索」，不是「注册」**。顺序不可颠倒：

| 层级 | 类别 | 例子 | 入库策略 |
|---|---|---|---|
| **T1**（最优先） | 编译器 / 构建工具 / 语言运行时 | gcc、g++、javac、dotnet、go、rustc、cmake、python、node | 优先发现，`-Apply` 自动登记（含版本指纹） |
| **T2** | 系统自带命令，**零级/一级** | certutil、robocopy、fc、ren、tar、curl、powershell、cmd | **只提示，永不入库**——Agent 本来就靠 `Get-Command` / 内置命令秒得，进索引只是冗余 |
| **T3** | 系统已注册的工具类软件 | Bandizip(`bz`)、Quicker、Chrome/Edge/Firefox、Git、ffmpeg、VSCode | 从 App Paths / 卸载表 / 常见安装位置发现，`-Apply` 自动登记；**Quicker 动作码由用户给，只提示不自动建条目** |
| **T4**（最后） | 其它工具软件与脚本 | 目录扫描发现的零散 exe、`.ps1/.py/.bat` 脚本 | 默认只报告；二进制需 `-IncludeTier4`；**脚本一律走归档审批，绝不自动入库** |

发现来源：PATH、工具/编译器常见目录（`-Dirs` 追加）、注册表 App Paths、卸载表 `DisplayIcon`、常见安装位置。同名 exe 的多来源会自动合并为一条最可靠路径，不会登记成 `git` 与 `git-2`。编译器 `bin` 目录里的附属程序（ar/as/ld/nm…）整目录跳过，避免刷屏。

写入是**显式**的，且可缩到只登记编译器：

```powershell
.\scripts\init-discovery.ps1 -MaxPerTier 99     # 先看全清单
.\scripts\init-discovery.ps1 -Apply             # 默认登记 T1 + T3
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 1     # 只登记编译器/运行时
.\scripts\init-discovery.ps1 -Apply -IncludeTier4    # 连 T4 二进制一起（脚本仍要审批）
```

批量新增只 `version + 1`；重复跑 `-Apply` 幂等（已在索引的路径跳过）。**只读检索每次新会话自动跑，但不要按定时器或「连续 N 次空候选」自动 `-Apply`**——那会悄悄污染索引，写盘动作由用户或明确需求触发。

`tier` 是条目的可选字段（1/3/4；T2 不入库所以没有 2）。`route_task_v2.ps1` 在**分数相同**时按 T1 > T3 > T4 > 未分层排序；任务相关性仍由分数主导，不让不相关的编译器压过真正匹配的压缩工具。

## 积极扫描（补充手段）
- 初始化分层检索走 `init-discovery.ps1`；只想深挖某个目录里的运行时/自动化库时用 `scripts/scan-directory.ps1 -Quick -Dirs <目录>`
- 优先发现：python/dotnet/gcc/java/lua/node/go/rust 等运行时；pyautogui/pywinauto/selenium 等自动化库
- 编译器/自动化自动登记；系统命令只提示不入库

## 工具检索前置（v2）
索引只存一份在磁盘上，Agent **不要把工具清单背进长期记忆**。每次任务先检索，再决定用哪个：

```powershell
.\scripts\route_task_v2.ps1 -Task "<用户任务原文>" -InjectPrompt
```

1. 先跑 v2，拿候选（默认 TopN=5，按 `functions`/`tags`/`keywords`/`category_path` 打分）
2. 从候选里选最合适的；同分时按 `T1 > T3 > T4 > T-` 排序（输出里带 `[T3]` 这类标签）；Quicker 动作标 `[GUI 兜底]`，永远排在普通工具之后
3. 候选为空或不合适 → 加 `-All`，或直接读 `registry.json` 全量兜底
4. 系统自带命令命中提示时直接调用，不查索引
5. 旧脚本 `route_task.ps1` 仍保留（按 `functions` 硬匹配列全部候选），可并行对比；切换默认入口前先跑两者验证效果

`route_task_v2.ps1` 是**只读**的，永不写索引；它输出的是候选清单，不是唯一答案。

## 工具文档分层（复杂工具写文档，简单工具直接指向 exe）

判断标准是 **接口数量 × 跨会话复用频次**，不是「工具本身复杂」：Godot / ffmpeg / Bandizip 这类接口多、会被多个会话反复调用的工具值得建档；`test.exe`、单用途脚本建档只是维护负担。

| 类型 | 索引形态 | 字段 |
|---|---|---|
| **简单工具** | `索引 → locator.primary → exe` | 不写 `usage_page` / `doc_level` / `interfaces`，零开销 |
| **复杂工具** | `索引 → usage_page + interfaces → 完整文档（按需）→ exe` | `usage_page`、`doc_level=detailed`、`interfaces[{name,syntax,note}]`、`doc_checked_at` |

**索引永远保留可执行文件路径**：不允许只存文档路径，否则连一次简单调用都要两跳。多一层文档的价值是「把接口知识沉淀一次」，不是「多一次跳转」——所以：

1. 结构化接口清单 `interfaces` 直接存在索引条目里，命中时由 `route_task_v2.ps1 -InjectPrompt` **一次注入**（接口名 + 说明 + 典型调用）。常见任务零跳转，不用 `--help` 试探。
2. 完整文档只在需要详细参数、开关、坑位时按需读：`tool-doc.ps1 -Id <id> -Full`。**不要把整本文档塞进每次 prompt**，会撑爆上下文。
3. `doc_level=brief` 是老条目（只有用法页、无接口清单）的兼容标记；`none` 表示简单工具。

```powershell
.\scripts\tool-doc.ps1 -List                  # 看所有条目的文档分层状态
.\scripts\tool-doc.ps1 -Id bz                # 基本信息和接口清单（不读全文）
.\scripts\tool-doc.ps1 -Id bz -InjectPrompt  # 紧凑片段，可直接注入别的会话
.\scripts\tool-doc.ps1 -Id bz -Full          # 需要全部参数/坑位时才展开
.\scripts\tool-doc.ps1 -Check                # 一致性体检：文档缺失、无接口清单、版本过期
```

建档流程：照 `tools\_template-detailed.md` 写文档（顶部 `<!-- tool_version: ... -->` 复核头）→ 照 `examples\interfaces-bz.json` 写接口清单 JSON → `update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocLevel detailed -InterfacesFile <清单.json> -DocChecked`。也可在注册时一步带上 `register.ps1 ... -UsagePage ... -InterfacesFile ...`。

**软件升级后**：`validate-registry.ps1 -Apply` 刷新版本指纹 → 复核文档接口是否变化 → 必要时更新 `interfaces` → `update-tool.ps1 -Id <id> -DocChecked`。`tool-doc.ps1 -Check` 会比对文档头 `tool_version` 与索引 `version_info.product_version`，不一致就告警。

## 工具文档生命周期与从简原则（强制）

**从简原则**：说明文档只写「实际用过或确实常用」的功能与接口。基本用不上、从没使用过的功能、参数、开关、退出码，**不要预先详细写**。第一次在任务里真正用到时，在任务之余用一条命令补写，索引与文档一起更新：

```powershell
.\scripts\record-interface.ps1 -Id bz -Name a -Syntax 'bz a -y out.zip <files>' -Note '追加文件到已有包' -Task '给压缩包补两个文件'
```

不要为了「文档看起来完整」去跑一遍 `--help` 把全部子命令抄进来：那会让注入片段变长、维护成本上升，而多数条目永远用不到。`tool-doc.ps1 -Check` 在接口数超过 8 条时会提示精简（`-WarnAbove` 可调）。

**添加 / 修改 / 删除时，索引与说明文档必须一起变**（脚本已自动联动，不要手工改文件）：

| 操作 | 索引 | 说明文档 |
|---|---|---|
| 注册简单工具（不传文档参数） | 只写 `locator.primary` | 不生成文件，`索引 → exe` 零开销 |
| 注册复杂工具（`-UsagePage` / `-InterfacesFile` / `-DocLevel detailed`） | 写 `usage_page` + `interfaces` | 文件不存在自动生成**从简骨架**，接口清单写进受管区块 |
| 改接口清单 `-InterfacesFile` | 原地更新 `interfaces`，幂等 | 自动同步文档里 `<!-- interfaces:start --> … <!-- interfaces:end -->` 表格 |
| 改用法页 `-UsagePage` | 原地更新 `usage_page` | 旧文档无人引用 → 移入 `tools\_archive\`；共享文档保留 |
| 复核 `-DocChecked` | 刷新 `doc_checked_at` | 刷新文档头 `tool_version` / `checked_at` |
| 任务里用到新接口 | `record-interface.ps1` 追加一条（幂等，记录 `used_count` / `last_used`） | 同步写入文档受管表；没有文档时自动建从简骨架 |
| 软删除 `unregister -Id` | `deleted=true` | **保留**文档，条目可随时重新激活 |
| 硬删除 `unregister -Id -Hard` | 物理移除条目 | **同时移出 `tools\` 根目录** → `tools\_archive\<id>-<时间戳>.md`；加 `-PurgeDoc` 才彻底删除 |

安全边界：只处理 `tools\` 下的 `.md`；`_template*.md`、`_archive\`、越界路径、被其它条目共享的文档一律不动。`tool-doc.ps1 -Check` 会报出孤儿文档、文档表格与索引 `interfaces` 不一致、版本头过期、接口清单臃肿。

## 维护触发规则（什么时候该动索引）
| 场景 | 动作 |
|---|---|
| **新会话初始化** | `init-discovery.ps1 -InjectPrompt`（只读，自动跑）→ 看四级清单 → 确认后才 `-Apply` |
| 任务到达 | `route_task_v2.ps1 -Task "<原文>"` 检索候选 |
| 工具调用报「文件不存在 / 命令未找到」 | **先** `validate-registry.ps1` 只读看报告 → 确认后再 `-Apply` 自愈路径 → 仍失败就报告用户，不反复重试 |
| 软件升级 / 换安装目录 | `validate-registry.ps1 -Apply` 刷新 `version_info` 或自愈路径；也可 `update-tool.ps1 -Id <id> -RefreshVersion / -Path <新路径>` |
| 升级后复核复杂工具文档 | `tool-doc.ps1 -Check` → 接口有变则更新 `interfaces` → `update-tool.ps1 -Id <id> -DocChecked` |
| 想给某工具补详细文档 | `update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocLevel detailed -InterfacesFile <清单.json>` |
| 用户要求改工具信息 / 补标签 | `update-tool.ps1 -Id <id> -Tags ... -Keywords ... -CategoryPath ... [-AddTags]`（原地改，保留 id 与 added_at） |
| 用户要求添加工具 | `register.ps1`（自制脚本见下节归档审批）；复杂工具带 `-UsagePage / -InterfacesFile` 会自动建从简文档；本机运行时发现可用 `scan-directory.ps1 -Quick` |
| 用户要求删除工具 | `unregister.ps1 -Id <id> [-Hard [-PurgeDoc]]`；**硬删会把说明文档一起移入 `tools\_archive`**，软删保留文档 |
| 任务里第一次用到某接口 | `record-interface.ps1 -Id <id> -Name <接口> -Syntax '<调用>' -Note '<一句话>'`（任务之余补写，索引与文档同步） |
| 发现某工具有新用法 | 补接口用 `record-interface.ps1`；只补元数据用 `update-tool.ps1 -Id <id> -Tags ... -AddTags`，**不要删了重注册** |

边界（刻意不做，别自作主张）：
- **不自动登记自制脚本**（归档审批规则优先）；不因「每隔 7 天 / 连续 3 次空候选」自动注册新条目
- 校验默认 dry-run，`-Apply` 才写盘；`verified:false` 的工具不自动删除
- 路径失效但 PATH 里有同名工具时，`validate -Apply` 会**改路径**而不是判定卸载；真的卸载要显式 `unregister -Id`
- 任何写入都 `version + 1` 并同步 `registry.md`；其它 Agent 下次任务懒加载，**不需要通知它们刷新**
- 维护完成后输出一行摘要：`[Registry] 操作: <动作> | 工具: <id> | 变更: <字段> | version: <新版本号>`

## 自制脚本归档审批（强制）
Agent 为复杂任务自制的脚本，按复用性分三类处置：

1. **一次性 / 复杂 / 无通用性**：放任务临时目录，用完即弃，**既不进索引也不必提案**。这是默认做法。
2. **想留作工具但无复用性**：`register.ps1 -Path <脚本>` 会被拦截，只生成待审提案到 `pending\pending-tools.json`（`$LASTEXITCODE=2`，`registry.json` 与 version 不变）。**必须请用户明确同意**，由用户（或用户授权的会话）执行 `approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'` 才能转正；Agent 不得自行填写 `-ApprovedBy`，也不得手工改索引绕过。脚本层已强制：`approve-tool.ps1` 生成一次性凭证写入提案队列并传给 `register.ps1`，只有凭证匹配才允许写入索引；`register.ps1 -ApprovedBy '<任意值>'` 单独调用一律拒绝并生成提案，Agent 无法靠拼参数绕过审批。
3. **通用、可参数化复用**：`register.ps1 -Path <脚本> -Reusable -Reason '<复用场景>'` 可直接登记，理由写入条目 `approval` 字段供追溯。

自制脚本登记后默认 `tier=4`（T4），提案与转正都会带上层级。二进制工具、Quicker 动作不受此门禁；`scan-directory.ps1` 发现的本机运行时也不受影响。判定有疑问时一律按第 2 类走审批。脚本层门禁是治理约束，不是安全边界——遵守规则靠 Agent 自律与用户把关。

## 索引管理
索引有两类实体：`tools`（按 `locator.primary` 定位）与 `quicker_actions`（id = `quicker-<动作码>`，靠 `starter` + `invoke_template` 调用）。下面四个脚本**同时支持两者**。

- 注册: `register.ps1 -Path <p> -Functions a,b [-Tags ...] [-Keywords ...] [-CategoryPath '类/子类'] [-Tier 1|3|4] [-AutoAnalyze] [-UsagePage ... -DocLevel ... -InterfacesFile ...]`（自制脚本见上节归档审批；Quicker 动作默认 T3；简单工具不传文档参数；传了文档参数会自动补建从简说明文档）
- 注册 Quicker: `register.ps1 -Quicker -ActionCode <码> -Functions a,b [-Name ...]`（软删过的同一码会原地恢复）
- 提案/审批: `approve-tool.ps1 -List` 查待审；`-Id <提案id> -ApprovedBy '<用户标识>'` 转正；`-Id <提案id> -Reject` 拒绝（提案里的分类元数据会随转正带入条目）
- 原地更新: `update-tool.ps1 -Id <id> [-Path <新路径>] [-Functions a,b] [-UsagePage ...] [-RefreshVersion] [-Show]`
  - 分类元数据: `-Tags a,b [-AddTags]` / `-Keywords '解压,压缩' [-AddTags]` / `-CategoryPath 'file_operation/archive'` / `-Tier 1|3|4`；`-Show` 可查看
  - 文档层: `-UsagePage 'tools/<id>.md'` / `-DocLevel none|brief|detailed` / `-InterfacesFile <清单.json>` / `-DocChecked`（接口清单幂等，重复执行不涨 version；改接口清单会同步刷新说明文档的受管表格，改用法页会归档旧文档）
  - 任务之余补写单条接口: `record-interface.ps1 -Id <id> -Name <接口> [-Syntax '<调用>'] [-Note '<一句话>'] [-Task '<任务>']`（从简原则的渐进式入口，幂等）
  - 升级/换目录/改说明都用它，**不要删了重注册**（会丢 id 与 added_at）
  - Quicker 动作另可用 `-Name / -ActionCode / -InvokeTemplate`；`-Path` 表示启动器，`-CommonPaths` 写 `starter_fallback`；改 `-ActionCode` 会同步改 id 与调用模板
- 删除: `unregister.ps1 -Id <id> [-Hard [-PurgeDoc]]`（默认软删并保留说明文档；`-Hard` 物理移除条目 + 把说明文档移入 `tools\_archive`；`-PurgeDoc` 才彻底删除文档）
- 校验: `validate-registry.ps1`（默认只出报告，确认后加 `-Apply` 才写入）
  - `-Apply` 会自动：修正搬迁后的路径、刷新升级后的 `version_info` 版本指纹、软删除已验证但路径失效的工具
  - Quicker 段另检查启动器有效性与动作码/模板一致性；启动器失效**只报告不自动删**（GUI 兜底动作）
- 路由: `route_task_v2.ps1 -Task "<描述>" [-TopN 5] [-InjectPrompt] [-All]`（检索前置，推荐；复杂工具的接口清单随命中结果一次注入）；`route_task.ps1 -Task "<描述>"`（按 functions 硬匹配的旧版，保留对比）
- 文档: `tool-doc.ps1 -List / -Id <id> [-Full] [-InjectPrompt] / -Check [-WarnAbove 8]`（只读；分层披露，别每次注入全文；`-Check` 会查孤儿文档、文档/索引接口表不一致、版本头过期、清单臃肿）

索引更新后 version 自动 +1，其他 agent 下次任务懒加载。
注意 1：路径未找到但从未验证通过（`verified:false`）的工具不会被自动删除，别把它当成失效工具。
注意 2：工具索引只回答「本机有哪些工具、在哪、怎么调」，**不负责生成代码/内容**；编译器只接收已写好的源文件。写代码是 Agent（必要时加载对应方向 skill/专家）的职责。
注意 3：`category_path` / `tags` / `keywords` / `tier` / `usage_page` / `doc_level` / `interfaces` 都是可选元数据，旧条目缺这些字段不影响任何脚本；缺 `tier` 记作 `T-`，缺文档字段按 `doc_level=none`（简单工具）处理。
'@
# ============ README.md ============
Write-File "README.md" @'
# agent-tool-registry

> 让 AI Agent 在任意一台 Windows 设备上，跨会话记住「这台机器有什么工具、装在哪、怎么用」。

一个纯本地、纯文本、零依赖的**设备级工具索引**：把散落在各处的命令行工具、编译器、GUI 兜底动作登记进 `registry.json`，让每个新会话的 Agent 一上来就知道该调什么，而不是每次重新摸索一遍。

---

## 目录

- [这是什么](#这是什么)
- [适用环境](#适用环境)
- [快速开始（3 步）](#快速开始3-步)
- [换一台设备 / 多机使用](#换一台设备--多机使用)
- [全新生成一份运行包](#全新生成一份运行包)
- [核心概念](#核心概念)
- [使用教程（按场景）](#使用教程按场景)
- [用户话术速查](#用户话术速查)
- [脚本参考](#脚本参考)
- [目录结构](#目录结构)
- [与 Agent 配合](#与-agent-配合)
- [数据文件与编码约定](#数据文件与编码约定)
- [开发者指南](#开发者指南)
- [常见问题](#常见问题)
- [已知边界](#已知边界)
- [许可证](#许可证)

---

## 这是什么

用 Agent 干活时，几个问题会反复出现：

| 痛点 | 本项目的做法 |
|---|---|
| 每次新会话都要重新问「这台机器装了什么」 | 一份 `registry.json` 持久保存，所有会话懒加载同一个索引 |
| 工具装在 `D:\Somewhere\...`，换机器路径全变 | 索引记录 `locator.primary` + 备用路径 + PATH 搜索，体检脚本自动自愈 |
| 简单工具也写一页文档，维护成本高 | **简单工具零文档**（索引直接指向 exe）；复杂工具才渐进建档 |
| 自制脚本被随手塞进索引，无人审核 | **审批门禁**：脚本只生成待审提案，必须用户明确同意才能转正 |
| 多个 Agent / 多进程同时写索引互相覆盖 | 命名 Mutex + 锁内合并 + 原子替换，并发新增不丢条目 |
| 删掉工具后文档变成孤儿 / 误删共享文档 | 三级删除 + 文档归档 + 共享保护 + 孤儿检测 |
| Agent 擅自写盘、重复执行把 version 刷爆 | 默认 dry-run、`-Apply` 才落盘、**无变更绝不写盘**、重复执行幂等 |

**特性一览**

- 零依赖：只用 Windows 自带 PowerShell，不联网、不装包、不需要管理员权限
- 路径无关：整个文件夹可以放在任意盘符 / 任意目录，clone 下来直接跑
- 跨 Agent / 跨会话：索引按 `version` 懒加载，改完不用通知其它会话
- 四级分层发现（T1 编译器 → T2 系统命令 → T3 已装软件 → T4 其它 / 脚本）
- 检索前置：按分类元数据打分取 TopN，`-All` 看全量，`-InjectPrompt` 输出可注入片段
- 文档从简：只记录实际用过的接口，用到再补，接口清单同步进索引与 md
- 可验收：随附 64 个用例的验收测试文档，任何改动都能回归

> 项目定位是「给 Agent 用的本机能力清单 + 治理规则」，不是包管理器，也不会替你安装软件。

---

## 适用环境

| 项 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11（依赖 `.exe`、注册表 App Paths、Quicker 启动器） |
| PowerShell | Windows PowerShell 5.1（系统自带）或 PowerShell 7.x |
| 权限 | 普通用户即可，无需管理员 |
| 外部依赖 | 无。不联网、不调用云服务、不写注册表 |
| Linux / macOS | 暂不支持（发现逻辑与路径语义面向 Windows） |

---

## 快速开始（3 步）

### 第 1 步：拿到文件夹

```powershell
git clone https://github.com/licn20216432/agent-tool-registry.git
cd agent-tool-registry
```

也可以直接下载 Release 的 zip 解压到任意目录，例如 `D:\Dev\agent-tool-registry`。**放在哪都行**，脚本按自身位置定位索引。

仓库自带的是**空索引模板**（`version=1` / `tools=[]`），不含任何人的个人数据，也不预置任何指向本机路径的工具条目。

### 第 2 步：跑一次自检（只读，不写盘）

在仓库根目录打开 PowerShell：

```powershell
.\scripts\validate-registry.ps1                        # 体检索引
.\scripts\route_task_v2.ps1 -Task "解压并编译"          # 检索路由
.\scripts\init-discovery.ps1 -InjectPrompt            # 列出本机四级可用工具
```

空索引下前两条会显示「无命中 / 回退全量」，这是正常的；第三条会列出本机编译器、系统命令与已装软件，并输出可注入 Agent 的片段。

> **不需要设置 `AGENT_REGISTRY` 环境变量。** `scripts\lib\registry-core.ps1` 默认按 `$PSScriptRoot\..\..\registry.json` 定位索引，所以整个文件夹搬走也能用。

### 第 3 步：把规则装进 Agent

把 [`AGENT_INIT_PROMPT.md`](AGENT_INIT_PROMPT.md) 全文贴给 Agent，或作为自定义规则 / 长期记忆 / system prompt 载入（各平台入口不同）。这份文件声明了交互契约、四级发现优先级、系统命令优先、文档分层与维护触发规则。

**只给索引、不给规则，等于只有通讯录没有使用约定。**

之后用户只需说自然语言（「把 7-Zip 加进索引，位置 …」「解压这个包」「xx 卸载了，清一下」），Agent 会自己选脚本、拼参数、执行并回报；本文档下面的命令都是给 Agent 参考的动作清单，用户不必敲。

---

## 换一台设备 / 多机使用

**最简做法：复制整个文件夹。** 路径、盘符随便换，脚本内部没有写死任何绝对路径。复制后跑一次只读的 `init-discovery.ps1 -InjectPrompt` 看看新机器的工具，确认后再登记。

> ⚠️ **迁移前先检查环境变量**：若你之前按旧版说明设过 User 级 `AGENT_REGISTRY`（绝对值），它会**优先于**默认的相对路径定位 —— 把文件夹搬到新位置后，脚本仍会读写旧目录的索引。搬迁前清除或改指向新目录：

```powershell
# 查看
[Environment]::GetEnvironmentVariable('AGENT_REGISTRY','User')
# 清除（当前会话也一起清）
[Environment]::SetEnvironmentVariable('AGENT_REGISTRY',$null,'User')
Remove-Item Env:\AGENT_REGISTRY -ErrorAction SilentlyContinue
```

### 可选：把索引放到仓库外

适合「多份代码共用一份索引」或「索引放在同步盘」：

```powershell
# 仅当前会话
$env:AGENT_REGISTRY = 'D:\sync\my-registry.json'

# 永久（User 级，重开终端生效，无需管理员）
[Environment]::SetEnvironmentVariable('AGENT_REGISTRY','D:\sync\my-registry.json','User')
```

设了之后，所有脚本都读这份索引，人读镜像 `registry.md` 也会**写到索引所在目录**（不是仓库目录）。用一个空目录里的索引时，先跑一次 `bootstrap-registry.ps1 -Root D:\sync` 生成初始文件。

### 可选：追加本机专属扫描目录

默认扫描位置是各软件的常见安装路径与 `%USERPROFILE%` 下的 `Tools/Scripts/Work`。你自己的目录用下面任一种方式告诉脚本：

```powershell
# 方式一：环境变量（分号分隔，对 init-discovery 和 scan-directory 都生效）
$env:AGENT_SCAN_DIRS = 'D:\MyTools;E:\Portable'

# 方式二：命令行参数（单次生效）
.\scripts\scan-directory.ps1 -Quick -Dirs 'D:\MyTools'
.\scripts\init-discovery.ps1 -InjectPrompt -Dirs 'D:\MyTools'
```

### 关于个人数据

`registry.json`、`registry.md`、`pending\pending-tools.json`、`tools\*.md`、`tools\_archive\` 都是**你本机的运行数据**。仓库里提供的是空模板；日常注册工具后这些文件会变化。给上游提 PR 时请勿提交它们，建议放在个人 fork / 本地分支，或用 `.git/info/exclude` 排除。

---

## 全新生成一份运行包

`bootstrap-registry.ps1` 把整个项目（32 个文件）内嵌成模板，可在**任意空目录**生成一份完整、可独立运行的副本：

```powershell
# 生成到指定目录
.\bootstrap-registry.ps1 -Root D:\my-agent-tools

# 不传 -Root：默认生成到脚本所在目录下的 generated\ 子目录（不会覆盖仓库自身）
.\bootstrap-registry.ps1
```

- 目标目录已有 `registry.json` 时**拒绝运行**，避免误跑清空注册记录；确需重建先备份再加 `-Force`。
- 生成的是空索引（`version=1`），交互契约、规则、修复标记全部带入。
- 验收文档 `TEST_GUIDE.md` 属于开发材料，**不会**进入生成包。

---

## 核心概念

### 索引 `registry.json`

机器读的唯一真源，UTF-8 **无 BOM**。顶层字段：

| 字段 | 说明 |
|---|---|
| `version` | 每次真实变更 +1；无变更绝不递增 |
| `tools[]` | 普通工具 / 脚本 |
| `quicker_actions[]` | GUI 兜底动作（`id = quicker-<动作码>`） |
| `rules` | 治理规则：本地优先、批量优先、GUI 仅兜底、审批必需等 |
| `last_updated` / `last_writer` | 最后写入时间与写入者 |

`registry.md` 是自动重建的**人读镜像**，与 json 同目录，不要手写。

### 两类实体

| | `tools[]` | `quicker_actions[]` |
|---|---|---|
| 定位 | `locator.primary` 指向可执行文件 | `starter` + `invoke_template` 调用 Quicker 启动器 |
| 层级 | 默认 T3 / T4 | 固定 T3，`requires_gui=true` |
| 检索排序 | 靠前 | **永远排在普通工具之后**（GUI 只是兜底） |
| 发现 | 可自动扫描 | 动作码由用户给，不自动发现 |

### 四级分层（T1–T4）

| 层级 | 内容 | 是否入库 |
|---|---|---|
| T1 | 编译器 / 运行时（gcc、python、dotnet…） | 可登记 |
| T2 | 系统自带命令（robocopy、tar、Compress-Archive…） | **只提示，不入库**，直接调用 |
| T3 | 已安装的软件工具（7-Zip、Bandizip、浏览器…） | 可登记 |
| T4 | 其它工具与自制脚本 | 二进制需 `-IncludeTier4`；脚本一律走审批 |

### 文档分层与「从简原则」

- **简单工具**：`usage_page = null`，不生成 `.md`，索引直接指向 exe，零维护开销。
- **复杂工具**：注册时带 `-InterfacesFile` 或 `-DocLevel detailed`，自动生成从简骨架与**受管接口区块** `<!-- interfaces:start --> … <!-- interfaces:end -->`。
- **用到再补**：任务中第一次用到新接口，用 `record-interface.ps1` 追加一条，索引与 md 同步更新，重复执行幂等。
- 只记录实际用过的接口，不预先罗列参数与开关；文档臃肿会被 `tool-doc.ps1 -Check` 提示。

### 版本、并发与幂等

- 每次真实变更 `version + 1`；相同参数重复执行 → 无变更、不写盘、不涨版。
- 写入用命名 Mutex 保护，锁内重读磁盘并**合并他人新增**，硬删意图不会被旧快照捡回。
- JSON 通过唯一 `.tmp` + `File.Replace` 原子替换，不留半截文件。
- 默认 dry-run：`validate-registry.ps1` / `init-discovery.ps1` 要 `-Apply` 才写盘；**例外**：`scan-directory.ps1` 发现运行时 / 自动化库会直接登记（见「主动扫描」）。

### 审批门禁

自制 `.ps1` / `.py` 等脚本默认**不允许直接入库**：`register.ps1` 会生成 `pending\pending-tools.json` 里的待审提案并退出，索引 version 不变。必须由用户明确同意后由 `approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'` 转正。

- `-ApprovedBy` 不能直接传给 `register.ps1` 绕过审批（会被拒绝）。
- 通用、可参数化复用的脚本可走声明式直登 `-Reusable -Reason '<复用场景>'`。
- 转正后一次性凭证清空、提案状态置 `approved`，重复拦截不会生成第二条提案。

### 删除分级

| 命令 | 索引 | 文档 |
|---|---|---|
| `unregister.ps1 -Id x` | 软删（`deleted=true`，可原地恢复并复用 id） | **保留** |
| `unregister.ps1 -Id x -Hard` | 物理移除条目 | 归档到 `tools\_archive\` |
| `unregister.ps1 -Id x -Hard -PurgeDoc` | 物理移除 | **彻底删除**，不可恢复 |

`-PurgeDoc` 不带 `-Hard` 会被拒绝且**不写盘**。共享文档、模板、`_` 开头的文件与越界路径一律不动。

---

## 使用教程（按场景）

以下命令都在仓库根目录执行；除注明外均为写操作（会 `version + 1`）。示例中的 `<...>` 请替换为本机实际值。

### 1. 让 Agent 先检索再动手

```powershell
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包"              # 打分 TopN=5
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包" -All          # 全量候选（不被 TopN 截断）
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包" -InjectPrompt # 输出可直接贴进 Prompt 的结构化片段
.\scripts\route_task.ps1 -Task "解压 7z 压缩包"                  # 旧版按 functions 硬匹配，可对比
```

无命中时自动回退全量；注入片段包含接口清单而不只是工具名；GUI 兜底动作排最后。

### 2. 注册一个简单工具

```powershell
.\scripts\register.ps1 -Path "C:\Program Files\7-Zip\7z.exe" -Functions 'extract,compress' -Tags 'archive,zip'
```

预期：`✅ 已注册: 7z.exe (ID: 7z)`，`version → 2`，**不生成** `tools\7z.md`（`usage_page` 为 null）。同路径重复执行会提示「已存在索引，跳过」且不涨版。

### 3. 注册一个复杂工具（接口清单 + 文档）

先准备接口清单 `examples\interfaces-bz.json` 那样的 JSON：

```json
[
  { "name": "c", "syntax": "bz c -y -fmt:zip out.zip <files>", "note": "新建包" },
  { "name": "x", "syntax": "bz x -aoa -o:<dir> <archive>", "note": "解压，保留目录结构" }
]
```

```powershell
.\scripts\register.ps1 -Path "<bz.exe 完整路径>" `
  -Functions 'extract,compress,list,test' `
  -Tags 'archive,zip,7z,rar' -Keywords '解压,压缩,打包' `
  -CategoryPath 'file_operation/archive' -Tier 3 `
  -InterfacesFile '.\examples\interfaces-bz.json'
```

预期：2 条接口入库、`doc_level=detailed`、`usage_page=tools/bz.md`，自动生成从简骨架和受管接口表。参考示例文档 [`tools\_example-bz.md`](tools/_example-bz.md)。

### 4. 渐进式补接口

```powershell
.\scripts\record-interface.ps1 -Id bz -Name l -Syntax 'bz l <archive>' -Note '列出包内容'
```

索引与 md 的受管区块同步追加；重复执行提示「内容相同，无需重复补写」，version 不变。

### 5. 更新工具

```powershell
.\scripts\update-tool.ps1 -Id bz -Path "<新路径>" -Tags 'archive,zip,qa'   # 原地改，保留 id 与 added_at
.\scripts\update-tool.ps1 -Id bz -UsagePage 'tools/bz-v2.md'                # 改用法页：旧页自动归档
.\scripts\update-tool.ps1 -Id bz -RefreshVersion                            # 刷新版本指纹
.\scripts\update-tool.ps1 -Id bz -DocChecked                                # 复核文档头
.\scripts\update-tool.ps1 -Id bz -Show                                      # 只看不改
```

相同字段重复执行「无变更，索引未改动」。

### 6. 删除与恢复

```powershell
.\scripts\unregister.ps1 -Id bz                       # 软删（文档保留）
.\scripts\register.ps1 -Path "<同路径>" -Functions 'extract'   # 原地恢复，复用 id，不产生 bz-2
.\scripts\unregister.ps1 -Id bz -Hard                # 硬删 + 文档归档
```

重新激活时若新的 `usage_page` 与保留的旧页不同，旧页会归档到 `tools\_archive\`，不会残留成孤儿文档；被其它条目共享的文档则保留。

### 7. 自制脚本审批全流程

```powershell
# 1) 尝试登记 → 被拦截，只生成提案
.\scripts\register.ps1 -Path '.\examples\pipeline-example.ps1' -Functions 'utility'

# 2) 查看待审队列
.\scripts\approve-tool.ps1 -List

# 3) 用户明确同意后转正（-ApprovedBy 必须是可确认的用户标识，Agent 不能自批）
.\scripts\approve-tool.ps1 -Id <提案id> -ApprovedBy 'alice'

# 4) 不同意则拒绝
.\scripts\approve-tool.ps1 -Id <提案id> -Reject -Reason '不满足复用条件'
```

### 8. Quicker GUI 兜底动作

```powershell
.\scripts\register.ps1 -Quicker -ActionCode 'SHOT' -Functions 'screenshot,gui' -Name '截图动作'
.\scripts\update-tool.ps1 -Id 'quicker-SHOT' -Name '截图动作 v2'
.\scripts\update-tool.ps1 -Id 'quicker-SHOT' -ActionCode 'SHOT2'   # 改码同步改 id 与 invoke_template
.\scripts\unregister.ps1 -Id 'quicker-SHOT2'                      # 软删
```

启动器默认从 `%ProgramFiles%` 推导，也可 `-QuickerExe` 指定；换安装目录时靠 PATH 自愈。

### 9. 体检与自愈

```powershell
.\scripts\validate-registry.ps1            # dry-run：只报告，绝不写盘
.\scripts\validate-registry.ps1 -Apply     # 落盘：刷新版本指纹 / last_checked / 自愈路径 / 软删失效条目
```

只对 `verified=true` 的路径失效条目自动软删；未验证条目只报告不自动删（保护设计）。体检收敛后重复 `-Apply` 不涨版。

### 10. 初始化发现与主动扫描

```powershell
.\scripts\init-discovery.ps1 -InjectPrompt                          # 四级清单（只读）
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 1                    # 只登记编译器
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 4 -IncludeTier4 -Dirs 'D:\MyTools'
.\scripts\scan-directory.ps1 -Quick -Dirs 'D:\MyTools'              # 主动扫描；命中运行时 / 自动化库会直接登记
.\scripts\tool-doc.ps1 -List                                       # 列出文档状态
.\scripts\tool-doc.ps1 -Id bz -Full                                # 读完整文档
.\scripts\tool-doc.ps1 -Check                                      # 孤儿 / 版本头 / 表格一致性检查
```

> **注意**：`scan-directory.ps1` 与 `init-discovery.ps1` 不同，它没有 `-Apply` 开关 —— 扫到 `python.exe` / `gcc.exe` / `pyautogui` 等运行时或自动化库时会**直接写入索引**（`version + 1`），这是「积极扫描」的既有设计。只想看不想写时，把 `-Dirs` 指向不含运行时的目录，或先备份 `registry.json`。

---

## 脚本参考

`scripts\` 下 13 个入口、`lib\` 下 4 个 dot-source 库，另有 `scripts\rename\rename.ps1`，共 19 个 `.ps1`。

| 脚本 | 作用 | 写盘 |
|---|---|---|
| `register.ps1` | 注册普通工具 / Quicker 动作；自制脚本走审批门禁 | ✅ |
| `update-tool.ps1` | 原地更新字段、改路径 / 文档页 / 动作码、刷新指纹 | ✅ |
| `unregister.ps1` | 软删 / 硬删 / `-PurgeDoc` | ✅ |
| `approve-tool.ps1` | 列出 / 同意 / 拒绝待审提案 | ✅ |
| `record-interface.ps1` | 渐进式补写接口 | ✅ |
| `validate-registry.ps1` | 体检与路径自愈（默认 dry-run） | 仅 `-Apply` |
| `init-discovery.ps1` | 四级分层发现（默认只读） | 仅 `-Apply` |
| `scan-directory.ps1` | 主动扫描运行时 / 自动化库 | ✅（发现新工具时） |
| `route_task_v2.ps1` | 打分检索 / TopN / `-All` / `-InjectPrompt` | ❌ |
| `route_task.ps1` | 旧版按 functions 硬匹配 | ❌ |
| `tool-doc.ps1` | 文档读取与一致性检查 | ❌ |
| `registry-sync.ps1` | 由 json 重建 `registry.md` 镜像 | ✅（镜像） |
| `rename\rename.ps1` | 批量重命名示例工具 | ❌（索引） |

**库**（被入口 dot-source，不直接调用）：`lib\registry-core.ps1`（索引读写 / 锁 / 原子替换 / 定位自愈）、`lib\doc-lifecycle.ps1`（文档生成 / 受管区块 / 归档 / 孤儿检测）、`lib\doc-fields.ps1`（文档字段与接口清单解析）、`lib\pending-store.ps1`（提案队列读写）。

---

## 目录结构

```
agent-tool-registry/
├─ registry.json                  # 索引真源（UTF-8 无 BOM，仓库内为空模板）
├─ registry.md                    # 人读镜像，自动重建，勿手写
├─ AGENT_INIT_PROMPT.md           # 给 Agent 的永久规则 / 交互契约
├─ README.md                      # 本文档
├─ TEST_GUIDE.md                  # 验收测试（P0→P8，64 用例，开发用）
├─ USAGE_PHRASES.md               # 用户侧自然语言话术速查
├─ bootstrap-registry.ps1         # 在任意空目录生成完整运行包
├─ LICENSE                        # MIT
├─ .gitignore
├─ scripts/
│  ├─ *.ps1                       # 13 个入口脚本
│  ├─ lib/                        # 4 个公共库
│  └─ rename/rename.ps1
├─ tools/
│  ├─ _template.md                # 从简文档模板
│  ├─ _template-detailed.md       # 详细文档模板
│  ├─ _example-bz.md              # 说明文档示例（下划线开头，不算孤儿）
│  ├─ _archive/                   # 硬删归档的文档
│  └─ _notes/                     # 补充笔记
├─ examples/
│  ├─ interfaces-bz.json          # 接口清单示例
│  └─ pipeline-example.ps1        # 解压→重命名→打包流水线示例（纯系统命令）
└─ pending/
   └─ pending-tools.json          # 自制脚本待审队列（仓库内为空模板）
```

---

## 与 Agent 配合

配套的用户侧话术见 [`USAGE_PHRASES.md`](USAGE_PHRASES.md)：用自然语言怎么说才不产生歧义。

[`AGENT_INIT_PROMPT.md`](AGENT_INIT_PROMPT.md) 是「使用约定」，核心是**交互契约**：

> 用户永远不需要自己写或粘贴 PowerShell 命令。用户用自然语言说出意图 + 必要信息，Agent 自己解析意图 → 选脚本 → 拼参数 → 执行 → 核对结果 → 用一句话回报。

几条关键约定：

1. **系统自带命令优先**：普通 zip、哈希、遍历、重命名直接用 PowerShell / `tar.exe`，不入库。
2. **检索前置**：动手前先 `route_task_v2.ps1 -Task '<描述>'`，把命中工具的接口清单注入上下文。
3. **新会话自动分层检索**：`init-discovery.ps1 -InjectPrompt` 只读，不需要批准；**绝不自动 `-Apply`**。
4. **从简原则**：简单工具不建档，接口用到再补。
5. **不可逆动作要确认**：`-Hard -PurgeDoc`、批量 `-Apply` 必须用户明确点头。
6. **维护触发**：软件升级 / 换目录 / 卸载后，用 `validate-registry.ps1` 与 `update-tool.ps1` 自愈，其它会话下次任务懒加载新 version，无需通知。

典型对话：

> 用户：「把 7-Zip 加进索引，位置 `C:\Program Files\7-Zip\7z.exe`，主要用来解压 rar」
> Agent：查重 → 判断为简单工具 → 执行 `register.ps1 -Path ... -Functions extract,compress -Tags archive,rar` → 回报「已注册 7z，version → 2」

---

## 数据文件与编码约定

| 类型 | 编码 |
|---|---|
| `.ps1` / `.md` | UTF-8 **带 BOM**（PowerShell 5.1 读中文不乱码） |
| `.json` | UTF-8 **无 BOM**（严格解析器会拒绝 BOM） |

读文本一律用 `-Encoding UTF8` 或 `[IO.File]::ReadAllText(path, [Text.Encoding]::UTF8)`；`Get-Content -Raw` 不带编码在 5.1 下默认 ANSI，中文会乱码。新建含中文的 `.ps1` 用 `[Text.UTF8Encoding]::new($true)`，写 `.json` 用 `::new($false)`。

**改了磁盘文件，记得同步 `bootstrap-registry.ps1` 里对应的 `Write-File` 模板块**——生成器内嵌了全部 32 个文件的副本，验收用例 T57 会逐块比对，不一致会报错。

---

## 开发者指南

### 跑验收测试

[`TEST_GUIDE.md`](TEST_GUIDE.md) 是完整的独立验收材料，按 P0 → P8 顺序执行即可判断有无回归：

- **铁律**：生产目录只读，所有写盘操作在隔离副本里进行，结束后删除副本并确认生产索引未变。
- 覆盖：注册 / 文档 / 审批 / Quicker / 更新 / 删除 / 检索 / 发现 / 体检 / 扫描 / 并发 / 一致性 / 全新生成，共 64 个用例。
- 标注「**回归哨兵**」的是历史已修缺陷，重点核对。
- 路径全部由文首的 `$Repo` / `$QA` 变量控制，可在本机任意位置运行。

### 自检命令

```powershell
# 全脚本语法
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $t=$null; $e=$null
  [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e) | Out-Null
  if ($e.Count) { "$($_.Name): $($e[0].Message)" }
}

# 严格 JSON（Python 可选）
python -c "import json,io; json.load(io.open('registry.json',encoding='utf-8')); print('OK')"
```

### 参与贡献

欢迎提 Issue / PR。几点建议：

- 改动脚本时同步 `bootstrap-registry.ps1` 模板块，并跑一遍 `TEST_GUIDE.md` 的 P0–P8。
- 不要提交个人 `registry.json` / `registry.md` / `pending-tools.json` / `tools\*.md` 运行数据。
- 新功能请补一个用例到验收文档（含 PASS/FAIL 断言），避免只做人工判读。
- 保持「默认只读、无变更不写盘、幂等、审批不可绕过」这几条底线。

---

## 常见问题

**Q：换电脑要改配置吗？**
不用。复制整个文件夹到任意位置即可；脚本按自身位置定位索引。只有想让索引放在仓库外时才设 `AGENT_REGISTRY`。

**Q：需要管理员权限 / 联网 / 装依赖吗？**
都不需要。唯一例外是永久设置 User 级环境变量（普通 PowerShell 即可，仍不需管理员）。

**Q：支持 Linux / macOS 吗？**
暂不支持。四级发现依赖 Windows 注册表 App Paths、`%ProgramFiles%`、`.exe` 与 Quicker 启动器，路径语义也是 Windows 的。

**Q：PowerShell 7 能用吗？**
可以。编码约定（BOM）与 `ConvertFrom-Json` 行为在 7.x 下都兼容；项目默认在 5.1 上验收。

**Q：为什么重复执行一条命令没反应？**
这是设计。无变更不写盘、不涨 `version`，输出「无变更，索引未改动」表示幂等生效。

**Q：为什么注册 `.ps1` 被拦下来了？**
自制脚本默认需要用户同意。走 `approve-tool.ps1 -List` → `-ApprovedBy` 转正；通用可复用脚本可用 `-Reusable -Reason`。

**Q：我把文件夹复制到新目录了，脚本怎么还在改旧目录的索引？**
你可能设过 User 级 `AGENT_REGISTRY` 绝对路径，它优先于默认的相对定位。按上一节的方法清除或改指向新目录即可；用 `$env:AGENT_REGISTRY` 打印当前值确认。

**Q：`tool-doc.ps1 -Check` 报孤儿文档？**
`tools\` 根目录下没有条目引用的 `.md` 会被提示。确认无用可手工删除或用 `-Hard` 清理；`_template*`、`_archive\`、`_notes\` 与 `_` 开头的文件不会误报。

**Q：索引改坏了怎么办？**
`registry.json` 是纯文本，先备份；小问题用 `validate-registry.ps1 -Apply` 自愈，严重损坏时从 `bootstrap-registry.ps1 -Root <新目录>` 生成一份空包再重新登记工具。

**Q：为什么 `registry.md` 会自动变？**
它是每次写入自动重建的人读镜像，别手写。索引放到仓库外时，镜像跟着写到索引同目录。

---

## 已知边界

- `$LASTEXITCODE=2; return` 在 `-File` 方式调用时进程退出码仍可能是 0；脚本一律用 `&` 调用并读 `$LASTEXITCODE`。
- 并发保护只保证**新增条目不丢**；两个进程同时改同一条目的字段仍是后写覆盖。
- T2 系统命令只提示不入库；Quicker 动作码不自动发现；自制脚本一律走审批——都是刻意设计。
- 体检只对 `verified=true` 的路径失效条目自动软删；未验证条目只报告。
- `bootstrap-registry.ps1` 生成的 `.md` 比源模板少一个结尾换行，是 `Write-File` 的既有行为，不算 bug。
- `rename\rename.ps1` 的大小写重命名、`examples\pipeline-example.ps1` 的解压残留属于低风险已知边界。

---

## 许可证

[MIT](LICENSE) © 2026 agent-tool-registry contributors

可以自由使用、修改、商用，只需保留版权与许可声明。
'@
# ============ scripts\update-tool.ps1 ============
Write-File "scripts\update-tool.ps1" @'
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
'@
# ============ tools\bz.md ============
Write-File "tools\_example-bz.md" @'
# 工具说明文档示例（tools\_example-bz.md）

> 这是**示例模板**，不是索引条目。文件名以 `_` 开头，因此 `tool-doc.ps1 -Check` 不会把它当成孤儿文档。
> 正式使用时无需手建文档：`register.ps1` 注册复杂工具会自动生成 `tools\<id>.md` 从简骨架。

<!-- doc_version: 1 | tool_version: <版本> | checked_at: <日期> | doc_level: detailed -->
<!-- 从简原则：只写实际用过 / 常用的接口；没用过的不预先罗列参数、开关与退出码 -->
<!-- tool-doc.ps1 -Check 会核对 tool_version 与索引 version_info.product_version -->

## 基本信息
- id / 名称：`<id>` / `<可执行文件名>`
- 位置：以 `registry.json` 的 `locator.primary` 为准（**本页不是调用入口**）
- 适用：系统自带命令处理不了的格式 / 批量 / 需要特定参数的场景
- 不适用：普通任务优先用系统自带的 `Compress-Archive` / `Expand-Archive` / `tar.exe`

## 接口清单（受管区块，由脚本同步，不要手改）
<!-- interfaces:start -->

| 接口 | 调用语法 | 说明 |
|---|---|---|
| `c` | `tool c -y out.zip <files>` | 新建包，会覆盖同名 |
| `x` | `tool x -aoa -o:<dir> <archive>` | 解压，保留目录结构 |

<!-- interfaces:end -->

## 待补
其它接口用到再补，不预先罗列。

## 维护提示
- 补接口：`record-interface.ps1 -Id <id> -Name <接口> -Syntax '<调用>' -Note '<一句话>'`，索引与本文档同步追加。
- 软删**保留**文档；`-Hard` 归档到 `tools\_archive\`；只有 `-Hard -PurgeDoc` 才彻底删除。
'@
# ============ scripts/lib/pending-store.ps1 ============
Write-File "scripts/lib/pending-store.ps1" @'
# pending-store.ps1 —— 自制脚本待审提案存储
# 由 register.ps1 / approve-tool.ps1 dot-source 引入。
# 复杂、无通用复用性的脚本只能先落在这里，用户明确同意后才允许进 registry.json。

# $scriptsDir 传调用脚本的 $PSScriptRoot（两者都在 <root>\scripts 下）
function Get-PendingFilePath([string]$scriptsDir) {
    $dir = if ($env:AGENT_REGISTRY) { Split-Path ([string]$env:AGENT_REGISTRY) -Parent }
           else { Split-Path ([string]$scriptsDir) -Parent }
    return (Join-Path $dir "pending\pending-tools.json")
}

function Read-Pending([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{
            note   = '复杂/无通用复用性的自制脚本提案队列；用户明确同意后才可进入 registry.json'
            policy = 'archive_approval_required'
            items  = @()
        }
    }
    $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $obj = $txt | ConvertFrom-Json
    if (-not ($obj.PSObject.Properties.Name -contains 'items') -or $null -eq $obj.items) {
        Add-Member -InputObject $obj -NotePropertyName 'items' -NotePropertyValue @() -Force
    }
    $obj.items = @($obj.items)   # 防止单条提案被折叠成对象
    return $obj
}

function Save-Pending([string]$path, $data) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $null; $mtx = $null; $owned = $false
    try {
        try {
            $mtx = [System.Threading.Mutex]::new($false, 'Local\AgentToolsPending_v31')
            try { $owned = $mtx.WaitOne(5000) }
            catch [System.Threading.AbandonedMutexException] { $owned = $true }
        } catch {
            $mtx = $null; $owned = $true
            Write-Warning '提案队列写锁不可用，已降级为无锁写入'
        }
        if (-not $owned) { throw "待审队列正被其他进程写入，请稍后重试" }

        # 锁内合并：别让后写进程把它人刚追加的提案整条覆盖掉
        $mine = @($data.items)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $diskObj = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $ids = @{}
                foreach ($x in $mine) { if ($x -and $x.PSObject.Properties['id']) { $ids[[string]$x.id] = $true } }
                foreach ($x in @($diskObj.items)) {
                    if ($x -and $x.PSObject.Properties['id'] -and -not $ids.ContainsKey([string]$x.id)) {
                        $mine += $x
                    }
                }
            } catch { Write-Warning ("提案队列重读失败，按内存快照写入: " + $_.Exception.Message) }
        }
        if ($data.PSObject.Properties.Name -contains 'items') { $data.items = @($mine) }
        else { Add-Member -InputObject $data -NotePropertyName 'items' -NotePropertyValue @($mine) -Force }
        $json = $data | ConvertTo-Json -Depth 10
        $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { [System.IO.File]::Replace($tmp, $path, $null) }
            catch {
                [System.IO.File]::Copy($tmp, $path, $true)
                [System.IO.File]::Delete($tmp)
            }
        } else {
            [System.IO.File]::Copy($tmp, $path, $true)
            [System.IO.File]::Delete($tmp)
        }
        $tmp = $null
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch {}
        }
        if ($mtx) {
            if ($owned) { try { $mtx.ReleaseMutex() } catch {} }
            try { $mtx.Dispose() } catch {}
        }
    }
}

function New-ProposalId([string]$toolPath) {
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($toolPath).ToLower()
    $leaf = $leaf -replace '[^a-z0-9_-]', '-'
    return "prop-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + $leaf
}
'@
# ============ scripts/approve-tool.ps1 ============
Write-File "scripts/approve-tool.ps1" @'
# approve-tool.ps1 —— 用户审批队列：列出 / 同意 / 拒绝自制脚本提案
# ⚠️ 本脚本代表「用户同意」这一动作。Agent 不得自行填写 -ApprovedBy 来绕过审批。
param(
    [switch]$List,
    [string]$Id,
    [string]$ApprovedBy,
    [switch]$Reject,
    [string]$Reason
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
. (Join-Path $PSScriptRoot "lib\pending-store.ps1")
$pendingPath = Get-PendingFilePath $PSScriptRoot
$p = Read-Pending $pendingPath
$items = @($p.items)
$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

if ($List -or -not $Id) {
    Write-Output "=== 自制脚本提案（共 $($items.Count) 条）==="
    if ($items.Count -eq 0) { Write-Output "（暂无提案）" }
    foreach ($i in $items) {
        $flag = if ([string]$i.status -eq 'pending_user_approval') { '[待用户同意]' } else { "[$($i.status)]" }
        Write-Output "$flag $($i.id)"
        Write-Output "    路径: $($i.path)"
        Write-Output "    功能: $(@($i.functions) -join ', ') | 理由: $(if($i.reason){$i.reason}else{'<无>'})"
    }
    Write-Output ""
    Write-Output "同意（须用户明确授权后执行）: .\scripts\approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'"
    Write-Output "拒绝: .\scripts\approve-tool.ps1 -Id <提案id> -Reject [-Reason '<原因>']"
    exit 0
}

$found = @($items | Where-Object { [string]$_.id -eq $Id })
if ($found.Count -eq 0) { Write-Output "❌ 未找到提案: $Id"; exit 1 }
if ($found.Count -gt 1) { Write-Output "❌ 提案 id 重复($($found.Count))，请人工核对 pending-tools.json"; exit 1 }
$item = $found[0]
if ([string]$item.status -ne 'pending_user_approval') {
    Write-Output "⚠️ 提案状态为 $($item.status)，无需重复处理"; exit 0
}
if (-not (Test-Path -LiteralPath ([string]$item.path) -PathType Leaf)) {
    Write-Output "❌ 脚本文件已不存在，提案无法转正: $($item.path)"
    Write-Output "   可用 -Reject 关闭该提案"; exit 1
}

if ($Reject) {
    Set-RegistryField $item 'status' 'rejected'
    Set-RegistryField $item 'rejected_at' $now
    Set-RegistryField $item 'rejected_reason' $Reason
    Save-Pending $pendingPath $p
    Write-Output "🗑️ 已拒绝并留痕: $Id（registry.json 未改动）"
    exit 0
}

if (-not $ApprovedBy) {
    Write-Output "🛑 必须显式提供 -ApprovedBy '<用户标识>'，且只能在用户明确同意之后执行"
    Write-Output "   本脚本不会默认取当前用户名；Agent 自行填写等于违反归档审批规则"
    exit 1
}

$reg = Get-Registry
if (@($reg.tools | Where-Object { [string]$_.locator.primary -eq [string]$item.path -and -not $_.deleted }).Count -gt 0) {
    Set-RegistryField $item 'status' 'approved'
    Set-RegistryField $item 'approved_by' $ApprovedBy
    Set-RegistryField $item 'approved_at' $now
    Set-RegistryField $item 'approved_reason' '该脚本已在索引中，仅补齐审批状态'
    Save-Pending $pendingPath $p
    Write-Output "⚠️ 该脚本已在索引中，仅把提案标记为 approved（未重复登记）"
    exit 0
}

# 转正：把用户同意作为凭证传给 register.ps1，条目会带 approval 字段
# 提案里若已带分类元数据与层级，一并带过去，避免审批后丢失 tags / keywords / category_path / tier
$metaArgs = @{}
foreach ($f in @('tags','keywords','category_path')) {
    if ($item.PSObject.Properties[$f] -and @($item.$f).Count -gt 0) {
        $metaArgs[$f] = @($item.$f) -join ','
    }
}
# 旧提案没有 tier 时按「自制脚本 = T4」补齐；越界值夹回 0..4，避免 register 参数校验失败
$metaArgs['tier'] = if ($item.PSObject.Properties['tier']) {
    [Math]::Min(4, [Math]::Max(0, [int]$item.tier))
} else { 4 }

# 一次性凭证：先写进提案队列，register.ps1 只认它，防止 Agent 自己拼 -ApprovedBy 绕过审批
$token = [guid]::NewGuid().ToString('N')
Set-RegistryField $item 'approval_token' $token
Save-Pending $pendingPath $p
& (Join-Path $PSScriptRoot "register.ps1") -Path ([string]$item.path) `
    -Functions (@($item.functions) -join ',') `
    -WhenToUse ([string]$item.when_to_use) -WhenNotToUse ([string]$item.when_not_to_use) `
    -ApprovedBy $ApprovedBy -ApprovalToken $token -Note ([string]$item.reason) @metaArgs

$reg2 = Get-Registry
$ok = @($reg2.tools | Where-Object { [string]$_.locator.primary -eq [string]$item.path -and -not $_.deleted })
if ($ok.Count -eq 0) {
    Set-RegistryField $item 'approval_token' $null
    Save-Pending $pendingPath $p
    Write-Output "❌ 转正失败，提案保持待审状态（registry.json 未写入该脚本）"
    exit 1
}
Set-RegistryField $item 'approval_token' $null
Set-RegistryField $item 'status' 'approved'
Set-RegistryField $item 'approved_by' $ApprovedBy
Set-RegistryField $item 'approved_at' $now
Set-RegistryField $item 'approved_reason' $(if ($Reason) { $Reason } else { '用户明确同意登记' })
Save-Pending $pendingPath $p
Write-Output "✅ 已按用户同意转正: $($ok[0].id) (version → $($reg2.version))"
Write-Output "   approval: user_approved by $ApprovedBy"
'@
# ============ scripts\init-discovery.ps1 ============
Write-File "scripts\init-discovery.ps1" @'
# init-discovery.ps1 —— 初始化时的分层可用工具检索（默认只读，永不自动写索引）
# 四级优先级：T1 编译器/运行时 > T2 系统自带（零级/一级，只提示不入库）>
#             T3 系统已注册的工具类软件（Bandizip/Quicker/浏览器等）> T4 其它工具软件与脚本
# 治理约束：默认 dry-run；-Apply 才登记，默认层 T1/T3（-OnlyTiers 可缩小，如仅编译器）；
#           T4 二进制需 -IncludeTier4；T4 脚本与 Quicker 动作一律不自动入库（归档审批 / 动作码由用户给）。
param(
    [switch]$Apply,
    [switch]$IncludeTier4,
    [switch]$InjectPrompt,
    [string[]]$Dirs = @(),
    [int]$MaxPerTier = 12,
    [int[]]$OnlyTiers = @(1,3)
)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
$ErrorActionPreference = 'Stop'
# -IncludeTier4 等价于把 T4 也纳入可登记层（用户显式给 -OnlyTiers 时以显式值为准）
if ($IncludeTier4 -and -not $PSBoundParameters.ContainsKey('OnlyTiers') -and 4 -notin $OnlyTiers) {
    $OnlyTiers = @($OnlyTiers) + 4
}
if ($IncludeTier4 -and $PSBoundParameters.ContainsKey('OnlyTiers') -and 4 -notin $OnlyTiers) {
    Write-Output "ℹ️ 显式 -OnlyTiers 优先，-IncludeTier4 已忽略（当前可登记层: T$(@($OnlyTiers | Sort-Object) -join '/T')）"
}

$TierNames = @{
    1 = '编译器 / 构建工具 / 语言运行时'
    2 = '系统自带命令（零级/一级，Agent 直接调用，不入库）'
    3 = '系统已注册的工具类软件（Bandizip / Quicker / 浏览器等）'
    4 = '其它工具软件与脚本'
}

# ===== T1：编译器、构建工具、语言运行时（最优先）=====
$T1 = @{}
$T1['gcc.exe']       = [PSCustomObject]@{ F=@('compile','build','c');    T=@('compile','build','c','gcc');        K=@('编译','gcc');      C='dev/compiler' }
$T1['g++.exe']       = [PSCustomObject]@{ F=@('compile','build','cpp');  T=@('compile','build','cpp','g++');      K=@('编译','g++');      C='dev/compiler' }
$T1['clang.exe']     = [PSCustomObject]@{ F=@('compile','build','c');    T=@('compile','build','c','clang');      K=@('编译','clang');    C='dev/compiler' }
$T1['clang++.exe']   = [PSCustomObject]@{ F=@('compile','build','cpp');  T=@('compile','build','cpp','clang');    K=@('编译');           C='dev/compiler' }
$T1['cl.exe']        = [PSCustomObject]@{ F=@('compile','build','cpp');  T=@('compile','build','msvc');           K=@('编译');           C='dev/compiler' }
$T1['csc.exe']       = [PSCustomObject]@{ F=@('compile','build','csharp'); T=@('compile','build','csharp');       K=@('编译');           C='dev/compiler' }
$T1['dotnet.exe']    = [PSCustomObject]@{ F=@('build','run','compile');  T=@('build','compile','dotnet','csharp'); K=@('编译','构建');  C='dev/toolchain' }
$T1['javac.exe']     = [PSCustomObject]@{ F=@('compile','java');         T=@('compile','build','java');           K=@('编译','java');     C='dev/compiler' }
$T1['go.exe']        = [PSCustomObject]@{ F=@('compile','build','go');   T=@('compile','build','go');             K=@('编译','go');       C='dev/toolchain' }
$T1['rustc.exe']     = [PSCustomObject]@{ F=@('compile','build','rust'); T=@('compile','build','rust');           K=@('编译','rust');     C='dev/compiler' }
$T1['cargo.exe']     = [PSCustomObject]@{ F=@('build','compile','rust'); T=@('build','compile','rust');           K=@('构建','rust');     C='dev/toolchain' }
$T1['make.exe']      = [PSCustomObject]@{ F=@('build','compile');        T=@('build','compile','make');           K=@('构建','make');     C='dev/toolchain' }
$T1['cmake.exe']     = [PSCustomObject]@{ F=@('build','compile');        T=@('build','compile','cmake');          K=@('构建','cmake');    C='dev/toolchain' }
$T1['ninja.exe']     = [PSCustomObject]@{ F=@('build','compile');        T=@('build','compile','ninja');          K=@('构建');           C='dev/toolchain' }
$T1['nasm.exe']      = [PSCustomObject]@{ F=@('compile','asm');          T=@('compile','asm');                    K=@('汇编');           C='dev/compiler' }
$T1['msbuild.exe']   = [PSCustomObject]@{ F=@('build','compile');        T=@('build','compile','msbuild');        K=@('构建');           C='dev/toolchain' }
$T1['python.exe']    = [PSCustomObject]@{ F=@('script','run','python');  T=@('python','script','run');            K=@('python','脚本');   C='dev/runtime' }
$T1['python3.exe']   = [PSCustomObject]@{ F=@('script','run','python');  T=@('python','script','run');            K=@('python','脚本');   C='dev/runtime' }
$T1['py.exe']        = [PSCustomObject]@{ F=@('script','run','python');  T=@('python','script','run');            K=@('python');         C='dev/runtime' }
$T1['node.exe']      = [PSCustomObject]@{ F=@('script','run','js');      T=@('node','javascript','script','run'); K=@('node','脚本');     C='dev/runtime' }
$T1['java.exe']      = [PSCustomObject]@{ F=@('run','java');             T=@('java','run');                       K=@('java');           C='dev/runtime' }
$T1['ruby.exe']      = [PSCustomObject]@{ F=@('script','run','ruby');    T=@('ruby','script','run');              K=@('ruby');           C='dev/runtime' }
$T1['php.exe']       = [PSCustomObject]@{ F=@('script','run','php');     T=@('php','script','run');               K=@('php');            C='dev/runtime' }
$T1['perl.exe']      = [PSCustomObject]@{ F=@('script','run','perl');    T=@('perl','script','run');              K=@('perl');           C='dev/runtime' }
$T1['lua.exe']       = [PSCustomObject]@{ F=@('script','run','lua');     T=@('lua','script','run');               K=@('lua');            C='dev/runtime' }
# 宿主 shell（powershell.exe / pwsh.exe / cmd.exe）属零级能力：Agent 本来就在里面跑，
# 用 Get-Command 秒得，登记进索引只会制造冗余 —— 归 T2，不进 T1。

# ===== T2：系统自带命令。零级/一级能力 Agent 本来就能快速找到，绝不入库 =====
$T2Names = @('certutil','robocopy','xcopy','fc','comp','ren','where','find','findstr',
             'makecab','cipher','tar','curl','icacls','takeown','fsutil','sfc','dism',
             'reg','tasklist','systeminfo','whoami','tree','sort','more','cmd',
             'powershell','pwsh')

# ===== T3：系统已注册 / 常见安装位置的工具类软件 =====
# Manual 不为空时只提示、不自动登记（典型：Quicker 动作必须用户提供动作码）
$T3 = @{}
$T3['bz.exe']            = [PSCustomObject]@{ F=@('extract','compress','list','test'); T=@('compress','extract','archive','zip','7z','rar'); K=@('解压','压缩','打包','归档'); C='file_operation/archive'; Manual='' }
$T3['bandizip.exe']      = [PSCustomObject]@{ F=@('extract','compress'); T=@('compress','extract','archive'); K=@('解压','压缩'); C='file_operation/archive'; Manual='' }
$T3['7z.exe']            = [PSCustomObject]@{ F=@('extract','compress','list','test'); T=@('compress','extract','archive','7z'); K=@('解压','压缩'); C='file_operation/archive'; Manual='' }
$T3['winrar.exe']        = [PSCustomObject]@{ F=@('extract','compress'); T=@('compress','extract','archive','rar'); K=@('解压','压缩'); C='file_operation/archive'; Manual='' }
$T3['rar.exe']           = [PSCustomObject]@{ F=@('extract','compress'); T=@('compress','extract','archive','rar'); K=@('解压','压缩'); C='file_operation/archive'; Manual='' }
$T3['chrome.exe']        = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web','chrome'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['msedge.exe']        = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web','edge'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['firefox.exe']       = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web','firefox'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['qqbrowser.exe']     = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web','qqbrowser'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['360chrome.exe']     = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['360se.exe']         = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['brave.exe']         = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['opera.exe']         = [PSCustomObject]@{ F=@('browser','web'); T=@('browser','web'); K=@('浏览器','网页'); C='gui/browser'; Manual='' }
$T3['git.exe']           = [PSCustomObject]@{ F=@('vcs','git','diff'); T=@('git','vcs','version_control','diff'); K=@('版本','提交','git'); C='dev/vcs'; Manual='' }
$T3['code.exe']          = [PSCustomObject]@{ F=@('editor','ide'); T=@('editor','ide','vscode'); K=@('编辑器','vscode'); C='dev/editor'; Manual='' }
$T3['ffmpeg.exe']        = [PSCustomObject]@{ F=@('convert','media'); T=@('convert','media','video','audio'); K=@('转码','视频','音频'); C='media/convert'; Manual='' }
$T3['magick.exe']        = [PSCustomObject]@{ F=@('convert','image'); T=@('convert','image'); K=@('图片','转换'); C='media/convert'; Manual='' }
$T3['everything.exe']    = [PSCustomObject]@{ F=@('search','find'); T=@('search','find','list'); K=@('搜索','查找'); C='file_operation/search'; Manual='' }
$T3['quickerstarter.exe'] = [PSCustomObject]@{ F=@('gui','automation'); T=@('quicker','gui','automation'); K=@('quicker','动作'); C='gui/quicker'; Manual='Quicker 动作启动器：动作码由用户提供，请用 register.ps1 -Quicker -ActionCode <码> 手动登记' }
$T3['quicker.exe']       = [PSCustomObject]@{ F=@('gui','automation'); T=@('quicker','gui','automation'); K=@('quicker','动作'); C='gui/quicker'; Manual='Quicker 主程序：动作登记走 register.ps1 -Quicker' }

$genericMeta = [PSCustomObject]@{ F=@('utility'); T=@('utility','misc'); K=@(); C='misc/other'; Manual='' }
$scriptMeta  = [PSCustomObject]@{ F=@('script'); T=@('script','misc'); K=@(); C='misc/script'; Manual='' }
$scriptExt   = @('.ps1','.psm1','.py','.pyw','.sh','.bat','.cmd','.js','.mjs','.vbs','.rb','.pl','.lua')
$excludeDirs = @('node_modules','.git','__pycache__','.venv','venv','obj','system volume information')
# 只比对「扫描根内部」的路径段：否则用户给 E:\venv\Tools 这类目标时，整个目录会被路径前缀误排除
function Test-ExcludedSegment([string]$full, [string]$root) {
    $rel = if ($root -and $full.Length -gt $root.Length -and $full.ToLower().StartsWith($root.ToLower())) {
        $full.Substring($root.Length)
    } else { $full }
    $segs = @(($rel.ToLower() -split '[\\/]') | Where-Object { $_ })
    foreach ($s in $segs) { if ($excludeDirs -contains $s) { return $true } }
    return $false
}
# 安装/卸载/崩溃上报类程序不是「可用工具」，扫描时直接忽略
$ignoreNames = @('uninstall.exe','unins000.exe','unins001.exe','setup.exe','installer.exe',
                 'update.exe','crashpad_handler.exe','elevation_service.exe','dxsetup.exe')
# 编译器/工具链的 bin 目录里除白名单主程序外都是附属工具（ar/as/ld/nm/addr2line…），
# 逐个当「其它工具软件」报告会淹没清单，也不该单独入库：整目录跳过非白名单 exe。
$toolchainBins = @(
    'c:\mingw64\bin', 'c:\msys64\mingw64\bin', 'c:\tdm-gcc-64\bin',
    'c:\program files\llvm\bin', 'c:\program files\go\bin', 'c:\program files\dotnet'
)

# ===== 收集原始候选（路径, 层级, 元数据, 来源）=====
$raw = New-Object 'System.Collections.Generic.List[object]'
function Add-Raw([string]$path, [int]$tier, $meta, [string]$source) {
    if (-not $path) { return }
    $script:raw.Add([PSCustomObject]@{ Path=$path; Tier=$tier; Meta=$meta; Source=$source })
}

# T1 来源 1：PATH 上的编译器 / 运行时
foreach ($name in $T1.Keys) {
    $cmds = @(Get-Command $name -ErrorAction Ignore |
              Where-Object { $_.CommandType -eq 'Application' -and $_.Source } | Select-Object -First 1)
    foreach ($c in $cmds) { Add-Raw ([string]$c.Source) 1 $T1[$name] 'PATH' }
}

# 扫描目录：默认工具/编译器常见位置 + 用户额外指定
$pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$scanDirs = @(
    'C:\mingw64\bin', 'C:\msys64\mingw64\bin', 'C:\TDM-GCC-64\bin',
    'C:\Program Files\LLVM\bin', 'C:\Program Files\Git\bin', 'C:\Program Files\dotnet',
    'C:\Program Files\nodejs', 'C:\Program Files\Go\bin',
    "$env:USERPROFILE\Tools", "$env:USERPROFILE\Scripts", "$env:USERPROFILE\Work",
    "$env:LOCALAPPDATA\Programs"
)
# 跨设备适配：本机专属目录由 AGENT_SCAN_DIRS（分号分隔）或 -Dirs 提供，不写死任何盘符
if ($env:AGENT_SCAN_DIRS) {
    $scanDirs += @($env:AGENT_SCAN_DIRS -split [IO.Path]::PathSeparator | Where-Object { $_ })
}
foreach ($d in $Dirs) { if ($d) { $scanDirs += $d } }
$scanDirs = @($scanDirs | Select-Object -Unique)
# 工具链 bin 目录从实际扫描根派生，避免硬编码漏掉 Git\bin / nodejs 等位置的附属程序
$toolchainBins = @($toolchainBins + @($scanDirs | Where-Object { $_ -and $_ -match '\\bin$' } |
    ForEach-Object { $_.ToLower().TrimEnd('\') }) | Select-Object -Unique)

foreach ($d in $scanDirs) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
    $files = @(Get-ChildItem -LiteralPath $d -Recurse -Depth 1 -File -ErrorAction Ignore |
        Where-Object {
            $_.Length -gt 0 -and
            ($_.Extension -eq '.exe' -or $scriptExt -contains $_.Extension.ToLower()) -and
            ($ignoreNames -notcontains $_.Name.ToLower()) -and
            ($T2Names -notcontains $_.BaseName.ToLower()) -and
            -not (Test-ExcludedSegment $_.FullName ([string]$d))
        } | Select-Object -First 200)
    foreach ($f in $files) {
        $leaf = $f.Name.ToLower()
        if ($T1.ContainsKey($leaf))      { Add-Raw $f.FullName 1 $T1[$leaf] '目录扫描' }
        elseif ($T3.ContainsKey($leaf))  { Add-Raw $f.FullName 3 $T3[$leaf] '目录扫描' }
        elseif ($toolchainBins -contains $d.ToLower().TrimEnd('\') -and $f.Extension -eq '.exe') { continue }
        else {
            $m = if ($scriptExt -contains $f.Extension.ToLower()) { $scriptMeta } else { $genericMeta }
            Add-Raw $f.FullName 4 $m '目录扫描'
        }
    }
}

# T3 来源 2：注册表 App Paths（系统「已注册」的软件）
$appPathRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths'
)
foreach ($root in $appPathRoots) {
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction Ignore)) {
        $leaf = ([string]$k.PSChildName).ToLower()
        if (-not $T3.ContainsKey($leaf)) { continue }
        $v = $null
        try { $v = $k.GetValue('') } catch { $v = $null }
        if (-not $v) { $v = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Ignore).'(default)' }
        if ($v) { Add-Raw ([string]$v) 3 $T3[$leaf] 'App Paths' }
    }
}

# T3 来源 3：卸载表 DisplayIcon（形如 "C:\...\app.exe",0）
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($root in $uninstallRoots) {
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction Ignore)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Ignore
        if (-not $p -or -not $p.DisplayIcon) { continue }
        $m = [regex]::Match([string]$p.DisplayIcon, '([A-Za-z]:\\[^"\r\n]*?\.exe)', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $clean = $m.Groups[1].Value
        $leaf = (Split-Path $clean -Leaf).ToLower()
        if ($T3.ContainsKey($leaf)) { Add-Raw $clean 3 $T3[$leaf] '卸载表' }
    }
}

# T3 来源 4：常见安装位置（浏览器 / 压缩软件 / Quicker）
$commonT3 = @(
    "$env:ProgramFiles\Bandizip\bz.exe", "$pf86\Bandizip\bz.exe",
    "$env:ProgramFiles\7-Zip\7z.exe", "$env:ProgramFiles\WinRAR\WinRAR.exe", "$pf86\WinRAR\WinRAR.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "$pf86\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$pf86\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Mozilla Firefox\firefox.exe", "$pf86\Mozilla Firefox\firefox.exe",
    "$env:ProgramFiles\Quicker\QuickerStarter.exe", "$pf86\Quicker\QuickerStarter.exe",
    "$env:ProgramFiles\Git\cmd\git.exe", "$env:ProgramFiles\Git\bin\git.exe"
)
foreach ($p in $commonT3) {
    if (-not $p) { continue }
    $leaf = (Split-Path $p -Leaf).ToLower()
    if ($T3.ContainsKey($leaf)) { Add-Raw $p 3 $T3[$leaf] '常见安装位置' }
}

# ===== 去重 + 验证 + 判定处置 =====
# 同路径按最小 tier 优先（编译器先于软件先于其它），再按名称稳定输出
$reg = Get-Registry
$indexPaths = @{}
# 只统计启用中的条目：软删条目不能占着路径位，否则工具重装到原路径后永远无法重新激活
foreach ($t in @($reg.tools | Where-Object { -not $_.deleted })) {
    if (-not $t.locator) { continue }
    $pp = [string]$t.locator.primary
    if ($pp) { $indexPaths[$pp.ToLower()] = [string]$t.id }
    foreach ($cp in @($t.locator.fallback.common_paths)) {
        if ($cp) { $indexPaths[([Environment]::ExpandEnvironmentVariables([string]$cp)).ToLower()] = [string]$t.id }
    }
}

$seen = @{}
$cands = @()
foreach ($r in @($raw | Sort-Object Tier, Path)) {
    $p = [Environment]::ExpandEnvironmentVariables([string]$r.Path)
    $p = $p.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    $fi = Get-Item -LiteralPath $p -ErrorAction Ignore
    if (-not $fi -or $fi.Length -le 0) { continue }   # 排除 WindowsApps 0 字节应用执行别名
    $key = $p.ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $isScript = $scriptExt -contains $fi.Extension.ToLower()
    $meta = if ($r.Meta) { $r.Meta } else { $genericMeta }
    $manual = if ($meta.PSObject.Properties['Manual']) { [string]$meta.Manual } else { '' }

    $status = if ($indexPaths.ContainsKey($key)) { '已在索引' } else { '新发现' }
    $decision = '可登记'
    if ($r.Tier -eq 2)                 { $decision = '不入库（零级/一级）' }
    elseif ($manual)                   { $decision = '需手动登记' }
    elseif ($r.Tier -eq 4 -and $isScript) { $decision = '需用户同意（归档审批）' }
    elseif ($r.Tier -eq 4 -and 4 -notin $OnlyTiers) { $decision = '只报告' }
    elseif ($OnlyTiers -notcontains $r.Tier) { $decision = '只报告' }   # 清单与 -Apply 行为保持一致
    if ($status -eq '已在索引') { $decision = '已在索引，无需写入' }
    $cands += [PSCustomObject]@{
        path=$p; name=$fi.Name; tier=[int]$r.Tier; meta=$meta; source=[string]$r.Source
        status=$status; decision=$decision; is_script=$isScript
        index_id=$(if ($indexPaths.ContainsKey($key)) { $indexPaths[$key] } else { '' })
    }
}

# ===== 同名 exe 合并：一个工具只保留一条最可靠路径 =====
# 同一软件常从多个来源被发现（PATH / App Paths / 卸载表 DisplayIcon / 常见安装位置），
# 若不合并，-Apply 会登记成 git 与 git-2 这种重复条目；优先已在索引 → 来源可靠 → 路径层级少。
$sourceRank = @{ 'PATH'=0; 'App Paths'=1; '常见安装位置'=2; '卸载表'=3; '目录扫描'=4 }
$byStatus   = @{ Expression={ if ($_.status -eq '已在索引') { 0 } else { 1 } }; Ascending=$true }
$bySource   = @{ Expression={ [int]$sourceRank[[string]$_.source] }; Ascending=$true }
$byDepth    = @{ Expression={ @($_.path -split '[\\/]').Count }; Ascending=$true }
$byLen      = @{ Expression={ $_.path.Length }; Ascending=$true }
$ordered = @($cands | Sort-Object $byStatus, $bySource, $byDepth, $byLen)
$byName = @{}; $deduped = @(); $merged = 0
foreach ($c in $ordered) {
    $k = $c.name.ToLower()
    if ($byName.ContainsKey($k)) { $merged++; continue }
    $byName[$k] = $true
    $deduped += $c
}
$byTier    = @{ Expression={ $_.tier }; Ascending=$true }
$byDecis   = @{ Expression={ $_.decision }; Ascending=$true }
$byPath    = @{ Expression={ $_.path }; Ascending=$true }
$cands = @($deduped | Sort-Object $byStatus, $byTier, $byDecis, $byPath)

# T2 单独检测（不进候选清单，只作提示）
$t2Hit = @()
foreach ($n in $T2Names) { if (Get-Command $n -ErrorAction Ignore) { $t2Hit += $n } }

# ===== 输出：索引现状 + 四层清单 =====
$live = @($reg.tools | Where-Object { -not $_.deleted })
$badPaths = 0
foreach ($t in $live) { if (-not (Resolve-Locator $t)) { $badPaths++ } }
$liveTiers = @{}
foreach ($t in $live) {
    $tv = if ($t.PSObject.Properties['tier']) { [int]$t.tier } else { 0 }
    $k = "T$tv"
    if (-not $liveTiers.ContainsKey($k)) { $liveTiers[$k] = 0 }
    $liveTiers[$k]++
}
$tierSummary = @($liveTiers.Keys | Sort-Object | ForEach-Object { "$_=$($liveTiers[$_])" }) -join ' / '

Write-Output "=== 初始化分层可用工具检索 $(if($Apply){'[APPLY 写入模式]'}else{'[只读 dry-run]'}) ==="
Write-Output "索引: version=$($reg.version) | 启用工具 $($live.Count) | 路径失效 $badPaths | Quicker 动作 $(@($reg.quicker_actions | Where-Object { -not $_.deleted }).Count)"
if ($tierSummary) { Write-Output "索引层级分布: $tierSummary（无 tier 字段记作 T0）" }
if ($badPaths -gt 0) { Write-Output "  ⚠️ 有 $badPaths 个条目路径失效：先跑 validate-registry.ps1 看报告，确认后 -Apply 自愈" }
Write-Output ""

for ($tier = 1; $tier -le 4; $tier++) {
    Write-Output "--- T$tier  $($TierNames[$tier]) ---"
    if ($tier -eq 2) {
        Write-Output "  $($t2Hit.Count) 个系统自带能力可用，全部【不入库】：$($t2Hit -join ', ')"
        Write-Output "  规则：零级/一级工具 Agent 本来就能快速找到（Get-Command / 内置命令），写进索引只会制造冗余。"
        Write-Output ""
        continue
    }
    $group = @($cands | Where-Object { $_.tier -eq $tier })
    if ($group.Count -eq 0) { Write-Output "  <未发现>"; Write-Output ""; continue }
    $shown = @($group | Select-Object -First $MaxPerTier)
    foreach ($c in $shown) {
        $mark = switch ($c.decision) {
            '可登记'                { '✔ 可登记' }
            '已在索引，无需写入'    { '✓ 已入库' }
            '只报告'                { '○ 只报告' }
            '需用户同意（归档审批）' { '⛔ 需审批' }
            '需手动登记'            { '✋ 需手动' }
            default                 { '· ' + $c.decision }
        }
        $fn = @($c.meta.F) -join '/'
        $tag = if ($c.status -eq '已在索引') { "（索引 id=$($c.index_id)）" } else { '' }
        Write-Output "  $mark | $($c.name) | $fn | $($c.status)$tag"
        Write-Output "        路径: $($c.path)"
        Write-Output "        来源: $($c.source) | 处置: $($c.decision)"
        if ($c.decision -eq '需手动登记') { Write-Output "        $($c.meta.Manual)" }
        if ($c.decision -eq '需用户同意（归档审批）') { Write-Output "        脚本不自动入库：用 register.ps1 生成提案，用户同意后 approve-tool.ps1 转正" }
    }
    if ($group.Count -gt $shown.Count) { Write-Output "  … 另有 $($group.Count - $shown.Count) 项未显示（调大 -MaxPerTier 可看全）" }
    Write-Output ""
}

$effective = "T$(@($OnlyTiers | Sort-Object) -join '/T')"
$addable = @($cands | Where-Object { $_.status -eq '新发现' -and $_.decision -eq '可登记' -and $OnlyTiers -contains $_.tier })
$approval = @($cands | Where-Object { $_.decision -eq '需用户同意（归档审批）' })
Write-Output "可登记层: $effective | 汇总: 新发现可登记 $($addable.Count) | 已在索引 $(@($cands | Where-Object { $_.status -eq '已在索引' }).Count) | 需审批脚本 $($approval.Count) | 只报告 $(@($cands | Where-Object { $_.decision -eq '只报告' }).Count) | 同名路径已合并 $merged"

# ===== -Apply：只对「可登记」候选批量写入，一次 Save-Registry（version 只 +1）=====
if ($Apply) {
    if ($addable.Count -eq 0) {
        Write-Output "无需写入：没有新的可登记候选，索引未改动。"
    } else {
        $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        $ids = @()
        foreach ($c in $addable) {
            $fi = Get-Item -LiteralPath $c.path
            $fp = [PSCustomObject]@{
                product_version = $(if ($fi.VersionInfo.ProductVersion) { ([string]$fi.VersionInfo.ProductVersion).Trim() } else { $null })
                file_size       = [long]$fi.Length
                modified        = $fi.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
                checked_at      = $now
            }
            # 软删过的同一路径重新出现（重装 / 自愈）：原地重新激活，复用 id 与 added_at
            $restored = Restore-SoftDeletedTool $reg $c.path
            if ($restored) {
                Set-RegistryField $restored 'version_info' $fp
                Set-RegistryField $restored 'verified' $true
                Set-RegistryField $restored 'last_checked' $now
                Set-RegistryField $restored 'tier' ([int]$c.tier)
                Set-RegistryField $restored 'discovery_source' $c.source
                $ids += [string]$restored.id
                continue
            }
            $base = [System.IO.Path]::GetFileNameWithoutExtension($c.name).ToLower()
            $newId = New-UniqueToolId $base $reg
            # 与手写索引 / route_task_v2 的打分格式一致：category_path 是分段数组而非单串
            $catParts = @(([string]$c.meta.C) -split '[\\/,]' | Where-Object { $_ })
            $entry = [PSCustomObject]@{
                id=$newId; name=$c.name; type='binary'; tier=[int]$c.tier
                functions=@($c.meta.F); platform=@('windows')
                tags=@($c.meta.T); keywords=@($c.meta.K); category_path=$catParts
                locator=[PSCustomObject]@{
                    primary=$c.path
                    fallback=[PSCustomObject]@{ registry=$null; common_paths=@(); search_path_env=$true }
                }
                example=''; when_to_use="初始化分层检索自动登记（T$($c.tier)：$($TierNames[$c.tier])）"
                when_not_to_use='系统自带命令能完成同一任务时优先直用'
                verified=$true; deleted=$false; deleted_at=$null; last_checked=$now
                added_by='init-discovery'; added_at=$now; usage_page=$null
                version_info=$fp; discovery_source=$c.source
            }
            $reg.tools += $entry
            $ids += $newId
        }
        Save-Registry $reg
        Write-Output "[Registry] 操作: init-discovery | 工具: $($ids -join ', ') | 变更: 新增/重新激活 $($ids.Count) 条（T$(@($addable | ForEach-Object { $_.tier } | Sort-Object -Unique) -join '/T')） | version: $($reg.version)"
    }
} else {
    Write-Output "只读，未写索引。确认清单后执行（-MaxPerTier 99 可看全）："
    Write-Output "  .\scripts\init-discovery.ps1 -Apply                 # T1 + T3（默认）"
    Write-Output "  .\scripts\init-discovery.ps1 -Apply -OnlyTiers 1    # 仅编译器"
    Write-Output "  .\scripts\init-discovery.ps1 -Apply -IncludeTier4   # 含 T4 二进制"
}

# ===== 可选：输出可注入 Agent 的分层能力片段 =====
if ($InjectPrompt) {
    Write-Output ""
    Write-Output "=== 以下注入 Agent Prompt ==="
    Write-Output "本机工具能力（优先级 T1 编译器 > T3 已注册软件 > T4 其它；T2 系统命令直接调用、不入库）："
    for ($tier = 1; $tier -le 4; $tier++) {
        if ($tier -eq 2) {
            Write-Output "- [T2 直接调用，不查索引] $($t2Hit -join ', ')"
            continue
        }
        foreach ($c in @($cands | Where-Object { $_.tier -eq $tier } | Select-Object -First $MaxPerTier)) {
            $st = if ($c.status -eq '已在索引') { "已入库 id=$($c.index_id)" } else { $c.decision }
            Write-Output "- [T$tier] $($c.name): $(@($c.meta.F) -join ',') | $($c.path) | $st"
        }
    }
    Write-Output "索引 version=$($reg.version)，每次任务请用 route_task_v2.ps1 重新检索，不要把本清单背进长期记忆。"
    Write-Output "T4 自制脚本须用户同意才能进索引；软件更新/卸载走 validate-registry.ps1 / unregister.ps1。"
}
'@
# ============ scripts/tool-doc.ps1 ============
Write-File "scripts/tool-doc.ps1" @'
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
'@
# ============ scripts/lib/doc-fields.ps1 ============
Write-File "scripts/lib/doc-fields.ps1" @'
# doc-fields.ps1 —— 工具文档字段的公共解析（由 register.ps1 / update-tool.ps1 dot-source）
# 结构化接口清单让后来的 Agent 不必再 --help 试探；写入入口统一在这里解析与校验。
function Test-DocLevelValue([string]$v) {
    return ($v -in @('none','brief','detailed'))
}

# 读接口清单 JSON：支持顶层数组，或 {"interfaces": [...]} 包装
# 每条：{"name":"c","syntax":"bz c ...","note":"新建压缩包"}
function Read-InterfaceList([string]$file) {
    if (-not $file) { return @() }
    $rp = Resolve-Path -LiteralPath $file -ErrorAction Ignore
    if (-not $rp) { throw "接口清单文件不存在: $file" }
    $raw = [System.IO.File]::ReadAllText([string]$rp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $arr = @()
    if ($raw -is [array]) { $arr = @($raw) }
    elseif ($raw -and $raw.PSObject.Properties['interfaces']) { $arr = @($raw.interfaces) }
    elseif ($raw -and $raw.PSObject.Properties['name'])       { $arr = @($raw) }
    else { throw "接口清单格式不支持：需要顶层数组、单条接口对象，或 {`"interfaces`": [...]}" }
    $out = @()
    foreach ($i in $arr) {
        if (-not $i -or -not ($i.PSObject.Properties['name']) -or -not $i.name) { continue }
        $out += [PSCustomObject]@{
            name   = [string]$i.name
            syntax = if ($i.PSObject.Properties['syntax']) { [string]$i.syntax } else { '' }
            note   = if ($i.PSObject.Properties['note'])   { [string]$i.note }   else { '' }
        }
    }
    return $out
}

# 幂等比较用：只取业务键 name/syntax/note。
# 不能用整对象 JSON —— record-interface.ps1 补写的接口带 used_count / last_used / added_from_task，
# 与接口清单文件的三字段对象必然不同，会把「内容没变」误判为变更并抹掉使用统计。
function Get-InterfaceFingerprint($list) {
    if (-not $list -or @($list).Count -eq 0) { return '' }
    $rows = @()
    foreach ($i in @($list)) {
        if (-not $i) { continue }
        $n = if ($i.PSObject.Properties['name'])   { [string]$i.name }   else { '' }
        $s = if ($i.PSObject.Properties['syntax']) { [string]$i.syntax } else { '' }
        $d = if ($i.PSObject.Properties['note'])   { [string]$i.note }   else { '' }
        $rows += ($n + "`t" + $s + "`t" + $d)
    }
    return ($rows -join "`n")
}
'@
# ============ tools/_template-detailed.md ============
Write-File "tools/_template-detailed.md" @'
# {工具名} 说明文档（复杂工具 / 接口较多时填写，从简）

<!-- doc_version: 1 | tool_version: {产品版本} | checked_at: {YYYY-MM-DD} | doc_level: detailed -->
<!-- 复核头：tool_version 要与 registry.json 的 version_info.product_version 一致，tool-doc.ps1 -Check 会核对 -->
<!-- 从简原则：只写「实际用过」或「确实常用」的接口；基本用不上、没使用过的功能与接口不要预先详细说明 -->

## 基本信息
- id / 名称：`{id}` / `{name}`
- 位置：`{locator.primary}`（索引里永远保留 exe 路径，本文档不是调用入口）
- 功能标签：{functions}　|　层级：T{tier}

## 接口清单（受管区块，由脚本同步，不要手改）
<!-- interfaces:start -->
| 接口 | 调用语法 | 说明 |
|---|---|---|
| `{已用接口1}` | `{syntax}` | {一句话说明} |
<!-- interfaces:end -->

> 这里只放已用过 / 常用的接口。没用过的接口**不要**预先写参数表、开关表、退出码表。
> 任务里真正用到新接口时，在任务之余补写：
> `.\scripts\record-interface.ps1 -Id {id} -Name <接口> -Syntax '<调用>' -Note '<一句话>' [-Task '<任务>']`
> 该命令会同时更新索引 `interfaces` 与本文档的受管区块。
> 索引里的 `interfaces` 由 `route_task_v2.ps1 -InjectPrompt` 一次注入，常见任务无需读本页。

## 典型调用
```powershell
# 只放可复制、确实跑通过的最小示例
```

## 坑 / 备注
- 只在踩过之后写；没遇到过的失败场景不要预先罗列。

## 版本复核
- 升级后：`validate-registry.ps1 -Apply` → `tool-doc.ps1 -Check` → 接口有变才更新 → `update-tool.ps1 -Id {id} -DocChecked`
'@
# ============ examples/interfaces-bz.json ============
Write-File "examples/interfaces-bz.json" @'
[
  { "name": "c", "syntax": "bz c -y -fmt:zip out.zip <files>", "note": "新建包,会覆盖同名" },
  { "name": "x", "syntax": "bz x -aoa -o:<dir> <archive>", "note": "解压,保留目录结构" },
  { "name": "l", "syntax": "bz l <archive>", "note": "列出包内容,解压前确认" }
]
'@
# ============ scripts\lib\doc-lifecycle.ps1 ============
Write-File "scripts\lib\doc-lifecycle.ps1" @'
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
'@
# ============ scripts\record-interface.ps1 ============
Write-File "scripts\record-interface.ps1" @'
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
'@
# ============ tools\_archive\README.md ============
Write-File "tools\_archive\README.md" @'
# tools\_archive（说明文档归档区）

硬删除工具时，`unregister.ps1 -Hard` 会把该条目 `usage_page` 指向的说明文档**移出 `tools\` 根目录**，按
`<id>-<时间戳>.md` 存到这里；索引条目本身同时物理移除。这样「删除工具 = 索引 + 说明文档一起消失」，
但历史文档仍可回溯，不会不可逆丢内容。

- 彻底不保留：加 `-PurgeDoc`，文档直接删除（不可恢复，请确认后再用）。
- 软删除（不带 `-Hard`）：文档**保留**，因为条目随时可能用 `register.ps1` 重新激活。
- 被多个条目共享的文档、以 `_` 开头的模板、`tools\` 之外的路径：**一律不动**。
- 本目录以 `_` 开头，`tool-doc.ps1 -Check` 的孤儿文档检测会跳过它。
- 清理归档文件属于人工决定，脚本不会自动删除本目录内容。
'@
# ============ tools\_notes\7z.md ============
Write-File "tools\_notes\7z.md" @'
# 7-Zip
- 功能: compress/extract/list/test
- 常用: `7z x a.7z -oC:\out` | `7z a out.7z .\dist\*` | `7z l a.zip` | `7z t a.7z`
- 坑: `-o` 后无空格；rar 需 UnRAR
- ✅ 大包/分卷(`-v500m`)/加密(`-p`)  ❌ 单文件轻量
'@
# ============ tools\_notes\gcc.md ============
Write-File "tools\_notes\gcc.md" @'
# GCC (MinGW-w64 / MSYS2)
- 功能: compile(c/c++)
- 环境: PATH 含 mingw64\bin
- 常用:
  - `gcc main.c -o main.exe`
  - `gcc -g main.c -o main.exe` （带调试符号）
  - `gcc -O2 main.c -o main.exe` （优化）
  - `g++ main.cpp -o main.exe -std=c++17`
- 链接 Win32 库: `-lwinmm` `-lgdi32` `-luser32`
- 坑: Windows 下缺 DLL 会运行时报错；交叉编译需指定 target
- ✅ 本地编译 C/C++  ❌ 解释型任务
'@
# ============ tools\_notes\git.md ============
Write-File "tools\_notes\git.md" @'
# Git for Windows
- 功能: version-control/vcs/clone/commit/diff
- 常用:
  - `git init` / `git clone <url>`
  - `git add .` / `git commit -m "msg"` / `git status`
  - `git diff` / `git diff --stat`
  - `git pull` / `git push -u origin main`
  - `git log --oneline --graph`
- 大文件: 配 Git LFS
- 忽略: `.gitignore`
- ✅ 代码/配置版本管理  ❌ 大二进制频繁变更
'@
# ============ tools\_notes\README.md ============
Write-File "tools\_notes\README.md" @'
# tools\_notes（通用知识笔记，不绑定索引条目）

这里放的是**不对应任何已注册工具**的通用笔记，例如 `7z.md`（本机未安装 7-Zip 时的背景说明）、
`gcc.md` / `git.md`。它们不是 `usage_page`，不会被索引引用，也不会被
`tool-doc.ps1 -Check` 的孤儿文档检测计入（检测只扫 `tools\` 根目录、`_` 开头的目录一律跳过）。

将来真的安装并注册了对应工具，可以把笔记挪回 `tools\` 根目录，用
`update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocChecked` 绑定成正式说明文档。

按从简原则，这里也只写实际会用到的内容；没用过的功能不要预先堆参数。
'@


# ============ USAGE_PHRASES.md ============
Write-File "USAGE_PHRASES.md" @'
# 用户话术速查（USAGE_PHRASES）

> 面向**用户**：用自然语言怎么跟 Agent 说，才能准确操作工具索引、不产生歧义。
> 面向 **Agent** 的完整规则在 [`AGENT_INIT_PROMPT.md`](AGENT_INIT_PROMPT.md)；本文是那份规则反过来推导出的「用户侧说法」，两篇配套看。
> 文中 `<...>` 请替换为本机实际值；本文不含任何机器专属路径或个人数据。

---

## 0. 交互契约：用户不写命令

**用户永远不需要自己写或粘贴 PowerShell 命令。** 说出「意图 + 必要信息」即可，Agent 自己解析意图 → 选脚本 → 拼参数 → 执行 → 核对结果 → 用一句话回报。

唯一例外：明确说「**给我命令我自己跑**」，Agent 才会把代码块贴给你。

---

## 1. 最大的歧义源：先分清两个问题

| 你想问的 | 必须出现的词 | Agent 会做什么 |
|---|---|---|
| **索引里已登记**了什么 | 「索引里**已登记**的」 | `route_task_v2.ps1 -All` / `tool-doc.ps1 -List`（只读） |
| **本机装了**什么（还没登记） | 「**四级发现**」「本机有哪些」+「只报告」 | `init-discovery.ps1 -InjectPrompt`（只读） |

⚠️ 只说「有哪些工具能用」是歧义的：规则表把它列在「只读检索并汇报」，但实际输出会同时带分层提示。
空索引下两者答案完全不同（一个是 0 个，一个是列一堆编译器）。**务必带上「已登记的」或「本机发现」**。

---

## 2. 查询类

| 目的 | 推荐话术 |
|---|---|
| 列全部已登记 | 「列一下工具索引里**已登记**的工具有哪些，包含 id、路径和用途」 |
| 按能力找 | 「索引里有没有能解压 rar 的工具？」 |
| 找工具干活 | 「我要解压这个 7z 包，先检索一下该用哪个工具」 |
| 看某个工具详情 | 「把 **bz** 的接口清单给我看看」／「展开 **bz** 的完整文档」 |
| 本机发现（不登记） | 「跑一次本机**四级发现**，**只报告、先别登记**，看看有哪些编译器和已装软件」 |
| 两个都要 | 「先看索引里已登记了什么，再跑一次四级发现，告诉我哪些值得补进索引——**都只报告，别写盘**」 |
| 文档体检 | 「检查一下工具文档有没有孤儿、版本头过期、接口表和索引不一致的」 |
| 待审提案 | 「列一下待审提案」 |

---

## 3. 添加类（三要素：路径 + 用途 + 类型）

**最稳的完整句式**：
> 「把 7-Zip 加进工具索引，路径是 `C:\Program Files\7-Zip\7z.exe`，主要用来解压和压缩 rar/7z，顺手打上 archive 标签」

- ✅ **必须给完整绝对路径**。规则明确「不猜路径」，不给只会追问你一句。
- ✅ 用途不给也行（Agent 会从工具名补 1–3 个 functions/tags，且**不会留空**，否则以后检索不到），但给了命中率更高。
- ❌ 别只说「把 Bandizip 加进索引」——缺路径，必然追问。

**复杂工具（带接口建档）**：
> 「把 bz 登记为**复杂工具**，路径 `<bz.exe 完整路径>`，并给这几个接口建档：c 新建包 `bz c -y out.zip <files>`、x 解压 `bz x -aoa -o:<dir> <archive>`」

**Quicker 兜底动作（必须给动作码）**：
> 「加一个 Quicker 兜底动作，动作码 **SHOT**，用途是截图」

**自制脚本（会走审批门禁，话术要预判）**：
> 第一步：「把 `<脚本路径>` 登记成工具」→ 会被拦下，只生成待审提案，索引 version 不变
> 第二步：「我批准提案 `<提案id>`，**批准人写 `alice`**」／「拒绝提案 `<提案id>`，原因是不满足复用条件」
> 或一步到位：「这是**通用可参数化复用**的脚本，复用场景是 XXX，按可复用直接登记」

⚠️ 批准人必须是**可确认的用户标识**，Agent 不得填自己、不得默认取当前用户名。转正唯一入口是 `approve-tool.ps1`。

---

## 4. 修改类（三要素：哪个工具 + 改哪个字段 + 改成什么）

| 目的 | 推荐话术 |
|---|---|
| 换路径 | 「把工具 **bz** 的路径改成 `<新路径>`」 |
| 补标签 | 「给 **bz** **补一个**标签 qa」 |
| 换标签 | 「把 **bz** 的标签**整体换成** archive,zip,qa」 |
| 版本刷新 | 「**bz** 升级到新版本了，刷新一下它的版本指纹」 |
| 改文档页 | 「把 **bz** 的用法页换成 `tools/bz-v2.md`」 |
| Quicker 改码 | 「把动作 **quicker-SHOT** 的动作码改成 SHOT2」 |
| 只看不改 | 「看一下 **bz** 现在登记的字段，别改」 |

⚠️ 四个高频坑：
1. 别用「那个压缩工具」——可能多个匹配，规则禁止「拿相似 id 凑数」，会追问。**带上 id 或唯一名字**。
2. 「改一下标签」有歧义：**追加** vs **替换**。说「补一个」或「整体换成」。
3. 别说「删了重新注册」——规则明令禁止，会丢 `id` 和 `added_at`，一律原地改。
4. 别让 Agent 直接手改 `registry.json`——索引与说明文档由脚本自动联动，手工改会破坏一致性。

---

## 5. 删除类（三级，必须说清档位）

| 话术 | 实际结果 |
|---|---|
| 「把 **bz** 从索引里删掉」 | **默认软删**（`deleted=true`），可原地恢复，说明文档保留 |
| 「把 **bz** 彻底从索引移除，文档归档保留」 | 硬删（`-Hard`），条目物理移除，文档移入 `tools\_archive\` |
| 「把 **bz** 彻底删除，连说明文档一起删干净」 | `-Hard -PurgeDoc`，**不可恢复**，Agent 会再向你确认一次 |
| 「恢复 **bz**」 | 重新注册同路径，复用原 id，不会产生 `bz-2` |

⚠️ 「删干净」「清掉」这类模糊词，按规则只会走软删。真要硬删，必须出现「**彻底**」并说明文档怎么处理。

---

## 6. 维护 / 其它

| 场景 | 推荐话术 |
|---|---|
| 软件升级 / 搬家 / 卸载 | 「Bandizip 换到 D 盘了，**先体检只给报告，我确认后再修**」 |
| 索引体检 | 「跑一次索引体检，**只报告别写盘**」 |
| 任务里用到新接口 | 「刚才用到 bz 的 l 接口（列包内容，命令 `bz l <archive>`），顺手记进接口清单」 |
| 批量登记发现结果 | 「把刚才四级发现里的 **T1 编译器**登记进索引」（明确层级，`-Apply` 才写盘） |
| 想自己拿命令 | 「**给我命令我自己跑**」（唯一能让 Agent 贴代码块的说法） |

### ⚠️ 特别注意：`scan-directory` 会直接写盘

`scan-directory.ps1` **没有 `-Apply` 开关**，扫到 `python.exe` / `gcc.exe` / `pyautogui` 等运行时或自动化库会**直接写入索引**。
所以「扫一下 `<目录>`，先只报告」这句话对它**无效**。想只读，改用：
> 「用**四级发现**看看 `<目录>` 里有什么，**只报告、别登记**」

---

## 7. 别这么说（容易白说或被误解）

| ❌ 别这么说 | 原因 |
|---|---|
| 直接粘一段 PowerShell 命令 | 交互契约规定用户不用写命令 |
| 「刷新一下」「同步给其它会话」 | 其它会话下次任务**懒加载**新 version，不需要通知 |
| 单独说「初始化」 | 规则明确「**不自动 `-Apply`**」。想看就说「只报告」，想登记就说「登记进索引」 |
| 「让索引帮我写段代码」 | 索引只回答「本机有哪些工具、在哪、怎么调」，写代码是 Agent 的职责 |
| 「把工具清单记进你的长期记忆」 | 规则明确「不要把工具清单背进长期记忆」，每次任务重新读盘 |

---

## 8. 空索引下的预期

仓库自带的是**空索引模板**（`version=1` / `tools=[]` / `quicker_actions=[]`），所以刚 clone 完说「索引里已登记了哪些工具」，Agent 会回报「索引为空」，`route_task_v2.ps1 -All` 会提示「先看系统自带命令，必要时 `register.ps1` / `scan-directory.ps1 -Quick`」——**这是正常的，不是坏了**。

想看到内容，先跑「四级发现只报告」，再明确说「把哪些登记进索引」。
'@
