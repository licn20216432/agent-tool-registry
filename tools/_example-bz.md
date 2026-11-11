# 工具说明文档示例（tools\_example-bz.md）

> 这是**示例模板**，不是索引条目。文件名以 `_` 开头，因此 `tool-doc.ps1 -Check` 不会把它当成孤儿文档。
> 正式使用时无需手建文档：`register.ps1` 注册复杂工具会自动生成 `tools\<id>.md` 从简骨架。

<!-- doc_version: 1 | tool_version: <版本> | checked_at: <日期> | doc_level: detailed -->
<!-- 从简原则：只写实际用过 / 常用的接口；没用过的不预先罗列参数、开关与退出码 -->
<!-- tool-doc.ps1 -Check 会核对 tool_version 与索引 version_info.product_version -->

## 基本信息
- id / 名称：`<id>` / `<可执行文件名>`
- 位置：以 `registry.json` 的 `locator.primary` 为准（**本页不是调用入口**）
- 适用：系统自带命令处理不了的格式 / 批量 / 需要特定参数的场景
- 不适用：普通任务优先用系统自带的 `Compress-Archive` / `Expand-Archive` / `tar.exe`

## 接口清单（受管区块，由脚本同步，不要手改）
<!-- interfaces:start -->

| 接口 | 调用语法 | 说明 |
|---|---|---|
| `c` | `tool c -y out.zip <files>` | 新建包，会覆盖同名 |
| `x` | `tool x -aoa -o:<dir> <archive>` | 解压，保留目录结构 |

<!-- interfaces:end -->

## 待补
其它接口用到再补，不预先罗列。

## 维护提示
- 补接口：`record-interface.ps1 -Id <id> -Name <接口> -Syntax '<调用>' -Note '<一句话>'`，索引与本文档同步追加。
- 软删**保留**文档；`-Hard` 归档到 `tools\_archive\`；只有 `-Hard -PurgeDoc` 才彻底删除。
