# 0.5.0 模型生命周期 helper 离线审查

状态：**当前离线审查未通过；发现两处清理问题，交主代理修复后复测**。评估岗位：方衡之（AI 代理）。
日期：2026-10-13。此报告只记录离线工程检查，不是模型实机场景验证。

## 当前交付结果

按主代理要求停止扩大覆盖。本轮最终命令：
`python3 -B services/runtime/test_supervisor.py`。

- Python 3.14.8，darwin；36 项，5.580 秒，**24 通过、8 失败、4 异常**，
  无跳过。两个产品问题导致多项情景失败，不能称 12 个独立缺陷。
- supervisor SHA-256：
  `c8140fae5a5e4601cf9f490ef3ef2bb6e1e883b83783bfd97a44f4a17d632dcd`。
- 测试 SHA-256：
  `6d819fd3b1f97006c1478e6dbc5e6c4aa524d0969b86a088eaa3606a5ed03a9b`。
- production 模块与隔离 helper 均使用运行开始时冻结的源码字节。
  主代理后续修订需重跑，不由此结果推定新源码通过。

| 检查组 | 通过 / 总数 | 结果 |
| --- | --- | --- |
| 端点、未安装、未知服务保留 | 5 / 5 | 通过 |
| 身份保护、launchd 策略/备份、迁移取消 | 12 / 12 | 通过 |
| 就绪响应、listener 归属、模型与 revision | 4 / 4 | 通过 |
| 故障隔离、锁超时、失败协议 | 2 / 3 | 一组失败跳过其他组 |
| 实际轻量 Python helper 协议/父死亡/锁 | 0 / 6 | 清理 EPERM 导致失败 |
| 实际轻量 Python 进程组/部分失败 | 1 / 6 | 其余受清理 EPERM 影响 |

## 立即处理：macOS 进程组消亡窗口的 EPERM

首轮固定 `services/runtime/supervisor.py` SHA-256：
`c8140fae5a5e4601cf9f490ef3ef2bb6e1e883b83783bfd97a44f4a17d632dcd`。

在临时目录中启动轻量 Python 组首与子进程，子进程忽略 SIGTERM，
使用 production `spawn`、`cleanup` 和 `main`。SIGKILL 后
`os.killpg(pgid, 0)` 在 macOS 上短暂返回 `PermissionError: [Errno 1]`；
`group_alive` 只处理 `ProcessLookupError`，因此清理抛异常。

- `test_stdin_stop_cleans_real_worker_and_child` 单独复测：返回码 1；
  stdout 为 `ready`、`error`（PermissionError），没有 `stopped`。
  测试组首与子进程 PID 在随后检查中均不存在。
- 首轮的 helper SIGTERM、父进程 SIGKILL、启动部分失败、取消后清理
  也触发相同错误。首轮 32 项中两项 migration 取消断言与当前
  checkpoint 位置不一致，已修正测试判据并通过，不能将它们混为产品缺陷。
- 风险不只是假错误提示：异常可能中止对其他已 spawn 组的后续清理。
- 建议主代理处理消亡窗口，同时不要将所有 EPERM 无条件解释为“不存在”。
  可以短暂重试或只读核对精确 PGID 成员；真正无法判断或清理时保留失败状态。

复现命令：

```sh
python3 -B services/runtime/test_supervisor.py
python3 -B services/runtime/test_supervisor.py HelperProtocolTests.test_stdin_stop_cleans_real_worker_and_child
```

测试文件和报告由评估代理写入；supervisor 由主代理修复。

## 另一个清理问题：一组失败跳过其他已 spawn 组

`FailureIsolationTests.test_cleanup_failure_in_one_group_does_not_skip_remaining_owned_group`
通过全 mock 的信号注入稳定失败。两个模拟 owned 组，先处理的组在 SIGTERM
返回 `PermissionError`，后处理组可以清理、但忽略 TERM 需升级 KILL。
当前 `cleanup` 第一处异常立即返回，另一组连 TERM 都未收到。

实际捕获的信号序列只有：
`[(10000002, SIGTERM)]`，缺少 `(10000001, SIGKILL)`。
这些是假 PID；`os` 被测试 facade 替换，没有真实信号发送。

建议：逐组收集停止/存活核对错误，继续清理全部自己 spawn 的组；最后再对
无法清理的组返回明确失败、保留未释放列表，不能提前报告 `stopped`。

## 最终失败项

下面每项完整名称均可作为 `unittest` 命令末尾参数单独运行：

```text
FailureIsolationTests.test_cleanup_failure_in_one_group_does_not_skip_remaining_owned_group
HelperProtocolTests.test_duplicate_waits_for_lock_and_cancel_does_not_touch_owner
HelperProtocolTests.test_force_killed_parent_cleans_group_even_with_stdin_writer_kept_open
HelperProtocolTests.test_lock_is_released_only_after_previous_cleanup
HelperProtocolTests.test_sigterm_to_helper_requests_cleanup
HelperProtocolTests.test_stdin_eof_cleans_real_worker_and_child
HelperProtocolTests.test_stdin_stop_cleans_real_worker_and_child
RealGroupTests.test_cancellation_immediately_after_spawn_cleans_owned_group
RealGroupTests.test_cleanup_kills_term_resistant_leader_and_descendant_but_not_control
RealGroupTests.test_run_cleans_all_groups_when_second_start_fails_after_spawn
RealGroupTests.test_run_cleans_first_group_when_second_start_fails
RealGroupTests.test_second_popen_failure_still_cleans_first_group
```

