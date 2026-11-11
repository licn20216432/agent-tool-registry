# Agent 初始化指令（永久规则）

读 `$env:AGENT_REGISTRY` 作为工具索引；**未设置时默认读本仓库根目录的 `registry.json`**（相对脚本位置解析，所以整个文件夹放在任意盘符 / 路径都能用，换设备不需要改配置）。

## 交互契约：用户只说意图，Agent 负责执行命令（强制）

**用户永远不需要自己写或粘贴 PowerShell 命令。** 本文档所有 `.\scripts\*.ps1` 代码块都是给 Agent 看的**内部动作清单**，不是交给用户的作业；用户用自然语言说出意图 + 必要信息（工具名 / 路径 / 改什么）即可。Agent 必须自己解析意图 → 选脚本 → 拼参数 → 执行 → 核对结果 → 用一句话回报。

| 用户怎么说（示例） | Agent 自动做什么 | 背后执行的动作（用户不用管） |
|---|---|---|
| 「把 Bandizip 加进索引，位置 `<本机实际路径>`，用来解压/压缩」 | 查重 → 判断简单/复杂工具 → 注册 → 回报 id 与 version | `register.ps1 -Path ... -Functions extract,compress -Tags ... -Keywords ... -CategoryPath ... -Tier 3` |
| 「把 bz 的路径改成 …」/「给 bz 补个标签」/「bz 升级了」 | 定位 id → **原地改**，保留 id 与 added_at | `update-tool.ps1 -Id bz -Path ...` / `-Tags ... -AddTags` / `-RefreshVersion` |
| 「删掉 xx 工具」 | 默认软删（可恢复）；明说「彻底删」才硬删；`-PurgeDoc` 单独确认 | `unregister.ps1 -Id xx [-Hard [-PurgeDoc]]`，说明文档由脚本自动联动 |
| 「加个 Quicker 动作，码是 SHOT」 | 写入 `quicker_actions` | `register.ps1 -Quicker -ActionCode SHOT -Functions ...` |
| 「这个任务里用到了 bz 的 a 接口，记一下」 | 任务之余按**从简原则**补写一条 | `record-interface.ps1 -Id bz -Name a -Syntax ... -Note ...` |
| 「有哪些工具能用」/「本机有什么编译器」 | 只读检索并汇报 | `init-discovery.ps1 -InjectPrompt` / `route_task_v2.ps1 -Task ...` / `tool-doc.ps1 -List` |
| 「初始化」+ 给出 `AGENT_INIT_PROMPT.md`（贴全文或给路径） | 自己读规则、确认索引位置、跑只读自检与分层检索 | 见下节「新会话初始化」的五步 |

执行要求：
1. **先读盘再动手**：每次任务从磁盘取最新 version（`route_task_v2.ps1` / `Get-Registry`），不背清单、不用旧记忆里的路径。
2. **缺信息只问一句**：没给路径、id 不明确、判断不了软删/硬删时先问清，不猜路径、不拿相似 id 凑数。用户只给了路径没说用途时，从工具名 / 对话上下文补 1–3 个 `functions` 和 `tags / keywords`（`-AutoAnalyze` 可辅助读 `--help`），**别留空**，否则以后 `route_task_v2.ps1` 检索不到；确实推不出才问。补写接口仍遵守从简原则，不预先抄全量参数。
3. **不可逆动作要用户点头**：`-Hard -PurgeDoc`（彻底删文档）、批量 `-Apply` 登记、自制脚本转正，都必须有用户明确指令；常规增删默认走可恢复方式（软删 / 归档）。
4. **自制脚本审批不因「说话」而绕过**：用户在对话里明确同意后，Agent 可代为执行 `approve-tool.ps1`，但 `-ApprovedBy` 必须是可确认的**用户标识**，不得填 Agent 自己、不得默认取当前用户名、不得手工改索引绕过。`approve-tool.ps1` 会生成一次性凭证并传给 `register.ps1`；直接给 `register.ps1` 塞 `-ApprovedBy` 会被拒绝，转正唯一入口是 `approve-tool.ps1`。
5. **写完必须回报**：输出 `[Registry] 操作: <动作> | 工具: <id> | 变更: <字段> | version: <新版本号>`，再用自然语言说明「索引现在变成什么样」；失败要说原因和下一步，不静默吞错。
6. **不要把命令甩给用户**：除非用户明确说「给我命令我自己跑」，否则别把脚本代码块复制进回复让用户执行。

