# AgentTools 功能验收测试文档

> 适用对象：仓库根目录 `$Repo`（agent-tool-registry v3.1，仓库自带**空索引模板** `version=1 / tools=[]`）
> 文档日期：2026-11-09
> 用途：**把本文连同项目目录交给另一个 Agent / 另一个会话**，它无需了解本项目的开发历史，按本文从上到下执行即可判断各功能是否完整、有无回归。
> 本文件是外部验收材料，**不参与 `bootstrap-registry.ps1` 模板同步**；全新生成的运行包里没有本文件属于正常现象。

---

## 0. 给接手 Agent 的角色指令（建议原文复制给它）

```
你是独立验收测试员。被测项目在仓库根目录 $Repo（Windows / PowerShell 5.1）。
请完整阅读 TEST_GUIDE.md，然后严格按 P0 → P8 的顺序执行其中的 PowerShell 代码块。

铁律：
1. 生产目录 $Repo 只读。所有会写盘的操作必须在隔离副本 $QA（默认 $env:TEMP\_AgentSim_QA）内进行。
2. 不要把 $env:AGENT_REGISTRY 指回生产目录后执行任何 -Apply / 注册 / 更新 / 删除。
3. 不要对生产目录运行 bootstrap-registry.ps1、不要带 -Force、不要用 -Hard -PurgeDoc。
4. 每个代码块都自带「公共前缀」，即使每次调用是新进程也要重新贴一遍。
5. 发现问题只记录，不要自行修改生产文件；记录到「文件:行号 + 实际输出 + 复现命令」。
6. 结束后必须删除 $QA，并确认生产 registry.json 的 version 与工具列表未变。

交付：按第 8 节的报告模板输出逐用例 PASS/FAIL 表 + 总结论 + FAIL 明细。
不要输出「看起来没问题」这类模糊结论；每条结论必须对应一个 PASS/FAIL 断言。
```

---

## 1. 被测对象速览

| 项 | 说明 |
|---|---|
| 真源 | `registry.json`（机器读，UTF-8 **无 BOM**），顶层含 `version` / `tools[]` / `quicker_actions[]` |
| 人读镜像 | `registry.md`（每次写入自动重建，必须与 json 同目录） |
| 提案队列 | `pending\pending-tools.json`（自制脚本待审，UTF-8 无 BOM） |
| 定位变量 | `$env:AGENT_REGISTRY`，**决定所有脚本读哪份索引、镜像写到哪里** |
| 两类实体 | `tools[]`（普通工具/脚本）与 `quicker_actions[]`（GUI 兜底动作，`id=quicker-<动作码>`） |
| 编码约定 | `.ps1` / `.md` 必须 UTF-8 **带 BOM**；`.json` 必须 UTF-8 **无 BOM**；读文本一律 `-Encoding UTF8` 或 `ReadAllText(..., UTF8)` |
| 写入规则 | 每次真实变更 `version + 1`；无变更不得写盘；默认 dry-run，`-Apply` 才落盘；锁内合并 + 原子替换 |

**入口脚本清单**（`scripts\` 下）：`register.ps1`、`update-tool.ps1`、`unregister.ps1`、`approve-tool.ps1`、`record-interface.ps1`、`validate-registry.ps1`、`init-discovery.ps1`、`scan-directory.ps1`、`route_task.ps1`、`route_task_v2.ps1`、`tool-doc.ps1`、`registry-sync.ps1`、`rename\rename.ps1`；`lib\` 下 4 个 dot-source 库。共 19 个 `.ps1`。

---

## 2. 覆盖矩阵（测试用例总览）

| 组 | 批次 | 覆盖功能 | 用例编号 |
|---|---|---|---|
| A 注册与文档 | P1 | 简单工具零文档、复杂工具从简骨架、接口清单、幂等、接口补写、复核、`-PurgeDoc` 保护 | T01–T13 |
| B 审批与 Quicker | P2 | 自制脚本门禁、凭证防绕过、提案转正、提案幂等、Quicker 注册/更新/改码/软删/恢复 | T14–T24 |
| C 更新与删除 | P3 | 原地更新、改路径、改文档页归档、软删保留文档、软删重注册复用 id、硬删归档、`-PurgeDoc` 彻底删 | T25–T32 |
| D 检索/发现/校验/扫描 | P4 | 打分检索、`-All` 真全量、TopN、无命中回退、注入接口清单、四级发现只读、`-Apply` 幂等、体检无幻写、扫描扩展名白名单 | T33–T46 |
| E 并发与一致性 | P5 | 并发新增不丢条目、镜像跟随环境变量、无残留临时文件、严格 JSON、镜像版本一致 | T47–T51 |
| F 生产只读终检 | P6 | 全脚本语法、编码、JSON、文档一致性、只读入口不写盘、bootstrap 模板块一致 | T52–T57 |
| G 全新生成 | P7 | bootstrap 在空目录生成完整包、空索引、规则与修复标记带入 | T58–T64 |

P8 无编号断言，输出 `FINAL` 行确认生产未被污染。标注「**回归哨兵**」的用例对应历史已修缺陷，必须重点核对：T10/T11/T12/T13（接口与幂等）、T15/T19（审批凭证）、T28/T29（软删复用 id）、**T30/T31（硬删不得被并发合并捡回）**、T33（`-All`）、T39/T41（初始化只读与自愈）、T43（扫描白名单）、T45/T46（体检）、T47/T48（并发与镜像）、T61/T62/T64（修复带入新包）。

---

## 3. 公共前缀（每个批次代码块都已自带）

> **路径配置**：所有批次只用两个变量 —— ` $Repo `（仓库根目录，默认当前目录，可用环境变量 AGENT_TOOLS_REPO 覆盖）与 ` $QA `（隔离副本，默认 $env:TEMP\_AgentSim_QA）。在仓库根目录打开 PowerShell 顺序执行即可；换机器、换盘符、换目录都不用改代码。

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function GetT([string]$id) { @((RR).tools | Where-Object { $_.id -eq $id })[0] }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }
function State([string]$t) { $r = RR; "STATE $t : v=$($r.version) tools=$(@($r.tools).Count) quicker=$(@($r.quicker_actions).Count)" }
```

`CK` 输出的 `PASS` / `FAIL` 就是报告数据源；**出现任何 FAIL 都要记录并继续跑完后续批次**，不要中途停止。

---

