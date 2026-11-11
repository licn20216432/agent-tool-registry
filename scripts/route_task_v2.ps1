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