用户提到「软件更新了 / 卸载了 / 换目录了」时，同样由 Agent 自己跑 `validate-registry.ps1`（先只读）或 `update-tool.ps1` / `unregister.ps1` 落地；**不需要通知其它会话刷新**，它们下次任务会懒加载新 version。

## 8 条核心原则
1. 本地优先　2. 批量优先　3. GUI 兜底　4. 积极发现
5. 粒度约束（一脚本一件事）　6. 复用检查（先参数化）
7. 先规划后执行（≥3步）　8. 归档审批（复杂/无复用脚本须用户同意）

## 系统自带命令优先（不入库，直接调）
- 哈希: `certutil -hashfile` / `Get-FileHash`
- 文件对比: `fc` / `comp` / `robocopy /L`
- 查重/重命名: `ren` / `Rename-Item`
- 编码/换行/BOM: PowerShell `.NET` 读写
- 目录遍历/筛选: `Get-ChildItem` / `dir /s`
- 磁盘分析: `Get-ChildItem | Measure-Object`
- 同步备份: `robocopy` / `xcopy`
- 分卷加密: `makecab` / `cipher`
- 轻量 zip: `Compress-Archive` / `Expand-Archive` / `tar.exe`
规则：遇到上面需求优先系统命令，不满足才写脚本或注册外部工具。
这些属于初始化分层检索的 **T2（零级/一级）**：`init-discovery.ps1` 只报告、绝不写入索引。

## 二次处理（GUI/外设/浏览器）
- 截图: .NET / `pyautogui.screenshot()`
- 键鼠: Win32 API / `pyautogui` / `pywinauto`
- 浏览器: Selenium / Playwright / CDP（浏览器本体路径由初始化检索 T3 发现，不靠猜）
- 兜底: Quicker 动作 → `QuickerStarter.exe -c "runaction:动作码 参数"` 
- 标记 `requires_gui=true`，无头环境不调

## 新会话初始化：自动分层检索（每次开会话自动跑，只读）

**用户侧只做两件事**：说一句「初始化」，并把本文件交给 Agent（贴全文，或给出仓库内 `AGENT_INIT_PROMPT.md` 的路径）。下面全部由 Agent 自己执行，不要求用户敲任何命令：

1. 读入本文件，作为本会话的永久规则
2. 确认索引可用：优先读 `$env:AGENT_REGISTRY`；未设置时脚本自动定位仓库根目录的 `registry.json`，**无需配置环境变量**。只有要把索引放到仓库外时才需要设置 `AGENT_REGISTRY`
3. 跑只读体检：`validate-registry.ps1` 与 `route_task_v2.ps1 -Task "<示例任务>"`
4. 跑 `init-discovery.ps1 -InjectPrompt`，把四级可用工具清单摘要给用户
5. **不自动 `-Apply`**；只有用户明确说「登记 / 加入索引」时才写盘

上面第 4 步的命令，**每个新会话开始时也要先跑一次**（只读、不写索引、不需要用户批准）：

```powershell
.\scripts\init-discovery.ps1 -InjectPrompt      # 分层清单 + 可直接注入的片段
```

它按四级优先级报告本机可用工具并交给 Agent 使用；**自动的是「检索」，不是「注册」**。顺序不可颠倒：

| 层级 | 类别 | 例子 | 入库策略 |
|---|---|---|---|
| **T1**（最优先） | 编译器 / 构建工具 / 语言运行时 | gcc、g++、javac、dotnet、go、rustc、cmake、python、node | 优先发现，`-Apply` 自动登记（含版本指纹） |
| **T2** | 系统自带命令，**零级/一级** | certutil、robocopy、fc、ren、tar、curl、powershell、cmd | **只提示，永不入库**——Agent 本来就靠 `Get-Command` / 内置命令秒得，进索引只是冗余 |
| **T3** | 系统已注册的工具类软件 | Bandizip(`bz`)、Quicker、Chrome/Edge/Firefox、Git、ffmpeg、VSCode | 从 App Paths / 卸载表 / 常见安装位置发现，`-Apply` 自动登记；**Quicker 动作码由用户给，只提示不自动建条目** |
| **T4**（最后） | 其它工具软件与脚本 | 目录扫描发现的零散 exe、`.ps1/.py/.bat` 脚本 | 默认只报告；二进制需 `-IncludeTier4`；**脚本一律走归档审批，绝不自动入库** |

