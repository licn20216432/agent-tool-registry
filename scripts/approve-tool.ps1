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
