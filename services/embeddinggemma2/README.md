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

源码现提供原生图片、音频和视频接口，完整 BF16 模型与原文本模型共用单个
推理 worker。启动时，六组文本输入必须在两份模型上得到逐项相同的
float32 向量，才会启用媒体接口并返回相同的 `encoder_signature`。
`encoder.py` 保持原始字节不变，媒体代码和预处理另由
`media_encoder_signature` 标识。

```http
POST /v1/media/embeddings
Content-Type: application/json

{
  "model": "embeddinggemma-2",
  "input_type": "document",
  "dimensions": 768,
  "input": {
    "kind": "video",
    "images": ["<base64 JPEG frame 1>", "<base64 JPEG frame 2>"],
    "timestamps": [0.0, 1.0],
    "audio": "<base64 PCM16 mono 16000Hz WAV for this segment>"
  }
}
```

示例中的尖括号内容需替换为原始文件字节的标准 base64，不能传 URL、路径或
data URI。响应与文本接口一致，并增加顶层 `media_encoder_signature`；
`data[0].embedding` 为 float 数组，不需要传 `encoding_format`。

- `image`：`images` 恰好一张 JPEG；不能混入音频或时间戳。
- `audio`：只传 `audio`，PCM16 little-endian、单声道、16 kHz 的 RIFF WAV，
  每段 20 ms–10 秒。服务不重采样、不降混、不截断。
- `video`：`images` 为按时间排列且尺寸相同的 1–8 帧 JPEG；
  可附同片段 WAV。时间戳若提供，必须逐帧对应、非负、有限、严格递增，
  跨度不超过 10 秒，可用源视频的绝对时间。视频走原生 video processor，
  保留全部传入帧，不进行二次采样。
- 官方模型要求纯媒体不加文本前缀；媒体 `query`/`document` 只标明检索角色，
  不改变同一媒体的向量。视频保留 checkpoint 的 `add_timestamps=false`，
  时间戳用来校验片段，不插入提示文本。
- 媒体单次传输上限为 48 MiB；JPEG 每帧最多 4 MiB、8192 边长、
  16,777,216 像素，总帧像素最多 33,554,432；WAV 最多 512 KiB。
  这些是片段传输与解码预算。App 应遍历完整长媒体逐段发送，不截掉文件尾部。
  缺少时间戳的 JPEG 序列无法自行说明实际时长，十秒分段由 App 保证。

`/health` 的 `modalities` 仅在媒体模型已加载、文本对齐通过后包含
`image/audio/video`；同时返回 `media_encoder_signature`、`media_status`
和 `media_limits`。媒体启动失败时文本接口继续可用，媒体请求返回 503。
无效字段返回 422、无效媒体返回 400、请求超预算返回 413、队列满返回 429；
错误响应与日志不回显媒体正文。所有模型文件都从固定本机目录读取。

离线检查（使用已有服务 Python，不需要新下载或安装）：

```sh
python -B scripts/test_media_api.py
python -B scripts/test_deployment_guards.py
```

真实验证脚本 `scripts/verify_media_real.py --execute-gpu` 会加载模型；
仅应在协调 GPU 与明确预算后运行，已有报告时拒绝自动重跑。
实际合成验证结果与边界见 [MEDIA-VALIDATION.md](MEDIA-VALIDATION.md)。
本次仅验证仓库中的隔离实例，未升级安装目录或重启线上 8871。
部署脚本已纳入 `media_encoder.py` 的复制；项目根的旧安装入口会直接复用
健康文本服务，整合方须另外处理明确的媒体版本升级，不能把它的“已就绪”
提示当作媒体能力已安装。

Ollama 服务另由 `scripts/start_ollama.py` 准备，LaunchAgent 为 `local.askbasemac.ollama`。如果由本项目脚本创建，可通过以下方式停止并移除登录启动配置；这不删除 Ollama 模型：

```sh
launchctl bootout "gui/$(id -u)/local.askbasemac.ollama"
rm "$HOME/Library/LaunchAgents/local.askbasemac.ollama.plist"
```

如果复用的是用户原来启动的 Ollama，该脚本不会为它创建或接管配置，应通过原来的启动方式管理。
