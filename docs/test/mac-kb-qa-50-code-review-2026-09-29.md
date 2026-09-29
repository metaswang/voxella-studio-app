# 50 条知识库 QA 回归复盘与修复验收

## 走查基线（修改业务代码之前）

源码基线 `5bfc3011`，参考原始 2026-09-16 的问题/oracle 和 2026-09-29 的结果记录。原结果表保留，不覆盖。记录共 50 条，25 条通过、25 条不通过；其中 41、42 无法选来源，50 无回答，不能等同于答案错误。

只读核对本机 Workbench、保存的问答、`app.log.1` 及当前实现。日志按实际用户消息时间/request_id 对应，排除同一日志里的单元测试请求。1–26 的实际请求有 planner、skill_selection、普通 chat/composer；27–49 有 native_tool/native_run。不能用前半段旧链路的结果判定当前原生循环仍有同样错误。第 50 条无响应的现场诊断和此前修复见设计实施记录。

## 共性分类

| 类别 | 失败 ID | 共性、当前代码结论 |
| --- | --- | --- |
| 片段当完整证据，未继续读上下文 | 1、2、3、4、6、8、9、20、23、24 | 旧链路只提供检索 excerpt/有界 composer。当前原生读取有完整 segment、时间窗口及 next_cursor，旧 composer 不在正常路径；仍需端测 agent 是否继续查缺口。 |
| 多来源/多维度覆盖不全与误拒答 | 7、10、11、18、19、34 | 旧 Top-K 无全集或比较保证。当前目录、来源搜索、逐来源读取和分析表存在，但 agent 可以仅用已读开头/历史回答停止。34 的原生失败回答重复 33 的概括；本次修改前 UI 重测 34 已正确列出焦虑/开支/冲突，属于取证和模型决策不稳定，不能称稳定的空索引故障。 |
| 目录、日期、极值统计 | 13、14、15、16、17 | 旧 catalog/context 丢失集合语义。当前仍有明确工具缺陷：排序只生成 sorted_session_ids，sessions 返回 UUID 顺序；只有 durationHint 的聚合无法读取本地总长；没有 transcript 筛选；metadata/citation 重复序列化使后续上下文预算过早用尽。17 还应给原文和时间，语义 Top-K 不能保证所有包含某短语的来源。 |
| 归因和无依据扩展 | 44；原 9/16 报告的 50 | 44 原文 9:17–9:53 确有主持人将学历/程度与备考联系的评论，但答案最终把评论/自述合并为自己的因果判断。应保留说话者归因，区分直接陈述和推断。50 的 transcript 只说实践变化、累积 bloated instructions，不支持性能/成本等外推。当前提示不能保证逐项语义蕴含，需强化取证/归因约束并实际回归，不能宣称引用 ID 校验能证明因果。 |
| 测试前提/记录误差 | 13、14、15、16、24、41、42（与上列重叠） | 当前 signed-out 隐藏 Cloud 是授权规则；41/42 是 BLOCKED_SCOPE。created/imported 日期不等于录制日，日期查询必须指定年份/时区。当前增加了来源；AI 的转录终点约 4h25m 超过 Infinity 约 3h52m，且两个原媒体文件均已不存在，不能据此比较媒体总长。MemoryCheck ASR 的实际媒体 1.52s 也比旧 Test 更短，旧 16 oracle 不再有效。24 保存的实际答案写 Claude Opus 4.5，不能按结果摘要中的“Opus.5”认定型号错误；本轮 UI 又按转录核实 Opus 4.5 与 Gemini 3 的热度/组织文化比较。 |
| 主线程布局与内存 | 50 | 现场 SwiftUI 懒布局/底部持续锚定反馈循环已由 5bfc3011 修复。当前是实际高度 VStack + 合并滚动；24 轮增长/120 秒等待回放通过。旧 pending 用户消息不会在重启后自动补发，不能凭无历史答案判定再次卡死。修复后真实 UI 第 50 条及其连续追问均结束；idle 期 CPU 回到 0%，search idle-unload 后 RSS 回落，见本轮 UI 记录。 |