`RealGroupTests.test_cleanup_reaches_descendant_after_leader_already_exited` 本轮通过。
EPERM 是时序窗口，因此相同源码不同运行中命中的情景数量不同；不应删掉失败用例
或反复跑到绿色便认定已修复。

## 已修迁移取消窗口

主代理移除了 flags 写入后、bootout 前的取消检查，并将旧 job 消失/端口释放
轮询改为不可取消的有界等待。两项注入分别在 flags 写回后和 bootout 返回后
设置 stop_event，要求迁移先完成、下一检查点响应取消。

两项均通过。方法本身可返回到调用者的下一检查点，也可在结束处抛 Stopping；
测试不强制无意义的检查点位置，但不允许旧 job 仍在时返回取消。
额外独立执行 `MigrationTests` 为 **12/12**，0.517 秒。

## 覆盖与证据边界

通过的离线检查包含默认/自定义端点分界、未知端口服务保留、磁盘和运行中
归属不一致拒绝、附加 listener 拒绝、身份读取失败保护、精确 job 策略迁移、
原始备份不覆盖、健康响应必须匹配自己 spawn 的 listener PID。

进程类检查使用真实的轻量 Python 子进程，测试 TERM/KILL、组首先退出、
部分启动失败、stdin stop/EOF、父进程被 SIGKILL 和重复实例锁。
父进程死亡案例由测试进程保留 stdin 写端，排除 EOF 解释。
这些只支持本机进程生命周期合同，不证明模型资源释放、GUI 退出或真实知识库正确性。

没有调用真实 launchctl/lsof/HTTP，没有读取或改写真实 LaunchAgents、模型和资料库，
没有下载、运行模型、提交 Git 或修改授权范围外文件。

本地原创工程检查已执行；代码路径审阅属于 E2 方法审阅，测试结果反驳
“当前 helper 所有退出情景均可靠清理并正确报告成功”的主张。不是论文复现 E3，
也不是模型实机场景 E4。真实模型资源、DEBUG App 四场景与模型内存验证由主代理
另行执行；只读参考了 `scripts/verify_model_lifecycle.py`，未运行该 driver。

未更新 `research/DECISIONS.md`：本轮用户仅授权写入本报告与测试文件，
应由主代理统一归档决策。

---

## 2026-10-13 修后复测追加：37/37，通过实机检查前的离线门槛

**最新结论：可以进入主代理计划的实机四场景检查。** 上文首轮失败结果与
原因保持原样，适用于旧 SHA；本段是主代理修复后的新结果。它不表示已经
通过实机模型验证，也不替代四场景中的进程、端口和资源释放证据。

本轮仅修正测试替身以适配新增只读查询，并补充一项关键 EPERM 反例，
没有扩大其他覆盖，也没有改 supervisor。

### 固定版本及实际结果

- supervisor SHA-256：
  `fb5973f1cc686c55ab300199e4d2e1591dfd868bbbafa962731ac57f20c295bd`。
- 测试 SHA-256：
  `b2f6abd715ba86af83803a45c9c8f8c10bb62cdef4ec97f7385245ba5205f5c6`。
- Python 3.14.8 / darwin。
- 命令：`python3 -B services/runtime/test_supervisor.py`。
- 最终：**37/37 通过，0 失败、0 异常、0 跳过，6.408 秒，退出码 0**。
  其中原有 36 项全部通过，新增反例 1 项通过。
- 原六项 helper 协议测试全部通过：stdin stop、EOF、helper SIGTERM、
  父进程 SIGKILL（仍保留 stdin 写端）、重复实例取消、清理后锁移交。
- 原六项轻量进程组检查全部通过：TERM/KILL 与无关对照保留、
  组首已退出后的子进程、启动取消、第二服务启动失败、第二组 spawn 后失败、
  第二次 Popen 失败。
- 身份、端点、迁移取消、模型健康归属和故障协议检查保持通过。

### 两处修复的评估

1. `group_alive` 遇 EPERM 时使用 `/bin/ps -axo pgid=` 查询精确组成员；
   不以权限错误直接推断消失。新增
   `FailureIsolationTests.test_eperm_cannot_mark_a_live_or_unknown_group_released`
   注入 EPERM，确认精确 PGID 存在仍返回 alive，相似数字不误匹配；
   `ps` 查询失败时保持 unknown，cleanup 报失败并保留该组。
2. cleanup 在单组停止失败后继续处理其他组，最后汇总仍存在或无法确认的组。
   原故障注入用例现在确认其余可清理组收到 SIGKILL，只有失败组留下，
   返回明确 `RuntimeFailure`；没有假报 `stopped`。

### 保留复测中的测试设施修正

最初直接以旧测试文件复跑新 supervisor，结果为 36 项、35 通过、1 异常，
6.391 秒。该异常来自旧测试 facade 拦截新增 `ps` 查询，并缺少
`subprocess.SubprocessError`，属于测试设施不兼容，未归为新产品缺陷。

修正后的真实轻量进程测试只额外放行**完全匹配**的只读命令
`/bin/ps -axo pgid=` 及固定参数，仅读 PGID，不读其他进程命令行。
launchctl、lsof、网络和模型相关操作依然被拦截；未知 PGID 不会收到信号。
EPERM 关键反例本身全部 mock，不运行 ps 或发送真实信号。

首轮阻断项在上述源码版本、声明的离线覆盖中已关闭。本轮没有读取或改写真实
LaunchAgents、模型、知识库，没有运行实机 driver、下载、提交 Git 或更新
范围外文件。工程证据仍为 E2 代码审阅加“本地原创工程检查已执行”，不升级为 E4。
