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