## 当前流程与修改前代码问题

正常入口 Controller.send → QAService.answer/dispatch → KnowledgeAgentRuntime → 授权 snapshot/证据工作区 → 原生 agent/tool loop → 流式 delta/最终回答。仅 DEBUG B0 走旧链路；metadata 问题无模型下载门禁。读取、索引搜索、引用和答案渲染分别检查。

以下是在改代码之前确认的事项：

| 编号 | 代码层发现 | 影响/计划 |
| --- | --- | --- |
| F1 | inventory 聚合先按 UUID 生成 rows，随后才排序 IDs；缺少 has_transcript 筛选，时长只用 hint | 排序行/极值可能错位，混入无原文来源；时长排名需要完整筛选集合的本地媒体探测，未知保留未知。 |
| F2 | 首轮 16 张 full metadata 及列表每行嵌套 citations，又在顶层重复 citations/snippet；目录消耗累计保守预算 | 63 来源的契约样本两请求已预留约 200k/240k，第三轮不能继续读。改紧凑目录卡片和非重复引用，保留完整 metadata 按需读取。 |
| F3 | 最终 Sources 返回 workspace 的全部 refs，含无关首轮卡片和缓存旧证据 | 来源多/不对应实际回答；按原生引用编号选本次答案实际引用，保持工作区编号稳定。 |
| F4 | 显示层把空格后的裸数字当 citation 删除 | 有证据时“共有 4。”等事实数字也会消失；只移除可识别的括号 citation，保留普通数值。 |
| F5 | 一个原始 segment >16k 字符时直接报错，cursor 无法越过它 | 完整 observation 设计仍有不可读原文；拆为稳定分页的原文片段，保留原时间及来源，不伪造细粒度时间。 |
| F6 | 原生 history 带旧 citation_number；不同 run 的编号可能变化。只验证来源存在，无法证明旧回答当前有效 | 显式标记旧答案未核查，移除旧引用编号，原文重新取证；强化逐维度回答、连续读/不把开头截断当缺证据、意见和推断分开。 |
| F7 | 缓存只限制 8 会话/64 项，单会话累积原始 payload 无字节界限 | 长对话可不断累积缓存。设字节上限，超限安全丢弃可重建的缓存；不改变磁盘历史/来源。与既已修复的 SwiftUI 现场卡死分开。 |
| F8 | 源搜索返回 match_source 但丢弃 card.snippet；无法从命中确认来源相关性 | 返回有界匹配 excerpt，明确节选并提示原文核查；来源卡片不冒充已读正文。 |
| F9 | 检索原文短语仍由 Top-K 返回，无法完整列出所有包含短语的来源 | 提供有类型的本地原文短语遍历，结果分页、时间锚点和未读来源明确返回；用于 17 的字面匹配全集，不替代语义检索。 |

目录完整性、范围过滤、分页正确性可由代码/测试证明；模型是否按 evidence 逐条归纳仍须真实端测，不以 contract replay 冒充语义通过。Cloud 不可见不绕过授权，不修改说话人识别/计数。

## 修复与端测

走查完成后统一实施并在此补录。需包含：工具/运行时回归、真实本机资料读取与时长检查、签名构建，以及 UI 原生 QA 的代表失败类别（多轮/跨来源/目录/时间定位/证据边界）。记录实际完成、未测和阻塞，不沿用旧 oracle 冒充当前通过。

### 新端测发现（先记录，再修复）

