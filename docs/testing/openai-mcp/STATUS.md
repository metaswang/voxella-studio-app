# VoxStudio OpenAI MCP 验证记录

记录日期：2026-10-02。整体双端验收尚未完成。

## 已验证

- 官方扩展研究基线：`900032d8bd7c1566202d0cb1666986584f932043`。
- `./scripts/bundle.sh debug --sign` 成功，签名检查通过；停止旧进程后启动仓库 `.build/VoxStudio.app`。
- 新进程监听 `127.0.0.1:19789`，公开 93 个工具；`voxstudio.library({})` 返回文本及 structuredContent，无业务错误。
- `ui://voxstudio/workbench/v1` 可读取，MIME `text/html;profile=mcp-app`，自包含 HTML 1,119,920 字节。
- `voxstudio@voxstudio-local` 0.1.0 安装成功；portable 和兼容 manifest、MCP 配置、图标与安装缓存哈希一致。
- MCP 定向测试：34 tests / 16 suites 全部通过。测试日志位于 `/tmp/voxstudio-mcp-test.log`。
- Vendor 反向请求测试通过：嵌套 capabilities、发送失败、超时、取消、停止、断开及晚到/重复响应。
- 运行中服务真实 HTTP/SSE 链路通过：GET SSE 发出 `openai/elicitation/create`，同 Session-ID POST 回传 cancel/decline；工具结果正确关联。非法 accept 被拒绝；method-not-found 返回 HTML fallback。仅标准 elicitation.form 不会启用 OpenAI 原生表单。
- 前端 TypeScript 检查和自包含构建通过；插件与 MCP manifest 的官方 JSON Schema 校验、四个技能校验通过。

可机器读取的证据：`running-build-verification.json` 和 `wire-form-verification.json`。源码存在用户既有修改和本任务未提交修改，不能将该构建视为仓库 HEAD 的干净发布。

## 已定位并修复的问题

用户截图出现 `Unknown tool: voxstudio.library` 时，插件已经安装，但新 app 的签名构建尚未完成，端口上仍是只公开 70 个工具的旧进程。完成构建、重启并实际调用后，新入口已可用。该问题由验证顺序造成，不需要重装插件。

## 未通过／待验证

ChatGPT Work 与 Codex 的以下项目仍需各自独立验证：面板实际显示、全局和聊天入口、真实附件读写和 ETag 冲突、原生表单 UI 的接受与取消、中文转录及多语言字幕、音视频真实播放与字幕定位、会话引用、五种文件编辑、显式应用到会话、重启恢复。

HTTP/SSE 的模拟宿主测试只验证协议链路，不能计为宿主原生表单 UI 验收通过。直接资源读取不能计为工作台显示或真实视频播放通过。

UI 自动化工具拒绝访问 `com.openai.codex` 原生应用。允许的 MCP Apps 接口只发现当前任务中已展开到侧栏的面板；检查时无可访问 tab。已请用户在新会话重新打开工作台；需获得实际面板结果后继续验证。该限制不应通过其他 UI 操作技术绕过。

## 当前限制与后续工作

- 转录表单模型字段使用现有自动语言路由，尚未提供逐任务模型覆盖。
- 原生资源选择支持已导入输入及 file URI；宿主返回的其他 opaque URI 需要走文件入口绑定流程，不能假定可解析成本地路径。
- 新接口 outputSchema 目前为通用对象，需要继续收紧具体字段契约。
- 尚需补充可控时钟的超时竞态测试、会话编辑持久化与同秒索引更新测试，以及完整业务端测。
- 临时输入／预览清理策略、宿主字幕写入前的格式诊断、未保存 cue 编辑的切换保护等需要继续审查。

因此本记录确认新版本运行和基础链路正常，不表示计划所有交付要求已完成。

## 2026-10-03 宿主工具加载修复

用户新截图提示“当前聊天未加载 voxstudio.library”，此时 app 的本机接口工作正常。内置 Codex app-server 只读诊断发现：停用的旧 `[mcp_servers.voxstudio]` 仍遮蔽同名插件 MCP，宿主仅列出旧 HTTPS 地址、pluginId 为 null、工具数为 0。

备份全局配置到私有临时文件后，仅将该停用项改名为 `voxstudio_legacy_remote`，保留其所有字段和值。重新通过内置运行时验证：`pluginId=voxstudio@voxstudio-local`、`httpOrigin=http://127.0.0.1:19789`、工具数 93、包含 `voxstudio.library`、toolsError=null。未改变 VoxStudio 进程或其他插件设置。

