# Mac Knowledge Base QA：50 条 Computer Use 端测报告

日期：2026-09-16  
被测应用：VoxStudio macOS Knowledge 页面  
参考设计：[mac-kb-qa-skills-planner.md](../design/mac-kb-qa-skills-planner.md)  
测试方式：Computer Use 操作可见 UI，同时观察应用日志中的 Knowledge QA 阶段和网络/LLM 错误。

## 1. 测试目标与范围

本轮从 Knowledge 页面可见的 27 个可问答 session 及其 transcript 设计 50 条问题：

- `all knowledge`：跨全部可见、已索引 session 的问题（1–20）。
- 单 session：问题明确绑定对应 session（21–50）。
- 每条问题均给出预期取证路径；医学相关问题要求只引用 transcript，并在回答中保留安全边界，不把 transcript 当作医学事实或治疗建议。
- 用户指出的截图问题单独回归：截图 1 显示已登录且 BYOK 已开启，因此“不需要登录/开启 BYOK”不是该状态下的事实。

## 2. 预期回答路径与判定口径

### 2.1 普通事实问答路径

```text
Understanding
  → query planner / query understanding
  → Searching（限定 scope 与 source origin）
  → search-complete（命中证据）
  → citations
  → Composing
  → Showing answer（答案 + 引用）
```

跨 session 总结、对比、库存、metadata、时间线类问题，在完整 Skills/Tools 设计中还应分别路由到 `session.list`、`get_metadata`、`compare_sessions`、`get_timeline` 等专用工具。当前 P0 实现仍以单次 RAG 为主，因此这类问题的“预期路径”记录为应有意图，而非声称已经具备完整 tool-loop。

### 2.2 结果代码

| 代码 | 含义 |
|---|---|
| `P0-BUSY` | 修复前在受控观察窗口内仍停留 busy/Understanding，随后为继续测试主动 Stop；这 40 条没有得到实际回答，因此只能记录为“未观察到结果”，不能判为通过或失败。日志中的 `-999` 是取消后的网络请求，不作为独立产品错误。 |
| `P1-HAPPY` | UI 有非空回答和 citation，日志走到 `showing-answer`。 |
| `P2-FALLBACK` | 检索有证据但上游回答模型失败/超时；应用返回非空、事实边界正确的 transcript 摘录 fallback。 |
| `P2-NO-EVIDENCE` | 请求正常结束，但该 scope 没有足够命中；应用返回 localized、非空的“不足证据”提示，不把它解释成账户不可用。 |
| `P3-GRAPH-FIXED` | graph query 没有显式实体时按“无 graph 命中”处理，不再记录 invalid structured result。 |
| `P4-OBS-BUSY` | 修复后在 18 秒观察点仍 busy，未得到足够证据判定为最终失败；该条需在稳定网络/模型下补测。 |

## 3. 已实施修复

1. planner 从普通 `.chat` 路径改为专用 `.graphQueryUnderstanding`，并保留 fallback；planner 不再无限等待。
2. 回答模型增加 30 秒超时边界。模型失败或超时仍有命中证据时，返回：
   - 中文：`我找到了相关的转录片段，但回答模型在时限内没有返回可用答案。下面列出最接近的证据摘录：`
   - 英文：`I found related transcript excerpts, but the answer model did not return a usable answer within the time limit. Here are the closest evidence excerpts:`
3. 去除 graph recall 对空实体列表的错误判定；空实体是合法的“没有 graph 起始实体”情况。
4. 增加 `understanding`、`searching`、`search-complete`、`composing`、`showing-answer` 和 answer-fallback 阶段日志。
5. 按仓库要求重新签名构建并重启：

```sh
./scripts/bundle.sh debug --sign
open "$PWD/.build/VoxStudio.app"
```

## 4. 50 条问题设计、范围、预期路径与结果

结果中的“修复前”表示该条在发现截图问题前执行；“修复后”表示 planner/fallback 修复后执行。`completed-or-fallback` 只说明 UI 正常结束或给出有证据 fallback，不等同于所有语义答案已经人工判定正确。

