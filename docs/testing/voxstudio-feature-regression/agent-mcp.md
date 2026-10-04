# 生成、Agent与MCP回归测试集

[测试计划](test-plan.md) · [功能地图](../../design/voxstudio-feature-map.md)

共同前置、fixture定义、权限准备、状态和证据标准见测试计划。以下均为已设计未执行；每个case需逐项填写实际结果。标记L/P/H/B/X/C含义见功能地图。

<a id="g01"></a>

## G01 内置AI编辑助手

范围：聊天、context、工具变更、恢复和取消。前置标记：B。定位：`Sources/VoxstudioPro/Agent/Panel`、`Sources/VoxstudioPro/Agent/Tools/ToolDefinitions.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G01-C01 | 正常/P0 | 在一次性项目让助手读取timeline并描述当前片段 | 描述符合真实工程；上下文属于活动timeline |
| G01-C02 | 编辑/P1 | 要求把指定测试片段移到明确时间，再核对UI/Undo | 实际tool修改正确目标；Undo能恢复 |
| G01-C03 | context/P1 | 切换项目/session后问当前source范围 | 不会把上一工程当作当前工程；引用对象准确 |
| G01-C04 | 失败/P1 | 无效provider/断网及tool参数错误 | 显示可恢复错误；不会用成功口吻掩盖未执行 |
| G01-C05 | 取消/P1 | 运行中Stop，随后用另一个简单请求 | 停止不重复执行变更；新请求可完成且不串结果 |

<a id="g02"></a>

## G02 AI图像生成

范围：模型/参考图/参数、任务与导入输出。前置标记：X。定位：`Sources/VoxstudioPro/Generation/Submission/ImageGenerationSubmission.swift`、`Sources/VoxstudioPro/Generation/UI/GenerationView.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G02-C01 | 正常/P0 | 在已授权测试预算内选择可用图像模型生成一张测试图 | 输出图片可解码；task/library记录对应 |
| G02-C02 | 参考/P1 | 用自有参考图和明确编辑prompt生成变体 | 参考被绑定到正确任务；结果尺寸/类型可核对 |
| G02-C03 | 配置/P1 | 切换允许的尺寸/数量/模型并查看成本预估 | 选项随模型规范化；提交使用实际所选参数 |
| G02-C04 | 边界/P1 | 空prompt、非法参考/数量、模型不支持参数时尝试提交 | 客户端校验/服务错误可理解；不提交隐式默认错误请求 |
| G02-C05 | 失败/P1 | 取消或受控provider错误后重试短请求 | 终态明确；无重复扣任务/错误覆盖已有素材 |

<a id="g03"></a>

## G03 AI视频生成

范围：text/image/reference、时长/比例、任务。前置标记：X。定位：`Sources/VoxstudioPro/Generation/Submission/VideoGenerationSubmission.swift`、`Sources/VoxstudioPro/Generation/Preprocessing/VideoPreprocessor.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G03-C01 | 正常/P0 | 授权预算内提交最短支持时长的视频测试prompt | 输出可播放有帧；duration/比例与参数一致 |
| G03-C02 | 首帧/P1 | 用自有图片Set as first frame再生成 | 任务引用首帧正确；输出可导入timeline |
| G03-C03 | 参考/P1 | 使用模型支持的reference素材/片段范围 | 预处理范围和source对应；不传错整段媒体 |
| G03-C04 | 边界/P1 | 切换模型后选择不支持的时长/比例/参考数量 | 校验或参数规范化可见；不会静默错用旧模型选项 |
| G03-C05 | 恢复/P1 | 任务延迟/失败/取消后重开并查询状态 | 可追踪task终态；成功结果不丢失，失败可恢复 |

<a id="g04"></a>

## G04 AI音频生成

范围：音频model/catalog、素材引用和输出。前置标记：X。定位：`Sources/VoxstudioPro/Generation/Submission/AudioGenerationSubmission.swift`、`Sources/VoxstudioPro/Generation/Catalog/AudioModelConfig.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G04-C01 | 正常/P0 | 授权预算内使用最短可用音频生成请求 | 输出有可播放音频；任务参数与素材记录一致 |
| G04-C02 | 配置/P1 | 切换支持的语言/时长/参考选项 | UI选项与所选模型匹配；实际参数可核对 |
| G04-C03 | timeline/P1 | 将成功输出加入测试timeline再导出 | source/path正确；音频长度与定位一致 |
| G04-C04 | 异常/P1 | 空prompt、不支持reference或损坏音频引用 | 阻止/清楚报错；不会创建假Ready素材 |
| G04-C05 | 恢复/P1 | provider错误/取消后重试并查看历史 | 旧task终态保留；重试不冒充旧结果 |

<a id="g05"></a>

## G05 AI媒体编辑与变换