证据：`host-plugin-loading-verification.json`。现有桌面聊天仍需刷新宿主连接／新开会话确认 UI；该后台验证不等于双端界面验收。恢复配置时只恢复原旧项的名称，避免覆盖后续其他配置修改；恢复会重新引入同名冲突。

## 2026-10-03 工作台模型入口兼容修复

新截图仍提示当前会话没有工作台入口。实际当前模型暴露的 VoxStudio 工具为按名称排列的前 23 项，最后为 `get_media`，不包含后部的 `voxstudio.library`；服务端和内置 Codex 运行时仍列出全部 93 项。尚未从宿主日志确定截取的具体阈值或实现原因。

新增 `app_workbench({})` 作为模型入口别名，复用 library 的业务数据和 MCP Apps UI resourceUri；保留原接口，不增加重复静态导航入口。其名称在新 94 项工具中排序第 4。插件 onboarding 优先调用该别名，并明确缺少模型工具不等于 app 没有运行。安装缓存已更新且哈希匹配。

34 项 MCP 定向测试通过，完成签名构建和重启。HTTP 实测新入口与 `voxstudio.library` 的 structuredContent 完全一致，view 为 library，UI resourceUri 正确。内置 Codex 运行时发现 94 项工具且包括新入口。当前正在执行的模型回合工具集不会随 HTTP 验证自动改变；需要下一回合核对实际模型曝光并验证面板显示。

证据：`model-entry-exposure-verification.json`。未将这些检查计为实际桌面面板或双端验收通过。

## 2026-10-03 空白面板修复

用户已经能调用 `app_workbench` 并打开侧栏，但面板空白。检查打包产物确认：构建脚本把 esbuild bundle 作为 String.replace 的替换字符串使用；依赖中的特殊 dollar 序列被解释成替换指令，导致模板 header 出现 33 次，内联脚本语法错误 `missing ) after argument list`。此前 TypeScript 和 esbuild 检查均在 HTML 插入前完成，因此没有覆盖最终交付脚本。

将插入改为 callback，按字面写入 bundle；在构建中用 Node vm.Script 校验 HTML escaping 后的实际内联脚本，并要求唯一插入 marker。修复后 header 只有 1 份，脚本语法正确，HTML 931,806 字节。TypeScript 检查、前端构建和签名打包均通过，已重启 app；运行中 MCP 资源字节哈希与源码产物一致。

使用从运行中 MCP 读取的 HTML，在真实 in-app browser 中与官方 AppBridge + PostMessageTransport 连接。验证 SDK 握手、初始 fixture 会话显示、导入控件显示和 Refresh 的 bridge 调用成功。截图 `render-preview.png` 明确使用 fixture 测试数据，属于浏览器渲染证据，不是 ChatGPT Work/Codex 原生插件面板验收。

机器证据：`panel-render-verification.json`。用户需关闭旧的空白面板，再调用 `app_workbench({})` 加载修复后的资源。完整业务和双端验收仍未完成。

## 2026-10-03 独立英文面板与原生视频编辑

按用户最新范围，MCP HTML 收敛为会话列表、转录、会话详情、配音四个独立文档。全界面固定英文，用户内容保留原语言；新的样式、暗色与窄屏布局、明确提交、草稿保护和保存冲突保留均在浏览器中检查。原通用文件编辑器不再注册为首版 HTML 入口，已有文档工具保留。

视频编辑 HTML、`app_video_editor` 和其导入包装已移除。插件新增 video-editing 技能，引导 ChatGPT/Codex 通过真实项目 ID、`get_timeline`、原生剪辑工具、撤销与导出直接操作 Mac editor。没有将浏览器模拟时间线操作计为原生端测。

- `npm run check` 和四份自包含 HTML 的构建／最终脚本语法校验通过。
- 最新 MCP 定向测试：38 tests / 17 suites 通过（`/tmp/voxstudio-mcp-real-sessions-tests.log`）。
- 原生项目绑定与撤销定向测试：14 tests / 2 suites 通过（`/tmp/voxstudio-native-video-route-tests.log`；与上述 MCP 筛选有部分重叠）。
- 签名构建通过（`/tmp/voxstudio-mcp-real-sessions-bundle.log`），正常退出无打开项目／活动作业的开发实例后重新启动。
- 运行服务公开 99 项工具；四个 UI resource 的字节与源码产物一致；视频编辑工具未绑定 HTML；插件 0.1.0 安装缓存和源码 manifest／技能哈希一致。