## 4. 批次执行

### P0 · 准备隔离副本（只跑一次，纯 PowerShell）

> 用同一语言准备+运行，避免跨工具调用时文件视图不一致。此批次会把副本里 `bz` 的路径指向假文件并清空版本指纹，使测试**不依赖本机是否安装 Bandizip**。

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$src = $Repo; $QA = Join-Path $env:TEMP '_AgentSim_QA'
if (Test-Path -LiteralPath $QA) { Remove-Item -LiteralPath $QA -Recurse -Force }
# 目标目录必须不存在：Copy-Item 会自行创建并把 src 的内容平铺进去（若先建目录会多套一层 AgentTools）
Copy-Item -LiteralPath $src -Destination $QA -Recurse -Force
$F = "$QA\fake"; New-Item -ItemType Directory -Force -Path $F | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
foreach ($n in @('alpha.exe','beta.exe','gamma.exe','delta.exe','epsilon.exe','zeta.exe','cong1.exe','cong2.exe','bz-placeholder.exe')) {
  [System.IO.File]::WriteAllBytes((Join-Path $F $n), [byte[]](0x4D,0x5A))
}
foreach ($n in @('selenium-notes.md','opencv_logo.png')) {
  [System.IO.File]::WriteAllText((Join-Path $F $n), 'not a tool', $utf8)
}
[System.IO.File]::WriteAllText((Join-Path $F 'helper.ps1'), 'Write-Output hi', $utf8)
$il = @(
  [PSCustomObject]@{ name='c'; syntax='alpha c -y out.zip'; note='new archive' },
  [PSCustomObject]@{ name='x'; syntax='alpha x -y';          note='extract' }
) | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $F 'ifaces.json'), $il, $utf8)
# 仓库自带空索引模板：在「副本」里造一条基准条目 bz，供 T48 镜像测试与 T54/P8 快照比对使用。
# 已有 bz 的索引会跳过；这段只改副本，生产索引始终保持起始状态。
$p = "$QA\registry.json"
$o = [System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
if (@($o.tools | Where-Object { $_.id -eq 'bz' }).Count -eq 0) {
  $bz = [PSCustomObject]@{
    id='bz'; name='bz.exe'; type='binary'
    functions=@('extract','compress','list','test'); platform=@('windows')
    locator=[PSCustomObject]@{
      primary="$F\bz-placeholder.exe"
      fallback=[PSCustomObject]@{ registry=$null; common_paths=@(); search_path_env=$true }
    }
    verified=$true; deleted=$false; deleted_at=$null; last_checked=$null
    added_by='qa'; added_at='2026-01-01T00:00:00'; usage_page=$null; version_info=$null
    # 基准条目按「复杂工具」构造：T36 需要有一条带接口清单的工具来验证 -InjectPrompt 注入内容
    doc_level='detailed'; tier=3
    tags=@('compress','extract','archive','zip','7z','rar'); keywords=@('解压','压缩')
    category_path=@('file_operation','archive')
    interfaces=@(
      [PSCustomObject]@{ name='c'; syntax='bz c -y -fmt:zip out.zip <files>'; note='新建包' },
      [PSCustomObject]@{ name='x'; syntax='bz x -aoa -o:<dir> <archive>'; note='解压' },
      [PSCustomObject]@{ name='l'; syntax='bz l <archive>'; note='列出包内容' }
    )
  }
  $o.tools = @($o.tools) + $bz
  [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 10), $utf8)
}
New-Item -ItemType Directory -Force -Path "$QA\alt" | Out-Null
Copy-Item -LiteralPath "$QA\registry.json" -Destination "$QA\alt\registry.json" -Force
# 环境自包含：让副本不依赖本机 Bandizip 安装情况。
# 必须用独立的占位文件，绝不能指向 alpha.exe 等参与注册测试的假工具，
# 否则 register.ps1 会判定「该路径已存在索引」跳过注册，后续断言全部级联失败。
$p = "$QA\registry.json"
$o = [System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($t in @($o.tools)) { if ($t.id -eq 'bz') { $t.locator.primary = "$F\bz-placeholder.exe"; $t.version_info = $null } }
[System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 10), $utf8)
$env:AGENT_REGISTRY = $p
"P0 READY | files=$((Get-ChildItem -LiteralPath $QA -Recurse -File).Count) | version=$(([System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8)|ConvertFrom-Json).version)"
```

**预期**：输出 `P0 READY`，`version=1`（仓库是空索引模板；P0 只在副本里造一条基准条目）；副本存在 `fake\` 且含 9 个假 exe（含专用的 `bz-placeholder.exe`）+ 2 个非工具文件 + `helper.ps1` + `ifaces.json`。若报「找不到 registry.json」或 version 不是 1，先检查 `$Repo` 路径，不要继续。

> 后续批次若因某种原因需要重来，重跑 P0 即可完全重置；**批次之间不要重置**，P1→P5 依赖前序状态。

---

### P1 · 注册 / 接口清单 / 复核 / 删除保护（A 组）

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function GetT([string]$id) { @((RR).tools | Where-Object { $_.id -eq $id })[0] }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }

# T01 简单工具：无文档字段、无 md 文件（索引 → exe 零开销）
$v0 = V
& "$S\register.ps1" -Path "$F\beta.exe" -Functions 'compress' -Tags 'archive' | Select-Object -Last 2
$b = GetT 'beta'
# 注意：新条目一律带 usage_page 属性，简单工具的值是 null；判据是「值为空 + 无 md 文件」，不是「属性不存在」
CK 'T01' ($b -and -not $b.usage_page -and -not (Test-Path "$QA\tools\beta.md")) '简单工具不生成说明文档（usage_page 为 null）'
CK 'T02' ((V) -eq $v0 + 1) '注册一次 version +1'

# T03 复杂工具：接口清单入库 + 从简文档骨架 + 受管区块
& "$S\register.ps1" -Path "$F\alpha.exe" -Functions 'extract,compress' -Tags 'archive,zip' -Keywords 'unzip,pack' -CategoryPath 'file_operation/archive' -InterfacesFile "$F\ifaces.json" | Select-Object -Last 3
$a = GetT 'alpha'
$doc = if (Test-Path "$QA\tools\alpha.md") { [System.IO.File]::ReadAllText("$QA\tools\alpha.md",[System.Text.Encoding]::UTF8) } else { '' }
CK 'T03' ($a -and @($a.interfaces).Count -eq 2) '接口清单 2 条入库'
CK 'T04' ($a -and $a.doc_level -eq 'detailed' -and $a.usage_page -eq 'tools/alpha.md') '复杂工具建档且 doc_level=detailed'
CK 'T05' ($doc.Contains('<!-- interfaces:start') -and $doc.Contains('alpha c -y out.zip')) '从简骨架含受管接口区块'
CK 'T06' (@((RR).tools | Where-Object { $_.id -like 'alpha*' }).Count -eq 1) '无重复 id'

# T07 重复注册同路径幂等
$v1 = V
& "$S\register.ps1" -Path "$F\beta.exe" -Functions 'compress' | Select-Object -Last 1
CK 'T07' ((V) -eq $v1 -and @((RR).tools | Where-Object { $_.id -eq 'beta' }).Count -eq 1) '重复注册不写盘、不产生重复条目'

# T08 任务之余补写接口（渐进式从简原则）
& "$S\record-interface.ps1" -Id alpha -Name a -Syntax 'alpha a -y out.zip' -Note 'append' | Select-Object -First 2
$a2 = GetT 'alpha'
CK 'T08' (@($a2.interfaces).Count -eq 3 -and (@($a2.interfaces | ForEach-Object { $_.name }) -join ',') -eq 'c,x,a') '补写接口后 3 条'
& "$S\record-interface.ps1" -Id alpha -Name a -Syntax 'alpha a -y out.zip' -Note 'append' | Select-Object -First 1
CK 'T09' (@((GetT 'alpha').interfaces).Count -eq 3) '重复补写同一接口幂等'

# T10 【回归哨兵】-InterfacesFile 不得抹掉已用接口；重复执行必须无变更
& "$S\update-tool.ps1" -Id alpha -InterfacesFile "$F\ifaces.json" | Select-Object -Last 2
CK 'T10' (@((GetT 'alpha').interfaces).Count -eq 3) '接口清单同步保留任务中补写的接口'
$v2 = V
& "$S\update-tool.ps1" -Id alpha -InterfacesFile "$F\ifaces.json" | Select-Object -Last 2
CK 'T11' ((V) -eq $v2) '相同接口清单重复执行不涨版'

# T12 【回归哨兵】-DocChecked 首次落盘、第二次幂等
& "$S\update-tool.ps1" -Id alpha -DocChecked | Select-Object -Last 2
$v3 = V
& "$S\update-tool.ps1" -Id alpha -DocChecked | Select-Object -Last 2
CK 'T12' ((V) -eq $v3) '-DocChecked 第二次不涨版'

# T13 【回归哨兵】-PurgeDoc 不带 -Hard 必须拒绝且不写盘
$v4 = V
& "$S\unregister.ps1" -Id alpha -PurgeDoc | Select-Object -Last 3
CK 'T13' ($LASTEXITCODE -eq 2 -and (V) -eq $v4 -and -not (GetT 'alpha').deleted) '-PurgeDoc 单独使用被拒绝且索引未变'
```