| ID | 范围 | 问题 | 预期回答路径（简要） | 端测结果 / 日志观察 |
|---:|---|---|---|---|
| 1 | all knowledge | DeepSeek R1 在 AI State of the Art & Future 中被描述成什么样的事件？ | `knowledge.search`；AI session 1:31–2:53；引用时间锚点。 | `P0-BUSY` 修复前；planner 未及时完成，Stop 后出现取消日志。 |
| 2 | all knowledge | AI State of the Art & Future 中，为什么受访者认为不会出现一家公司的技术完全独占？ | 搜索 AI 2:53–3:59；提取研究人员流动、无独占技术。 | `P0-BUSY` 修复前；未进入稳定检索/作答。 |
| 3 | all knowledge | AI State of the Art & Future 中，预算和硬件如何成为 AI 竞争差异？ | 搜索 AI 3:39–3:59；回答预算/硬件约束并引用。 | `P0-BUSY` 修复前；观察到 busy，Stop 后为 `-999` 取消。 |
| 4 | all knowledge | Origin of Writing 中，最早可称为文字的现有证据追溯到何时何地？ | 搜索 Origin 0:48–1:35；返回约公元前 3500 年、两河流域位置。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 5 | all knowledge | Origin of Writing 中，图画符号如何逐渐能够记录语言和声音？ | 搜索 1:35–3:58；图画符号→声音符号→语言/语法/文学。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 6 | all knowledge | Origin of Writing 中，为什么早期文字系统需要词典编纂和标准化？ | 搜索 4:44–6:17；解释词汇、读法与系统标准化。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 7 | all knowledge | High School Athletics & Activities Overview 和 SAS Student Development and Parent Resources 对学生成长的共同关注点是什么？ | 跨 session 检索/比较；提取成长、习惯、品格、社区。 | `P0-BUSY` 修复前；比较问题未到可验证回答阶段。 |
| 8 | all knowledge | High School Athletics & Activities Overview 中，两个未进入 varsity rugby 的学生后来分别如何回应？ | 搜索 High School 0:09–1:42；分别提取两个 rugby 例子。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 9 | all knowledge | SAS Student Development and Parent Resources 中，学校如何解释学业困难与屏幕时间的关系？ | 搜索 SAS 0:00–1:35；区分观察到的屏幕时长与因果结论。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 10 | all knowledge | SAS Student Development and Parent Resources 中，为什么家长活动或 book club 不只是传递内容？ | 搜索 SAS 2:46–5:40；提取面对面讨论/社区价值。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 11 | all knowledge | all knowledge 中有哪些 session 讨论 AI、coding agents 或 skills？请按主题列出来源。 | `session.list`/库存 + semantic search；按 AI、coding agent、skills 聚类并列 session。 | `P0-BUSY` 修复前；库存/分类路径未被真正调用。 |
| 12 | all knowledge | all knowledge 中哪些 session 涉及学校活动、学生发展或家长资源？ | `session.list` + metadata/summary；筛选 High School、SAS 等标题。 | `P0-BUSY` 修复后前的批量观察仍 busy；未作语义正确性判定。 |
| 13 | all knowledge | all knowledge 中有哪些 session 涉及颈椎、骨盆或手法治疗？请区分 Local/Cloud。 | `session.list` + origin metadata；按身体主题和 origin 分组。 | `P0-BUSY` 修复前；未稳定返回库存结果。 |
| 14 | all knowledge | all knowledge 中哪些 session 来自 Cloud，哪些来自 Local？ | `session.list`/metadata；读取 source origin，不从标题推断。 | `P0-BUSY` 修复前；未稳定返回库存结果。 |
| 15 | all knowledge | 最近的 Sep 14–15 sessions 分别讨论了什么主题？ | `session.recent` + `get_summary`；按日期列标题与主题。 | `P0-BUSY` 修复前；未到可验证的 recent/summary 路径。 |
| 16 | all knowledge | 可问答 session 中最长和最短的分别是哪条？请给出标题和时长。 | `session.list` + metadata；比较 duration，并注明可问答过滤条件。 | `P0-BUSY` 修复前；未完成 metadata 比较。 |
| 17 | all knowledge | all knowledge 中出现 “Thank you” 的转录片段来自哪些 session？ | `knowledge.search`；保留命中 session 标题和时间。 | `P0-BUSY` 修复前；未完成稳定检索。 |
| 18 | all knowledge | When Life Gives You Lemons 和 Make Your Own Lemonade 的共同建议是什么？ | 跨 session search/compare；抽取共同建议并区分各自证据。 | `P0-BUSY` 修复前；比较路径未稳定完成。 |
| 19 | all knowledge | Avoid Overloading Projects with Skills、Skill Files for Workflow Guidance、Rethinking Skills for Coding Agents 三条 session 的核心主题如何对比？ | 三 session compare；分别总结后给共同点/差异。 | `P0-BUSY` 修复前；未完成稳定回答。 |
| 20 | all knowledge | AI State of the Art & Future 在 3:39 左右讲了什么？请返回时间锚点。 | `get_timeline`/`search_segments`；定位 3:39 邻近片段并引用。 | `P0-BUSY` 修复前；未稳定完成 timeline 取证。 |
| 21 | Infinity, Mathematics, and Reality | 为什么 Galileo 认为自然数与完全平方数的一一对应令人困惑？ | `session.search_segments`；定位 5:09–6:42；解释一一对应的反直觉性。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 22 | Infinity, Mathematics, and Reality | Cantor-Hume principle 如何定义两个集合大小相同？ | 单 session 搜索 7:29–8:15；给出一一对应定义。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 23 | AI State of the Art & Future | Sebastian 如何解释 DeepSeek 在开放权重模型用户中的吸引力？ | 单 session 搜索 2:53–3:39；引用开放权重/可用性语境。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 24 | AI State of the Art & Future | Nathan 如何比较 Anthropic 的代码文化与 Gemini 3 的市场关注度？ | 单 session 搜索 3:59–5:29；分别提取代码文化和市场关注。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 25 | Origin of Writing | “cuneiform” 这个名字的含义是什么，19 世纪在哪里重新发现？ | 单 session 搜索 7:05–7:50；返回 wedge-shaped 与 Iraq 发掘语境。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 26 | Origin of Writing | 楔形文字为何能长期存在，又为什么最终被字母系统取代？ | 搜索 3:58–5:30、6:17–7:50；分两段证据作答，不补写 transcript 未说内容。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 27 | High School Athletics & Activities Overview | Eagle Way 的五项核心价值是什么？ | 单 session 搜索 5:39–6:26；列五项并附 citation。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 28 | High School Athletics & Activities Overview | 高中体育团队如何选拔，学生如何获得赛季/注册信息？ | 单 session 搜索 3:53–4:39；提取 tryout、团队和注册信息。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 29 | SAS Student Development and Parent Resources | 这场 transcript 中学校所说的 “good” 包含哪些目标？ | 单 session 搜索 0:46–1:35；whole child、习惯、心理健康等。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 30 | SAS Student Development and Parent Resources | 为什么发言人强调每个孩子要走自己的 pathway，而不是和同伴比较？ | 单 session 搜索 1:35–2:33；解释个体路径，避免外推成学校政策。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 31 | MAGA Pressure on Republicans | transcript 如何解释没有 Trump 在 ballot 上时的 turnout problem？ | 单 session 搜索 0:00–1:04；明确标注为 transcript 观点，不验证政治事实。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 32 | MAGA Pressure on Republicans | 发言人提出了哪些关于 filibuster、redistricting 和 2026 的行动主张？ | 搜索 2:00–3:19、4:17–5:00；按“发言人主张”归因并保留不确定性。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 33 | When Life Gives You Lemons… | “make lemonade” 的核心不是假装没事，而是什么？ | 单 session 搜索 0:00–0:45；提取承认挫折、选择下一步。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 34 | When Life Gives You Lemons… | transcript 给出的应对焦虑、财务压力和冲突的具体小行动有哪些？ | 单 session 搜索 0:45–1:44；按焦虑/财务/冲突分组，保留原意。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 35 | 调整骨盆错位动作 | transcript 描述了哪些动作/步骤？只摘录原话并附时间。 | 单 session `search_segments`；只返回 timed evidence；医学安全提示。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 36 | 调整骨盆错位动作 | transcript 提到哪些居家应用注意事项或限制？只根据证据回答。 | 单 session search；只引用证据，不能把操作变成诊疗建议。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 37 | 颈椎错位与枕头调整 | transcript 如何把颈椎问题与枕头调整联系起来？ | 单 session search；提取关系和 speaker/time citation。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 38 | 颈椎错位与枕头调整 | transcript 中有哪些居家操作步骤或注意事项？只摘录并带时间。 | 单 session search；原话摘录 + 时间，附医学边界。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 39 | 颈椎调理与居家手法学习感受 | 说话者描述了哪些学习/体验结果？ | 单 session search；总结体验结果并附证据。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 40 | 颈椎调理与居家手法学习感受 | transcript 如何区分专业调理与居家手法？ | 单 session search；分别抽取两者描述，不自行补充医疗结论。 | `P0-BUSY` 修复前；受控观察时 busy。 |
| 41 | 手法治疗与居家应用体验（Cloud） | 这场 Cloud session 主要记录了什么体验？只用该 session 证据。 | session scope + Cloud visibility filter + `search_segments`/summary。 | 修复后 `completed-or-fallback`；观察到 query planner/search 路径，UI 正常结束或有证据 fallback。 |
| 42 | 手法治疗与居家应用体验（Cloud） | Cloud session 中明确提到哪些居家应用步骤？请保留不确定性。 | session scope + Cloud filter；只返回 timed evidence，保留不确定性。 | 延长观察后 `P2-NO-EVIDENCE`：UI 返回“这个 session 中没有找到足够的证据”，非空且没有错误地提示登录/BYOK；本次没有可供引用的步骤。 |
| 43 | 土木工程师转中医师的人生转折 | 说话者叙述了哪些人生转折和动机？ | 单 session search；按时间顺序抽取转折/动机。 | 修复后 `completed-or-fallback`；planner/search/answer-fallback 或完成路径可见。 |
| 44 | 土木工程师转中医师的人生转折 | 工程背景被描述为如何影响后来的中医道路？ | 单 session search；只根据 transcript 解释影响关系。 | 修复后 `completed-or-fallback`；无空答案。 |
| 45 | Avoid Overloading Projects with Skills | 为什么把太多 skills 放进 project 会降低模型选 skill 的能力？ | 单 session 搜索 0:02–0:47；解释上下文膨胀、描述变短、区分能力下降。 | 首次修复后观察为 busy；第二次修复后回归 `P1-HAPPY`：UI 给出准确解释并引用 `0:02`，日志 `search-complete hits=1`、`showing-answer`。 |
| 46 | Avoid Overloading Projects with Skills | transcript 隐含的 skill package 选择原则是什么？ | 单 session search；从 transcript 归纳选择原则并标注为归纳。 | 修复后 `completed-or-fallback`；未见空答案。 |
| 47 | Skill Files for Workflow Guidance | skill file 是什么格式、通常承载什么？ | 单 session 搜索 0:01–0:37；Markdown、scripts、workflow/task guidance。 | 修复后 `completed-or-fallback`；未见空答案。 |
| 48 | Skill Files for Workflow Guidance | skill file 与 plugin/task-specific instructions 的关系是什么？ | 单 session search；区分文件格式、插件绑定和任务范围。 | 延长观察后 `P1-HAPPY`（约 15 秒）：回答说明 skill file 可承载 plugin/task-specific workflow 指令，并带 `0:01` citation。 |
| 49 | Rethinking Skills for Coding Agents | transcript 认为 coding-agent 的 best practices 发生了什么变化？ | 单 session 搜索 0:02–0:30；总结实践变化。 | 修复后 `completed-or-fallback`；未见空答案。 |
| 50 | Rethinking Skills for Coding Agents | accumulated bloated instructions 会造成什么问题？ | 单 session search；提取 instructions 累积/膨胀导致的影响。 | 延长观察后 UI 完成并有 `0:02` citation；但答案加入了 transcript 未明确支持的“性能、效率、延迟和成本”影响，记录为 grounding overreach，不能判为无条件通过。 |