证据：`focused-panels-running-verification.json`、`redesign-library.png`、`redesign-transcription.png`、`redesign-session.png`、`redesign-dubbing.png`。这些 redesign 截图使用明确标记的 fixture 数据。

## 2026-10-03 会话列表数据来源修复

用户正在查看的 `19790` 浏览器预览此前只展示四条固定示例，并没有连接真实 app 数据。开发预览改为默认通过官方 AppBridge 转发实际 MCP 读取：显示 27 条真实会话，逐项数据与直接 MCP 读取一致，最近标题和时长与提供服务的最新 Mac app 窗口匹配。选择真实 session ID 后，独立详情成功读取对应转录；app 重启后旧 Session-ID 自动重新初始化，列表恢复。

固定示例现在必须显式使用 `?mode=fixture`。真实浏览器预览明确标为 read-only，创建／编辑请求被拒绝，交互业务仍在安装的 ChatGPT/Codex 插件执行。代理限制协议方法和工具、拒绝跨源请求，并在页面离开时关闭 MCP 会话。运行服务的库入口与刷新接口返回相同会话；补充测试防止关联配音把原转录归类为配音，并改用原生计算时长。

原生诊断曾按名称打开 `/Applications/VoxStudio.app` 旧安装实例。它有 sandbox 数据目录，与仓库开发构建不同；已改为按完整 bundle 路径选择最新构建，没有迁移、合并或覆盖两份数据。自动审批拒绝终止旧安装实例，理由是不能确认未保存状态，因此保留它；正常退出和重启仅针对本次开发实例，在确认 openCount=0 且无活动作业后执行。

证据：`live-preview-verification.json`、`live-library.png`。当前浏览器已保留真实数据页供用户查看。浏览器真实 MCP 数据验证仍不等于 ChatGPT Work/Codex 原生渲染、原生表单、业务生成或 prompt 修改时间线的完整双端验收。

## 2026-10-03 会话媒体预览修复

用户截图的 `Fixture does not implement media.session_preview` 来自固定示例宿主：它没有实现预览工具，也没有注册二进制 resource 读取回调。为显式 fixture 模式补齐 `media.session_preview`、`media.preview` 和 `resources/read`，包含自制 15 秒 H.264/AAC 视频及安静测试音频；没有使用用户媒体作为 fixture。默认真实 app 模式保持不变。

共享播放器等待浏览器实际读取元数据后展示控件，提供明确的 Play/Pause preview 按钮，不自动播放；资源、解码或加载错误显示英文说明。会话和语言切换会释放播放器并暂停旧媒体，过期的异步预览结果不会替换当前内容。字幕使用 clip 起点加浏览器播放时间同步，点击字幕可复用当前 clip 定位，超出范围则加载新的片段。

- `npm run check`、`npm run build`、`npm run build:preview` 和最终 HTML 脚本语法校验通过；`git diff --check` 通过。
- 使用官方 AppBridge + PostMessageTransport，在 in-app browser 中完整播放 fixture 视频及音频，各 15 秒，无 media error；验证 8 秒定位、16 秒新 clip 和切换语言后 media 元素清理。
- 真实 app 的视频会话完整播放 15 秒（568×320），真实 MP3 会话的音频预览播放至 15.061333 秒；两者 readyState=4、ended=true、media.error=null。真实音频点击 00:05 字幕后 currentTime=5.12，字幕同步更新。
- `./scripts/bundle.sh debug --sign` 成功，日志 `/tmp/voxstudio-session-media-bundle.log`。运行中 `ui://voxstudio/session/v1` 的 SHA-256 为 `3893ccbe6e2abb572b65e34c5710b1d771e8bff984b21a5d57b80c6ad5324d42`，与源码及签名包一致。资源按请求读取文件，因此此次 HTML 修复已经由当前服务提供；Mac 锁屏时没有强制终止或重启 app。

证据：`session-media-playback-verification.json`、`session-media-running-resource.json`、`session-media-real-video.png`、`session-media-real-audio.png`。保留真实会话预览页供用户查看；旧面板需关闭后重新打开或刷新本地预览页以加载新脚本。这些是真实浏览器和本地 MCP 媒体链路验证，未计为 ChatGPT Work/Codex 两个原生插件宿主的完整端测。