发现来源：PATH、工具/编译器常见目录（`-Dirs` 追加）、注册表 App Paths、卸载表 `DisplayIcon`、常见安装位置。同名 exe 的多来源会自动合并为一条最可靠路径，不会登记成 `git` 与 `git-2`。编译器 `bin` 目录里的附属程序（ar/as/ld/nm…）整目录跳过，避免刷屏。

写入是**显式**的，且可缩到只登记编译器：

```powershell
.\scripts\init-discovery.ps1 -MaxPerTier 99     # 先看全清单
.\scripts\init-discovery.ps1 -Apply             # 默认登记 T1 + T3
.\scripts\init-discovery.ps1 -Apply -OnlyTiers 1     # 只登记编译器/运行时
.\scripts\init-discovery.ps1 -Apply -IncludeTier4    # 连 T4 二进制一起（脚本仍要审批）
```

批量新增只 `version + 1`；重复跑 `-Apply` 幂等（已在索引的路径跳过）。**只读检索每次新会话自动跑，但不要按定时器或「连续 N 次空候选」自动 `-Apply`**——那会悄悄污染索引，写盘动作由用户或明确需求触发。

`tier` 是条目的可选字段（1/3/4；T2 不入库所以没有 2）。`route_task_v2.ps1` 在**分数相同**时按 T1 > T3 > T4 > 未分层排序；任务相关性仍由分数主导，不让不相关的编译器压过真正匹配的压缩工具。

## 积极扫描（补充手段）
- 初始化分层检索走 `init-discovery.ps1`；只想深挖某个目录里的运行时/自动化库时用 `scripts/scan-directory.ps1 -Quick -Dirs <目录>`
- 优先发现：python/dotnet/gcc/java/lua/node/go/rust 等运行时；pyautogui/pywinauto/selenium 等自动化库
- 编译器/自动化自动登记；系统命令只提示不入库

## 工具检索前置（v2）
索引只存一份在磁盘上，Agent **不要把工具清单背进长期记忆**。每次任务先检索，再决定用哪个：

```powershell
.\scripts\route_task_v2.ps1 -Task "<用户任务原文>" -InjectPrompt
```

1. 先跑 v2，拿候选（默认 TopN=5，按 `functions`/`tags`/`keywords`/`category_path` 打分）
2. 从候选里选最合适的；同分时按 `T1 > T3 > T4 > T-` 排序（输出里带 `[T3]` 这类标签）；Quicker 动作标 `[GUI 兜底]`，永远排在普通工具之后
3. 候选为空或不合适 → 加 `-All`，或直接读 `registry.json` 全量兜底
4. 系统自带命令命中提示时直接调用，不查索引
5. 旧脚本 `route_task.ps1` 仍保留（按 `functions` 硬匹配列全部候选），可并行对比；切换默认入口前先跑两者验证效果

`route_task_v2.ps1` 是**只读**的，永不写索引；它输出的是候选清单，不是唯一答案。

## 工具文档分层（复杂工具写文档，简单工具直接指向 exe）

判断标准是 **接口数量 × 跨会话复用频次**，不是「工具本身复杂」：Godot / ffmpeg / Bandizip 这类接口多、会被多个会话反复调用的工具值得建档；`test.exe`、单用途脚本建档只是维护负担。

| 类型 | 索引形态 | 字段 |
|---|---|---|
| **简单工具** | `索引 → locator.primary → exe` | 不写 `usage_page` / `doc_level` / `interfaces`，零开销 |
| **复杂工具** | `索引 → usage_page + interfaces → 完整文档（按需）→ exe` | `usage_page`、`doc_level=detailed`、`interfaces[{name,syntax,note}]`、`doc_checked_at` |

**索引永远保留可执行文件路径**：不允许只存文档路径，否则连一次简单调用都要两跳。多一层文档的价值是「把接口知识沉淀一次」，不是「多一次跳转」——所以：