---

### P2 · 审批门禁与 Quicker 生命周期（B 组）

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function GetT([string]$id) { @((RR).tools | Where-Object { $_.id -eq $id })[0] }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }
function Pending { [System.IO.File]::ReadAllText("$QA\pending\pending-tools.json",[System.Text.Encoding]::UTF8) | ConvertFrom-Json }

# T14 自制脚本被拦截：只生成提案，索引不动
$v0 = V
& "$S\register.ps1" -Path "$F\helper.ps1" -Functions 'utility' | Select-Object -Last 4
$p = Pending
CK 'T14' ($LASTEXITCODE -eq 2 -and (V) -eq $v0 -and @($p.items | Where-Object { $_.status -eq 'pending_user_approval' }).Count -ge 1) '脚本入库被拦截，生成待审提案'

# T15 【回归哨兵】-ApprovedBy 不能单独绕过审批
& "$S\register.ps1" -Path "$F\helper.ps1" -Functions 'utility' -ApprovedBy 'fake_user' | Select-Object -Last 3
CK 'T15' (@((RR).tools | Where-Object { $_.name -eq 'helper.ps1' }).Count -eq 0) '-ApprovedBy 直连被拒'

# T16 提案幂等（重复拦截不新增第二条提案）
$cnt = @((Pending).items).Count
& "$S\register.ps1" -Path "$F\helper.ps1" -Functions 'utility' | Select-Object -Last 1
CK 'T16' (@((Pending).items).Count -eq $cnt) '同路径提案不重复入队'

# T17 approve-tool 必须显式 -ApprovedBy；T18 正确路径转正
$propId = @((Pending).items | Where-Object { $_.status -eq 'pending_user_approval' })[0].id
& "$S\approve-tool.ps1" -Id $propId | Select-Object -Last 2
CK 'T17' ($LASTEXITCODE -eq 1 -and @((RR).tools | Where-Object { $_.name -eq 'helper.ps1' }).Count -eq 0) '缺 -ApprovedBy 不转正'
& "$S\approve-tool.ps1" -Id $propId -ApprovedBy 'qa_tester' | Select-Object -Last 4
$h = @((RR).tools | Where-Object { $_.name -eq 'helper.ps1' })[0]
$pi = @((Pending).items | Where-Object { $_.id -eq $propId })[0]
CK 'T18' ($h -and $h.approval.mode -eq 'user_approved') '审批转正并留痕 approval.mode'
CK 'T19' ([string]$pi.status -eq 'approved' -and -not $pi.approval_token) '提案状态 closed 且一次性凭证已清空'