F10：05:58:30Z 提交第 17 条 `Thank you` 来源问题，UI/磁盘用户消息正确，但 agent 调用 session_aggregate 并再次回答上一题时长极值。前两题 20、16 已正确完成。走查 Controller 固定 queryText、Responses 保持 input 顺序，未发现传错 query 的证据；运行时把当前问题埋在事实/缓存大块的末尾，历史问题仍用无标记的 user 角色，工具后没有重申当前任务，存在旧任务干扰。修复方向：显式标记历史仅供消歧，将当前问题放为独立末条用户消息，并在工具结果之后恢复当前问题。共享证据继续保留，但历史分析不代表当前任务。

F11：F10 修复后第 17 条正确使用 knowledge_find_text，列出 8 个来源、时间点和 1 个不可读来源；但生成了 `[18–21]` 等引用区间，当前括号解析仅接受单编号/逗号列表，导致 Sources 只保留 2 个来源，区间标记残留正文。应统一支持区间形式并加防止超大区间展开的界限；在本轮剩余端测后一起修复和重测。

F12：06:06:49Z 第 19 条三短来源对比，取得三个来源的摘要和原文后，第三个模型请求因预算拒绝（前两次已预留 141293，published=0）。没有卡死，但无法给答案。工具的 segments/summary 与 citation.snippet/match_text 重复传全文，多个宽泛来源发现又叠加无关 excerpt。与 F2 属同一类，在实际复杂问题仍存在。应在模型 observation 中只序列化一次正文、保留完整原始 payload 和 UI refs 可重读；明确标题先走字面目录定位，语义探索才使用宽泛发现。保持 240k/16 请求共享上限，不靠放大预算掩盖重复。

F12 复查：06:15:20Z 去重版本重新测试 19，字面目录定位已生效，但三次请求后（167843）仍无法进行下一轮。初始 16 张卡片和 24 条旧证据索引在每次请求重传；卡片无原文长度，agent 先摘要又 metadata，再计划原文，放大串行阶段开销。继续修正为预置最多 4 张卡片、12 条短证据索引，并在卡片给原文字数/segment 数，让短源直接阅读，按来源合批独立定位/读取。所有未预置事实仍可通过分页工具完整获取。

F13：Sources 导航走查确认：aggregate 的 sourceID 为虚拟集合，没有 sessionUUID，仍显示“打开转录”按钮，但 CitationResolver 会直接返回；另一个不一致是工具能读取 subtitle-only/dub fallback，Controller/TranscriptView 却仅接受 session.transcript，导致这种有原文引用不能打开。随后统一修正为集合证据不可跳转，转录 UI 和工具共用同一可读材料选择；原 ASR 的 UI citation 跳转已端测到 0:02，subtitle fallback 由本地合同测试覆盖。

