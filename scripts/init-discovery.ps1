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