### 4.1 P0-BUSY 条目的预期回答结果（测试 oracle）

下面是根据 transcript 内容和问题设计得到的“应该回答什么”。它们不是 app 当时返回的答案；`P0-BUSY` 的事实是这些 oracle 在修复前没有被 UI 观察到。

#### all knowledge：1–10

| ID | 预期回答结果 |
|---:|---|
| 1 | 应说明 DeepSeek R1 在 2025 年 1 月发布，是中国团队的开放权重模型，接近当时 SOTA，但成本/计算资源更低；引用 AI session 约 1:31–2:53。 |
| 2 | 应说明受访者认为研究人员会流动、技术不会被单一公司永久独占，因此不会自然形成 winner-takes-all；引用约 2:53–3:59，并标明这是 transcript 观点。 |
| 3 | 应说明预算和硬件资源会决定训练/部署能力，从而形成竞争差异；引用约 3:39–3:59，不扩展成外部市场结论。 |
| 4 | 应返回最早文字证据约公元前 3500 年，地点在幼发拉底河与底格里斯河之间的两河流域；引用 Origin 约 0:48–1:35。 |
| 5 | 应按演变链回答：图画符号 → 表示声音的符号 → 能表达语言、语法和文学；引用约 1:35–3:58。 |
| 6 | 应说明随着符号和读法增多，需要词典编纂、词汇整理和标准化来维持可读性/一致性；引用约 4:44–6:17。 |
| 7 | 应比较两个 session 的共同点：不只看单一成绩，而是关注 whole child、习惯、品格/价值观、社区参与和每个人的成长路径；分别标注两个来源。 |
| 8 | 应分别叙述两名 rugby tryout 学生未进入 varsity 后的回应/后续选择，不能把两个例子合并或补造人物信息；引用 High School 约 0:09–1:42。 |
| 9 | 应区分学校观察到的组织/时间管理困难与每天约 5–7 小时屏幕使用，不应把 transcript 说成已证明屏幕时间造成学业困难；引用 SAS 约 0:00–1:35。 |
| 10 | 应说明 parent coffee/book club 的价值还包括面对面讨论、关系和社区经验，而不只是把一份内容传递给家长；引用 SAS 约 2:46–5:20。 |

