import Foundation

/// Topic classification using the existing embedding space. These are candidate
/// labels, not generated facts. Unknown topics may deliberately remain untagged.
enum AutoTagging {
    struct Candidate: Sendable {
        let label: String
        let description: String
        let terms: [String]
        var prompt: String { "\(label): \(description)" }
    }
    private struct Score {
        let label: String
        let rank: Double
        let semantic: Double
        let anchored: Bool
    }

    // Keep topic descriptions bilingual so Chinese and English libraries share
    // stable labels. Existing labels in the same knowledge base extend this set.
    static let catalog: [Candidate] = [
        topic("AWS", "Amazon Web Services cloud infrastructure", ["aws", "amazon web services", "亚马逊云"]),
        topic("Amazon EC2", "EC2 virtual machines instances compute on AWS", ["ec2"]),
        topic("Amazon EKS", "Amazon EKS managed Kubernetes clusters", ["eks"]),
        topic("Kubernetes", "Kubernetes container orchestration pods clusters deployments", ["kubernetes", "k8s", "kubectl"]),
        topic("容器", "Docker containers images container runtime 容器镜像", ["docker", "containerd", "容器"]),
        topic("云计算", "Cloud computing infrastructure services 云计算基础设施", ["cloud computing", "云计算"]),
        topic("网络", "Computer networking TCP IP routing DNS BGP 网络协议路由", ["tcp", "dns", "bgp", "网络", "路由"]),
        topic("Linux", "Linux operating system kernel administration 内核操作系统", ["linux", "ebpf", "内核"]),
        topic("eBPF", "eBPF kernel tracing networking observability", ["ebpf", "bpf"]),
        topic("安全", "Cybersecurity access control encryption vulnerabilities 信息安全", ["security", "encryption", "安全", "漏洞", "加密"]),
        topic("数据库", "Databases SQL queries transactions indexes 数据库事务索引", ["database", "sql", "sqlite", "postgresql", "数据库"]),
        topic("存储备份", "Data storage backups disaster recovery 数据存储备份恢复", ["backup", "storage", "备份", "存储"]),
        topic("可观测性", "Monitoring logs metrics tracing observability 系统监控", ["observability", "monitoring", "prometheus", "可观测", "监控"]),
        topic("DevOps", "CI CD continuous integration deployment automation", ["devops", "ci/cd", "持续集成"]),
        topic("软件架构", "Software architecture distributed systems system design 分布式系统设计", ["architecture", "distributed systems", "软件架构", "分布式"]),
        topic("编程", "Software programming source code algorithms 软件编程代码", ["programming", "编程", "程序设计"]),
        topic("Python", "Python programming language libraries development", ["python"]),
        topic("Swift", "Swift programming language SwiftUI Apple development", ["swift", "swiftui"]),
        topic("Web 开发", "Web frontend backend HTML CSS JavaScript React 网页开发", ["javascript", "typescript", "react", "html", "css", "前端"]),
        topic("iOS 开发", "iPhone iOS mobile app development UIKit", ["ios", "uikit", "iphone app"]),
        topic("macOS", "macOS Mac desktop applications Apple computer", ["macos", "appkit"]),
        topic("机器学习", "Machine learning training prediction statistical models 机器学习", ["machine learning", "机器学习"]),
        topic("大语言模型", "Large language models LLM transformers language generation", ["llm", "large language model", "大语言模型"]),
        topic("RAG", "Retrieval augmented generation knowledge base embeddings semantic search 检索增强生成知识库", ["rag", "retrieval augmented", "知识库", "检索增强"]),
        topic("AI Agent", "AI agents tool use autonomous workflows 人工智能代理智能体", ["agent", "智能体"]),
        topic("模型训练", "Neural network training fine tuning optimization gradients 模型训练微调", ["fine-tuning", "finetuning", "模型训练", "微调"]),
        topic("模型推理", "Model inference serving quantization KV cache 模型推理量化部署", ["inference", "quantization", "kv cache", "推理", "量化"]),
        topic("GPU", "GPU parallel computing CUDA Metal acceleration", ["gpu", "cuda"]),
        topic("多模态", "Multimodal image audio video language models 多模态模型", ["multimodal", "多模态"]),
        topic("计算机视觉", "Computer vision image recognition object detection 图像识别目标检测", ["computer vision", "图像识别", "目标检测"]),
        topic("语音技术", "Speech recognition synthesis text to speech 语音识别合成", ["speech recognition", "tts", "asr", "语音识别", "语音合成"]),
        topic("数据分析", "Data analytics visualization statistics 数据分析可视化统计", ["data analysis", "analytics", "数据分析", "可视化"]),
        topic("数学", "Mathematics equations algebra calculus probability 数学公式", ["mathematics", "calculus", "数学", "概率"]),
        topic("物理", "Physics mechanics quantum energy experiments 物理力学", ["physics", "quantum", "物理", "量子"]),
        topic("生物", "Biology organisms genetics cells ecology 生物遗传细胞", ["biology", "genetics", "生物", "细胞"]),
        topic("医疗健康", "Medicine healthcare clinical treatment health 医疗健康", ["medicine", "healthcare", "医疗", "健康"]),
        topic("金融投资", "Finance investment stocks bonds portfolio 金融投资", ["investment", "portfolio", "股票", "投资", "金融"]),
        topic("财务", "Accounting financial statements revenue budget 财务报表会计预算", ["accounting", "financial statement", "财务", "会计", "预算"]),
        topic("法律", "Law legal contracts regulations 法律合同法规", ["legal", "contract", "法律", "合同", "法规"]),
        topic("市场营销", "Marketing advertising customers campaigns 市场营销广告", ["marketing", "advertising", "营销", "广告"]),
        topic("产品设计", "Product design user experience interface usability 产品交互设计", ["product design", "ux", "用户体验", "产品设计"]),
        topic("项目管理", "Project management milestones schedule delivery 项目计划进度交付", ["project management", "milestone", "项目管理", "里程碑"]),
        topic("教育学习", "Education teaching learning courses 教育教学学习课程", ["education", "teaching", "教育", "教学"]),
        topic("历史", "History historical events civilizations 历史文明", ["history", "历史"]),
        topic("文学写作", "Literature fiction novels creative writing 文学小说写作", ["literature", "fiction", "文学", "小说", "写作"]),
        topic("摄影", "Photography cameras photos composition 摄影相机构图", ["photography", "camera", "摄影", "相机"]),
        topic("视频制作", "Filmmaking video editing cinema storyboard 视频剪辑电影制作", ["filmmaking", "video editing", "剪辑", "分镜", "短剧"]),
        topic("音乐", "Music musical instruments singing melody 音乐乐器歌唱", ["music", "singing", "音乐", "乐器"]),
        topic("旅行", "Travel tourism itinerary destinations 旅行旅游行程", ["travel", "tourism", "旅行", "旅游"]),
        topic("烹饪美食", "Food cooking recipes ingredients meals 烹饪食谱美食", ["cooking", "recipe", "烹饪", "食谱", "美食"]),
        topic("运动健身", "Sports fitness exercise training 运动健身", ["fitness", "exercise", "健身", "运动"]),
        topic("农业园艺", "Agriculture gardening fruit trees crops cultivation 农业园艺种植果园", ["agriculture", "gardening", "农业", "园艺", "果园"]),
        topic("自然风景", "Natural landscape mountains forests rivers ocean 自然山水风景", ["landscape", "风景", "山水"]),
        topic("动物", "Animals pets wildlife birds cats dogs 动物宠物鸟猫狗", ["animal", "wildlife", "动物", "宠物"]),
        topic("建筑空间", "Architecture buildings interiors rooms urban spaces 建筑室内空间", ["building", "interior", "建筑", "室内"]),
        topic("交通汽车", "Transportation cars vehicles roads railways 交通汽车道路", ["transportation", "vehicle", "交通", "汽车"]),
    ]

