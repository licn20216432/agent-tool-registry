param([switch]$Apply)
. (Join-Path $PSScriptRoot "lib\registry-core.ps1")
$reg = Get-Registry

$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$updated = $false; $missing = @(); $neverVerified = @(); $relocated = @(); $okList = @(); $upgraded = @(); $checked = 0
$qChecked = 0; $qOk = @(); $qMissing = @(); $qRelocated = @(); $qUpgraded = @(); $qBadCode = @()

foreach ($t in @($reg.tools)) {
    if ($t.deleted) { continue }
    $checked++
    $resolved = Resolve-Locator $t
    # last_checked 不在这里单独改：否则纯体检也会写盘涨 version。
    # 统一在确有其它变更、准备 Save-Registry 时一并刷新（见文件末尾）。

    # 软件升级检测：索引记录过版本指纹时，对比磁盘上的当前文件
    $fpOld = if ($t.PSObject.Properties['version_info']) { $t.version_info } else { $null }
    if ($resolved -and $fpOld -and $fpOld.product_version) {
        $fi = Get-Item -LiteralPath $resolved -ErrorAction Ignore
        if ($fi) {
            $curVer = if ($fi.VersionInfo.ProductVersion) { ([string]$fi.VersionInfo.ProductVersion).Trim() } else { $null }
            $curSize = [long]$fi.Length
            $curMod = $fi.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
            $why = $null
            if ($curVer -and [string]$curVer -ne [string]$fpOld.product_version) {
                $why = "版本 $($fpOld.product_version) → $curVer"
            } elseif ($curSize -ne [long]$fpOld.file_size -or [string]$curMod -ne [string]$fpOld.modified) {
                $why = "版本未变但文件已更新（$curSize 字节 / $curMod）"
            }
            if ($why) {
                $upgraded += "$($t.id): $why"
                if ($Apply) {
                    $newFp = [PSCustomObject]@{
                        product_version = $curVer
                        file_size       = $curSize
                        modified        = $curMod
                        checked_at      = $now
                    }
                    Set-RegistryField $t 'version_info' $newFp
                    $updated = $true
                }
            }
        }
    }

    if (-not $resolved) {
        # 从未验证通过的工具（如未安装的 7-Zip）只报告，绝不自动软删除
        if ($t.verified -eq $true) {
            $missing += $t.id
            if ($Apply) { Set-ToolDeleted $t $true; $updated = $true }
        } else {
            $neverVerified += $t.id
        }
    } elseif ([string]$resolved -ne [string]$t.locator.primary) {
        $relocated += "$($t.id) → $resolved"
        if ($Apply) {
            Set-RegistryField $t.locator 'primary' ([string]$resolved)
            $updated = $true
        }
    } else {
        $okList += $t.id
    }
}

