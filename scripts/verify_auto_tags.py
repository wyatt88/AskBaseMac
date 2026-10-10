#!/usr/bin/env python3
"""Small synthetic text smoke against the existing local EmbeddingGemma 2.

Never opens the user's library or configures/downloads a model. These examples
are an engineering check, not a general tagging-accuracy benchmark.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ("集群调度", "Amazon EKS",
     "Amazon EKS runs a managed Kubernetes control plane. Administrators use kubectl to deploy pods, inspect nodes and configure cluster networking on AWS."),
    ("内核追踪", "eBPF",
     "eBPF provides Linux kernel tracepoints and kprobes. Maps carry observability metrics to userspace. This guide explains eBPF programs for network tracing."),
    ("温室栽培", "农业园艺",
     "园艺记录：温室里的番茄幼苗需要充足光照，定期浇水并保持土壤透气。种植时安排株距，观察叶片，控制病虫害，果实成熟后及时采收。"),
    ("资产配置", "金融投资",
     "基金投资应分散配置股票和债券，评估波动风险，控制管理费用。长期投资不能保证收益，市场价格会变化，定期再平衡要考虑交易成本。"),
    ("晚餐准备", "烹饪美食",
     "烹饪食谱：鸡肉切块，用姜片和少量盐腌制。锅中加油煎至表面金黄，再加入土豆和胡萝卜，小火炖煮到熟透，最后撒上葱花。"),
    ("界面代码", "Swift",
     "SwiftUI uses declarative View structures and State bindings. Swift developers compose VStack and HStack layouts and use async await for background tasks."),
    ("资料问答", "RAG",
     "RAG combines retrieval augmented generation with semantic search. Split documents into chunks, encode embeddings, retrieve relevant passages, and cite the knowledge base sources."),
    ("旋律练习", "音乐",
     "音乐课堂中先听钢琴演奏的旋律，再按节拍歌唱。练习时区分音高与节奏，让乐器伴奏和人声保持协调。"),
    ("无意义字串", None, "zxqv lmnzr pqtzz xyqrzz vvzxkl zzzqv"),
    ("待补内容", None, "TODO TODO TODO TBD TBD ... ???"),
]


def main():
    subprocess.run(["swift", "build", "--product", "askbase"], cwd=ROOT, check=True)
    binary_dir = subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=ROOT, text=True
    ).strip().splitlines()[-1]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:8871/health", timeout=10) as response:
        health = json.load(response)
    with tempfile.TemporaryDirectory(prefix="AskBase-AutoTagVerify-") as directory:
        base = Path(directory)
        files = []
        for title, _, text in CASES:
            path = base / f"{title}.txt"
            path.write_text(text)
            files.append(str(path))
        started = time.monotonic()
        result = subprocess.run(
            [str(Path(binary_dir) / "askbase"), "--root", str(base / "library"), "import", *files],
            cwd=ROOT, capture_output=True, text=True, check=True, timeout=180,
        )
        report = json.loads(result.stdout)
        by_title = {d["title"]: d for d in report["imported"]}
        checks = {
            "all_indexed": len(by_title) == len(CASES) and not report["failures"],
            "no_tagging_errors": not report["tagging_warnings"],
        }
        for title, expected, _ in CASES:
            tags = by_title.get(title, {}).get("tags", [])
            checks[title] = expected in tags if expected else not tags
        output = {
            "scope": "10 synthetic text cases; no real-corpus or media-quality acceptance",
            "encoder_signature": health["encoder_signature"],
            "model": health["model"],
            "model_revision": health.get("revision"),
            "elapsed_seconds": round(time.monotonic() - started, 2),
            "checks": checks,
            "tags": {title: d["tags"] for title, d in by_title.items()},
        }
        destination = ROOT / "evidence/local/auto-tags-verification.json"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(output, ensure_ascii=False, indent=2))
        print(json.dumps(output, ensure_ascii=False, indent=2))
        if not all(checks.values()):
            raise SystemExit("Synthetic tagging smoke failed; inspect evidence/local/auto-tags-verification.json")


if __name__ == "__main__":
    main()
