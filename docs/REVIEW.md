# AskBaseMac 独立工程审查

审查日期：2026-10-07（Asia/Shanghai）。最终状态：累计发现的 1 项 P1、6 项 P2 **均已独立复核关闭**；本轮针对当前文件补核 F02/F04/F05/F06，限定审查范围内没有剩余交付阻塞。历史触发与失败证据保留，最终关闭依据见文末。没有修改应用源码。

范围：`Sources/AskBaseCore/ModelClients.swift`、`KnowledgeEngine.swift`、`Retrieval.swift`，以及 `scripts/start_ollama.py`、`setup_embedding.py`、`build_app.py`。`Models.swift`、实现契约及被调用的安装/打包依赖仅用于核实接口和执行路径。为确认 F03，额外只读了 `LibraryStore.upsertDocument` 的实现，没有接管 storage/import 或 UI 审查。不运行 live 模型，不改真实资料库，不启动服务，不执行 SwiftPM 构建。

本报告的源码结论属于 **E2／支持**；其中执行过替身的项目另标“本地纯检查已执行”。这不是论文 E3 复现、整机 E4 验收或真实模型质量结论。

| 编号 | 级别 | 实际错误 | 验证方式 |
| --- | --- | --- | --- |
| F01 | P1，已关闭 | 修复前允许云模型通过本机 Ollama 接收资料 | 新版原客户端的 9 项独立离线复核通过 |
| F02 | P2，已关闭 | 加载失败后唤起未经归属核对的同名任务 | 身份匹配/缺失/不可解析分支及无 fallback 检查通过 |
| F03 | P2，已关闭 | 导入失败/取消覆盖导入期间的元数据编辑 | 更新后 6 个引擎场景通过 |
| F04 | P2，已关闭 | 运行环境部分安装失败后，同一安装命令无法修复 | 缺包、缺文件、同尺寸损坏检测及原安装函数修复检查通过 |
| F05 | P2，已关闭 | 两次并发启动共用临时文件，导致启动命令失败 | 实际 flock 的双调用串行检查通过；唯一临时文件与原子替换已核对 |
| F06 | P2，已关闭 | 缺引用及无法解析的引用编号被接受 | 当前原客户端的 12 项离线引用场景通过 |
| F07 | P2，已关闭 | 按宿主架构构建，却固定发布为 arm64 包 | 更新后 arm64 接受、x86_64 拒绝均符合预期 |

## F01 — P1，已关闭：本机 Ollama 地址不能保证回答模型在本机运行