#### all knowledge：11–20

| ID | 预期回答结果 |
|---:|---|
| 11 | 应列出讨论 AI、coding agents 或 skills 的来源，至少包括 AI State of the Art & Future、OpenRouter GLM subtitle experiment、Avoid Overloading Projects with Skills、Skill Files for Workflow Guidance、Rethinking Skills for Coding Agents，并按主题分组。 |
| 12 | 应返回涉及学校活动/学生发展/家长资源的 High School Athletics & Activities Overview 和 SAS Student Development and Parent Resources。 |
| 13 | 应返回颈椎、骨盆或手法治疗相关 session，并按 origin 标注：调整骨盆错位动作（Local）、颈椎错位与枕头调整（Local）、颈椎调理与居家手法学习感受（Local）、手法治疗与居家应用体验（Cloud）；只列有证据的标题。 |
| 14 | 应根据 metadata 而非标题回答：`手法治疗与居家应用体验` 是 Cloud；其余本轮可见的 26 个可问答 session 是 Local。 |
| 15 | 应按日期返回：Sep 15 的 Infinity, Mathematics, and Reality、调整骨盆错位动作、Thank you；Sep 14 的 AI State of the Art & Future、Origin of Writing，并各给一句 transcript 主题。 |
| 16 | 应在“可问答且有 transcript”的集合内比较 metadata：最长为 Infinity, Mathematics, and Reality（约 3h52m），最短为 Test（约 0:10）；给出标题和时长。 |
| 17 | 应返回命中 “Thank you” 的 session 标题、片段和时间锚点；不能仅因为 session 标题叫 Thank you 就声称所有命中都来自该 session。 |
| 18 | 应概括两个 Lemon session 的共同建议：承认挫折、保持希望并选择下一步可执行行动；同时保留各自 session 的独立证据。 |
| 19 | 应形成三方对比：Avoid Overloading 讲上下文膨胀导致 skill 选择变差；Skill Files 讲 Markdown/workflow/plugin/task 指令；Rethinking 讲 coding-agent 实践变化及精简累积指令。 |
| 20 | 应返回 AI session 约 3:39 的时间锚点，内容是预算和硬件如何形成 AI 竞争差异；不能把邻近段落改写成完整行业预测。 |