1. 结构化接口清单 `interfaces` 直接存在索引条目里，命中时由 `route_task_v2.ps1 -InjectPrompt` **一次注入**（接口名 + 说明 + 典型调用）。常见任务零跳转，不用 `--help` 试探。
2. 完整文档只在需要详细参数、开关、坑位时按需读：`tool-doc.ps1 -Id <id> -Full`。**不要把整本文档塞进每次 prompt**，会撑爆上下文。
3. `doc_level=brief` 是老条目（只有用法页、无接口清单）的兼容标记；`none` 表示简单工具。

```powershell
.\scripts\tool-doc.ps1 -List                  # 看所有条目的文档分层状态
.\scripts\tool-doc.ps1 -Id bz                # 基本信息和接口清单（不读全文）
.\scripts\tool-doc.ps1 -Id bz -InjectPrompt  # 紧凑片段，可直接注入别的会话
.\scripts\tool-doc.ps1 -Id bz -Full          # 需要全部参数/坑位时才展开
.\scripts\tool-doc.ps1 -Check                # 一致性体检：文档缺失、无接口清单、版本过期
```

建档流程：照 `tools\_template-detailed.md` 写文档（顶部 `<!-- tool_version: ... -->` 复核头）→ 照 `examples\interfaces-bz.json` 写接口清单 JSON → `update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocLevel detailed -InterfacesFile <清单.json> -DocChecked`。也可在注册时一步带上 `register.ps1 ... -UsagePage ... -InterfacesFile ...`。

**软件升级后**：`validate-registry.ps1 -Apply` 刷新版本指纹 → 复核文档接口是否变化 → 必要时更新 `interfaces` → `update-tool.ps1 -Id <id> -DocChecked`。`tool-doc.ps1 -Check` 会比对文档头 `tool_version` 与索引 `version_info.product_version`，不一致就告警。

## 工具文档生命周期与从简原则（强制）

**从简原则**：说明文档只写「实际用过或确实常用」的功能与接口。基本用不上、从没使用过的功能、参数、开关、退出码，**不要预先详细写**。第一次在任务里真正用到时，在任务之余用一条命令补写，索引与文档一起更新：

```powershell
.\scripts\record-interface.ps1 -Id bz -Name a -Syntax 'bz a -y out.zip <files>' -Note '追加文件到已有包' -Task '给压缩包补两个文件'
```

不要为了「文档看起来完整」去跑一遍 `--help` 把全部子命令抄进来：那会让注入片段变长、维护成本上升，而多数条目永远用不到。`tool-doc.ps1 -Check` 在接口数超过 8 条时会提示精简（`-WarnAbove` 可调）。

**添加 / 修改 / 删除时，索引与说明文档必须一起变**（脚本已自动联动，不要手工改文件）：