- 状态：主代理修复，独立复核通过；原始问题保留用于追溯。
- 初读位置：旧版 `Sources/AskBaseCore/ModelClients.swift:160–172,201–213`；`scripts/start_ollama.py:26–30,50`。修复位置：新版 `ModelClients.swift:159–206`。
- 修复前触发条件：用户已有正常运行且允许云功能的 Ollama，并选择已登记的云模型或云模型别名。`start_ollama.py` 直接返回 `already_running`，不会使已有进程采用新建 LaunchAgent 中的 `OLLAMA_NO_CLOUD=1`。
- 修复前原因：`models()` 只解码模型名，全部作为“本地模型”返回；`answer()` 在非空检查后直接把资料片段、问题和历史发给 `/api/chat`。没有在发送正文前确认模型的远端属性。环回地址校验与禁止 HTTP 重定向阻止不了 Ollama 自身的云转发。
- 影响：在本地知识库的默认承诺下，私有资料可能进入云推理；这不是要求生产安全认证，而是当前产品的请求路由错误。
- 建议：列表过滤云模型，且每次发送私有正文前用无正文的模型信息查询确认所选模型为本地模型，拒绝远端元数据或无法确认的模型。需覆盖无 `cloud` 字样的别名，不能仅依赖模型名后缀。复用服务与新建服务分别验证；不要擅自修改用户已有 Ollama 配置。
- 证据：E2／支持；本地纯检查已执行。返回带远端信息的 `fixture:cloud` 模型后，客户端仍把它列入候选并调用 `/api/chat`；捕获的调用只有 `/api/tags`、`/api/chat`，没有前置模型信息检查。官方 [Authentication](https://docs.ollama.com/api/authentication) 明示登录后的本地 API 能调用云模型；[Cloud](https://docs.ollama.com/cloud) 和 [FAQ](https://docs.ollama.com/faq#how-do-i-disable-ollama-cloud-features) 说明禁用云能力需要配置并重启。读取日期为本审查日期，读取深度为上述相关章节。
- 未验证：没有访问用户实际云模型、发出模型请求或证明本机已经发生资料外发。
- **修复复核**：读取新版 `ModelClients.swift` 和新增 `Tests/AskBaseCoreTests/ModelClientTests.swift`。独立构造 8 个离线场景，直接使用磁盘原源码与新增的 URLSession configuration 注入接口，没有再做内存源码替换。候选列表筛选；无 cloud 字样别名的 `remote_model`、`remote_host`；缺失模型信息；仅 embedding 能力；未知 format；合法 GGUF；合法 safetensors，均符合预期。五类不兼容情况只发送 `/api/show`，合法模型按 `/api/show → /api/chat` 顺序发送。
- **私有正文检查**：独立读取 `httpBody` 或 `httpBodyStream`，验证 show 的 JSON 键集合严格等于 `["model"]`，不含合成的问题、资料、历史 sentinel。不是仅在 body 为 nil 时把空字符串当作证明。
- **关闭边界**：确认标准 Ollama 元数据条件下的请求路由问题已修复；没有宣称任意恶意本地代理均可被客户端识别，也不扩展成生产安全认证。
- **再次复核**：主代理随后补入 remote 元数据类型校验，独立增加 `remote_host=42` 场景，同样在只发送模型名后拒绝。F01 相关独立检查累计 9 项，均通过。

## F02 — P2，已关闭：bootstrap 失败后不核对已加载任务身份就 kickstart

- 状态：最终离线复核关闭，见文末；以下触发、位置与原因描述初读版本。
- 位置：`scripts/start_ollama.py:59–72`。
- 触发条件：同名 LaunchAgent 已加载，实际运行定义与当前磁盘 plist 不同；当前端口没有监听，例如原任务暂时退出。磁盘 plist 不存在或恰好匹配本次定义。
- 原因：检查的只是磁盘 plist。任何 `bootstrap` 非零返回都进入 `kickstart gui/<uid>/local.askbasemac.ollama`，从未查询已加载任务的 program、arguments 和 working directory。`bootstrap` 的失败并不证明任务存在、归本应用所有或定义相同。
- 影响：可能唤起另一份安装的任务；若该任务启动后提供 `/api/tags`，脚本还会返回本应用的 `running` 成功信息。
- 建议：在任何控制动作之前核对已加载定义，只对确认匹配的任务执行 `kickstart`；不能确认归属时保留现场并返回明确错误。区分“任务已加载”与其他 bootstrap 错误；检查 kickstart 返回值。
- 证据：E2／支持；本地纯检查已执行。对原 `main()` 注入“bootstrap 返回 5，随后 tags 可用”，捕获调用顺序为 `bootstrap → kickstart`，没有 `launchctl print`，最终仍报告 `running`。与嵌入服务自带管理脚本已有的归属检查形成直接对照，但没有假定两者功能必须完全相同。
- 未验证：没有读取、唤起或停止真实 LaunchAgent，也没有判断用户本机当前任务归属异常。

## F03 — P2，已关闭：导入取消或失败会覆盖用户刚编辑的元数据

- 状态：主代理修复，独立复核通过；下述触发与原因描述初读版本。
- 位置：`Sources/AskBaseCore/KnowledgeEngine.swift:115–129`，尤其 `125–129`。
- 触发条件：导入已把 indexing 文档存入库并正在等待 embedding；用户修改标题、收藏或标签；随后请求失败或取消。
- 原因：`pending` 保存的是导入开始时的整份文档。catch 只检查该文档还存在，随后把旧副本的状态改为 failed 并整体 upsert；没有合并当前文档。背景核对确认 `LibraryStore.upsertDocument` 会采用传入的标题/收藏/标签，不替引擎保留最新值。
- 影响：用户已经成功保存的编辑被静默回滚。单一 actor 不能避免 await 前后使用旧副本的问题。
- 建议：catch 中根据 pending.id 重新读取当前文档，只改状态、错误和更新时间；不要回写旧 metadata。另应让同一文档的初次导入与重新索引共享操作身份，避免旧操作失败覆盖较新操作的状态。
- 证据：E2／支持；本地纯检查已执行。实际 `KnowledgeEngine` 源码配内存 store/importer 和可暂停 embedder：把标题改为 `Edited`、收藏设为 true、标签设为 `keep-me`，再取消并恢复错误；观察到 `title=Original, favorite=false, tags=[], status=failed`。没有以该替身结果冒充 SQLite 集成测试。
- 未验证：未操作真实资料库，未测试 UI 是否在所有导入阶段都允许编辑；引擎公开 API 已可触发。
- **修复复核**：catch 现按 pending.id 重读当前文档。相同暂停/编辑/取消检查变为 `title=Edited, favorite=true, tags=[keep-me], status=failed`。同时新增的 indexing 状态 guard 在读取原文件之前拒绝重新索引同一文档；删除、取消、跨批签名检查未回归。6 个离线引擎场景均符合预期，F03 关闭。

## F04 — P2，已关闭：部分安装留下 Python 后，再次 setup 不会补齐依赖

- 状态：最终离线复核关闭，见文末；以下触发、位置与原因描述初读版本。
- 位置：`scripts/setup_embedding.py:34–38`；背景依赖 `services/embeddinggemma2/scripts/install_runtime.py:48–54`。
- 触发条件：首次安装已创建运行环境的 `.venv/bin/python`，也已复制 `scripts/manage.py`，但后续安装依赖失败，例如下载中断。模型服务尚未正常运行。
- 原因：只以这两个文件存在判断“完整安装”。下一次 setup 直接执行旧环境的 `manage.py start` 并返回，没有检查所需包、模型完整性或安装完成标记，也没有恢复安装分支。
- 影响：同一条安装命令重复执行也不能完成安装；服务缺包启动失败后，用户必须自行诊断并清理运行目录。
- 建议：安装流程记录并原子提交完成标记；仅复用通过本地完整性检查的运行环境。部分安装应在确认归属后恢复依赖安装，再启动并检查健康；不能自动清除不明目录。
- 证据：E2／支持；本地纯检查已执行。提供“Python 和 manage.py 已存在、健康端点不可用、start 缺依赖失败”的替身，捕获到唯一命令为 `manage.py start`，没有 pip/安装修复步骤。依赖脚本确实先建 venv、再安装包，因此该中间状态可达。
- 未验证：没有中断真实安装、下载模型或改变已有运行环境。当前健康实例不触发此问题。

## F05 — P2，已关闭：重复启动没有互斥，固定临时文件发生竞争

- 状态：最终离线复核关闭，见文末；以下触发、位置与原因描述初读版本。
- 位置：`scripts/start_ollama.py:27–35,59–66`。
- 触发条件：服务尚未监听时，两次启动同时通过健康与端口检查，例如首次启动较慢时用户再次执行命令。
- 原因：两次调用都使用 `PLIST.with_suffix(".tmp")`，检查到写入之间没有锁。进程 A、B 先后写入同一临时路径，A 将其替换成 plist 后，B 再 chmod/replace 会发现临时文件不存在。
- 影响：至少一个启动命令报 `FileNotFoundError`，即使另一进程已经使服务运行；配置不同的并发调用还会让检查与实际提交不一致。
- 建议：对这一服务的“检查—写定义—加载—就绪”过程加单实例锁，在取得锁后重新检查健康与身份；临时文件使用唯一名字并原子替换。只改临时文件名不能解决重复 bootstrap 与归属检查竞争。
- 证据：E2／支持；本地纯检查已执行。内存文件系统交错 `A.write → B.write → A.replace → B.replace`，第二次 replace 抛出 `FileNotFoundError /review/plists/job.tmp`。这是确定交错检查，不是实际 launchd 压力测试。
- 未验证：没有并行启动真实脚本，也没有声称用户已遇到该竞争。

## F06 — P2，已关闭：缺引用及不能解析的编号会放行

- 状态：最终离线复核关闭，见文末；以下保留原始问题及前轮发现编号边界的过程。
- 位置：新版 `Sources/AskBaseCore/ModelClients.swift:253–269`，剩余问题在 `263–267`；保存路径 `KnowledgeEngine.swift:269–271`。
- 触发条件：模型返回非空回答，但没有任何 `[n]` 标记，例如忽略引用格式直接回答事实。
- 原因：只遍历已经出现的引用编号，匹配结果为空时直接成功返回。引擎随后把这段文本与全部检索片段一起存入历史，检索候选容易被误当作正文已经引用的证据。
- 影响：产品的“带来源问答”在这一正常模型响应边界上缺少实际引用；用户无法把陈述对应到片段。
- 建议：区分“明确资料不足的拒答”和“事实性回答”；事实性回答至少要求有效来源标记，缺失时重试一次或明确呈现为未能提供引用，不把候选来源列表当作已完成引用。该建议不要求自动证明每一句事实，也不等于仅有编号就证明支持关系成立。
- 证据：E2／支持；本地纯检查已执行。初读版在离线替身返回 `This answer has no citation.` 时成功返回正文；返回 `[2]` 且仅有一个来源时则会拒绝。F01 修复后独立重查，合法本地模型通过 show，`answer()` 仍接受事实性正文 `预算为 900 万元。`，不带引用，因此本项尚未关闭。
- 未验证：没有测量真实模型缺引用率或逐句证据支持率；保留合法编号不代表语义支持已经验证。
- **已修复部分**：独立检查确认无引用事实性正文被拒绝；精确的“资料中没有足够信息。”可返回；合法 `[1]` 可返回；只有一个来源时 `[9]` 被拒绝。
- **前轮剩余触发**：返回 `预算为 900 万元。[999999999999999999999999999999999]`，或使用全角数字 `[１]`。ICU 正则 `\d+` 会匹配，但 `Int(...)` 分别因溢出或字符格式返回 nil；`if let` 因而跳过范围检查，同时 `matches` 非空绕过了缺引用 guard。两个响应在前轮独立离线检查中均被接受；最终复核已拒绝。
- **前轮建议**：每个匹配必须成功解析为规范编号且处于实际来源范围；解析失败要抛错，不能跳过。可将可接受格式限定为 ASCII 数字，但仍须明确拒绝整数溢出。无需调用真实模型即可覆盖。

## F07 — P2，已关闭：产物命名为 arm64，但构建未固定架构

- 状态：主代理修复，独立复核通过；下述原因描述初读版本。
- 位置：初读 `scripts/build_app.py:19–21,55–58`；修复在新版 `19–24`。
- 触发条件：在 Intel Mac 或 x86_64 macOS runner 上执行该脚本。
- 原因：两条 `swift build` 命令都使用宿主默认架构，打包文件名却固定为 `AskBase-Local-0.1.0-macOS-arm64.zip`。脚本没有架构限制、显式 `--arch` 或 Mach-O 检查。
- 影响：可产生内含 x86_64 程序、标为 arm64 的分发包；没有 Rosetta 的 Apple Silicon 环境不能把它作为原生 arm64 应用直接运行。不能仅根据 zip 名称判断可复建出的目标架构。
- 建议：明确只支持 Apple Silicon 时，在构建与查找产物的两条命令中使用一致的 arm64 参数，或在不支持的宿主上提前失败；打包前检查实际 Mach-O 架构。若支持多架构，名称与支持说明应相应区分。
- 证据：E2／支持；本地纯检查已执行。把 `--show-bin-path` 的结果替换成 `/review-fixture/.build/x86_64-apple-macosx/release`，原打包 `main()` 仍从该路径复制程序并生成 arm64 名称的 zip；所有构建、复制、签名、压缩动作均为替身。
- 未验证：没有运行 Intel 构建，也没有推断当前 `macos-15` runner 的实际架构；本轮不争用主代理的 SwiftPM 构建。
- **修复复核**：两条 SwiftPM 命令现均固定 `--arch arm64`，并在写入分发目录之前通过 `lipo -archs` 确认产物。独立替身返回 x86_64 时，脚本拒绝且无复制/写入；返回 arm64 时继续打包。两个分支及两条命令参数均已独立核对，F07 关闭。

## 已检查且不列为缺陷的路径

- **query/document 配方**：捕获的实际客户端请求分别带 `input_type=query` 与 `document`、`dimensions=768`；输入保持原文，没有由客户端重复添加前缀。背景配置与 encoder 代码显示服务端按类型添加 `task: search result | query: ` 或 `title: none | text: `，两种配方共同进入编码签名。没有发现本轮客户端把两种类型混用。
- **编码签名切换**：同一文档的两批返回不同签名时，实际引擎拒绝提交，内存 store 中最终 chunks 为 0。检索路径逐块检查 768 维与查询返回签名，混合库会明确报错；未把“全部需要重索引”本身列为缺陷。
- **删除与取消**：embedding 等待期间删除文档，返回后未重新创建文档；生成时删除对话或取消 Task，模型替身返回后均拒绝保存，消息数为 0。检查限于单个引擎 actor、内存存储及可控暂停点。
- **一轮消息保存**：最终读取版本已改为 `saveExchange(user:assistant:)`，没有继续按初读版本的两次 `saveMessage` 报告半轮保存问题。事务本身归 storage 代理验证。
- **本机 HTTP 边界**：外部域名、带 userinfo 的歧义地址、额外路径在客户端前置校验中被拒绝。HTTP 重定向的委托代码返回 nil；本轮未执行重定向集成测试。F01 是 Ollama 后端转发，与客户端 URL 校验不同。
- **安装与构建输入**：11 个脚本直接依赖的源文件/目录存在；包含固定模型 revision、固定 MLX-VLM commit 和官方模型文件清单。应用 bundle 当前装入程序、图标、Examples，模型服务需要单独安装；不能将它表述成自带模型、首次启动无需准备的独立离线包。
- **setup 健康复用检查**：最终读取版本已检查 revision 与 768 维；不再按初读版本报告这两项遗漏。

## 其他边界与明确未验证项

1. **RAG 历史**：读取了完整 prompt 组装与检索调用。历史仅取最后四条、每条截到 1200 字，旧来源快照不发送；当前检索只嵌入当轮 question，不使用历史补全指代。未运行真实模型验证“它、上面的计划、刚才的 [1]”等追问，不声称多轮追问或历史引用语义正确。提示词限制不能替代这种实际检查；本轮也不据此声称已复现真实检索质量下降。
2. **数值防御**：纯检查发现 `[1e20, …]` 的 768 维有限向量通过 `validEmbedding`，但 `Retrieval.cosine` 的 Float 累积溢出，结果不是有限数。随附 EG2 服务会 L2 归一化，因此正常服务输出不具备该触发条件，本轮不把它列为当前交付阻塞；将来放宽兼容服务时应限制向量范数或采用稳定的归一化/累积，并拒绝非有限 score。
3. **召回去重**：`abs(ordinalDifference) < 1` 只覆盖相同 ordinal，不会排除相邻分块。已核对代码，但没有真实语料证据证明相邻块应被去掉，不把注释与实现差异直接扩大成检索质量缺陷。
4. **应用交付**：没有执行完整 Swift build/test、实际签名、解压启动、Gatekeeper/隔离属性、Intel 或全新 Mac 环境验证；这些应由当前负责整合/打包的主代理提供实际结果。本报告不能替代完整应用的可运行证明。
5. **真实存储与 UI**：没有操作真实库，没有复跑 storage/import 或 UI 代理的测试，没有验证跨进程写入、UI 取消按钮、真实 PDF 和文件权限。没有对其结果做未经核对的背书。
6. **真实模型与生命周期**：没有下载权重、安装依赖、运行 live 推理、创建/重启服务或修改 launchd。没有验证启动延迟、内存峰值、模型效果或真实安装的恢复能力。

## 检查证据与方法

- 逐行审阅六个限定文件、Models、实现契约；必要时沿接口核对安装依赖、服务输入配方与 `upsertDocument`。
- 三个限定 Python 脚本均通过 AST 语法解析。启动、安装、打包的原 `main()` 通过内存文件系统/函数替身执行；系统调用、下载、复制、签名和服务控制没有真正执行。
- Swift 检查直接从标准输入解释源码，使用 Swift 6.4、明确 SDK 与 `arm64-apple-macosx14.0` 目标，没有运行 SwiftPM 或争用项目构建锁。首个未指定 SDK/目标的解释调用无法加载默认目标标准库，未执行测试；显式指定后成功。
- 引擎检查使用原 `Models`、`ModelClients`、`Retrieval`、`KnowledgeEngine` 源码，替换的是存储/导入依赖及模型 provider。五个场景的输出如下。不是 SQLite 或真实解析器测试。
- 客户端检查仅在**内存源码**中给 URLSession configuration 注入 `URLProtocol`；磁盘源码未改。最初仅全局注册 URLProtocol 未能拦截 ephemeral session，对隔离的 `127.0.0.1:9` 连接被拒绝；随后显式注入传输替身，所有成功检查均未接触 live 模型或模型端口。
- F01 修复复核改用新版正式提供的 `LocalHTTPClient(configuration:)`，以原文件解释执行，独立断言列表筛选、请求顺序和实际请求正文；8 项检查通过。没有运行 XCTest 全套，新增 `ModelClientTests` 属于已读代码而非本审查者已跑测试。
- 后续变更按变化范围复查：F01 增加错误类型场景后为 9 项通过；F03 的 6 项引擎场景通过；F07 的 2 个架构分支通过；F06 的 4 个常规引用/拒答分支通过，2 个不能解析编号分支仍失败。未为没有变化的部分重复运行完整检查。
- 主代理后续报告 live RAG 15/15、原离线 40 项通过，新增测试等待全套重跑；同时报告本机 show 为 safetensors/gemma4/completion、31.7B，自有 Ollama 使用 `env -i` 与 `OLLAMA_NO_CLOUD=1`。这些明确归属于主代理报告，未并入本审查者的独立执行计数。

```text
metadata_after_cancel:
  title=Original, favorite=false, tags=[], status=failed
delete_during_import:
  documents=0, failures=1, imported=0
mid_batch_signature_change:
  imported=0, chunks=0, error=索引过程中编码模型发生变化
delete_conversation_during_answer:
  rejected=true, messages=0
cancel_answer:
  rejected=true, messages=0

query_document_recipe:
  types=[query,document], dimensions=[768,768], inputs unchanged
cloud_model_and_uncited_answer:
  models=[fixture:cloud], requests=[/api/tags,/api/chat],
  accepted_answer=This answer has no citation.
out_of_range_citation:
  rejected=true
remote_and_ambiguous_bases:
  rejected=3
finite_vector_overflow:
  accepted_embedding=true, score_finite=false

launch_identity:
  calls=[bootstrap,kickstart], queried_loaded_identity=false, reported=running
concurrent_start:
  FileNotFoundError /review/plists/job.tmp
partial_install_retry:
  commands=[manage.py start], attempted_pip_repair=false
build_architecture:
  copied=x86_64-apple-macosx/release/AskBaseMac, zip_label=macOS-arm64
referenced_build_install_inputs:
  checked=11, missing=[]

F01 fix verification (8 independent checks):
  picker_filters: [local-gguf,local-mlx]
  remote_model / remote_host / missing_info / embedding_only / unknown_format:
    rejected, requests=[/api/show]
  local_gguf / local_safetensors:
    accepted, requests=[/api/show,/api/chat]
  every preflight: body.keys=[model], no private sentinel
F06 recheck after F01 fix:
  accepted_uncited_answer=预算为 900 万元。

Subsequent fixes:
  F01 malformed remote_host=42: rejected before /api/chat
  F03 metadata_after_cancel: Edited, true, [keep-me], failed
  F03 reindex_while_importing: blocked before file parse
  F07 x86_64: rejected, no copies or writes
  F07 arm64: accepted; both build commands contain --arch arm64
  F06 uncited_fact: rejected
  F06 exact_refusal / valid_citation: accepted
  F06 out_of_range: rejected
  F06 overflow_number / unicode_number: ACCEPTED (remaining failure)
```

### 前轮审查快照（SHA-256）

审查期间主代理仍在修改文件，因此初读与最终快照不同；本报告按以下内容核对。2026-10-07 21:10:12 +08:00 最后检查时，下列 9 个文件均与记录散列一致。后续变更须针对相关条目复核，不能自动视为关闭。

| 文件 | SHA-256 |
| --- | --- |
| `Sources/AskBaseCore/ModelClients.swift`（F01/F06 复核版） | `0bbbd0302782877143fb8c95b9abc66f9a66e9dd26969bf49edc6d3694c78115` |
| `Sources/AskBaseCore/KnowledgeEngine.swift` | `31b81e626d5e1dad856cb7a68acb6d566e207b63d12e75531a3463fb308cb595` |
| `Sources/AskBaseCore/Retrieval.swift` | `f7022d9c174483745a512d21c7d47a3714de296722bd2a398dfd02e4e49c9f1d` |
| `scripts/start_ollama.py` | `7316082db912d6b9bd08ca3169d7a084b0e2f439cf2ee30c38aaa02bf9d183dc` |
| `scripts/setup_embedding.py` | `335439933e4a9a11ad6a66bc09c56e1723f77e90948feb68c8ec972b81658fee` |
| `scripts/build_app.py` | `b271e30ece0741b567c5e9afb50edc892efb33730c24ae2e0d56f348fe97645a` |
| `Sources/AskBaseCore/Models.swift` | `c7e298a014afd15da47b477f5e20e6395841d380dc5f965fd70ca3bae6cbb5b6` |
| `docs/IMPLEMENTATION-CONTRACT.md` | `97556bbdbe1d83927c936d84f3407554e7f4f5d26b09601c9e1108cec17b09cd` |
| `Tests/AskBaseCoreTests/ModelClientTests.swift`（只读） | `2b2068da16b9cf67a12ee559f461ab502fa87ef6f9f14a41ee67358594e32463` |

## 协调记录

- 发现 F01 后立即尝试向主代理 `01a11463-024c-7100-8b3f-fb75773199b2` 发送具体阻塞报告。
- 工具返回不能向当前原生代理的祖先聊天投递，当前工具列表也未提供原生代理消息能力。因此用本共享文件与会话进度即时暴露发现；没有把失败的发送表述为已送达。
- 主代理随后明确告知已从共享文件读取 F01，并完成修复；本审查者已按上述独立场景复核关闭，继续通过本文件协调。
- 本轮唯一写入的项目文件为 `docs/REVIEW.md`。没有修改研究决策文件、全局记忆、源码、服务配置或 Git 状态。

## 最终限定复核与关闭记录

2026-10-07 21:18:02 +08:00 核对当前文件散列。本轮只复核 F02/F04/F05/F06 和已指出的向量溢出边界，没有扩展新的评审范围。**这四项现已关闭；连同前轮关闭的 F01/F03/F07，限定范围内没有剩余 material blocker，可结束个人 macOS 首版的这一轮独立工程审查。**

| 项目 | 当前实现与关闭依据 | 结果 |
| --- | --- | --- |
| F02 | `scripts/start_ollama.py:29–46,84–98` 解析已加载任务的 program、完整 arguments、working directory；仅在匹配时 kickstart。未知身份拒绝，bootstrap 非零即失败，不再 fallback。离线检查覆盖外来身份、匹配、未加载、不可解析，以及 bootstrap 失败后不 kickstart。 | 关闭 |
| F04 | `scripts/setup_embedding.py:19–61,82–107` 检查配置、运行脚本、固定 revision、官方文件集合、大小、SHA-256/LFS 或 Git blob 哈希及依赖导入，再决定复用或修复。`install_runtime.py:34–48,55–83` 修复缺失/损坏的目标文件，重跑依赖安装，成功后原子写完成标记。原函数在微型合成文件上完成“检测损坏 → 修复 → 重新通过检查”。 | 关闭 |
| F05 | `scripts/start_ollama.py:109–122` 的 flock 覆盖健康/身份检查、写配置、启动和等待就绪；`86–93` 使用唯一临时文件并原子替换。离线双调用在首个持锁期间仅一次进入 start，释放后第二次进入，最大并发为 1；失败路径无临时文件残留。 | 关闭 |
| F06 | `ModelClients.swift:257–273` 要求每个匹配均为 ASCII、可转 Int、来源范围内且十进制字符串回转一致。溢出、Unicode、前导零和零编号单独出现或与有效 `[1]` 并存均被拒绝；合法引用和精确资料不足拒答仍可返回。 | 关闭 |

### 本轮实际执行的证据

- **仓库离线脚本：6/6 通过。** 执行 `python3 -B scripts/test_setup_guards.py -v`；包括外来 launchd 身份拒绝、不泄露捕获输出、bootstrap 无 fallback、双调用串行、部分安装重试和错误架构拒绝。执行前已检查测试内容：系统控制、网络、包安装和构建调用均为替身；临时目录由测试回收。
- **独立 Python 补核：11/11 检查通过。** 直接载入当前 `start_ollama.py`、`setup_embedding.py` 和被调用的 `install_runtime.py`，覆盖匹配/未加载/不可解析身份、完整安装接受、同尺寸坏哈希拒绝、缺依赖拒绝、缺模型文件拒绝、损坏与缺失目标修复、依赖重装命令、完成标记和修复后接受。模型数据仅为 `b"good"` 与 `b"{}"` 等合成小文件；所有 subprocess 均被截获，没有运行实际 Python 环境、uv 或 launchctl。
- **当前 Swift 客户端的离线脚本：12/12 引用场景通过。** 从磁盘读取原 `Models.swift`、`ModelClients.swift`，用 Swift 解释器经标准输入执行，显式注入 URLProtocol 替身；没有复制修改源文件，没有使用 SwiftPM。覆盖无引用正文、精确拒答、合法编号、超出来源范围，以及溢出、全角数字、前导零、零编号各自单独/与有效编号并存。每例均确认请求由替身按 `/api/show → /api/chat` 接收，未访问实际端口。
- **向量范数：5/5 纯函数检查通过。** 当前 `validEmbedding` 接受 768 维单位向量，拒绝全零、非单位、`1e20` 巨值和 NaN。源码核对 `ModelClients.swift:136,143–148` 与 `LibraryStore.swift:377` 均采用这一校验；范数用 Double 累加，原先 finite-but-huge 导致 Float cosine 溢出的入口已封住。本项不冒充真实 SQLite 集成测试。

本轮简要输出：

```text
test_setup_guards: Ran 6 tests, OK
independent_startup_install_checks: 11 passed; external_processes_executed=0
current_client_citation_cases: 12 passed; interpreter_exit=0; stderr=""
validEmbedding_cases: 5 passed
remaining_material_blockers_in_reviewed_scope: 0
```

### 最终复核文件快照（SHA-256）

| 文件 | SHA-256 |
| --- | --- |
| `scripts/start_ollama.py` | `2bcb405e8d25973934bf9746944a81cf438677bf3289cc61574a2cf86b420368` |
| `scripts/setup_embedding.py` | `e340ee880f23ebf1bafee6337cc88c15cb811f496fe2a29b9deac259fd03915e` |
| `services/embeddinggemma2/scripts/install_runtime.py`（安装依赖，只读） | `cb734b945ef2fa4d683ffe967254298ded485bbdc928f5e17e088e100c968bcf` |
| `scripts/test_setup_guards.py` | `1499cd472692f76d96de47b292a2b8eafcbd84425c7efd80a4ae279c3d268ef0` |
| `Sources/AskBaseCore/ModelClients.swift` | `d6b9c94637e9643b91375bbc0f5b9ff97965a55c634f7262fedc315b66499598` |
| `Sources/AskBaseCore/LibraryStore.swift`（仅核对范数入口，只读） | `e48c99768de3239ccb12fa945bbd2667001e39a5337fa1a7ebe292c64ce6e414` |
| `Tests/AskBaseCoreTests/ModelClientTests.swift`（只读，未运行 XCTest） | `e32fbbfa4c89cfbfca0d373429f29ad0a9786c02e8976bcb2d2c6155fbc21d33` |

### 明确未验证项与交接

- 没有启动、停止、查询或调用真实 launchd/模型服务，没有访问或修改真实资料库，也没有运行 SwiftPM、全套 XCTest、实际应用构建或签名。
- 安装修复用小文件和包安装替身验证控制路径；真实下载、断网恢复、依赖实际安装、实际 launchctl 输出兼容性及双进程启动均未现场验证。
- 未重做真实 GUI、模型质量、真实引用的语义支持、干净机器安装或发布 zip 的整机验收。这些由主代理当前的完整测试与 GUI/模型 QA 接续；其运行结果不计入本报告的独立证据。
- 以上是验证边界，不新增为个人首版交付阻塞。唯一交付写入为本 `docs/REVIEW.md`；未改源码或协调代理负责的文件。
