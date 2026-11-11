# agent-tool-registry

> 让 AI Agent 在任意一台 Windows 设备上，跨会话记住「这台机器有什么工具、装在哪、怎么用」。

一个纯本地、纯文本、零依赖的**设备级工具索引**：把散落在各处的命令行工具、编译器、GUI 兜底动作登记进 `registry.json`，让每个新会话的 Agent 一上来就知道该调什么，而不是每次重新摸索一遍。

---

## 目录

- [这是什么](#这是什么)
- [适用环境](#适用环境)
- [快速开始（3 步）](#快速开始3-步)
- [换一台设备 / 多机使用](#换一台设备--多机使用)
- [全新生成一份运行包](#全新生成一份运行包)
- [核心概念](#核心概念)
- [使用教程（按场景）](#使用教程按场景)
- [用户话术速查](#用户话术速查)
- [脚本参考](#脚本参考)
- [目录结构](#目录结构)
- [与 Agent 配合](#与-agent-配合)
- [数据文件与编码约定](#数据文件与编码约定)
- [开发者指南](#开发者指南)
- [常见问题](#常见问题)
- [已知边界](#已知边界)
- [许可证](#许可证)

---

## 这是什么

用 Agent 干活时，几个问题会反复出现：

| 痛点 | 本项目的做法 |
|---|---|
| 每次新会话都要重新问「这台机器装了什么」 | 一份 `registry.json` 持久保存，所有会话懒加载同一个索引 |
| 工具装在 `D:\Somewhere\...`，换机器路径全变 | 索引记录 `locator.primary` + 备用路径 + PATH 搜索，体检脚本自动自愈 |
| 简单工具也写一页文档，维护成本高 | **简单工具零文档**（索引直接指向 exe）；复杂工具才渐进建档 |
| 自制脚本被随手塞进索引，无人审核 | **审批门禁**：脚本只生成待审提案，必须用户明确同意才能转正 |
| 多个 Agent / 多进程同时写索引互相覆盖 | 命名 Mutex + 锁内合并 + 原子替换，并发新增不丢条目 |
| 删掉工具后文档变成孤儿 / 误删共享文档 | 三级删除 + 文档归档 + 共享保护 + 孤儿检测 |
| Agent 擅自写盘、重复执行把 version 刷爆 | 默认 dry-run、`-Apply` 才落盘、**无变更绝不写盘**、重复执行幂等 |

**特性一览**

- 零依赖：只用 Windows 自带 PowerShell，不联网、不装包、不需要管理员权限
- 路径无关：整个文件夹可以放在任意盘符 / 任意目录，clone 下来直接跑
- 跨 Agent / 跨会话：索引按 `version` 懒加载，改完不用通知其它会话
- 四级分层发现（T1 编译器 → T2 系统命令 → T3 已装软件 → T4 其它 / 脚本）
- 检索前置：按分类元数据打分取 TopN，`-All` 看全量，`-InjectPrompt` 输出可注入片段
- 文档从简：只记录实际用过的接口，用到再补，接口清单同步进索引与 md
- 可验收：随附 64 个用例的验收测试文档，任何改动都能回归

> 项目定位是「给 Agent 用的本机能力清单 + 治理规则」，不是包管理器，也不会替你安装软件。

---

## 适用环境

| 项 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11（依赖 `.exe`、注册表 App Paths、Quicker 启动器） |
| PowerShell | Windows PowerShell 5.1（系统自带）或 PowerShell 7.x |
| 权限 | 普通用户即可，无需管理员 |
| 外部依赖 | 无。不联网、不调用云服务、不写注册表 |
| Linux / macOS | 暂不支持（发现逻辑与路径语义面向 Windows） |

---

## 快速开始（3 步）

### 第 1 步：拿到文件夹

```powershell
git clone https://github.com/licn20216432/agent-tool-registry.git
cd agent-tool-registry
```

也可以直接下载 Release 的 zip 解压到任意目录，例如 `D:\Dev\agent-tool-registry`。**放在哪都行**，脚本按自身位置定位索引。

仓库自带的是**空索引模板**（`version=1` / `tools=[]`），不含任何人的个人数据，也不预置任何指向本机路径的工具条目。

### 第 2 步：跑一次自检（只读，不写盘）

在仓库根目录打开 PowerShell：

```powershell
.\scripts\validate-registry.ps1                        # 体检索引
.\scripts\route_task_v2.ps1 -Task "解压并编译"          # 检索路由
.\scripts\init-discovery.ps1 -InjectPrompt            # 列出本机四级可用工具
```

空索引下前两条会显示「无命中 / 回退全量」，这是正常的；第三条会列出本机编译器、系统命令与已装软件，并输出可注入 Agent 的片段。

> **不需要设置 `AGENT_REGISTRY` 环境变量。** `scripts\lib\registry-core.ps1` 默认按 `$PSScriptRoot\..\..\registry.json` 定位索引，所以整个文件夹搬走也能用。

### 第 3 步：把规则装进 Agent

把 [`AGENT_INIT_PROMPT.md`](AGENT_INIT_PROMPT.md) 全文贴给 Agent，或作为自定义规则 / 长期记忆 / system prompt 载入（各平台入口不同）。这份文件声明了交互契约、四级发现优先级、系统命令优先、文档分层与维护触发规则。

**只给索引、不给规则，等于只有通讯录没有使用约定。**

之后用户只需说自然语言（「把 7-Zip 加进索引，位置 …」「解压这个包」「xx 卸载了，清一下」），Agent 会自己选脚本、拼参数、执行并回报；本文档下面的命令都是给 Agent 参考的动作清单，用户不必敲。

---

## 换一台设备 / 多机使用

**最简做法：复制整个文件夹。** 路径、盘符随便换，脚本内部没有写死任何绝对路径。复制后跑一次只读的 `init-discovery.ps1 -InjectPrompt` 看看新机器的工具，确认后再登记。

> ⚠️ **迁移前先检查环境变量**：若你之前按旧版说明设过 User 级 `AGENT_REGISTRY`（绝对值），它会**优先于**默认的相对路径定位 —— 把文件夹搬到新位置后，脚本仍会读写旧目录的索引。搬迁前清除或改指向新目录：

```powershell
# 查看
[Environment]::GetEnvironmentVariable('AGENT_REGISTRY','User')
# 清除（当前会话也一起清）
[Environment]::SetEnvironmentVariable('AGENT_REGISTRY',$null,'User')
Remove-Item Env:\AGENT_REGISTRY -ErrorAction SilentlyContinue
```

### 可选：把索引放到仓库外

适合「多份代码共用一份索引」或「索引放在同步盘」：

```powershell
# 仅当前会话
$env:AGENT_REGISTRY = 'D:\sync\my-registry.json'

# 永久（User 级，重开终端生效，无需管理员）
[Environment]::SetEnvironmentVariable('AGENT_REGISTRY','D:\sync\my-registry.json','User')
```

设了之后，所有脚本都读这份索引，人读镜像 `registry.md` 也会**写到索引所在目录**（不是仓库目录）。用一个空目录里的索引时，先跑一次 `bootstrap-registry.ps1 -Root D:\sync` 生成初始文件。

### 可选：追加本机专属扫描目录

默认扫描位置是各软件的常见安装路径与 `%USERPROFILE%` 下的 `Tools/Scripts/Work`。你自己的目录用下面任一种方式告诉脚本：

```powershell
# 方式一：环境变量（分号分隔，对 init-discovery 和 scan-directory 都生效）
$env:AGENT_SCAN_DIRS = 'D:\MyTools;E:\Portable'

# 方式二：命令行参数（单次生效）
.\scripts\scan-directory.ps1 -Quick -Dirs 'D:\MyTools'
.\scripts\init-discovery.ps1 -InjectPrompt -Dirs 'D:\MyTools'
```

### 关于个人数据

`registry.json`、`registry.md`、`pending\pending-tools.json`、`tools\*.md`、`tools\_archive\` 都是**你本机的运行数据**。仓库里提供的是空模板；日常注册工具后这些文件会变化。给上游提 PR 时请勿提交它们，建议放在个人 fork / 本地分支，或用 `.git/info/exclude` 排除。

---

## 全新生成一份运行包

`bootstrap-registry.ps1` 把整个项目（32 个文件）内嵌成模板，可在**任意空目录**生成一份完整、可独立运行的副本：

```powershell
# 生成到指定目录
.\bootstrap-registry.ps1 -Root D:\my-agent-tools

# 不传 -Root：默认生成到脚本所在目录下的 generated\ 子目录（不会覆盖仓库自身）
.\bootstrap-registry.ps1
```

- 目标目录已有 `registry.json` 时**拒绝运行**，避免误跑清空注册记录；确需重建先备份再加 `-Force`。
- 生成的是空索引（`version=1`），交互契约、规则、修复标记全部带入。
- 验收文档 `TEST_GUIDE.md` 属于开发材料，**不会**进入生成包。

---

## 核心概念

### 索引 `registry.json`

机器读的唯一真源，UTF-8 **无 BOM**。顶层字段：

| 字段 | 说明 |
|---|---|
| `version` | 每次真实变更 +1；无变更绝不递增 |
| `tools[]` | 普通工具 / 脚本 |
| `quicker_actions[]` | GUI 兜底动作（`id = quicker-<动作码>`） |
| `rules` | 治理规则：本地优先、批量优先、GUI 仅兜底、审批必需等 |
| `last_updated` / `last_writer` | 最后写入时间与写入者 |

`registry.md` 是自动重建的**人读镜像**，与 json 同目录，不要手写。

### 两类实体

| | `tools[]` | `quicker_actions[]` |
|---|---|---|
| 定位 | `locator.primary` 指向可执行文件 | `starter` + `invoke_template` 调用 Quicker 启动器 |
| 层级 | 默认 T3 / T4 | 固定 T3，`requires_gui=true` |
| 检索排序 | 靠前 | **永远排在普通工具之后**（GUI 只是兜底） |
| 发现 | 可自动扫描 | 动作码由用户给，不自动发现 |

### 四级分层（T1–T4）

| 层级 | 内容 | 是否入库 |
|---|---|---|
| T1 | 编译器 / 运行时（gcc、python、dotnet…） | 可登记 |
| T2 | 系统自带命令（robocopy、tar、Compress-Archive…） | **只提示，不入库**，直接调用 |
| T3 | 已安装的软件工具（7-Zip、Bandizip、浏览器…） | 可登记 |
| T4 | 其它工具与自制脚本 | 二进制需 `-IncludeTier4`；脚本一律走审批 |

### 文档分层与「从简原则」

- **简单工具**：`usage_page = null`，不生成 `.md`，索引直接指向 exe，零维护开销。
- **复杂工具**：注册时带 `-InterfacesFile` 或 `-DocLevel detailed`，自动生成从简骨架与**受管接口区块** `<!-- interfaces:start --> … <!-- interfaces:end -->`。
- **用到再补**：任务中第一次用到新接口，用 `record-interface.ps1` 追加一条，索引与 md 同步更新，重复执行幂等。
- 只记录实际用过的接口，不预先罗列参数与开关；文档臃肿会被 `tool-doc.ps1 -Check` 提示。

### 版本、并发与幂等

- 每次真实变更 `version + 1`；相同参数重复执行 → 无变更、不写盘、不涨版。
- 写入用命名 Mutex 保护，锁内重读磁盘并**合并他人新增**，硬删意图不会被旧快照捡回。
- JSON 通过唯一 `.tmp` + `File.Replace` 原子替换，不留半截文件。
- 默认 dry-run：`validate-registry.ps1` / `init-discovery.ps1` 要 `-Apply` 才写盘；**例外**：`scan-directory.ps1` 发现运行时 / 自动化库会直接登记（见「主动扫描」）。

### 审批门禁

自制 `.ps1` / `.py` 等脚本默认**不允许直接入库**：`register.ps1` 会生成 `pending\pending-tools.json` 里的待审提案并退出，索引 version 不变。必须由用户明确同意后由 `approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'` 转正。

- `-ApprovedBy` 不能直接传给 `register.ps1` 绕过审批（会被拒绝）。
- 通用、可参数化复用的脚本可走声明式直登 `-Reusable -Reason '<复用场景>'`。
- 转正后一次性凭证清空、提案状态置 `approved`，重复拦截不会生成第二条提案。

### 删除分级

| 命令 | 索引 | 文档 |
|---|---|---|
| `unregister.ps1 -Id x` | 软删（`deleted=true`，可原地恢复并复用 id） | **保留** |
| `unregister.ps1 -Id x -Hard` | 物理移除条目 | 归档到 `tools\_archive\` |
| `unregister.ps1 -Id x -Hard -PurgeDoc` | 物理移除 | **彻底删除**，不可恢复 |

`-PurgeDoc` 不带 `-Hard` 会被拒绝且**不写盘**。共享文档、模板、`_` 开头的文件与越界路径一律不动。

---

## 使用教程（按场景）

以下命令都在仓库根目录执行；除注明外均为写操作（会 `version + 1`）。示例中的 `<...>` 请替换为本机实际值。

### 1. 让 Agent 先检索再动手

```powershell
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包"              # 打分 TopN=5
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包" -All          # 全量候选（不被 TopN 截断）
.\scripts\route_task_v2.ps1 -Task "解压 7z 压缩包" -InjectPrompt # 输出可直接贴进 Prompt 的结构化片段
.\scripts\route_task.ps1 -Task "解压 7z 压缩包"                  # 旧版按 functions 硬匹配，可对比
```

无命中时自动回退全量；注入片段包含接口清单而不只是工具名；GUI 兜底动作排最后。

### 2. 注册一个简单工具

```powershell
.\scripts\register.ps1 -Path "C:\Program Files\7-Zip\7z.exe" -Functions 'extract,compress' -Tags 'archive,zip'
```

预期：`✅ 已注册: 7z.exe (ID: 7z)`，`version → 2`，**不生成** `tools\7z.md`（`usage_page` 为 null）。同路径重复执行会提示「已存在索引，跳过」且不涨版。

### 3. 注册一个复杂工具（接口清单 + 文档）

先准备接口清单 `examples\interfaces-bz.json` 那样的 JSON：

```json
[
  { "name": "c", "syntax": "bz c -y -fmt:zip out.zip <files>", "note": "新建包" },
  { "name": "x", "syntax": "bz x -aoa -o:<dir> <archive>", "note": "解压，保留目录结构" }
]
```

```powershell
.\scripts\register.ps1 -Path "<bz.exe 完整路径>" `
  -Functions 'extract,compress,list,test' `
  -Tags 'archive,zip,7z,rar' -Keywords '解压,压缩,打包' `
  -CategoryPath 'file_operation/archive' -Tier 3 `
  -InterfacesFile '.\examples\interfaces-bz.json'
```

预期：2 条接口入库、`doc_level=detailed`、`usage_page=tools/bz.md`，自动生成从简骨架和受管接口表。参考示例文档 [`tools\_example-bz.md`](tools/_example-bz.md)。

### 4. 渐进式补接口

```powershell
.\scripts\record-interface.ps1 -Id bz -Name l -Syntax 'bz l <archive>' -Note '列出包内容'
```

索引与 md 的受管区块同步追加；重复执行提示「内容相同，无需重复补写」，version 不变。

### 5. 更新工具

```powershell
.\scripts\update-tool.ps1 -Id bz -Path "<新路径>" -Tags 'archive,zip,qa'   # 原地改，保留 id 与 added_at
.\scripts\update-tool.ps1 -Id bz -UsagePage 'tools/bz-v2.md'                # 改用法页：旧页自动归档
.\scripts\update-tool.ps1 -Id bz -RefreshVersion                            # 刷新版本指纹
.\scripts\update-tool.ps1 -Id bz -DocChecked                                # 复核文档头
.\scripts\update-tool.ps1 -Id bz -Show                                      # 只看不改
```

相同字段重复执行「无变更，索引未改动」。

### 6. 删除与恢复

```powershell
.\scripts\unregister.ps1 -Id bz                       # 软删（文档保留）
.\scripts\register.ps1 -Path "<同路径>" -Functions 'extract'   # 原地恢复，复用 id，不产生 bz-2
.\scripts\unregister.ps1 -Id bz -Hard                # 硬删 + 文档归档
```

重新激活时若新的 `usage_page` 与保留的旧页不同，旧页会归档到 `tools\_archive\`，不会残留成孤儿文档；被其它条目共享的文档则保留。

### 7. 自制脚本审批全流程

```powershell
# 1) 尝试登记 → 被拦截，只生成提案
.\scripts\register.ps1 -Path '.\examples\pipeline-example.ps1' -Functions 'utility'

# 2) 查看待审队列
.\scripts\approve-tool.ps1 -List

# 3) 用户明确同意后转正（-ApprovedBy 必须是可确认的用户标识，Agent 不能自批）
.\scripts\approve-tool.ps1 -Id <提案id> -ApprovedBy 'alice'

# 4) 不同意则拒绝
.\scripts\approve-tool.ps1 -Id <提案id> -Reject -Reason '不满足复用条件'
```

### 8. Quicker GUI 兜底动作

```powershell
.\scripts\register.ps1 -Quicker -ActionCode 'SHOT' -Functions 'screenshot,gui' -Name '截图动作'
.\scripts\update-tool.ps1 -Id 'quicker-SHOT' -Name '截图动作 v2'
.\scripts\update-tool.ps1 -Id 'quicker-SHOT' -ActionCode 'SHOT2'   # 改码同步改 id 与 invoke_template
.\scripts\unregister.ps1 -Id 'quicker-SHOT2'                      # 软删
```

启动器默认从 `%ProgramFiles%` 推导，也可 `-QuickerExe` 指定；换安装目录时靠 PATH 自愈。

### 9. 体检与自愈

```powershell
.\scripts\validate-registry.ps1            # dry-run：只报告，绝不写盘
.\scripts\validate-registry.ps1 -Apply     # 落盘：刷新版本指纹 / last_checked / 自愈路径 / 软删失效条目
```

只对 `verified=true` 的路径失效条目自动软删；未验证条目只报告不自动删（保护设计）。体检收敛后重复 `-Apply` 不涨版。

### 10. 初始化发现与主动扫描

```powershell
.\scripts\init-discovery.ps1 -InjectPrompt                          # 四级清单（只读）
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 1                    # 只登记编译器
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 4 -IncludeTier4 -Dirs 'D:\MyTools'
.\scripts\scan-directory.ps1 -Quick -Dirs 'D:\MyTools'              # 主动扫描；命中运行时 / 自动化库会直接登记
.\scripts\tool-doc.ps1 -List                                       # 列出文档状态
.\scripts\tool-doc.ps1 -Id bz -Full                                # 读完整文档
.\scripts\tool-doc.ps1 -Check                                      # 孤儿 / 版本头 / 表格一致性检查
```

> **注意**：`scan-directory.ps1` 与 `init-discovery.ps1` 不同，它没有 `-Apply` 开关 —— 扫到 `python.exe` / `gcc.exe` / `pyautogui` 等运行时或自动化库时会**直接写入索引**（`version + 1`），这是「积极扫描」的既有设计。只想看不想写时，把 `-Dirs` 指向不含运行时的目录，或先备份 `registry.json`。

---

## 脚本参考

`scripts\` 下 13 个入口、`lib\` 下 4 个 dot-source 库，另有 `scripts\rename\rename.ps1`，共 19 个 `.ps1`。

| 脚本 | 作用 | 写盘 |
|---|---|---|
| `register.ps1` | 注册普通工具 / Quicker 动作；自制脚本走审批门禁 | ✅ |
| `update-tool.ps1` | 原地更新字段、改路径 / 文档页 / 动作码、刷新指纹 | ✅ |
| `unregister.ps1` | 软删 / 硬删 / `-PurgeDoc` | ✅ |
| `approve-tool.ps1` | 列出 / 同意 / 拒绝待审提案 | ✅ |
| `record-interface.ps1` | 渐进式补写接口 | ✅ |
| `validate-registry.ps1` | 体检与路径自愈（默认 dry-run） | 仅 `-Apply` |
| `init-discovery.ps1` | 四级分层发现（默认只读） | 仅 `-Apply` |
| `scan-directory.ps1` | 主动扫描运行时 / 自动化库 | ✅（发现新工具时） |
| `route_task_v2.ps1` | 打分检索 / TopN / `-All` / `-InjectPrompt` | ❌ |
| `route_task.ps1` | 旧版按 functions 硬匹配 | ❌ |
| `tool-doc.ps1` | 文档读取与一致性检查 | ❌ |
| `registry-sync.ps1` | 由 json 重建 `registry.md` 镜像 | ✅（镜像） |
| `rename\rename.ps1` | 批量重命名示例工具 | ❌（索引） |

**库**（被入口 dot-source，不直接调用）：`lib\registry-core.ps1`（索引读写 / 锁 / 原子替换 / 定位自愈）、`lib\doc-lifecycle.ps1`（文档生成 / 受管区块 / 归档 / 孤儿检测）、`lib\doc-fields.ps1`（文档字段与接口清单解析）、`lib\pending-store.ps1`（提案队列读写）。

---

## 目录结构

```
agent-tool-registry/
├─ registry.json                  # 索引真源（UTF-8 无 BOM，仓库内为空模板）
├─ registry.md                    # 人读镜像，自动重建，勿手写
├─ AGENT_INIT_PROMPT.md           # 给 Agent 的永久规则 / 交互契约
├─ README.md                      # 本文档
├─ TEST_GUIDE.md                  # 验收测试（P0→P8，64 用例，开发用）
├─ USAGE_PHRASES.md               # 用户侧自然语言话术速查
├─ bootstrap-registry.ps1         # 在任意空目录生成完整运行包
├─ LICENSE                        # MIT
├─ .gitignore
├─ scripts/
│  ├─ *.ps1                       # 13 个入口脚本
│  ├─ lib/                        # 4 个公共库
│  └─ rename/rename.ps1
├─ tools/
│  ├─ _template.md                # 从简文档模板
│  ├─ _template-detailed.md       # 详细文档模板
│  ├─ _example-bz.md              # 说明文档示例（下划线开头，不算孤儿）
│  ├─ _archive/                   # 硬删归档的文档
│  └─ _notes/                     # 补充笔记
├─ examples/
│  ├─ interfaces-bz.json          # 接口清单示例
│  └─ pipeline-example.ps1        # 解压→重命名→打包流水线示例（纯系统命令）
└─ pending/
   └─ pending-tools.json          # 自制脚本待审队列（仓库内为空模板）
```

---

## 与 Agent 配合

配套的用户侧话术见 [`USAGE_PHRASES.md`](USAGE_PHRASES.md)：用自然语言怎么说才不产生歧义。

[`AGENT_INIT_PROMPT.md`](AGENT_INIT_PROMPT.md) 是「使用约定」，核心是**交互契约**：

> 用户永远不需要自己写或粘贴 PowerShell 命令。用户用自然语言说出意图 + 必要信息，Agent 自己解析意图 → 选脚本 → 拼参数 → 执行 → 核对结果 → 用一句话回报。

几条关键约定：

1. **系统自带命令优先**：普通 zip、哈希、遍历、重命名直接用 PowerShell / `tar.exe`，不入库。
2. **检索前置**：动手前先 `route_task_v2.ps1 -Task '<描述>'`，把命中工具的接口清单注入上下文。
3. **新会话自动分层检索**：`init-discovery.ps1 -InjectPrompt` 只读，不需要批准；**绝不自动 `-Apply`**。
4. **从简原则**：简单工具不建档，接口用到再补。
5. **不可逆动作要确认**：`-Hard -PurgeDoc`、批量 `-Apply` 必须用户明确点头。
6. **维护触发**：软件升级 / 换目录 / 卸载后，用 `validate-registry.ps1` 与 `update-tool.ps1` 自愈，其它会话下次任务懒加载新 version，无需通知。

典型对话：

> 用户：「把 7-Zip 加进索引，位置 `C:\Program Files\7-Zip\7z.exe`，主要用来解压 rar」
> Agent：查重 → 判断为简单工具 → 执行 `register.ps1 -Path ... -Functions extract,compress -Tags archive,rar` → 回报「已注册 7z，version → 2」

---

## 数据文件与编码约定

| 类型 | 编码 |
|---|---|
| `.ps1` / `.md` | UTF-8 **带 BOM**（PowerShell 5.1 读中文不乱码） |
| `.json` | UTF-8 **无 BOM**（严格解析器会拒绝 BOM） |

读文本一律用 `-Encoding UTF8` 或 `[IO.File]::ReadAllText(path, [Text.Encoding]::UTF8)`；`Get-Content -Raw` 不带编码在 5.1 下默认 ANSI，中文会乱码。新建含中文的 `.ps1` 用 `[Text.UTF8Encoding]::new($true)`，写 `.json` 用 `::new($false)`。

**改了磁盘文件，记得同步 `bootstrap-registry.ps1` 里对应的 `Write-File` 模板块**——生成器内嵌了全部 32 个文件的副本，验收用例 T57 会逐块比对，不一致会报错。

---

## 开发者指南

### 跑验收测试

[`TEST_GUIDE.md`](TEST_GUIDE.md) 是完整的独立验收材料，按 P0 → P8 顺序执行即可判断有无回归：

- **铁律**：生产目录只读，所有写盘操作在隔离副本里进行，结束后删除副本并确认生产索引未变。
- 覆盖：注册 / 文档 / 审批 / Quicker / 更新 / 删除 / 检索 / 发现 / 体检 / 扫描 / 并发 / 一致性 / 全新生成，共 64 个用例。
- 标注「**回归哨兵**」的是历史已修缺陷，重点核对。
- 路径全部由文首的 `$Repo` / `$QA` 变量控制，可在本机任意位置运行。

### 自检命令

```powershell
# 全脚本语法
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $t=$null; $e=$null
  [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e) | Out-Null
  if ($e.Count) { "$($_.Name): $($e[0].Message)" }
}

# 严格 JSON（Python 可选）
python -c "import json,io; json.load(io.open('registry.json',encoding='utf-8')); print('OK')"
```

### 参与贡献

欢迎提 Issue / PR。几点建议：

- 改动脚本时同步 `bootstrap-registry.ps1` 模板块，并跑一遍 `TEST_GUIDE.md` 的 P0–P8。
- 不要提交个人 `registry.json` / `registry.md` / `pending-tools.json` / `tools\*.md` 运行数据。
- 新功能请补一个用例到验收文档（含 PASS/FAIL 断言），避免只做人工判读。
- 保持「默认只读、无变更不写盘、幂等、审批不可绕过」这几条底线。

---

## 常见问题

**Q：换电脑要改配置吗？**
不用。复制整个文件夹到任意位置即可；脚本按自身位置定位索引。只有想让索引放在仓库外时才设 `AGENT_REGISTRY`。

**Q：需要管理员权限 / 联网 / 装依赖吗？**
都不需要。唯一例外是永久设置 User 级环境变量（普通 PowerShell 即可，仍不需管理员）。

**Q：支持 Linux / macOS 吗？**
暂不支持。四级发现依赖 Windows 注册表 App Paths、`%ProgramFiles%`、`.exe` 与 Quicker 启动器，路径语义也是 Windows 的。

**Q：PowerShell 7 能用吗？**
可以。编码约定（BOM）与 `ConvertFrom-Json` 行为在 7.x 下都兼容；项目默认在 5.1 上验收。

**Q：为什么重复执行一条命令没反应？**
这是设计。无变更不写盘、不涨 `version`，输出「无变更，索引未改动」表示幂等生效。

**Q：为什么注册 `.ps1` 被拦下来了？**
自制脚本默认需要用户同意。走 `approve-tool.ps1 -List` → `-ApprovedBy` 转正；通用可复用脚本可用 `-Reusable -Reason`。

**Q：我把文件夹复制到新目录了，脚本怎么还在改旧目录的索引？**
你可能设过 User 级 `AGENT_REGISTRY` 绝对路径，它优先于默认的相对定位。按上一节的方法清除或改指向新目录即可；用 `$env:AGENT_REGISTRY` 打印当前值确认。

**Q：`tool-doc.ps1 -Check` 报孤儿文档？**
`tools\` 根目录下没有条目引用的 `.md` 会被提示。确认无用可手工删除或用 `-Hard` 清理；`_template*`、`_archive\`、`_notes\` 与 `_` 开头的文件不会误报。

**Q：索引改坏了怎么办？**
`registry.json` 是纯文本，先备份；小问题用 `validate-registry.ps1 -Apply` 自愈，严重损坏时从 `bootstrap-registry.ps1 -Root <新目录>` 生成一份空包再重新登记工具。

**Q：为什么 `registry.md` 会自动变？**
它是每次写入自动重建的人读镜像，别手写。索引放到仓库外时，镜像跟着写到索引同目录。

---

## 已知边界

- `$LASTEXITCODE=2; return` 在 `-File` 方式调用时进程退出码仍可能是 0；脚本一律用 `&` 调用并读 `$LASTEXITCODE`。
- 并发保护只保证**新增条目不丢**；两个进程同时改同一条目的字段仍是后写覆盖。
- T2 系统命令只提示不入库；Quicker 动作码不自动发现；自制脚本一律走审批——都是刻意设计。
- 体检只对 `verified=true` 的路径失效条目自动软删；未验证条目只报告。
- `bootstrap-registry.ps1` 生成的 `.md` 比源模板少一个结尾换行，是 `Write-File` 的既有行为，不算 bug。
- `rename\rename.ps1` 的大小写重命名、`examples\pipeline-example.ps1` 的解压残留属于低风险已知边界。

---

## 许可证

[MIT](LICENSE) © 2026 agent-tool-registry contributors

可以自由使用、修改、商用，只需保留版权与许可声明。
