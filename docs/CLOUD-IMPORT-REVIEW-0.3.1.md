# 0.3.1 云盘导入独立审查

审查岗位：魏慎言（独立审稿）；日期：2026-10-09，Asia/Shanghai。

范围：审阅 `DocumentImporter` 与新的 `FileSnapshotReader`，编写离线回归。仅修改本文件及 `Tests/AskBaseCoreTests/CloudImportRegressionTests.swift`；生产实现由主代理负责。本记录不构成真实 iCloud / OneDrive 验收。

**最终结论：本次修复范围内可发布，未发现剩余阻断项。** 独立发现的 P1 混合版本问题已由主代理修复，稳定的 22 项离线回归全部通过；首次失败证据保留在下文。测试文件已冻结，不再扩展本轮测试范围。

## 初步建议

原实现将读取前后的 ctime 全等作为必要条件。这会把“字节完全相同、扩展属性发生变化”的文件拒绝掉。用户报告与该机制相容，但没有访问用户文件或云盘日志，不能据此断定每次实际失败的根因。

1. 在 `NSFileCoordinator` 的普通内容读取 accessor 内完成打开、流式复制和校验，使用 accessor 给出的 URL。不能使用 `.immediatelyAvailableMetadataOnly` 读取内容。`.withoutChanges` 只抑制要求 presenter 保存，不是 metadata-only；默认 `[]` 可用于取得 presenter 保存后的内容。每次重试新建 coordinator。
2. 保留 `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` 和打开后 `fstat` 普通文件检查。不启用 `.resolvesSymbolicLink`，否则协调前的链接可能被解析成目标 URL，削弱后续 `O_NOFOLLOW` 的意义。
3. ctime / mtime 的变化只是重新检查内容的信号。复核相同打开对象的字节数与 SHA256，并检查复核期间的大小、mtime、ctime、身份。不能把 ctime 一律忽略，也不能仅因 xattr 变化无限重试。
4. 原子替换不一定影响已打开 FD 的可读性。接受快照前比较当前路径与 FD 的 device/inode/类型；不一致应重新协调当前路径，而不能返回被替换的旧文件。当前路径变成符号链接或非普通文件时仍应拒绝。
5. 保留最多三次尝试，只重试可恢复的版本竞争。权限、非普通文件、磁盘写入失败、用户取消不应变成三轮昂贵操作。每次失败应清理该轮暂存目录。
6. 异步调用避免在 UI 执行器上阻塞。取消必须同时传到 coordinator 和逐块复制/复核检查；取消状态、coordinator 安装/解绑需要同步，覆盖“取消先发生、worker 后启动”的窗口。不能依赖后台 GCD 队列上的 `Task.isCancelled` 自动继承调用方状态。
7. `cancel()` 不会中断已进入的 accessor；操作仍需逐块检查并在返回前清理。`read(2)` 本身若阻塞，不能承诺硬性的毫秒级中断。不得在持有状态锁时执行耗时 IO 或等待 presenter。
8. snapshot 复制完成便释放协调范围，解析、媒体处理和后续索引使用私有快照，以免长时间占用源文件的协调读锁。

## 一手依据与读取深度

证据状态：E2／支持（API 契约、新旧实现及取消/生命周期的方法审阅）；运行结果另记为本地原创工程实验，不是 E3 论文复现或 E4 场景验证。