    private static func topic(_ label: String, _ description: String, _ terms: [String]) -> Candidate {
        Candidate(label: label, description: description, terms: terms)
    }

    static func candidates(existingTags: [String]) -> [Candidate] {
        var output = catalog
        var seen = Set(catalog.map { $0.label.lowercased() })
        for tag in existingTags {
            let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, tag.count <= 32, !tag.contains(where: \.isNewline),
                  seen.insert(tag.lowercased()).inserted else { continue }
            output.append(topic(tag, "Documents about \(tag) · 关于\(tag)的资料", [tag.lowercased()]))
            if output.count >= 128 { break }
        }
        return output
    }

    /// Bound work on large books/videos, sampling across the entire document.
    static func sample(_ chunks: [DocumentChunk]) -> [DocumentChunk] {
        guard chunks.count > 24 else { return chunks }
        return (0..<24).map { chunks[$0 * (chunks.count - 1) / 23] }
    }

    static func select(candidates: [Candidate], vectors: [[Float]],
                       chunks: [DocumentChunk], title: String) -> [String] {
        guard candidates.count == vectors.count, !chunks.isEmpty else { return [] }
        let sampled = sample(chunks)
        // Media labels/filenames are not content evidence. Use only actual OCR
        // for lexical support; semantic media vectors can still match topics.
        let readable = sampled.filter { $0.media == nil || $0.media?.textSource != nil }
        let evidence = ((chunks.first?.media == nil ? title + "\n" : "") +
                        readable.map { String($0.text.prefix(4_000)) }.joined(separator: "\n")).lowercased()
        var scores: [Score] = []
        for (candidate, vector) in zip(candidates, vectors) {
            let similarities = sampled.map { Retrieval.cosine(vector, $0.embedding) }.sorted(by: >)
            let coverage = max(1, (similarities.count + 3) / 4)
            let mean = similarities.prefix(coverage).reduce(0, +) / Double(coverage)
            let semantic = 0.65 * similarities[0] + 0.35 * mean
            let anchored = candidate.terms.contains { contains($0, in: evidence) }
            let rank: Double = semantic + (anchored ? 0.07 : 0.0)
            scores.append(Score(label: candidate.label, rank: rank, semantic: semantic, anchored: anchored))
        }
        scores.sort { $0.rank == $1.rank ? $0.label < $1.label : $0.rank > $1.rank }
        // Uniform embeddings carry no discriminating evidence.
        // Cosine scores in this space can have a high common baseline, even for
        // meaningless input. Require separation from unrelated topics as well
        // as an absolute floor. Similarity is not a calibrated probability.
        let semantics = scores.map(\.semantic).sorted()
        guard let best = scores.first, let high = semantics.max(), let low = semantics.min(),
              high - low >= 0.015 else { return [] }
        let selected = scores.filter { score in
            let threshold: Double = score.anchored ? 0.30 : 0.48
            let separation: Double = score.anchored ? 0.05 : 0.08
            return score.semantic >= threshold
                && score.semantic >= semantics[semantics.count / 2] + separation
                && score.rank >= best.rank - 0.10
        }
        return Array(selected.prefix(5).map(\.label))
    }

    private static func contains(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let isASCII = term.unicodeScalars.allSatisfy { $0.isASCII }
        let pattern = isASCII ? "(?<![a-z0-9])\(escaped)(?![a-z0-9])" : escaped
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