| 操作 | 索引 | 说明文档 |
|---|---|---|
| 注册简单工具（不传文档参数） | 只写 `locator.primary` | 不生成文件，`索引 → exe` 零开销 |
| 注册复杂工具（`-UsagePage` / `-InterfacesFile` / `-DocLevel detailed`） | 写 `usage_page` + `interfaces` | 文件不存在自动生成**从简骨架**，接口清单写进受管区块 |
| 改接口清单 `-InterfacesFile` | 原地更新 `interfaces`，幂等 | 自动同步文档里 `<!-- interfaces:start --> … <!-- interfaces:end -->` 表格 |
| 改用法页 `-UsagePage` | 原地更新 `usage_page` | 旧文档无人引用 → 移入 `tools\_archive\`；共享文档保留 |
| 复核 `-DocChecked` | 刷新 `doc_checked_at` | 刷新文档头 `tool_version` / `checked_at` |
| 任务里用到新接口 | `record-interface.ps1` 追加一条（幂等，记录 `used_count` / `last_used`） | 同步写入文档受管表；没有文档时自动建从简骨架 |
| 软删除 `unregister -Id` | `deleted=true` | **保留**文档，条目可随时重新激活 |
| 硬删除 `unregister -Id -Hard` | 物理移除条目 | **同时移出 `tools\` 根目录** → `tools\_archive\<id>-<时间戳>.md`；加 `-PurgeDoc` 才彻底删除 |

安全边界：只处理 `tools\` 下的 `.md`；`_template*.md`、`_archive\`、越界路径、被其它条目共享的文档一律不动。`tool-doc.ps1 -Check` 会报出孤儿文档、文档表格与索引 `interfaces` 不一致、版本头过期、接口清单臃肿。

## 维护触发规则（什么时候该动索引）
| 场景 | 动作 |
|---|---|
| **新会话初始化** | `init-discovery.ps1 -InjectPrompt`（只读，自动跑）→ 看四级清单 → 确认后才 `-Apply` |
| 任务到达 | `route_task_v2.ps1 -Task "<原文>"` 检索候选 |
| 工具调用报「文件不存在 / 命令未找到」 | **先** `validate-registry.ps1` 只读看报告 → 确认后再 `-Apply` 自愈路径 → 仍失败就报告用户，不反复重试 |
| 软件升级 / 换安装目录 | `validate-registry.ps1 -Apply` 刷新 `version_info` 或自愈路径；也可 `update-tool.ps1 -Id <id> -RefreshVersion / -Path <新路径>` |
| 升级后复核复杂工具文档 | `tool-doc.ps1 -Check` → 接口有变则更新 `interfaces` → `update-tool.ps1 -Id <id> -DocChecked` |
| 想给某工具补详细文档 | `update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocLevel detailed -InterfacesFile <清单.json>` |
| 用户要求改工具信息 / 补标签 | `update-tool.ps1 -Id <id> -Tags ... -Keywords ... -CategoryPath ... [-AddTags]`（原地改，保留 id 与 added_at） |
| 用户要求添加工具 | `register.ps1`（自制脚本见下节归档审批）；复杂工具带 `-UsagePage / -InterfacesFile` 会自动建从简文档；本机运行时发现可用 `scan-directory.ps1 -Quick` |
| 用户要求删除工具 | `unregister.ps1 -Id <id> [-Hard [-PurgeDoc]]`；**硬删会把说明文档一起移入 `tools\_archive`**，软删保留文档 |
| 任务里第一次用到某接口 | `record-interface.ps1 -Id <id> -Name <接口> -Syntax '<调用>' -Note '<一句话>'`（任务之余补写，索引与文档同步） |
| 发现某工具有新用法 | 补接口用 `record-interface.ps1`；只补元数据用 `update-tool.ps1 -Id <id> -Tags ... -AddTags`，**不要删了重注册** |

边界（刻意不做，别自作主张）：
- **不自动登记自制脚本**（归档审批规则优先）；不因「每隔 7 天 / 连续 3 次空候选」自动注册新条目
- 校验默认 dry-run，`-Apply` 才写盘；`verified:false` 的工具不自动删除
- 路径失效但 PATH 里有同名工具时，`validate -Apply` 会**改路径**而不是判定卸载；真的卸载要显式 `unregister -Id`
- 任何写入都 `version + 1` 并同步 `registry.md`；其它 Agent 下次任务懒加载，**不需要通知它们刷新**
- 维护完成后输出一行摘要：`[Registry] 操作: <动作> | 工具: <id> | 变更: <字段> | version: <新版本号>`

## 自制脚本归档审批（强制）
Agent 为复杂任务自制的脚本，按复用性分三类处置：

1. **一次性 / 复杂 / 无通用性**：放任务临时目录，用完即弃，**既不进索引也不必提案**。这是默认做法。
2. **想留作工具但无复用性**：`register.ps1 -Path <脚本>` 会被拦截，只生成待审提案到 `pending\pending-tools.json`（`$LASTEXITCODE=2`，`registry.json` 与 version 不变）。**必须请用户明确同意**，由用户（或用户授权的会话）执行 `approve-tool.ps1 -Id <提案id> -ApprovedBy '<用户标识>'` 才能转正；Agent 不得自行填写 `-ApprovedBy`，也不得手工改索引绕过。脚本层已强制：`approve-tool.ps1` 生成一次性凭证写入提案队列并传给 `register.ps1`，只有凭证匹配才允许写入索引；`register.ps1 -ApprovedBy '<任意值>'` 单独调用一律拒绝并生成提案，Agent 无法靠拼参数绕过审批。
3. **通用、可参数化复用**：`register.ps1 -Path <脚本> -Reusable -Reason '<复用场景>'` 可直接登记，理由写入条目 `approval` 字段供追溯。

自制脚本登记后默认 `tier=4`（T4），提案与转正都会带上层级。二进制工具、Quicker 动作不受此门禁；`scan-directory.ps1` 发现的本机运行时也不受影响。判定有疑问时一律按第 2 类走审批。脚本层门禁是治理约束，不是安全边界——遵守规则靠 Agent 自律与用户把关。

## 索引管理
索引有两类实体：`tools`（按 `locator.primary` 定位）与 `quicker_actions`（id = `quicker-<动作码>`，靠 `starter` + `invoke_template` 调用）。下面四个脚本**同时支持两者**。

- 注册: `register.ps1 -Path <p> -Functions a,b [-Tags ...] [-Keywords ...] [-CategoryPath '类/子类'] [-Tier 1|3|4] [-AutoAnalyze] [-UsagePage ... -DocLevel ... -InterfacesFile ...]`（自制脚本见上节归档审批；Quicker 动作默认 T3；简单工具不传文档参数；传了文档参数会自动补建从简说明文档）
- 注册 Quicker: `register.ps1 -Quicker -ActionCode <码> -Functions a,b [-Name ...]`（软删过的同一码会原地恢复）
- 提案/审批: `approve-tool.ps1 -List` 查待审；`-Id <提案id> -ApprovedBy '<用户标识>'` 转正；`-Id <提案id> -Reject` 拒绝（提案里的分类元数据会随转正带入条目）
- 原地更新: `update-tool.ps1 -Id <id> [-Path <新路径>] [-Functions a,b] [-UsagePage ...] [-RefreshVersion] [-Show]`
  - 分类元数据: `-Tags a,b [-AddTags]` / `-Keywords '解压,压缩' [-AddTags]` / `-CategoryPath 'file_operation/archive'` / `-Tier 1|3|4`；`-Show` 可查看
  - 文档层: `-UsagePage 'tools/<id>.md'` / `-DocLevel none|brief|detailed` / `-InterfacesFile <清单.json>` / `-DocChecked`（接口清单幂等，重复执行不涨 version；改接口清单会同步刷新说明文档的受管表格，改用法页会归档旧文档）
  - 任务之余补写单条接口: `record-interface.ps1 -Id <id> -Name <接口> [-Syntax '<调用>'] [-Note '<一句话>'] [-Task '<任务>']`（从简原则的渐进式入口，幂等）
  - 升级/换目录/改说明都用它，**不要删了重注册**（会丢 id 与 added_at）
  - Quicker 动作另可用 `-Name / -ActionCode / -InvokeTemplate`；`-Path` 表示启动器，`-CommonPaths` 写 `starter_fallback`；改 `-ActionCode` 会同步改 id 与调用模板
- 删除: `unregister.ps1 -Id <id> [-Hard [-PurgeDoc]]`（默认软删并保留说明文档；`-Hard` 物理移除条目 + 把说明文档移入 `tools\_archive`；`-PurgeDoc` 才彻底删除文档）
- 校验: `validate-registry.ps1`（默认只出报告，确认后加 `-Apply` 才写入）
  - `-Apply` 会自动：修正搬迁后的路径、刷新升级后的 `version_info` 版本指纹、软删除已验证但路径失效的工具
  - Quicker 段另检查启动器有效性与动作码/模板一致性；启动器失效**只报告不自动删**（GUI 兜底动作）
- 路由: `route_task_v2.ps1 -Task "<描述>" [-TopN 5] [-InjectPrompt] [-All]`（检索前置，推荐；复杂工具的接口清单随命中结果一次注入）；`route_task.ps1 -Task "<描述>"`（按 functions 硬匹配的旧版，保留对比）
- 文档: `tool-doc.ps1 -List / -Id <id> [-Full] [-InjectPrompt] / -Check [-WarnAbove 8]`（只读；分层披露，别每次注入全文；`-Check` 会查孤儿文档、文档/索引接口表不一致、版本头过期、清单臃肿）

索引更新后 version 自动 +1，其他 agent 下次任务懒加载。
注意 1：路径未找到但从未验证通过（`verified:false`）的工具不会被自动删除，别把它当成失效工具。
注意 2：工具索引只回答「本机有哪些工具、在哪、怎么调」，**不负责生成代码/内容**；编译器只接收已写好的源文件。写代码是 Agent（必要时加载对应方向 skill/专家）的职责。
注意 3：`category_path` / `tags` / `keywords` / `tier` / `usage_page` / `doc_level` / `interfaces` 都是可选元数据，旧条目缺这些字段不影响任何脚本；缺 `tier` 记作 `T-`，缺文档字段按 `doc_level=none`（简单工具）处理。
