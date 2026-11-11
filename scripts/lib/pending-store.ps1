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
