# 知识库回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="k01"></a>

## K01 知识来源、索引与范围

范围：Source列表、索引可用性、当前/多会话范围。前置标记：L。定位：`Sources/VoxstudioPro/Knowledge/KnowledgeSourceListView.swift`、`Sources/VoxstudioPro/Search/Indexing`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| K01-C01 | 正常/P0 | 加入两份内容互斥的测试转录，查看来源与索引状态 | 正确来源可用；进度到达可检索终态 |
| K01-C02 | 范围/P0 | 只选A、只选B、选A+B分别问同一对照问题 | 答案/证据仅来自选择范围；不越范围引用 |
| K01-C03 | 空态/P1 | 无来源或空scope进入Knowledge | 说明需要来源；不会拿历史范围回答 |
| K01-C04 | 更新/P1 | 编辑测试转录后等待/刷新索引再检索新旧事实 | 使用最新内容；旧索引状态可追踪 |
| K01-C05 | 删除/P1 | 删除可丢弃测试来源后再检索其专属内容 | 不返回已移除来源的新证据；历史引用有可理解缺失反馈 |

<a id="k02"></a>

## K02 语义检索与图谱召回

范围：语义搜索、rerank、graph recall与证据范围。前置标记：L。定位：`Sources/VoxstudioPro/Knowledge/KnowledgeRetrievalService.swift`、`Sources/VoxstudioPro/Knowledge/KnowledgeGraphServices.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| K02-C01 | 语义/P0 | 对已知事实使用同义表达/不同语言查询 | 召回相应证据；不是只匹配标题字符串 |
| K02-C02 | 排序/P1 | 加入相近主题干扰来源，启用可用rerank查询 | 首批证据与问题相关；干扰内容不支撑结论 |
| K02-C03 | 图谱/P1 | 用两个来源的已知人物/事件关系问跨段问题 | 可追踪关联来源；关系不凭空推断为事实 |
| K02-C04 | 无匹配/P1 | 问来源不含的具体事实 | 无证据时说明缺失/澄清；不编造引用 |
| K02-C05 | 异常/P1 | embedding/rerank资源缺失后查询并恢复 | 错误或降级路径明确；恢复后可重新检索 |

<a id="k03"></a>

## K03 知识问答与多轮交互

范围：有证据答案、scope、多轮、取消和模型路由。前置标记：B。定位：`Sources/VoxstudioPro/Knowledge/KnowledgeQAService.swift`、`Sources/VoxstudioPro/Knowledge/Agent/KnowledgeAgentRuntime.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| K03-C01 | 正常/P0 | 询问测试转录中有标准答案的问题 | 关键事实正确，回答有对应证据 |
| K03-C02 | 多轮/P1 | 追问代词/时间比较，再换到不相关来源 | 历史上下文合理；切换scope不泄露旧范围事实 |
| K03-C03 | 回答模式/P2 | 分别选concise/normal/detailed回答同一问题 | 长度/结构有区别，核心事实和引用一致 |
| K03-C04 | 澄清/P1 | 提出歧义人名、矛盾来源与超出来源的问题 | 请求澄清或标明冲突/无法证实；不做无证据肯定 |
| K03-C05 | 取消/P1 | 长回答中Stop，立即提交下一题并切换页面 | 停止有终态；新回答不混入前次半成品 |

<a id="k04"></a>

## K04 引用定位与来源摘要

范围：citation chip、转录范围、时间戳、来源摘要。前置标记：B。定位：`Sources/VoxstudioPro/Knowledge/CitationResolver.swift`、`Sources/VoxstudioPro/Knowledge/KnowledgeTranscriptView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| K04-C01 | 定位/P0 | 点击回答里的引用并播放所指时间范围 | 打开正确session/范围，内容实际支持该句 |
| K04-C02 | 多引用/P1 | 跨两份来源问题逐个点击引用 | 每个标号/来源/时间与实际证据一致 |
| K04-C03 | 边界/P1 | 引用起始0秒、接近结尾及长段落 | 高亮不越界；首尾文字和播放范围可见 |
| K04-C04 | 摘要/P1 | 打开来源摘要并核对关键事实，返回问答 | 摘要属于当前来源；返回保留原对话 |
| K04-C05 | 缺失/P1 | 在一次性测试数据中移除来源后点历史引用 | 可理解失效提示；不跳到无关session |

<a id="k05"></a>

## K05 知识对话持久化与恢复

范围：会话切换、消息复制、错误恢复入口。前置标记：B。定位：`Sources/VoxstudioPro/Knowledge/KnowledgeChatStore.swift`、`Sources/VoxstudioPro/Knowledge/KnowledgeChatPane.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| K05-C01 | 保存/P0 | 完成两轮问答后导航、重启并重开 | 消息、scope、引用保持关联；无重复答案 |
| K05-C02 | 隔离/P1 | 建立两个测试对话并反复切换 | 历史不串台；草稿/选择范围规则明确 |
| K05-C03 | 复制/P2 | 复制含引用与多段文字的答案 | 文本可用；没有复制加载占位文字 |
| K05-C04 | 错误/P1 | 使provider无效/网络断开，查看恢复动作并修复 | AI Service/重试等入口可用；不永久Thinking |
| K05-C05 | 重复/P1 | 快速点击发送/在已运行问答时再提交 | 串行/阻止策略明确；不多次扣请求或生成重复消息 |