#### 单 session：21–30

| ID | 预期回答结果 |
|---:|---|
| 21 | 应说明 Galileo 的困惑：自然数与完全平方数可以建立一一对应，虽然平方数看起来只是自然数的一部分，却因此显示相同的“大小”；引用 5:09–6:42。 |
| 22 | 应说明 Cantor–Hume principle：两个集合大小相同，当且仅当它们之间存在一一对应；引用 7:29–8:15。 |
| 23 | 应说明 Sebastian 将 DeepSeek 对开放权重用户的吸引力归因于开放可用、研究者可接触和较低资源门槛；引用 2:53–3:39。 |
| 24 | 应分别比较 Anthropic 的代码文化/重视人类努力与 Gemini 3 获得市场注意的现象；必须归因给 Nathan/transcript，不加入外部排名。 |
| 25 | 应说明 cuneiform 意为 wedge-shaped，并说明 19 世纪在 Iraq 的发掘中重新被认识；引用 7:05–7:50。 |
| 26 | 应把“长期存在”的原因与“后来被字母系统取代”分开回答，只使用 transcript 明确给出的耐久、词典/标准化和字母系统语境，不臆造完整历史因果。 |
| 27 | 应准确列出五项 Eagle Way 核心价值：compassion、fairness、honesty、respect、responsibility；引用 5:39–6:26。 |
| 28 | 应说明体育团队通过 tryout/选拔确定队伍，学生从学校提供的赛季信息/注册渠道获得安排；引用 3:53–4:39。 |
| 29 | 应说明 transcript 中的 “good” 包含 whole-child 成长、良好习惯、心理健康和帮助孩子形成自己的发展路径；引用 0:46–1:35。 |
| 30 | 应说明每个孩子有自己的 pathway，发展节奏和需要不同，因此不应以同伴作为唯一比较标准；引用 1:35–2:33。 |

