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
