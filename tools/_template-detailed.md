# {工具名} 说明文档（复杂工具 / 接口较多时填写，从简）

<!-- doc_version: 1 | tool_version: {产品版本} | checked_at: {YYYY-MM-DD} | doc_level: detailed -->
<!-- 复核头：tool_version 要与 registry.json 的 version_info.product_version 一致，tool-doc.ps1 -Check 会核对 -->
<!-- 从简原则：只写「实际用过」或「确实常用」的接口；基本用不上、没使用过的功能与接口不要预先详细说明 -->

## 基本信息
- id / 名称：`{id}` / `{name}`
- 位置：`{locator.primary}`（索引里永远保留 exe 路径，本文档不是调用入口）
- 功能标签：{functions}　|　层级：T{tier}

## 接口清单（受管区块，由脚本同步，不要手改）
<!-- interfaces:start -->
| 接口 | 调用语法 | 说明 |
|---|---|---|
| `{已用接口1}` | `{syntax}` | {一句话说明} |
<!-- interfaces:end -->

> 这里只放已用过 / 常用的接口。没用过的接口**不要**预先写参数表、开关表、退出码表。
> 任务里真正用到新接口时，在任务之余补写：
> `.\scripts\record-interface.ps1 -Id {id} -Name <接口> -Syntax '<调用>' -Note '<一句话>' [-Task '<任务>']`
> 该命令会同时更新索引 `interfaces` 与本文档的受管区块。
> 索引里的 `interfaces` 由 `route_task_v2.ps1 -InjectPrompt` 一次注入，常见任务无需读本页。

## 典型调用
```powershell
# 只放可复制、确实跑通过的最小示例
```

## 坑 / 备注
- 只在踩过之后写；没遇到过的失败场景不要预先罗列。

## 版本复核
- 升级后：`validate-registry.ps1 -Apply` → `tool-doc.ps1 -Check` → 接口有变才更新 → `update-tool.ps1 -Id {id} -DocChecked`