#### 单 session：31–40

| ID | 预期回答结果 |
|---:|---|
| 31 | 应以 transcript 归因的方式说明：发言人把没有 Trump 出现在 ballot 上与 MAGA/共和党 turnout problem 联系起来；不得把观点写成已验证的政治事实。 |
| 32 | 应按 transcript 列出关于 filibuster、redistricting 和 2026 的行动主张，并逐项标明“发言人提出/讨论”，不替其背书。 |
| 33 | 应说明 “make lemonade” 不是假装没有挫折，而是承认发生了什么，然后选择下一步行动；引用 0:00–0:45。 |
| 34 | 应按主题列出 transcript 中的小行动：对焦虑保持耐心并采取行动/希望，借助自然和他人；面对财务压力削减开支；冲突中暂时离开；引用 0:45–1:44。 |
| 35 | 应只返回“调整骨盆错位动作”中实际说出的动作/步骤及时间，缺少证据的步骤应明确说没有找到；不能生成医学操作。 |
| 36 | 应只返回该 session 明确说出的居家应用注意事项/限制及时间，并加“这是 transcript 摘录，不是医学建议”的边界。 |
| 37 | 应只说明该 session 如何把颈椎问题与枕头调整联系起来，并附 speaker/time citation；不得用外部医学知识补因果。 |
| 38 | 应只摘录“颈椎错位与枕头调整”中明确出现的居家步骤/注意事项和时间；没有证据就返回 localized no-evidence。 |
| 39 | 应总结“颈椎调理与居家手法学习感受”中说话者描述的学习过程和体验结果，并引用原 session。 |
| 40 | 应区分 transcript 中对专业调理和居家手法的描述，使用该 session 的原话/时间，不自行给出诊断或疗效结论。 |