# ===== Quicker 动作体检 =====
# GUI 兜底动作没有文件路径可删：启动器失效只报告，绝不自动软删除
foreach ($q in @($reg.quicker_actions)) {
    if ($q.deleted) { continue }
    $qChecked++
    $resolved = Resolve-QuickerStarter $q

    # 动作码与调用模板必须一致，否则 runaction 会打到一个不存在的码
    $codeOk = $q.action_code -and $q.invoke_template -and
              ([string]$q.invoke_template).Contains([string]$q.action_code)
    if (-not $codeOk) { $qBadCode += "$($q.id)（码=$($q.action_code)）" }

    # Quicker 主程序升级检测（启动器文件的版本指纹）
    $fpOld = if ($q.PSObject.Properties['version_info']) { $q.version_info } else { $null }
    if ($resolved -and $fpOld -and $fpOld.product_version) {
        $fi = Get-Item -LiteralPath $resolved -ErrorAction Ignore
        if ($fi) {
            $curVer = if ($fi.VersionInfo.ProductVersion) { ([string]$fi.VersionInfo.ProductVersion).Trim() } else { $null }
            $curSize = [long]$fi.Length
            $curMod  = $fi.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
            $why = $null
            if ($curVer -and [string]$curVer -ne [string]$fpOld.product_version) {
                $why = "Quicker $($fpOld.product_version) → $curVer"
            } elseif ($curSize -ne [long]$fpOld.file_size -or [string]$curMod -ne [string]$fpOld.modified) {
                $why = "Quicker 版本未变但启动器已更新（$curSize 字节）"
            }
            if ($why) {
                $qUpgraded += "$($q.id): $why"
                if ($Apply) {
                    Set-RegistryField $q 'version_info' ([PSCustomObject]@{
                        product_version = $curVer; file_size = $curSize
                        modified = $curMod; checked_at = $now
                    })
                    $updated = $true
                }
            }
        }
    }

    if (-not $resolved) {
        # 启动器失效只报告：翻转 verified 会让「体检 → 写盘 → 恢复 → 再写盘」反复 version bump
        $qMissing += "$($q.id)（starter=$($q.starter)）"
    } elseif ([string]$resolved -ne [string]$q.starter) {
        $qRelocated += "$($q.id) → $resolved"
        if ($Apply) { Set-RegistryField $q 'starter' $resolved; $updated = $true }
    } else {
        $qOk += $q.id
        if ($Apply -and $q.verified -ne $true) { Set-RegistryField $q 'verified' $true; $updated = $true }
    }
}

Write-Output "=== 索引校验：启用工具 $checked 个 / Quicker 动作 $qChecked 个 ==="
if ($okList.Count -gt 0) { Write-Output "✅ 路径有效: $($okList -join ', ')" }
if ($relocated.Count -gt 0) { Write-Output "🔧 路径可修正: $($relocated -join '; ')" }
if ($upgraded.Count -gt 0) { Write-Output "🔄 软件已更新: $($upgraded -join '; ')" }
if ($missing.Count -gt 0) { Write-Output "⚠️ 已验证工具路径失效: $($missing -join ', ')" }
if ($neverVerified.Count -gt 0) { Write-Output "ℹ️ 尚未验证/未安装（不自动删除）: $($neverVerified -join ', ')" }

Write-Output "--- Quicker 动作 ---"
if ($qChecked -eq 0) { Write-Output "（未注册启用中的 Quicker 动作）" }
if ($qOk.Count -gt 0) { Write-Output "✅ 启动器有效: $($qOk -join ', ')" }
if ($qRelocated.Count -gt 0) { Write-Output "🔧 启动器可修正: $($qRelocated -join '; ')" }
if ($qUpgraded.Count -gt 0) { Write-Output "🔄 Quicker 已升级: $($qUpgraded -join '; ')" }
if ($qBadCode.Count -gt 0) { Write-Output "⚠️ 动作码与调用模板不一致: $($qBadCode -join '; ')" }
if ($qMissing.Count -gt 0) { Write-Output "⚠️ 启动器不可用（GUI 动作只报告，不自动删除）: $($qMissing -join '; ')" }

if (-not $Apply) {
    Write-Output "--- 仅检查，未写入索引。确认无误后加 -Apply 才会落盘 ---"
    Write-Output "    用法: .\scripts\validate-registry.ps1 -Apply"
    if ($upgraded.Count -gt 0) { Write-Output "    软件更新时 -Apply 会自动刷新版本指纹（也可手动跑 update-tool.ps1 -Id <id> -RefreshVersion）" }
} else {
    if ($updated) {
        # 体检时间随真正的变更一起落盘，不单独制造一次 version bump
        foreach ($t in @($reg.tools | Where-Object { -not $_.deleted })) {
            Set-RegistryField $t 'last_checked' $now
        }
        foreach ($q in @($reg.quicker_actions | Where-Object { -not $_.deleted })) {
            Set-RegistryField $q 'last_checked' $now
        }
        Save-Registry $reg
        Write-Output "--- 已写入索引 → version $($reg.version) ---"
    } else {
        Write-Output "--- 无需变更，索引未改动 ---"
    }
}