范围：Upscale/Edit/Lip Sync/Reframe/音频变换/音乐SFX。前置标记：X。定位：`Sources/VoxstudioPro/Generation/Edit/AIEditMenu.swift`、`Sources/VoxstudioPro/Generation/Edit/EditSubmitter.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G05-C01 | 图像/P1 | 在模型支持时对自有图分别Edit及Upscale，分开留证 | 输出关联原图；所选动作/尺寸真实生效 |
| G05-C02 | 口型/P1 | 授权预算内用自有测试视频+语音执行Lip Sync | 结果可播；匹配正确视频和音频，不错源 |
| G05-C03 | 构图/P1 | 执行Reframe到支持比例，导入结果 | 比例/构图与请求一致；原素材保留 |
| G05-C04 | 音频/P1 | 分别执行Audio cleanup及dubbing可用菜单 | 两种动作各有输出/终态；不混淆本地增强与remote cleanup |
| G05-C05 | 配乐/P1 | 对短视频分别Generate Music及Generate SFX | 输出类型/长度/原video关联准确；分开记录 |
| G05-C06 | 门控/P0 | 对不支持类型/无能力模型打开AI Edit及取消提交 | 仅可用动作可提交；取消不生成/扣费 |
| G05-C07 | 恢复/P1 | 任一变换受控失败后重试，检查来源/历史与费用记录 | 失败透明；retry不误改原素材或重复成功任务 |

<a id="g06"></a>

## G06 MCP编辑器工具

范围：本地HTTP服务、工程/track/clip/export工具。前置标记：L。定位：`Sources/VoxstudioPro/Agent/MCP/MCPService.swift`、`Sources/VoxstudioPro/Agent/Tools/ToolDefinitions.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G06-C01 | 发现/P0 | 从当前target进程的MCP endpoint握手、list tools并读取项目 | 返回当前app/工程数据；不连接旧实例服务 |
| G06-C02 | 编辑/P1 | 在一次性项目调用add/move/split片段工具并检查UI | UI和保存数据反映正确变更；位置符合参数 |
| G06-C03 | 选择/P1 | 通过工具切换timeline/track设置后在UI播放 | 活动context一致；不修改另一工程 |
| G06-C04 | 校验/P1 | 缺必填、未知ID、越界时间及不合法路径请求 | 结构化失败；无部分破坏或进程崩溃 |
| G06-C05 | 恢复/P1 | app重启、服务关闭/端口占用后重连 | 断连清晰；不会误把其他服务数据当作target |

<a id="g07"></a>

## G07 MCP媒体处理工具

范围：voice/transcription/dubbing/media status/preview。前置标记：L。定位：`Sources/VoxstudioPro/Agent/MCP/MCPMediaTools.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G07-C01 | 转录/P0 | transcription.create传Downloads绝对路径，poll media.status到终态 | session真实存在；UI、状态和输出对应 |
| G07-C02 | 字幕/P1 | 调用segment、translate、select_track分别核对UI与导出 | 轨道真实生成/选择；每种操作失败不混同原文成功 |
| G07-C03 | 声音/P1 | voice.list/create/preview后dubbing.create短测试文本 | reference正确；输出可播放；不同ID不串 |
| G07-C04 | preview/P1 | media.preview指定有限time范围并核对cue与音频 | 有界片段/路径及时间戳准确；UI导航目标正确 |
| G07-C05 | 异常/P1 | 错session/voice ID、缺参数、非法范围或缺文件 | 返回明确信息；无永久busy、假结果或越界文件访问 |

<a id="g08"></a>

## G08 MCP知识工具

范围：knowledge.ask与检索/证据工具、scope。前置标记：B。定位：`Sources/VoxstudioPro/Agent/MCP/MCPKnowledgeTools.swift`、`Sources/VoxstudioPro/Knowledge/Agent/KnowledgeToolRegistry.swift`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G08-C01 | 正常/P0 | knowledge.ask查询标准事实并核对回答/引用 | 与来源事实一致；结果结构可消费 |
| G08-C02 | scope/P0 | 传只含A的session_ids，再问只存在于B的事实 | 不越范围；明确缺证据 |
| G08-C03 | 历史/P1 | 传合法多轮history追问，再用新scope请求 | 上下文正确；旧范围不会被history强行带入证据 |
| G08-C04 | 路由/P1 | 显式allow_cloud=false并观察已配置可用本地/BYOK路由 | 不授权Cloud路径；不可满足时返回恢复信息 |
| G08-C05 | 异常/P1 | 空query、未知session、非法answer_mode/history | 校验失败明确；没有隐式扩大scope或错服务调用 |

<a id="g09"></a>

## G09 应用内Skills管理

范围：社区/已安装、详情、启用和外部agent入口。前置标记：X。定位：`Sources/VoxstudioPro/Settings/Skill`、`Sources/VoxstudioPro/Agent/Skills`。

| Case ID | 维度/优先级 | 前置及操作 | 预期结果 |
|---|---|---|---|
| G09-C01 | 列表/P0 | 查看社区和installed、搜索一个已知skill并打开详情 | 名称/状态/说明正确；空结果可退出 |
| G09-C02 | 安装/P1 | 经授权只安装可信测试skill到隔离配置 | 安装成功后可见；路径/版本来源可记录 |
| G09-C03 | 使用/P1 | 启用测试skill并用对应简单任务调用 | 行为/上下文符合该skill；不影响无关任务 |
| G09-C04 | 失败/P1 | 断网/无效包/重复安装同一skill | 错误可恢复；不产生损坏或重复installed项 |
| G09-C05 | 清理/P1 | 移除仅本次测试安装项并重开installed列表 | 移除范围准确；其他既有skill保留 |