### 4.2 P0-BUSY 根因分析

结论是：这 40 条当时确实没有得到预期回答结果；但不能把它们都记成“答案错误”。第一坏阶段是回答前的 query planner/LLM 请求没有在测试观察窗口内收敛，随后测试脚本为了继续下一批主动 Stop。

| 证据 | 分析结论 |
|---|---|
| 修复前 UI 长时间停在 `Understanding question…`，没有进入 `Searching knowledge…`、`search-complete` 或 `showing-answer` | 故障/等待点在检索前的 planner，而不是已完成检索后答案内容错误。 |
| 修复前 planner 使用 `.chat` route；该 route 默认 `timeoutSeconds=60`、每个模型最多 2 次尝试 | 单条问题最坏会等待约两个 60 秒请求再加退避；在 18 秒端测窗口中必然大量显示 busy。并发提交多条问题还会让同一 provider 同时处理多个 planner 请求。 |
| 延迟样本出现约 24.753 秒、11,419 bytes 的 HTTP 200，但 UI 当时仍没有及时展示最终答案 | provider 的“请求成功”与 app 的“完整 pipeline 收敛并展示 finished”不是同一件事；在 planner/后续阶段缺乏 bounded state transition 时，用户仍看到等待。 |
| 主动点击 Stop 后出现 CFNetwork `-999` | `-999` 是取消当前 URLSession task 的结果，是端测停止动作的后果；它不能证明 provider 原本会返回错误，也不能证明 transcript 没有证据。 |
| 修复后 planner 改为 `.graphQueryUnderstanding`，策略为 15 秒、1 次尝试；即使失败也回退原问题继续检索 | 修复样本出现 planner timeout 后仍能进入 `searching`/`search-complete`，证明之前的主要阻塞点确实是 planner 等待策略，而非必须依赖 planner 才能检索。 |
| 修复后答案阶段增加 30 秒 timeout；一次样本在答案模型异常后出现 `answer-fallback` 并展示非空摘录，另一次 ID 45 在 HTTP 200 后到 `showing-answer` | 后续答案模型慢/TLS 失败是独立的上游风险；bounded fallback 解决了“永远 busy/空答案/错误账户文案”，但不能把上游延迟变成稳定低延迟。 |
| graph recall 的 invalid structured result 在第二次修复后消失 | 这是另一个 graph 空实体处理问题，不是 1–40 停在 Understanding 的主根因；它发生在检索并行阶段，已单独修复。 |

因此，原报告缺少的两点已经补齐：一是 1–40 的预期答案 oracle，二是“首个失败阶段 + 证据 + 修复验证”的根因分析。后续补测应把 `P0-BUSY` 改成明确的 `NOT_OBSERVED`，并区分“未观察到结果”“no evidence”“fallback”“grounding error”。

## 5. 日志与 UI 证据

### 5.1 修复前观察

- 1–40 条均完成了 Computer Use 提交并在受控观察点记录；多数仍停在 busy/Understanding，主动 Stop 后产生 `CFNetwork` 的 `-999` 取消记录。
- 对 DeepSeek 问题做过延迟观察，日志显示一次约 24.753 秒、HTTP 200 的慢请求，但当时 UI 没有及时展示最终答案，说明“请求成功”并不等于“UI 已完成收敛”。
- 修复前的长 planner 路径可能在约 60 秒级别等待，和截图中“已找到相关片段但模型不可用”的错误事实一起暴露了状态/错误文案问题。

### 5.2 修复后阶段日志

修复后样本中观察到以下顺序（字段中的 scope 与实际 UI 选择一致）：

```text
knowledge qa stage=understanding scope=session
knowledge qa stage=searching scope=session
knowledge qa stage=search-complete scope=session hits=1
knowledge qa stage=composing scope=session citations=1
... chat HTTP 200 ...
knowledge qa stage=showing-answer scope=session chars=133
```