- 本机 Apple SDK：`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSFileCoordinator.h`。已读取 options、线程约束、协调读取及取消契约相关注释。
- [Apple：协调读取](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:error:byaccessor:))：同步协调读取会等待必要的 ubiquitous 内容下载，accessor URL 可能更新。
- [Apple：withoutChanges](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/withoutchanges)：控制 presenter 保存请求。
- [Apple：cancel](https://developer.apple.com/documentation/foundation/nsfilecoordinator/cancel())：允许从任意线程调用；未进入 accessor 时停止等待，已进入时等待 accessor 自行结束。

以上解释的是 Foundation 的协调契约，不证明任意第三方 File Provider 都不会失败，也不证明当前 OneDrive 或 iCloud 账号的实际下载状态。

## 回归范围与通过条件

只创建合成临时文件；通过 hook 控制真实文件变更的时点，不伪造 stat 或哈希结果。

| 反证场景 | 通过条件 |
| --- | --- |
| 实际 setxattr 导致 ctime 变化，内容未变 | 确认真实 ctime 改变、大小和 mtime 不变；复核发生；同次尝试成功 |
| mtime 改变但字节未变 | 复核后接受，输出 hash/字节数与完整内容相符 |
| 第一段复制后同大小原位覆盖，含恢复旧 mtime | 拒绝第一轮候选，重新读取完整新内容 |
| 复核已读前缀后再次改写 | 不能接受第一轮候选，最终得到完整稳定版本或有限失败 |
| 原子替换，包括相同字节的新 inode | 重新协调当前 URL；不能继续把旧 FD 当作当前源 |
| 三轮均变化 | 正好三次后给出清晰错误，所有失败暂存清理 |
| 源路径被替换为符号链接 | 拒绝读取链接目标，不留下候选快照 |
| accessor 已复制首段后取消 | 抛出 CancellationError；不继续重试，清理部分快照 |
| presenter 尚未答复协调请求时取消 | 无需 presenter 先释放即可结束等待，不执行复制 |
| 预取消、正常 remove、下游抛错 | 不遗留快照；remove 可重复调用 |

## 首轮实际结果与阻断项

首轮源码 SHA256：

- `FileSnapshotReader.swift`：`87433ecc8f9153b4a855f53506a9bd91ea46deaa1b5a122fa335d0257e4fc19a`
- `DocumentImporter.swift`：`70e10396918f52053e1d7a2761a4bd660b90fcf95c3e9ed4b698c4585d84c896`
- 首轮测试文件：`598cc126e6e1fa3977e0d572f806c9480b8342cd9267f3bfa42a114b88370629`

2026-10-09 20:41:52–20:41:57，macOS 27.0.1 (26A434)、Apple Swift 6.4、arm64。19 项执行，18 项通过，1 项失败（同一场景的 3 个断言）；运行前后上述文件哈希相同。证据为本地原创工程实验，支持发现，不是论文复现。

**P1／首轮阻断、最终已关闭：第二遍校验未检测新的 ctime 变化，可能接受混合版本。**

- 位置：`FileSnapshotReader.copy()` 第二遍 `fstat` 后的 guard，首轮文件第 193–196 行。
- 反例：3 MiB + 29 字节的 A 文件，复制首段后实际原位写 B 并恢复 mtime；复制末段后恢复 A 和原 mtime；第二遍读取首段后再次实际写 B 并恢复 mtime。两遍读到同样的 A 前缀＋B 后缀，hash 相同；源最终为 B，结果却为混合内容，第一轮即被接受。
- 失败用例：`testRepeatedWritesWithRestoredMtimeCannotValidateATornSnapshot`。结果混合 hash `7a4575fda3a3d0b385dd11f30c7045c999ff5f4025ff1bf03be363758713ec17`，应取得完整 B 的 hash `9d1caff55246a8b6a6b72fbb9087d7120acd87913f7447934d1910a80ded91fe`。
- 最小修复：第二遍前后也要求 `sameChangeTime(after, final)`，若不一致则使用既有有限重试。首次复制期间仅 xattr 变化、随后复核稳定的场景仍可在第一轮通过。复核期间持续发生 xattr churn 可能消耗重试预算，这是保守拒绝的代价，应避免宣称“所有 metadata 变化永不失败”。
- 状态：已即时向主代理报告；主代理随后在第二遍 guard 增加 `sameChangeTime(after, final)`，独立复验通过并关闭。本审查未修改生产代码。

已通过的取消证据包括：真实 `NSFilePresenter.relinquishPresentedItem(toReader:)` 被调用、回调仍被扣留时取消 readAsync，任务在 3 秒测试上限内退出，未进入复制、未创建 snapshot；随后才释放 presenter。上限只是测试防挂，不是产品下载 timeout。另已通过首段真实磁盘写入后取消、末段写完但返回前取消、成功返回后的调用方 defer 清理，以及 `DocumentImporter.withSnapshot` 在下游异常/取消时的清理。

测试使用独立临时 Swift package，仅包含实际 `AskBaseCore`、`CSQLite` 与新回归测试的符号链接，沿用 macOS 14 最低目标和 Swift 5 language mode。这样不会编译 App/CLI，也不修改生产 `Package.swift`；并不是整个仓库测试或 App 构建。独立 `--scratch-path` 位于下方 run 目录的 `build`。

首轮日志：

- run 目录：`/var/folders/hv/5prqbh_110j7s3y22c3vx7z80000gn/T/askbase-cloud-review-5t1ihumf`
- `run2.log`、`run2-results.xml`、`run2-before.json`、`run2-after.json`。
- 第一次编译发现新测试内 `off_t`/`Int` 断言类型不匹配，已转换类型并修复 presenter Sendable 签名；那次没有执行测试。上面的 19 项是修复测试编译后真正执行的结果。

随后加入读取中截断、第二遍校验中取消和 16 次完成/取消交接竞态检查，共 22 项。修复前第二轮于 20:46:31–20:46:39 执行：21 项通过、同一 P1 用例失败（3 个断言）。该轮 `FileSnapshotReader.swift` SHA256 为 `3f608e68528a67bb498625850489d888b07d91e6ae2b83233aa40a91b5e5b462`，记录保留为 `run3.log`、`run3-results.xml`、`run3-before.json`、`run3-after.json`。

## 最终独立复验

2026-10-09 **20:49:17–20:49:21，22/22 通过，0 failures，执行时间 3.478 秒，退出码 0**。同一独立 scratch，运行前后被测源文件和测试文件哈希一致：

| 文件 | 最终 SHA256 |
| --- | --- |
| `Sources/AskBaseCore/FileSnapshotReader.swift` | `1a13ba5828c4522c472f3a1994e042153a3eeddbadad45d4846d5d9c97dd22df` |
| `Sources/AskBaseCore/DocumentImporter.swift` | `70e10396918f52053e1d7a2761a4bd660b90fcf95c3e9ed4b698c4585d84c896` |
| `Tests/AskBaseCoreTests/CloudImportRegressionTests.swift` | `d912980d7b19f64cb505801a27e50de01ed7ab93fdef10fad6b58f5a0a0d56e2` |

最终日志与哈希在同一 run 目录：`run4.log`、`run4-results.xml`、`run4-before.json`、`run4-after.json`。前三轮文件保留；未覆盖首次失败记录。

实际命令（临时 package 只链接 Core、CSQLite 与这一个测试文件）：

```sh
swift test \
  --package-path /var/folders/hv/5prqbh_110j7s3y22c3vx7z80000gn/T/askbase-cloud-review-5t1ihumf/package \
  --scratch-path /var/folders/hv/5prqbh_110j7s3y22c3vx7z80000gn/T/askbase-cloud-review-5t1ihumf/build \
  --disable-automatic-resolution --disable-keychain --disable-netrc -j 2 \
  --filter CloudImportRegressionTests \
  --xunit-output /var/folders/hv/5prqbh_110j7s3y22c3vx7z80000gn/T/askbase-cloud-review-5t1ihumf/run4-results.xml
```

| 主张 | 最强反证及实际检查 | 最终判断 |
| --- | --- | --- |
| 单纯 metadata 改变不再误拒绝 | 真实 setxattr 验证 ctime 变、size/mtime/bytes 不变；以及单独改变 mtime；两项均进行完整第二遍 hash 后一次成功 | 支持，本地实验通过 |
| 拒绝混合或过时快照 | 原位改写、恢复 mtime、第二遍已读前缀改写、两遍相同混合 hash、原子替换含同字节/同 mtime、截断 | 支持；P1 反例修复后通过 |
| 保留普通文件与符号链接边界 | 初始 symlink/FIFO/目录拒绝；复制中替换为 symlink，目标保持不变 | 支持，未放宽到跟随最终路径符号链接 |
| 取消协调等待和进行中的 IO 工作 | 真实 presenter 仍扣留回调时取消成功；首段、末段、第二遍读后取消，均抛 CancellationError，未重试 | 支持本次离线场景；不声称真实云盘下载取消时延 |
| 快照所有权与清理明确 | snapshotCreated 抛错、各失败轮次、remove 重复调用、调用方 defer、withSnapshot 下游异常/取消；16 次完成/取消竞态全部无遗留 | 支持已测交接顺序；16 次不等于全部线程调度的穷尽证明 |
| 持续变化不会无限读或无限重试 | 每轮实际追加，读取限定为该轮初始长度；三轮持续改写后明确报错，所有失败目录清理 | 支持；3 次包括第一次，200/400 ms 退避逐 25 ms 检查取消（代码审阅） |

最终源码使用 `.withoutChanges`，取当前已保存版本，避免请求其他应用保存未保存的编辑；它仍为内容协调读取。异步控制对象以锁同步取消状态和 coordinator 引用，锁外执行 `cancel()`；取消状态覆盖 worker 尚未开始及 continuation 返回后的清理检查。AppState 的 security-scoped access 在 await 导入/媒体查询期间由 defer 保持，属于代码审阅，未作为 App UI 或沙盒实机验收。

主代理另报告完整仓库 `swift test` **153/153** 通过，日志为 `/tmp/AskBase-0.3.1-full-tests.log`。该结果属于主代理的集成验证；独立审查的实际执行范围为上述 22 项。不将其与独立 22 项相加成 175 个不同用例。

## 非阻断风险与交付边界

- **真实云盘未直接复验。** 没有访问 iCloud / OneDrive 账号、报错 PDF 或用户资料；Foundation presenter 等待是实际本地系统协调，仍不能替代实际 File Provider 占位文件下载、断网、账号退出等验收。用户报告根因判断保持“与 metadata 误拒绝机制相容”。
- **复核期间必须稳定。** 第二遍仍发生 ctime 变化，包括仅 xattr 变化，可能消耗三轮预算并保守失败。此行为避免再次接受混合版本；不承诺持续 metadata churn 永远成功。
- **取消不是任意 IO 的硬中断。** 协调等待和受控分段边界已验证，已经进入内核的阻塞读/同步操作未验证硬性中断时限。未加下载 timeout 是当前设计选择，不以任意时长拒绝大文件。
- **环境覆盖有限。** 实际执行平台为 macOS 27.0.1 / arm64；macOS 14 实机、具体云盘版本、干净机器、签名/安装和 Release 包未由此审查验证。

本审查仅新增两份授权文件；未修改生产源代码、提交、推送、构建 App/CLI、打包、调用模型或使用 GPU。结论允许主代理继续其已授权的发布流程；真实云盘修复效果仍需后续目标环境确认。
