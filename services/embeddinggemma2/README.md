# EmbeddingGemma 2 服务

本目录保存可重建的本地推理服务，应用通过回环 HTTP 使用它。

从项目根目录执行 `python3 scripts/setup_embedding.py`。完整依赖固定在 `requirements.lock.txt`，模型文件树及散列来自固定官方 revision，保存在 `evidence/official-file-tree.json`。下载、安装过程生成的机器路径及日志不加入版本控制。

实际运行目录为 `~/Library/Application Support/AskBase/EmbeddingGemma2`。不要把它移动回 Documents 后直接用作后台服务目录。

```sh
cd "$HOME/Library/Application Support/AskBase/EmbeddingGemma2"
.venv/bin/python scripts/manage.py status
.venv/bin/python scripts/manage.py start
.venv/bin/python scripts/manage.py stop
.venv/bin/python scripts/manage.py restart
```

LaunchAgent 名为 `local.askbase.embeddinggemma2`，登录时启动；`uninstall` 子命令移除登录启动配置但保留模型和环境。管理器停止前检查归属，不接管未知端口或后台任务。进程通过干净环境启动，不继承其他应用的云凭据。

API 默认监听 `127.0.0.1:8871`：

```sh
curl http://127.0.0.1:8871/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"embeddinggemma-2","input":"怎样备份知识库？","input_type":"query","dimensions":768}'
```

返回包含 `data[].embedding`、`encoder_signature` 和 dimensions。资料入库使用 `input_type: "document"`。服务自动加前缀，拒绝超长输入、无效模型或维度；单次 1–8 段，最多 8192 token/段（包括前缀），最多 4 个正在处理或等待的请求。

只启用文本/代码路径。模型完整下载不代表应用已经支持图片、音频或视频。

Ollama 服务另由 `scripts/start_ollama.py` 准备，LaunchAgent 为 `local.askbasemac.ollama`。如果由本项目脚本创建，可通过以下方式停止并移除登录启动配置；这不删除 Ollama 模型：

```sh
launchctl bootout "gui/$(id -u)/local.askbasemac.ollama"
rm "$HOME/Library/LaunchAgents/local.askbasemac.ollama.plist"
```

如果复用的是用户原来启动的 Ollama，该脚本不会为它创建或接管配置，应通过原来的启动方式管理。
