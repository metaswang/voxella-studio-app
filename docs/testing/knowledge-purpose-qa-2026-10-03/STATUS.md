# 知识库 QA 实施与验证记录（2026-10-03）

## 已实现的边界

QA 默认只使用当前 canonical 正文：Transcript 优先；缺少可用 Transcript 时使用同来源、角色和当前 revision 的字幕 fallback。text-only 正文可读；部分 Transcript 不借字幕补尾；显式字幕/翻译请求仍读取对应材料。

字幕、mediaClip、text/video/mixed 向量、独立视频帧索引、素材预览和 Workbench 通用融合搜索保留。QA kinds 和 scope 在候选前筛选；QA 无命中不扩大到素材通道。素材命中提供定位候选，不据字幕或分数断言画面事实。

正文与媒体 lane 分别维护 manifest 和就绪状态；QA 重建、Transcript 到来及正文切换不删除未变化素材。首次升级校验并接管匹配的旧 clips/向量；已存在 video/mixed 的 clip 只补缺失 text 通道。无字幕视频缺少时长时探测实际媒体时长。真正删除 session 才清理所有通道。

约 60 秒软窗与 512/768 token 预算共用实际 tokenizer 和 UTF-16 原文映射。长段全文保留；可信 words 细化时间，其他材料保留粗时间或未知时间。分块独立执行、取消传播、加载合并和有界缓存避免长来源占住共享读取 actor；未变化正文跳过分块。最终句界再次校验硬上限。

旧 `/mcp` 和 `knowledge.ask` 保留；新 `/knowledge/mcp` 提供六个只读工具与独立 session。新 `voxstudio-knowledge` 和原 `voxstudio` 插件均已安装、启用。App Agent/B0 的 provider、预算、流式、取消、历史及追问接口保留。

实现细节见 [设计记录](../../design/knowledge-qa-purpose-routing.zh-CN.md)、[MCP 接口](../../local-mcp-knowledge.md)和[插件安装](../../plugins/openai-plugin-install.md)。

## 自动回归

最终知识库、MCP、长文本、视频帧及素材工具回归：**276 tests / 65 suites 通过**。覆盖 QA/media 隔离、字幕 fallback、旧素材迁移、逐模态补齐、实际无字幕视频时长、完整目录、账号范围、分页/引用、长段和 Unicode、并发读取/取消及历史材料变化。

```bash
swift test --disable-sandbox --traits BundledSpeech --no-parallel \
  --filter 'Knowledge|SessionRAG|MCP|WorkbenchSessionSearch|WeMM|TranscriptSegmenter|VisualIndexer|VisualSearch|FrameSampler|CaptureFrameTool|SearchMediaTool'
```

真实本机模型验证：**4 tests / 3 suites 通过**。包含受控证据评测、实际现有会话的临时索引和查询，以及真实 WeMM 图像索引/共享文本查询。使用临时数据库，不替换用户索引或修改其材料。

```bash
VOXELLA_RUN_LOCAL_FIXTURES=1 RUN_KNOWLEDGE_PURPOSE_EVAL=1 \
RUN_WEMM_SEARCH_INTEGRATION=1 VOXSTUDIO_KNOWLEDGE_SESSION_EXPERIMENT=1 \
  swift test --disable-sandbox --traits BundledSpeech --no-parallel \
  --filter 'KnowledgePurposeQuality|realWeMMImageIndexAndSharedTextQuery|KnowledgeSessionDatasetExperiment'
```

帧回归实际捕获源视频和时间线，通过 MCP 读取 PNG，并验证撤销；素材工具验证原有 spoken 范围和 mediaRef 限制。其他视觉测试验证采样、帧向量和查询生命周期。

插件打包 **4 tests 通过**；新 skill 校验通过；Python/Bash 语法和 `git diff --check` 通过。两插件 ZIP 输出为 `.build/openai-plugin/VoxStudio-OpenAI-Plugin.zip`。

完整仓库测试未全部运行。`BundledSpeech,SparkleUpdates` 测试组合曾受现有 `AppUpdaterTests` 初始化接口不匹配阻止；以上回归使用 `BundledSpeech`。签名 App 构建仍包含正常配置的 Sparkle 功能。

## 已测检索质量

由于没有人工标注，按完整受控资料逐题生成并审阅 **60 个参考答案、98 个精确证据范围**，标记 `model_assisted_source_review`。这是可回放的受控资料集，不是用户真实资料的人工独立标准答案。见 [fixture](../../../Tests/Fixtures/Knowledge/purpose-qa-v1/README.md)。

WeMM 256 维、Qwen3 reranker、5 秒 rerank 预算、返回 8。43 题有 canonical 正文排序证据，分别经过 Native、当前 B0、新 MCP；其他题验证完整目录、聚合、材料可读性或显式字幕等行为。