F14：06:26:58Z 第 7 条比较在四次请求（186106 字节式预留估计）后仍触发预算。走查确认预算把整个 AgentContentBlock JSON 的字节数作为 token，含反复重传的 opaque/encrypted reasoning；已完成请求的预留从不按实际 usage 结算。无法据此声称实际消耗了 186106 token。应传递 Responses terminal usage，以实际 input_tokens + output_tokens 结算已经完成的请求，仍为尚无 usage 的请求保守预留；单请求 ID 隔离避免 worker 相互退款/重复结算。OpenAI 明确 output_tokens 包括不可见生成量，不能另把 reasoning_tokens 再加一次。[官方计数说明](https://developers.openai.com/api/docs/guides/token-counting)、[Responses usage](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)。具体 encrypted 大小贡献尚未测量，不把它单独认定为唯一根因。

### 已实施的统一修复

- F1：目录行和 IDs 同序排序；加入 has_transcript 与 asc/desc；显式时长排序在最多四个并发内探测完整筛选集合；最长/最短及 unknown_count 属于全筛选集合。
- F2/F8/F12：紧凑目录/首轮事实，来源发现保留有界匹配 excerpt；原文/摘要正文在模型 observation 中只传一次。完整原始 observation 保留于 payload，UI refs 保留原摘录。明确标题先用字面目录定位；共享预算仍为 240k token、16 请求、180 秒；已完成请求按 provider usage 结算，无 usage 的请求保留保守估计。
- F3/F4/F11：最终 Sources 按实际引用编号选择，支持逗号和有界区间；继续按来源 ID 分组保留时间点。只移除可识别的括号 citation，保留普通数字；拒绝倒序/超大区间展开。
- F5：超长原 segment 分为稳定的原文分页，保留原时间，不推断分句时间。
- F6/F10：旧答案移除旧编号并标注未核查，历史问题标注仅供消歧；当前问题独立置于末条用户消息，每轮工具后重申。强化连续阅读、逐来源/维度覆盖、观点归因和原文证据边界。
- F7：单会话原始证据缓存上限 8 MiB，工具条目合计 16 MiB/64 项，最多 8 会话；条目不再保存整工作区的全部 refs。
- F9：knowledge_find_text 在完整可读 timed material 内扫描字面短语，支持跨 segment、分页、原时间、来源及不可读项。匹配数是命中 segment 数，不是短语出现次数。
- F13：集合证据使用文档图标且禁用转录跳转；Controller、TranscriptView 和工具共享原始 ASR / 原始字幕 / 配音 fallback 的材料选择，保留原时间和语言。
- F14：AgentStreamEvent 传递 usage，预算按独立 native request ID 结算；OpenAI output 总数不重复加 reasoning，Anthropic 累计 output 取最后值、input 包括缓存读写，兼容端 usage-only chunk 不丢弃。缺失/非法 usage 继续保留估计，重复结算不会退款其他请求。Anthropic 的 message_delta 是累计计数，见[官方流式说明](https://platform.claude.com/docs/en/build-with-claude/streaming)。

本地回归：`VOXSTUDIO_KB_REVIEW_DATASET=1 swift test --filter 'Knowledge|SessionIndex|SearchService|AgentProvider|AgentTransport|HostedAgent|OpenAIResponses|WorkbenchNavigation|MeetingRecorder'`，**189 tests / 34 suites 通过**（9.830 秒）。其中真实资料只在 opt-in 本机读取；八个目标窗口可读、媒体未知不由转录位置填补、字面 Thank you 查出 8 来源/25 命中 segment。其余包含超长 Unicode 原文、媒体探测/排序、当前问题在原生输入末端、三来源完整读取预算、缓存与引用区间；新增 provider usage 解析、worker 预留隔离，以及含较大 opaque reasoning 的六轮契约回放。

运行日志：`/tmp/voxstudio-kb-review-regression-final.log`；构建日志：`/tmp/voxstudio-kb-review-bundle.log`。日志和本机原始资料不提交仓库。模型契约回放证明结构/预算，真实回答语义另以 UI 记录判定。


### 本轮实际 UI 记录（不覆盖原 50 条结果）

使用签名 debug app，在原有长历史会话继续问答，没有清空旧消息。用户明确允许本机知识库目录、摘要、转录发送至 `api.openai.com` 的 `gpt-6-luna`。端测期间暂移除 chat 的 OpenRouter fallback，结束后恢复；本机测试的 mock provider 请求不属于实际资料传输。

| ID | 实际结果 / 时间（UTC） | 结论 |
| --- | --- | --- |
| 20 | 首次授权后完成，回答 3:39 邻域的预算、硬件和研究员流动，Source 1 | PASS，原生工具取证，无旧 planner/composer。 |
| 16 | 多次完成，46 可读来源；27 已知媒体总长、19 未知；已知最长 Origin 3605.04s、最短 MemoryCheck ASR 1.52s，明确不能断言全体极值 | PASS_CURRENT_DATA，旧 oracle 已失效。 |
| 17 | 05:58 错答上一题 → F10；06:03 正确列八来源但 Sources 2 → F11；修复后 Sources 8，46/47 可读、一来源不可读，原文短语扫描完整 | PASS（修复后）。旧错误消息仍保留，不声称追溯修复。 |
| 18 | 两 Lemon 来源给共同建议：承认挫折、选择小行动，Source 2 | PASS。 |
| 8 | 两 rugby 学生分别：grade 10 放弃；grade 9 致谢、投入训练，后进 varsity / championship。一个来源、多时间锚点 | PASS，两个例子没有合并。 |
| 19 | 06:06、06:15 预算失败 → F12；06:24:22 完成三方对比，Sources 3，4 requests，131880 旧字节式预留 | PASS（紧凑首轮/短源直接读取后）；该预留数不是实际 token。 |
| 14 | 06:24:35 后完成，47 可见 Local 来源，Cloud 0；同名但不同 ID 两条仍各自列出 | PASS_CURRENT_SCOPE，当前 signed-out Cloud 隐藏，不按旧 27 来源基线判错。 |
| 15 | 06:25 后完成，2026-09-14/15 新建/导入四来源：Origin、AI、Thank you、Infinity；写明日期依据、Thank you 原文碎片不足主题 | PASS_CURRENT_DATA，不把导入时间当录制时间。 |
| 9 | 06:26:39 完成；组织/时间管理、5–7h 屏幕、学习时间推测；不写成已证因果。Source 1 / 4 requests | PASS。 |
| 7 | 06:26:58 首次重现 F14；修复版 07:25:27–07:26:08 完成两来源比较，5 requests、Sources 2、报告 usage 47467 tokens | PASS。改前 186106 是预留估计字节，不能代表 token；解决预算误拒答。 |

| 50 | 07:26:39–07:26:45，single-source 原问法后以 evidence-boundary 问法复测，Sources 1；随后连续追问“哪些旧做法”，Sources 1 | PASS，说明转录只明确提到可能积累臃肿指令；性能、效率、成本、延迟、维护后果均未由原文证明，追问回答为大量手把手指导可能已不再需要。历史中的旧扩展答案仍保留。 |
| 44 | 07:27:44–07:28:05，逐项区分主持人评论与嘉宾自述，Source 1 | PASS，否定未经转录支持的“工程知识直接迁移”，并区分旁人觉得放弃工程可惜与嘉宾转行原因。 |
| 34 | 07:28:28–07:28:34，焦虑/财务/冲突三类，Source 1 | PASS，各维度分别回答并带 0:45 原文锚点。 |
| 24 | 07:28:48–07:29:06，Claude Opus 4.5 / Gemini 3，Source 1、Speaker 3 · 4:01 | PASS，模型名称与热度观点按 transcript 区分，不声称性能排名。 |

其他 UI 回归：Sources 按 source ID 分组；三来源对比显示 3 个 Sources，修复版第 7 条显示 2 个 Sources，未复现截图里的同一来源重复卡片。字幕原文 citation 点击后进入对应 transcript 并显示 0:02 片段。

资源复测：第 7 条活跃期间一次 RSS 采样约 4.41 GiB、147% CPU（请求进行中，33 秒）；问答完成后约两分钟样本 RSS 约 1.93 GiB、CPU 0%；连续其余问答及索引负载后，Local Search 在 07:30:26 完成 idle-unload（MLX active 0MB），随后 RSS 约 1.0 GiB、CPU 0%。idle-unload 前瞬时峰值不可省略，但在该样本窗口内未持续攀升，也未出现未响应 UI；这是一轮有限端测，不能推出所有长时间工作负载均无泄漏。

结束设置：仅 AI editing chat 暂移除的 `openrouter/google/gemini-2.5-flash-lite` fallback 已通过 UI 恢复原值；UI 显示当前 Knowledge 范围回到 All knowledge。真实资料端测只走 OpenAI `api.openai.com`。

签名 debug 构建通过，codesign 验证 valid on disk / satisfies its Designated Requirement；189 tests / 34 suites 通过。UI 真实端测覆盖上述代表案例，并非将全部 50 条标为通过。Cloud 41/42 仍是 BLOCKED_SCOPE；本机缺失原媒体的全局媒体时长仍未知。
