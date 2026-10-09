# Chat Composer 0.3.2 独立原生交互审查

日期：2026-10-09（Asia/Shanghai）；岗位：方衡之。父代理负责实现、集成、Debug 构建与运行；本岗位独立编写验证器、审阅源码和回读产物。本次收尾仅更新本报告，验证器源码冻结，不提交 Git、不另行 build/run。

## 最终结果

**最终隔离运行 `ez2iqze3` 的 79/79 个布尔断言全部为 true；当前四份源码 SHA-256 与运行清单、build-proof 一致。已覆盖范围内未发现新的实质阻断问题。**

检查在本机 macOS 27.0.1、实际 ChatView 已挂载的 NSTextView 上完成，由 LaunchServices `open -n` 启动。报告记录 `generation_requests=0`；源码确认发送用例由 spy 拦截，composer-only 分支在模型生成／导入等流程前退出。`app.log` 为 0 字节。此结论依据运行报告和代码路径，未另做网络流量计量。

证据状态：源码为 **E2／方法已审阅**；行为为**本地原创工程检查已执行，结果支持所列断言**。这不是论文复现，不标 E3；下列人工交互与发布边界尚未覆盖，不标 E4。“独立”指岗位审查独立，不代表另一台机器重跑或独立模型统计样本。

## 已验证范围

| 范围 | 最终证据与结果 |
| --- | --- |
| 发送及换行 | 实际 editor 接收原生 NSEvent：Return、CmdReturn、数字键盘 Enter 各发送一次；重复按键不重发；canSubmit=false 不发；ShiftReturn／OptionReturn 在光标处换行。 |
| IME 发送契约 | `setMarkedText` 确认真实 marked range 存在；普通／CmdReturn 均不调用发送，周边正文保留；显式提交预编辑后 Return 可发送。 |
| 文本、选择与撤销 | 中文／emoji 选择替换、方向键移动与扩选、私有剪贴板多行粘贴、UTF-16 光标位置、原生 Undo／Redo 通过。 |
| 真实 SwiftUI 回写 | 恢复原 coordinator 后，输入回写 binding、异步刷新后的光标／选区保持、Undo／Redo 均通过；普通刷新保留 composition，外部草稿替换清除旧 composition 且新 binding 不被回写覆盖。 |
| 可写区域与滚动 | 空态／单行下方左中右区域 hitTest 命中 editor，插入位置正确；80 行长文首尾可见、无横向扩张、滚动约束可达边界；程序清空和原生选区删除均缩回视口并回到原点。 |
| 焦点、占位符与恢复 | 首字符／空态 caret 原点一致，占位符不进入 text storage，焦点切换通知通过；本轮初始空草稿的正文属性、选区、焦点、委托、Undo 状态、设置与滚动恢复通过。 |

验证器的临时委托、独立 UndoManager、发送／焦点 spy 段内不跨 `await`，退出经 `defer` 还原；使用私有剪贴板，不改系统通用剪贴板。异步 binding 检查在恢复真实 coordinator 后进行，避免把 SwiftUI 重设 onSubmit／canSubmit 误判为产品失败。AppSmokeVerifier 同时检查实际打开的隔离库路径与 documents／notes／conversations 为空，路径命名并非唯一隔离依据。

## 发现与修复摘要

| 历程 | 定位与最终处理 |
| --- | --- |
| 首轮未进入输入用例 | 窗口尚不可见／直接 binary 启动等待超时，属于启动方式和验证时序；父代理改为 LaunchServices 启动及 10 秒有界窗口等待。不能计作产品输入失败。 |
| `w01mxz9d`：77/79，恢复项 false | 无窗口 NSTextView 最小检查确认：空正文属性比较和选区比较均为 true，只有空位置 `{0,0}` 的 affinity 被 AppKit 从 upstream 规范化为 downstream。验证器仅对该空态允许规范化；属性正文／选区仍严格比较，非空 affinity 不放宽。最终恢复项通过，未发现空 attributed string 丢失。 |
| `w01mxz9d`：普通刷新预编辑 false | `editor.string != binding` 会把尚未通知 delegate 的预编辑误判为外部替换。父代理改为 coordinator 缓存 `lastBoundText`，只有 binding 实际变化才替换；最终 `swiftui_update_preserves_active_composition=true`。 |
| `w0lviciy`：78/79，外部替换 false | `unmarkText` 在 updateNSView 内同步触发 textDidChange，把旧预编辑写回新 binding。父代理增加 `guard !isUpdatingView`；最终 `external_draft_replacement_discards_old_composition=true`，同轮正常输入回写及 Undo／Redo 仍通过。 |