# T20~T23 Quicker：注册 → 更新 → 改动作码 → 软删 → 恢复 → 硬删
& "$S\register.ps1" -Quicker -ActionCode 'QA-SHOT' -Functions 'screenshot,gui' -Name 'QA 截图动作' | Select-Object -Last 2
$q = @((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT' })[0]
CK 'T20' ($q -and $q.requires_gui -eq $true -and $q.tier -eq 3) 'Quicker 动作登记在 quicker_actions，T3/GUI 兜底'
& "$S\update-tool.ps1" -Id 'quicker-QA-SHOT' -Name 'QA 截图动作 v2' | Select-Object -Last 2
CK 'T21' (@((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT' })[0].name -eq 'QA 截图动作 v2') '原地更新不改 id'
& "$S\update-tool.ps1" -Id 'quicker-QA-SHOT' -ActionCode 'QA-SHOT2' | Select-Object -Last 2
$q2 = @((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT2' })[0]
CK 'T22' ($q2 -and ([string]$q2.invoke_template).Contains('QA-SHOT2')) '改动作码同步改 id 与 invoke_template'
& "$S\unregister.ps1" -Id 'quicker-QA-SHOT2' | Out-Null
CK 'T23' (@((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT2' })[0].deleted -eq $true) 'Quicker 软删可用'
& "$S\register.ps1" -Quicker -ActionCode 'QA-SHOT2' -Functions 'screenshot' | Select-Object -Last 2
CK 'T24' (@((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT2' }).Count -eq 1 -and -not @((RR).quicker_actions | Where-Object { $_.id -eq 'quicker-QA-SHOT2' })[0].deleted) '原地恢复不产生重复条目'
```

---

### P3 · 更新 / 文档联动 / 删除分级（C 组）

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function GetT([string]$id) { @((RR).tools | Where-Object { $_.id -eq $id })[0] }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }

# T25 原地改路径 / 标签，保留 id 与 added_at；重复执行无变更
$added = (GetT 'alpha').added_at
& "$S\update-tool.ps1" -Id alpha -Path "$F\delta.exe" -Tags 'archive,zip,qa' | Select-Object -Last 3
$a = GetT 'alpha'
CK 'T25' (([string]$a.locator.primary) -eq "$F\delta.exe" -and $a.added_at -eq $added) 'update-tool 原地更新，保留 added_at'
$v = V
& "$S\update-tool.ps1" -Id alpha -Path "$F\delta.exe" -Tags 'archive,zip,qa' | Select-Object -Last 2
CK 'T26' ((V) -eq $v) '相同字段重复更新不涨版'

# T27 改 usage_page 时旧文档归档、新文档生成
& "$S\update-tool.ps1" -Id alpha -UsagePage 'tools/alpha-v2.md' | Select-Object -Last 3
CK 'T27' ((Test-Path "$QA\tools\alpha-v2.md") -and @(Get-ChildItem -LiteralPath "$QA\tools\_archive" -Filter '*alpha*' -File).Count -ge 1) '旧说明文档已归档，新文档已生成'

# T28 【回归哨兵】软删保留文档 + 软删后重注册复用原 id
& "$S\unregister.ps1" -Id alpha | Select-Object -Last 3
CK 'T28' ((GetT 'alpha').deleted -eq $true -and (Test-Path "$QA\tools\alpha-v2.md")) '软删保留说明文档'
& "$S\register.ps1" -Path "$F\delta.exe" -Functions 'extract' -InterfacesFile "$F\ifaces.json" | Select-Object -Last 3
CK 'T29' (-not (GetT 'alpha').deleted -and @((RR).tools | Where-Object { $_.id -like 'alpha*' }).Count -eq 1) '重注册复用 id=alpha，无 alpha-2'

# T30 硬删归档文档；T31 -Hard -PurgeDoc 彻底删文档
& "$S\unregister.ps1" -Id alpha -Hard | Select-Object -Last 3
CK 'T30' (@((RR).tools | Where-Object { $_.id -eq 'alpha' }).Count -eq 0 -and @(Get-ChildItem -LiteralPath "$QA\tools\_archive" -Filter '*alpha*' -File).Count -ge 1) '硬删移除条目并归档文档'
& "$S\register.ps1" -Path "$F\zeta.exe" -Functions 'extract' -UsagePage 'tools/zeta-qa.md' | Select-Object -Last 2
& "$S\unregister.ps1" -Id zeta -Hard -PurgeDoc | Select-Object -Last 3
CK 'T31' (-not (Test-Path "$QA\tools\zeta-qa.md") -and @((RR).tools | Where-Object { $_.id -eq 'zeta' }).Count -eq 0) '-PurgeDoc 彻底删除文档且不留归档'

# T32 删除后 tool-doc -Check 不应报孤儿 / 软删持有文档（已固化为自动断言）
$chk = & "$S\tool-doc.ps1" -Check 2>&1 | Out-String
($chk -split "`n" | Where-Object { $_ -match '汇总|孤儿|软删持有' }) | ForEach-Object { '  ' + $_.Trim() }
CK 'T32' (-not $chk.Contains('孤儿文档') -and -not $chk.Contains('软删持有文档')) '删除后无孤儿 / 软删持有文档告警'
```

T32 为**自动断言**：输出中不应出现指向已删工具 `alpha`/`zeta` 的「孤儿文档」或「软删持有文档」告警；`_archive\`、`_notes\`、`_` 开头的示例文档不应被误报。完整输出请一并贴进报告。

---

### P4 · 检索 / 初始化发现 / 体检 / 扫描（D 组）

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function GetT([string]$id) { @((RR).tools | Where-Object { $_.id -eq $id })[0] }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }

# 补足 >5 个工具，用于验证 TopN / -All
foreach ($n in @('gamma','epsilon','cong1','cong2')) { & "$S\register.ps1" -Path "$F\$n.exe" -Functions 'extract,compress' -Tags 'archive' | Out-Null }
$nTools = @((RR).tools | Where-Object { -not $_.deleted }).Count

# T33 【回归哨兵】-All 真全量；T34 默认 TopN 生效；T35 无命中回退全量
$a = & "$S\route_task_v2.ps1" -Task 'extract archive' -All 2>&1 | Out-String
$head = @($a -split "`n" | Where-Object { $_ -match '候选:' })[0]
$num = [int]([regex]::Match($head, '工具\s+(\d+)\s+个').Groups[1].Value)
CK 'T33' ($num -eq $nTools -and $nTools -gt 5) "-All 列出全部 $nTools 个工具（不被 TopN=5 截断）"
$top = & "$S\route_task_v2.ps1" -Task 'extract archive' 2>&1 | Out-String
$topNum = [int]([regex]::Match((@($top -split "`n" | Where-Object { $_ -match '候选:' })[0]), '工具\s+(\d+)\s+个').Groups[1].Value)
CK 'T34' ($topNum -le 5) '不带 -All 时 TopN=5 生效'
$fb = & "$S\route_task_v2.ps1" -Task 'zzz_no_match_zzz' -All 2>&1 | Out-String
CK 'T35' ($fb.Contains('回退') -or $fb.Contains('全量')) '无命中时回退全量'

# T36 -InjectPrompt 注入结构化接口清单；T37 Quicker 排后
$inj = & "$S\route_task_v2.ps1" -Task '解压 7z 压缩包' -InjectPrompt 2>&1 | Out-String
CK 'T36' ($inj.Contains('=== 以下注入 Agent Prompt ===') -and $inj.Contains('接口')) '注入片段含接口清单/说明（不是只有工具名）'
# 不能用整段 IndexOf('GUI 兜底')：候选汇总行里也有这四个字，会误判。按行找 [GUI 兜底] 标记行
$rows = @($inj -split "`n"); $iTool = -1; $iGui = -1
for ($k = 0; $k -lt $rows.Count; $k++) {
  if ($rows[$k] -match '^\s+\[T' -and $rows[$k] -notmatch 'GUI') { $iTool = $k }
  if ($rows[$k] -match '\[GUI 兜底\]' -and $iGui -lt 0) { $iGui = $k }
}
CK 'T37' ($iGui -eq -1 -or $iGui -gt $iTool) 'GUI 兜底动作排在普通工具之后'

# T38 只读入口不写盘（route_task / tool-doc / init-discovery / validate dry-run）
$v0 = V
& "$S\route_task_v2.ps1" -Task 'compress' | Out-Null
& "$S\tool-doc.ps1" -List | Out-Null
& "$S\validate-registry.ps1" | Out-Null
CK 'T38' ((V) -eq $v0) '只读入口（含 validate dry-run）不写盘'

# T39 【回归哨兵】init-discovery 默认只读；T40 系统命令 T2 不入库
$v1 = V
$d = & "$S\init-discovery.ps1" -InjectPrompt -Dirs $F 2>&1 | Out-String
CK 'T39' ((V) -eq $v1) 'init-discovery 默认（含 -InjectPrompt）不写索引'
CK 'T40' (@((RR).tools | Where-Object { $_.tier -eq 2 }).Count -eq 0) 'T2 系统命令只提示不入库'

# T41 -Apply 幂等 + 软删条目可原地重新激活
& "$S\unregister.ps1" -Id gamma | Out-Null
$d2 = & "$S\init-discovery.ps1" -Apply -OnlyTiers 4 -IncludeTier4 -Dirs $F 2>&1 | Out-String
CK 'T41' (-not (GetT 'gamma').deleted -and @((RR).tools | Where-Object { $_.id -like 'gamma*' }).Count -eq 1) '初始化发现重新激活软删条目，无 gamma-2'
$v2 = V
& "$S\init-discovery.ps1" -Apply -OnlyTiers 4 -IncludeTier4 -Dirs $F 2>&1 | Out-String | Out-Null
CK 'T42' ((V) -eq $v2) 'init-discovery -Apply 重复执行幂等'

# T43 【回归哨兵】scan-directory 不得把 .md/.png 当工具；T44 不执行被扫描 exe
$v3 = V
$sc = & "$S\scan-directory.ps1" -Quick -Dirs $F 2>&1 | Out-String
CK 'T43' (-not $sc.Contains('selenium-notes.md') -and -not $sc.Contains('opencv_logo.png')) '非可执行文件不登记为自动化工具'
CK 'T44' ((V) -eq $v3) 'scan-directory 在假目录（无运行时）上不产生新条目、不写盘'

# T45 体检幂等：前序测试会让索引产生真实修正，先跑一次收敛，第二次必须不写盘
# （不要在脏索引上直接断言「纯体检不写盘」，那属于测试设计错误而非产品缺陷）
& "$S\validate-registry.ps1" -Apply | Out-Null
$v4 = V
$vout = & "$S\validate-registry.ps1" -Apply 2>&1 | Out-String
($vout -split "`n" | Where-Object { $_ -match '无需变更|已写入索引' }) | ForEach-Object { '  ' + $_.Trim() }
CK 'T45' ((V) -eq $v4) '体检收敛后重复 -Apply 不写盘（无变更不涨版）'
$path = $env:AGENT_REGISTRY
$o = [System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
$beforeLC = @($o.tools | Where-Object { $_.id -eq 'beta' })[0].last_checked
# validate 只对 verified=true 的路径失效条目软删；未验证条目只报告不自动删（保护设计）
$eps = @($o.tools | Where-Object { $_.id -eq 'epsilon' })[0]
$eps.locator.primary = "$F\GONE.exe"
$eps.verified = $true
[System.IO.File]::WriteAllText($path, ($o | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
& "$S\validate-registry.ps1" -Apply | Out-Null
$o2 = [System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
$afterLC = @($o2.tools | Where-Object { $_.id -eq 'beta' })[0].last_checked
CK 'T46' (@($o2.tools | Where-Object { $_.id -eq 'epsilon' })[0].deleted -eq $true -and $afterLC) '路径失效软删 + 其它条目 last_checked 已落盘'
"  last_checked before=$beforeLC after=$afterLC（同秒可能相同，不算 bug）"
```

> T36 的判读要点：**注入片段里应出现接口清单/典型调用，而不是只有工具名**；若只输出工具名说明文档层未生效。
> T45 上方会打印体检摘要，请把「无需变更 / 已写入索引」的实际字样一并贴进报告。

---

### P5 · 并发 / 镜像 / 文件一致性（E 组）

```powershell
# 配置区：默认把当前目录当仓库根目录；不在根目录运行时设置 AGENT_TOOLS_REPO 或改写下一行
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$env:AGENT_REGISTRY = "$QA\registry.json"
$S = "$QA\scripts"; $F = "$QA\fake"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function V { [int](RR).version }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }

# T47 【回归哨兵】两个进程同时注册不同工具，两者都必须存活且 version 涨 2
foreach ($n in @('cong1','cong2')) { & "$S\unregister.ps1" -Id $n -Hard | Out-Null }
$v0 = V
$sb = {
  param($s,$f,$reg,$name)
  $env:AGENT_REGISTRY = $reg
  & "$s\register.ps1" -Path "$f\$name.exe" -Functions 'compress' 2>&1 | Out-String
}
$j1 = Start-Job -ScriptBlock $sb -ArgumentList $S,$F,$env:AGENT_REGISTRY,'cong1'
$j2 = Start-Job -ScriptBlock $sb -ArgumentList $S,$F,$env:AGENT_REGISTRY,'cong2'
$null = Wait-Job -Job @($j1,$j2) -Timeout 90
$null = Receive-Job -Job $j1; $null = Receive-Job -Job $j2
Remove-Job -Job @($j1,$j2) -Force
$r = RR
CK 'T47' (@($r.tools | Where-Object { $_.id -eq 'cong1' }).Count -eq 1 -and @($r.tools | Where-Object { $_.id -eq 'cong2' }).Count -eq 1 -and $r.version -eq $v0 + 2) '并发新增不丢条目，version 正确递增 2'

# T48 【回归哨兵】registry.md 跟随 AGENT_REGISTRY
$rootMd = "$QA\registry.md"
$before = (Get-Item -LiteralPath $rootMd).LastWriteTime
$env:AGENT_REGISTRY = "$QA\alt\registry.json"
& "$S\update-tool.ps1" -Id bz -Tags 'mirror_test' | Select-Object -Last 2
CK 'T48' ((Test-Path "$QA\alt\registry.md") -and ((Get-Item -LiteralPath $rootMd).LastWriteTime -eq $before)) '镜像写到 alt 目录，根目录 md 未被误改'
$env:AGENT_REGISTRY = "$QA\registry.json"

# T49 无残留 .tmp；T50 严格 UTF-8 JSON；T51 镜像版本与 json 一致
CK 'T49' (@(Get-ChildItem -LiteralPath $QA -Recurse -Filter '*.tmp' -File).Count -eq 0) '原子写未残留临时文件'
$r2 = [System.IO.File]::ReadAllText("$QA\registry.json",[System.Text.Encoding]::UTF8) | ConvertFrom-Json
$md = [System.IO.File]::ReadAllText("$QA\registry.md",[System.Text.Encoding]::UTF8)
CK 'T50' ($r2.version -ge 1 -and @($r2.tools).Count -ge 0) 'registry.json 可按 UTF-8 严格解析'
CK 'T51' ($md.Contains("版本 v$($r2.version)")) 'registry.md 版本号与 json 同步'
```

> 可选的更严格 JSON 校验（需要 Python 3，在副本目录执行）：`python -c "import json,io; json.load(io.open('registry.json',encoding='utf-8')); json.load(io.open('pending/pending-tools.json',encoding='utf-8')); print('OK')"` —— 该检查会拒绝 BOM 与非法转义，比 `ConvertFrom-Json` 严格。检查生产索引时在仓库根目录执行同一条命令。

---

### P6 · 生产目录只读终检（F 组，**不写任何盘**）

```powershell
# 配置区
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$prod = $Repo
$env:AGENT_REGISTRY = "$prod\registry.json"
function RR { [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }
$v0 = [int](RR).version
$ids0 = @((RR).tools | ForEach-Object { $_.id }) -join ','

# T52 全部 .ps1 语法
$files = @(Get-ChildItem -LiteralPath $prod -Recurse -Filter '*.ps1' -File)
$bad = 0
foreach ($f in $files) {
  $t = $null; $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e) | Out-Null
  if ($e.Count -gt 0) { $bad++; "  SYNTAX $($f.Name): $($e[0].Message) @line $($e[0].Extent.StartLineNumber)" }
}
CK 'T52' ($bad -eq 0 -and $files.Count -ge 19) "$($files.Count) 个 ps1，语法错误 $bad"

# T53 编码约定
$encBad = @()
foreach ($f in @(Get-ChildItem -LiteralPath $prod -Recurse -File)) {
  $b = [System.IO.File]::ReadAllBytes($f.FullName)
  $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  if ($f.Extension -in @('.ps1','.md') -and -not $hasBom) { $encBad += "$($f.Name):缺 BOM" }
  if ($f.Extension -eq '.json' -and $hasBom) { $encBad += "$($f.Name):多了 BOM" }
}
CK 'T53' ($encBad.Count -eq 0) "编码异常 $($encBad.Count) 项：$($encBad -join '; ')"

# T54 生产 JSON 与状态（与起始快照比对，空索引模板或已有工具的索引都适用）
$r = RR
$ids1 = @($r.tools | ForEach-Object { $_.id }) -join ','
CK 'T54' ($r.version -eq $v0 -and $ids1 -eq $ids0 -and @($r.quicker_actions).Count -eq 0) "生产索引未被改动：version=$($r.version) / tools=[$ids1] / quicker 为空"

# T55 文档一致性检查
$chk = & "$prod\scripts\tool-doc.ps1" -Check 2>&1 | Out-String
CK 'T55' (-not $chk.Contains('❌')) 'tool-doc -Check 无 ❌ 级问题（输出需人工复核）'
$chk

# T56 只读入口在生产上也不写盘
& "$prod\scripts\route_task_v2.ps1" -Task '解压 7z 压缩包' -InjectPrompt | Out-Null
& "$prod\scripts\init-discovery.ps1" -InjectPrompt | Out-Null
& "$prod\scripts\validate-registry.ps1" | Out-Null
CK 'T56' ([int](RR).version -eq $v0) '生产上三个只读入口未改 version'

# T57 bootstrap 模板块与磁盘文件一致（registry.json 允许唯一有意差异）
$lines = [System.IO.File]::ReadAllLines("$prod\bootstrap-registry.ps1",[System.Text.Encoding]::UTF8)
$blocks = 0; $diff = @()
for ($i = 0; $i -lt $lines.Length; $i++) {
  if ($lines[$i] -like 'Write-File *') {
    $rel = ($lines[$i] -split '"')[1]
    $j = $i + 1
    while ($j -lt $lines.Length -and $lines[$j] -ne "'@") { $j++ }
    $body = if ($j -gt $i + 1) { (($lines[($i+1)..($j-1)]) -join "`n") + "`n" } else { "`n" }
    $disk = [System.IO.File]::ReadAllText((Join-Path $prod ($rel -replace '/', '\')),[System.Text.Encoding]::UTF8).TrimStart([char[]]@([char]0xFEFF))
    $blocks++
    if ($body -ne $disk -and $rel -ne 'registry.json') { $diff += $rel }
    $i = $j
  }
}
CK 'T57' ($blocks -ge 31 -and $diff.Count -eq 0) "模板块 $blocks 个，非预期差异 $($diff.Count)：$($diff -join ', ')"
```

> T55 是半自动项：`tool-doc.ps1 -Check` 会打印缺失文档、版本头、孤儿、表格不一致、臃肿、软删持有文档等提示。请把打印出的完整输出贴进报告，人工确认无实际缺失。
> T57 若因 bootstrap 生成的 md 少一个结尾换行而报差，请核对是否仅 `\n` 差异——这是 `Write-File` 的既有行为，不算 bug（见第 7 节）。

---

### P7 · 全新目录生成（G 组）

> **必须在同一次 PowerShell 调用内完成准备→运行→校验→清理**，曾出现跨调用文件视图不一致导致误判。

```powershell
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }
# 配置区
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
$dir = Join-Path $QA 'fresh'
$out = Join-Path $dir 'out'
[System.IO.Directory]::CreateDirectory($dir) | Out-Null
# bootstrap 支持 -Root，直接生成到隔离目录，不再复制 / 改写脚本源码
& (Join-Path $Repo 'bootstrap-registry.ps1') -Root $out | Select-Object -Last 2
$files = @(Get-ChildItem -LiteralPath $out -Recurse -File)
CK 'T58' ($files.Count -ge 31) "全新目录生成 $($files.Count) 个文件"
$r = [System.IO.File]::ReadAllText("$out\registry.json",[System.Text.Encoding]::UTF8) | ConvertFrom-Json
CK 'T59' ($r.version -eq 1 -and @($r.tools).Count -eq 0 -and @($r.quicker_actions).Count -eq 0) '全新索引为空（version=1）'
$p = [System.IO.File]::ReadAllText("$out\AGENT_INIT_PROMPT.md",[System.Text.Encoding]::UTF8)
CK 'T60' ($p.Contains('## 交互契约')) '新生成包带最新交互契约'
$core = [System.IO.File]::ReadAllText("$out\scripts\lib\registry-core.ps1",[System.Text.Encoding]::UTF8)
$reg  = [System.IO.File]::ReadAllText("$out\scripts\register.ps1",[System.Text.Encoding]::UTF8)
$v2   = [System.IO.File]::ReadAllText("$out\scripts\route_task_v2.ps1",[System.Text.Encoding]::UTF8)
$scan = [System.IO.File]::ReadAllText("$out\scripts\scan-directory.ps1",[System.Text.Encoding]::UTF8)
# 原子替换在源码里写作 [System.IO.File]::Replace(...)，不是字面量 "File.Replace"
CK 'T61' ($core.Contains('Restore-SoftDeletedTool') -and $core.Contains('::Replace(') -and $core.Contains('Mark-RegistryRemoval')) '并发/软删/硬删修复已带入'
CK 'T62' ($reg.Contains('ApprovalToken') -and $v2.Contains('999999') -and $scan.Contains('autoExt')) '审批/全量检索/扫描白名单修复已带入'
CK 'T63' (-not (Test-Path "$out\TEST_GUIDE.md")) '验收文档不进运行包（预期如此）'
$unreg = [System.IO.File]::ReadAllText("$out\scripts\unregister.ps1",[System.Text.Encoding]::UTF8)
CK 'T64' ($unreg.Contains('Mark-RegistryRemoval')) '硬删意图标记已接入 unregister.ps1'
# X01 孤儿文档修复与相对路径定位必须带进新包
CK 'X01' ($reg.Contains('Archive-StaleUsagePage') -and $core.Contains('$PSScriptRoot')) '孤儿文档修复与路径无关定位已带入新包'
# X02 关键可移植性：不设 AGENT_REGISTRY，新包也要能自己找到索引
$envSave = $env:AGENT_REGISTRY
Remove-Item Env:\AGENT_REGISTRY -ErrorAction Ignore
$probe = & "$out\scripts\route_task_v2.ps1" -Task 'archive' -All 2>&1 | Out-String
if ($envSave) { $env:AGENT_REGISTRY = $envSave }
CK 'X02' ($probe -and -not $probe.Contains('索引文件不存在')) '新生成包不设 AGENT_REGISTRY 也能独立定位索引'
[System.IO.Directory]::Delete($dir, $true)
'P7 fresh dir cleaned'
```

---

### P8 · 清理与最终确认

```powershell
# 配置区
$Repo = if ($env:AGENT_TOOLS_REPO) { $env:AGENT_TOOLS_REPO } else { (Get-Location).Path }
$QA = Join-Path $env:TEMP '_AgentSim_QA'
function CK([string]$id,[bool]$c,[string]$d) { "{0} {1} | {2}" -f $(if($c){'PASS'}else{'FAIL'}),$id,$d }
$env:AGENT_REGISTRY = Join-Path $Repo 'registry.json'
if (Test-Path -LiteralPath $QA) { Remove-Item -LiteralPath $QA -Recurse -Force }
$r = [System.IO.File]::ReadAllText($env:AGENT_REGISTRY,[System.Text.Encoding]::UTF8) | ConvertFrom-Json
"FINAL | version=$($r.version) tools=$(@($r.tools | ForEach-Object { $_.id }) -join ',') quicker=$(@($r.quicker_actions).Count) | qa_dir_exists=$(Test-Path $QA)"
$tmpCount = @(Get-ChildItem -LiteralPath $Repo -Recurse -Filter '*.tmp' -File).Count
# 与起始状态无关的污染检测：生产索引里不能出现任何测试用 id
$testIds = @('alpha','beta','gamma','delta','epsilon','zeta','cong1','cong2','helper','quicker-QA-SHOT','quicker-QA-SHOT2','quicker-QA-DOC','sharea','shareb')
$leaked = @(@($r.tools) + @($r.quicker_actions) | Where-Object { $_ -and $testIds -contains [string]$_.id })
CK 'FINAL' ($leaked.Count -eq 0 -and -not (Test-Path $QA) -and $tmpCount -eq 0) '生产索引无测试残留 / QA 已清理 / 无 tmp'
"TMP_COUNT | $tmpCount"
```

**预期**：`CK 'FINAL'` 输出 PASS；FINAL 行在仓库空索引模板下为 `version=1 / tools=（空） / quicker=0 / qa_dir_exists=False`，`TMP_COUNT | 0`。若你已在本地注册过工具，FINAL 行显示你的起始快照即可，只要没有测试用 id 就视为未污染。任何一项不符都说明测试过程污染了生产，必须立刻报告。

> 删除前再次确认路径是 `$QA`（默认系统临时目录下的 `_AgentSim_QA`），**不是** `$Repo`。这是本文档唯一允许执行的删除操作。

---

## 5. 判定标准

- **全部通过**：P0–P8 所有 `CK` 输出 PASS，人工判读项（T55/T57）无实际告警，P8 最终行符合预期。
- **判定为有问题**：任一 FAIL，或出现以下任一现象——`version` 无变更却涨、命令重复执行写盘、生产索引被改、生成 `xxx-2` 重复条目、并发丢条目、`.md/.png` 被当工具、`-PurgeDoc` 单独生效、`-ApprovedBy` 能直连入库、镜像写错目录、残留 `.tmp`。
- **FAIL 处理**：记录「用例号 / 复现命令 / 实际输出 / 涉及文件:行号 / 影响等级（P0 数据丢失或静默失败 / P1 功能错误 / P2 边界体验）」，不要自行改生产文件。

## 6. 报告模板

```
## 验收结论
通过 / 未通过（FAIL N 项）

## 环境
PowerShell 版本 | 被测目录 | 生产 version 起始值/结束值 | 隔离目录是否已清理

## 逐用例结果
| 用例 | 结果 | 实际输出要点 | 备注 |
|---|---|---|---|
| T01 | PASS | ... | |
| ... | ... | ... | |

## FAIL 明细
（用例号 / 命令 / 实际输出 / 文件:行号 / 影响等级）

## 人工判读项
T55 / T57 的完整输出与结论（T32、T36、T45 已改为自动断言）

## 终检
语法错误数 | 编码异常数 | tool-doc -Check | 模板块差异 | 残留 .tmp | P8 FINAL 行
```

## 7. 已知边界（**不要误报为 bug**）

1. `$LASTEXITCODE=2; return` 在 `-File` 方式调用时，进程退出码仍可能是 0；编排器应读 `$LASTEXITCODE`，脚本一律用 `&` 调用。
2. `-Reusable -Reason '<场景>'` 是设计允许的「声明式直登」，不是绕过审批（复杂、无复用性脚本才需用户同意）。
3. 并发保护只保证**新增条目不丢**；两个进程同时改**同一条目**的字段仍是后写覆盖。
4. T2 系统自带命令（零级/一级）只提示、不入库；Quicker 动作码不自动发现；自制脚本一律走审批——都是刻意设计。
5. 软删**保留**说明文档；`-Hard` 归档到 `tools\_archive\`；只有 `-Hard -PurgeDoc` 才彻底删除；共享文档、模板、越界路径一律不动。
6. `bootstrap-registry.ps1` 生成的 `.md` 比源模板少一个结尾换行，是 `Write-File` 既有行为；仓库自带空索引模板，全新生成包与仓库的 `registry.json` 都是 `version=1 / tools=[]`（T57 仍允许该文件存在有意差异）。
7. 副本里把 `bz` 路径指向假 exe、清空版本指纹后，`tool-doc -Check` 若提示版本头差异属环境差异；**文档一致性以 P6 的生产检查为准**。
8. 全新生成的运行包不含 `TEST_GUIDE.md`；本文件是外部验收材料，不在 31 个模板块内。
9. `rename\rename.ps1` 的大小写重命名、`examples\pipeline-example.ps1` 的解压残留属于低风险已知边界，未在本次修复范围内。
10. 体检只对 `verified=true` 的路径失效条目软删；**未验证工具路径失效只报告、不自动删**（T46 因此先把 `verified` 置 true）。
11. P0 规范化只改副本；生产 `registry.json` 全程不应有任何变化。
12. `scan-directory.ps1` **没有** `-Apply` 开关：默认模式扫到 `python.exe` / `gcc.exe` / 自动化库时会直接 `Save-Registry`（见 AGENT_INIT_PROMPT「积极扫描」，属设计）。T44 用不含运行时的假目录验证「无新工具时不写盘」；不传 `-Dirs` 时会扫到本机运行时并登记，不要误判为 bug。
13. P0 造的基准条目是「复杂工具但无用法页」，副本里 `tool-doc -Check` 可能提示 1 项文档差异；T32 只断言无孤儿 / 软删持有文档告警，文档一致性以 P6 的生产检查为准。
12. 中文 `PASS/FAIL` 描述在某些控制台里会显示成乱码（编码显示问题，不影响断言），先执行 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` 即可。

## 8. 常见踩坑（给接手 Agent）

| 坑 | 正确做法 |
|---|---|
| `$args` 是 PowerShell 保留变量 | 自定义函数参数名不要用 `$args`，否则传参丢失、静默走错分支 |
| 把 `string[]` 直接 `@arr` splatting | 会把元素当位置参数，可能误触发 Quicker 分支；参数用哈希表 splatting 或直接写全 |
| `Get-Content -Raw` 不带编码 | Windows PowerShell 5.1 默认 ANSI，中文会乱码；一律 `-Encoding UTF8` 或 `ReadAllText(..., UTF8)` |
| 新建 `.ps1` 忘了 BOM | 含中文的脚本会解析崩；写文件用 `[System.Text.UTF8Encoding]::new($true)` |
| `.json` 带了 BOM | 严格解析器（Python `json.load`）会报错；写文件用 `::new($false)` |
| `exit` 依赖进程退出码 | 脚本内 `exit` 与 `-File` 行为不一致；用 `&` 调用并读 `$LASTEXITCODE` |
| 准备与执行拆到不同工具调用 | 极少数情况下文件视图不一致；P0/P7 已设计为同一次调用内自洽 |
| 误把 `$env:AGENT_REGISTRY` 留在副本路径 | 每次批次开头重设；P6/P8 必须指回生产 |
| 在生产目录跑 `-Apply` / `-Hard` | 全部写操作只允许在 `$QA` |

---

**附：功能面覆盖对照**（确认没有漏测）
注册（简单/复杂/脚本/Quicker）· 更新（路径/标签/分类/动作码/文档页/接口）/ 幂等 · 删除（软/硬/PurgeDoc/文档联动/归档）· 审批（拦截/提案/凭证/转正/拒绝/幂等）· 文档（从简骨架/受管区块/接口补写/复核/孤儿检查/共享保护）· 检索（打分/TopN/-All/回退/注入/Quicker 排后）· 初始化（四级分层/只读/Apply/软删自愈）· 体检（dry-run/路径自愈/版本指纹/last_checked）· 扫描（扩展名白名单/不执行 exe）· 一致性（并发/原子写/镜像路径/无 BOM/模板同步/全新生成）。