在一次完整的 Eagle Way 回归中还观察到：graph query understanding 主请求约 15.105 秒超时，fallback 约 9.922 秒恢复，随后仍完成 planner、search、citations；回答模型没有在 30 秒边界内返回时，UI 展示非空证据摘录，而不是空白或错误的 BYOK/登录提示。

第二次修复后，`KnowledgeGraphRecallService` 的空实体分支直接返回空 graph hits；最终 ID 45 回归日志未再出现：

```text
knowledge graph recall unavailable: The graph model returned an invalid structured result.
```

这项观察支持 `P3-GRAPH-FIXED`。

本次延长观察还验证了三个边界：Cloud 单 session 的 ID 42 能结束为非空 no-evidence；ID 48 能在约 15 秒后完成并带 citation；ID 50 能完成但暴露了回答模型可能把 transcript 中“冗长/膨胀、需要精简”扩展成未明确出现的性能/成本后果。后者是需要后续加强 evidence gate 或 claim-level grounding 的产品问题。

### 5.3 截图问题回归结论

截图 1 的状态是已登录、BYOK 开关开启且已选择保存的 key。截图 2 的文案“sign in for hosted AI, or enable BYOK in Settings”因此不是该状态下的事实。

修复后的 fallback 文案只陈述可观测事实：“回答模型在时限内没有返回可用答案”，并继续展示最接近的 transcript 证据；不再暗示用户未登录或未开启 BYOK。需要注意，旧的错误文案仍可能存在于 app 持久化的旧聊天历史中；这不是新代码再次生成的结果。新的 ID 45 回归已经显示正确答案和 citation。

## 6. 汇总结果

| 阶段 | 条数 | 结论 |
|---|---:|---|
| 修复前 1–40 | 40 | 全部有端测提交记录；在受控窗口多数 `P0-BUSY`，不能作为最终语义正确性通过。 |
| 修复后首次 41–50 | 10 | 初次观察为 6 条 `completed-or-fallback`，4 条在 18 秒观察点仍 busy；随后对 42、48、50 做延长且校正 scope 的补测。 |
| 修复后补测 42、48、50 | 3 | 42=`P2-NO-EVIDENCE`，48=`P1-HAPPY`，50=完成但有 grounding overreach。 |
| 第二次修复后重点回归 ID 45 | 1 | `P1-HAPPY`；非空中文答案、1 个 citation、日志到 `showing-answer`。 |
| 单元测试 | 32 | `KnowledgeQATests`：32 tests / 9 suites 全部通过。 |
| 构建 | 2 次 | 两次 `bundle.sh debug --sign` 均成功；仅有仓库既有编译/链接 warning。 |

## 7. 问题观察与剩余风险

1. 上游 provider/网络仍可能出现 TLS 错误（例如 `-1200`）或模型超时（例如 `-1001`）。当前代码会在有检索证据时给出 bounded fallback，避免空答案和错误的账户状态解释；但 fallback 不是完整 LLM 总结。
2. ID 50 的回答超出了当前 evidence snippet 的明确内容，说明“只使用 transcript”提示尚不足以阻止模型做常识性扩展；后续应增加 claim-level evidence gate 或要求逐句绑定 citation。
3. 设计稿要求的 inventory、metadata、compare、timeline 专用 skills/tools 尚未全部落地；本报告中的 11–20 条因此同时作为后续 P0/P1 路由能力的验收样例。
4. 旧历史消息不会自动重写。若需要清理旧错误文案，应另行设计迁移/删除策略，不能把清理历史和本次运行时修复混为一谈。

## 8. 后续建议

- 在稳定网络下重跑 42、48、50，并把最终 UI 文本、citation 数量和完整阶段日志补录到本报告。
- 按设计稿为 11–20 增加 session inventory、metadata、compare、recent、timeline tool route，再补测这些问题；当前单次 RAG 只能证明相关证据召回，不能证明完整集合运算或比较结果。
- 保留当前阶段日志和 truthful fallback 作为所有后续 Knowledge QA 端测的必检项。
