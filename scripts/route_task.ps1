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
