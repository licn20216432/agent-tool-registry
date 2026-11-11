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