| 路径 | Recall@8（证据 span） | nDCG@8（passage） | p50 / p95 延迟 | scope 违规 |
|---|---:|---:|---:|---:|
| Native | 92.38% | 0.7461 | 438 / 849 ms | 0 |
| 当前 B0 | 92.38% | 0.7461 | 441 / 839 ms | 0 |
| 新 MCP | 92.38% | 0.7461 | 444 / 764 ms | 0 |

三个额外英文/跨语言探针均 Recall/nDCG 1.0，单独汇总；样本规模不能证明普遍英文质量收益。模型分数仅用于排序。

8 题首轮候选未覆盖全部证据，主要涉及穷举、比较和冲突材料；需要 fetch/全文核验，不能把 search 候选当完整答案。逐题记录见 [results](retrieval-results.json)，汇总见 [summary](retrieval-summary.json)。

当前 B0 与 Native 共用改造后的检索层，不是冻结旧版基线。此报告未测回答模型的事实/引用正确率、四种 skill 条件消融、正式素材检索质量指标和费用；对应字段保持 false/null。不能用上述检索指标代替答案正确率，或声称薄 skill 已经优于原 skill。

## 签名构建与运行验收

按仓库要求执行 `./scripts/bundle.sh debug --sign`，随后启动 `.build/VoxStudio.app`。最终运行验收结果单独保存为 `http-acceptance.json`；不保存真实正文、标题、source ID、文件路径或预览字节。

运行中实际发现六个新只读工具、100 个旧工具、31 个本地来源和五个启用方法。canonical 读取、查词和引用 fetch，显式字幕及 media_clips 检索均通过；素材返回八个候选，媒体 locator/fetch 和一秒旧工具预览可用。界面检查确认知识库来源列表和原文面板、从来源打开原视频、显示视频画面、暂停播放及独立字幕浏览均正常。

现有 App 问答链路另用一个公开视频问题验收：约 3.94 秒完成回答，事实与当前 Transcript 相符，一条引用的 provenance 为 `original_segments`、generation 与当前正文一致，原文字面查词命中一次；粗时间没有改写成伪精确定位。见 [native-answer-acceptance.json](native-answer-acceptance.json)。该单题检查不构成正式答案质量或 skill 消融评测，不改变上面 false/null 指标。

可重跑本地协议与媒体预览验收：

```bash
python3 scripts/check-knowledge-mcp.py --preview \
  --output /private/tmp/voxstudio-knowledge-http-smoke.json
```

该脚本检查新旧工具列表、只读 annotations/output schema、跨 profile 404、无状态工具隔离、JSON 与 structuredContent 一致、完整本地目录/聚合、methods、canonical 查询/引用读取、查词、显式字幕、media_clips 定位、旧正文工具及预览。它不调用云端回答模型；缺少对应本地材料的检查会跳过，不能据此声称命中质量已测。

宿主插件已安装并启用，刷新后已出现新 `knowledge-qa` skill；本轮宿主工具列表没有暴露新 MCP 工具（刷新时 App 未运行）。协议检查直接连接了实际 App 的两个 profile。正式 Work/Codex 的多题回答与 skill 消融仍需在 App 运行时加载新插件的宿主环境完成，不能只凭 HTTP 成功确认。

## 插件发布与 Settings 更新

本轮沿用已有 EU R2/CDN 发布路径，发布双插件 ZIP：VoxStudio 0.1.1 与 VoxStudio Knowledge 0.1.0，分别安装、启用。包大小 15,368 字节，20 个文件；不可变下载链接与 SHA-256 见 [release](plugin-release.json)。R2 回读、公开 CDN GET/HEAD、完整字节、哈希、附件响应和缓存校验均通过。旧版本对象保留；没有更改 CDN Worker、DMG 发布通道或 Sparkle appcast。

Settings → MCP → Codex / ChatGPT Work 增加知识问答和媒体制作选择，默认知识问答。对应安装命令、服务地址与示例随选择切换；一个 ZIP 可独立安装两个插件。增加中英文说明及两个插件共用会话库、保留素材/视频帧能力的提示。实际界面检查覆盖两种宿主入口、媒体切换、下载按钮及说明弹窗；布局已检查。

再次完成签名 debug 构建并启动新 App，276 tests / 65 suites 回归通过，4 个打包/安装测试通过。新 App 的两个 HTTP profile、显式字幕、八个媒体候选、引用读取及旧预览再次验收通过。发布包从最终源码重建得到相同哈希。记录见 [settings acceptance](plugin-settings-acceptance.json) 和 [CDN verification](plugin-cdn-verification.json)。本轮没有补做正式宿主多题回答或 skill 消融。

暂存区的完整 Swift 模块已独立 typecheck 通过，验证未依赖其他未暂存的新文件或共享文件改动。此次提交限定知识库实现、双插件及 Settings 相关内容；其他功能的工作区改动保留。