两项 IME 缺陷是扩展边界检查中的真实发现，现有证据不足以将其认定为用户最初输入框问题的原因。最终源码亦确认：发送按钮已移除全局 CmdReturn shortcut；placeholder 使用正文匹配的 TextKit 容器与 origin；`tile()` 扩展 editor 至视口。长文清空后的缩回行为已有本轮运行证据，不再保留为待验猜测。

## 固定证据

- [最终原生检查记录](verification/chat-composer-0.3.2.json)：79/79，包含四份源码 SHA-256、环境和截图散列。主代理将原始结果归档并补充版本、日期及视觉检查信息。
- [开发期负面结果](verification/chat-composer-development-0.3.2.json)：保留 77/79 和 78/79 两次运行的失败项及对应源码散列；不计为最终通过。
- 原始最终报告 SHA-256：`575b458bbaa702ada1f49cc17caebb3436a41631cd587da35e716c0d014cdc93`；运行清单与 build-proof 内容一致，app.log 为空。本岗位核对源码及 Debug 运行，Release 二进制散列见主代理另附的安装包记录。

下列为本岗位重新计算并与证明逐项匹配的 SHA-256（目录均为 `Sources/AskBaseMac/`）：

| 文件 | SHA-256 |
| --- | --- |
| `ChatComposer.swift` | `5482859393c53b157e75f5dd4ae950af1902d0f683bc2cae9a1d64373dcf1b99` |
| `ChatView.swift` | `dfe423bf727ecd8f800f8008f563772c9015aaa789d515605fad17245faf169b` |
| `AppSmokeVerifier.swift` | `ee18b4b8c20ba7560ed2422b8b1919fa6ec03e7e77e981ed0c955117d031e86c` |
| `ComposerUIVerifier.swift` | `474cb3b2b54d7d751f4a96b87e77dd0891905ce36f7cb423cb687717d588e2da` |

本轮截图产物已确认存在并核对 PNG 尺寸：[01-composer-empty-dark.png](screenshots/01-composer-empty-dark-0.3.2.png)（2480×1640）；[02-composer-multiline-dark.png](screenshots/02-composer-multiline-dark-0.3.2.png)（2480×1640）；[03-composer-empty-light-minimum.png](screenshots/03-composer-empty-light-minimum-0.3.2.png)（2200×1584）。它们来自实际 ChatView 的 AppKit cacheDisplay；最终视觉确认由父代理接续，本报告不将文件存在或尺寸正确等同于视觉验收。

## 未验证边界

- NSEvent 直接交 editor，未经过硬件键盘、NSApplication／菜单完整分发；marked-text 注入未覆盖真实中文候选窗选词。私有剪贴板入口、UndoManager 调用不等于实按 CmdV／CmdZ。空白区验证为 hitTest 与插入位置，未派发真实鼠标点击；滚动为程序约束与定位，未覆盖触控板惯性、回弹、滚动条拖动及连续窗口缩放。
- binding 用例覆盖不同文本的外部替换，未验证真实会话切换时两边草稿字符串相同的情形；恢复断言运行于初始空草稿，未单独运行已有复杂属性正文／撤销历史的恢复。未在 macOS 14、其他机器或其他输入源回归。
- 本次不评估模型生成质量、回答中停止流程、Release 构建／安装／签名／公证。父代理接续截图视觉确认与 Release 打包安装；本报告仅给出这份 Debug 原生交互证据的结论。
