# tools\_notes（通用知识笔记，不绑定索引条目）

这里放的是**不对应任何已注册工具**的通用笔记，例如 `7z.md`（本机未安装 7-Zip 时的背景说明）、
`gcc.md` / `git.md`。它们不是 `usage_page`，不会被索引引用，也不会被
`tool-doc.ps1 -Check` 的孤儿文档检测计入（检测只扫 `tools\` 根目录、`_` 开头的目录一律跳过）。

将来真的安装并注册了对应工具，可以把笔记挪回 `tools\` 根目录，用
`update-tool.ps1 -Id <id> -UsagePage 'tools/<id>.md' -DocChecked` 绑定成正式说明文档。

按从简原则，这里也只写实际会用到的内容；没用过的功能不要预先堆参数。
