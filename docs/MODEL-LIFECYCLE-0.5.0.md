# 0.5.0 模型随 App 启停

旧版关闭 App 后，独立 LaunchAgent 仍保活模型。现在打开 App 会启动并加载已安装的专用模型；关闭最后一个窗口或退出 App，会取消工作、保存笔记、结束模型服务及其子进程。模型权重、资料和索引保留。

## 实现与归属

应用持有轻量 Python supervisor，复用已有 EmbeddingGemma 2 Python 环境。它核对旧 AskBase LaunchAgent 的程序、完整参数、工作目录及监听 PID，备份配置，关闭 RunAtLoad/KeepAlive 后卸载旧 job。随后直接创建独立进程组，模型日志留在本机。

App 正常退出发送管道停止消息并等待确认；App 崩溃或被强制退出时，helper 通过管道 EOF 或父进程变化清理。先向所有自己启动的组发送 TERM，超时再向仍存在的组发送 KILL。一个组出错不会跳过其他组。未能确认释放时显示错误，不把发送停止信号当成退出成功。

自定义端点、未知监听进程和其他应用启动的共享 Ollama 保留原管理方式。普通回答沿用服务本身的驻留策略；只有 AskBase 管理的 Ollama 会预加载所选模型并随应用驻留。关闭应用时终止其服务，释放模型。

应用使用普通 AppKit 事件循环完成异步保存和清理，成功后再结束进程。退出期间可取消，未保存笔记或未完成清理会保留应用和明确错误。独立资料库模式默认不接管服务；DEBUG 验证必须显式加 `--manage-models`。

## 实际检查

在 Apple M5 Max / 64 GiB 本机，使用已有 EmbeddingGemma 2 和 `gemma4:31b-mlx`，四项独立空库检查通过：

| 情景 | 结果 |
| --- | --- |
| 正常退出 | App、supervisor、模型进程组结束，8871/11434 释放 |
| 关闭最后一个窗口 | 同一退出流程完成，服务未重新拉起 |
| 强制结束 App | supervisor 清理其模型进程组后自行退出 |
| 模型加载中结束 App | 已启动进程清理，无孤儿服务 |

前三次启动均核对 `/health` 和 Ollama `/api/ps`，确认所选回答模型已驻留；连续重新打开均成功加载。单次所见嵌入 MLX active 约 2.03 GB，回答模型报告 size_vram 约 19.36 GB。清理证据是进程组及端口消失，不代表所有 macOS 文件缓存立即归零，也不是内存或延迟基准。

191 项 Swift 核心测试、16 项安装脚本测试、19 项嵌入部署保护测试、37 项 supervisor 测试通过。真实进程测试及首次失败的修复记录见[机器可读证据](verification/model-lifecycle-0.5.0.json)和[离线反例审查](MODEL-LIFECYCLE-REVIEW-0.5.0.md)。

首次 GitHub macOS 15 检查发现取消测试过早读取 `URLProtocol.stopLoading` 回调状态。测试已改为有界等待对应请求的明确回调，并按每次测试的标识排除历史回调；预加载测试 10/10 重新通过。此修正只改测试同步，不改变 App 或模型服务代码。

## 重跑

先关闭其他 AskBase 实例。以下显式验证会加载本机已有模型，并迁移已核实归属的旧 AskBase 服务；只使用临时空资料库：

```sh
python3 scripts/build_app.py --debug
python3 scripts/verify_model_lifecycle.py \
  --bundle 'dist/build-products.noindex/AskBase Local.app' \
  --output evidence/local/lifecycle-check --execute
```

此检查通过 DEBUG 原生 AppKit 行为触发退出，没有用真实用户文档，也未替代物理鼠标/键盘、系统注销/关机或各种插件共同使用服务的验收。若 supervisor 本身同时被强制杀死，不能依靠它执行后续清理；不宣称能够处理任意外部进程控制。

重新执行不带 `--debug` 的构建命令，才能制作正式 Release 安装包。
