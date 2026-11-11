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
