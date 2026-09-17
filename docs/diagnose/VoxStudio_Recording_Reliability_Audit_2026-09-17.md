# VoxStudio 录音可靠性二轮源码审查

审查日期：2026-09-17。对象：用户上传的 `voxella-studio-app-source.zip`。

**结论：修复方向正确，但录音可靠性闭环尚未完成。发现 22 项应处理的问题：2 项 P0、16 项 P1、4 项 P2。** 其中 P0 指可能删除唯一录音或让旧会话破坏新会话的发布阻断项；P1 指录音完整性、恢复、时序、持久化或隐私边界问题；P2 指实时性、边缘音频完整性与诊断问题。这不是远程可利用漏洞/CVE 审计。

## 范围与验证边界

已逐段审查录音引擎、麦克风 backend、Controller、重采样、混音/拼接、manifest、设备选择、退出流程，以及录音交给 Workbench 的持久化链路。未修改应用源码。

附件包含 627 个文件。未找到可用于重建该应用的 Package.swift、Xcode 工程或录音测试集；发现 scripts/test-local-models.sh，但它不是本次录音回归测试。执行环境为 Swift 6.2.1 / Linux，不能据此宣称已在 macOS 15.7.3 编译、测试或复现用户原始事故。以下区分源码已确认的路径、独立 Swift 实验、逻辑模型和待 macOS 故障注入的行为；不将代码风险等同于原始事故根因。

压缩包 SHA-256：`08d1bc58bfa9f1cf5536f2ac71377ee97626d10f031c8db44f14dccf243dd639`。

## 已执行的验证

1. 从原始源文件提取 withTimeout helper，搭配模拟原生回调：配置 50 ms、回调 400 ms，实际约 401 ms 才返回超时。证明 helper 不能独立保证截止时间，不是 macOS 媒体测试。
2. 执行原始 manifest 扫描器（仅移除测试不使用的 macOS 容量方法、替换 Log）：failed 候选被跳过；非媒体但非空、标记 inProgress 的文件被接受。这证明筛选/校验逻辑的行为，不证明任意真实受损媒体能否解码。
3. 忠实状态逻辑模型：无样本但每次重启确认成功，120 秒内重启 20 次仍不 failed；部分补静音后 cursor 未提交导致下次从旧 PTS 重写；mute 零 append 仍刷新 lastAppended。模型假设在脚本中明确标注。

## 逐项问题与修复

### R01 · P0 · 保全路径仍调用 cancelWriting，可能删除正在保全的唯一文件

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:618–625`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:654–679`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:723–739`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:794–798`

**问题与影响：** finishWriting 超时后，completePreservedOutput 先收集现存 URL，再调用 resetLocked；后者对仍处于 writing 的 writer 调用 cancelWriting。Apple 的契约明确：如果 writer 已创建输出文件，cancelWriting 会删除它。后续 Task 可能仍以刚才收集的 URL 返回成功。另一个可达分支是“请求视频、已写音频、没有视频帧”：该分支在 preserveOutputIfNeeded 前已经 cancelWriting。故“只有明确丢弃才删除”目前不成立。

**解决方案：** 把 release/reset、用户 discard、异常 salvage 拆成不同操作。非 discard 路径禁止取消拥有唯一副本的 writer。先把已封口片段及 journal 持久化，未完成 writer 归入独立的 pending-finalization 上下文；只在拥有可验证副本或用户明确丢弃时允许破坏性取消。不得仅去掉 cancelWriting 就宣称崩溃可恢复，还要验证文件已落盘及可读。返回成功前再次校验路径和媒体。

**回归验证：** 注入 finishWriting 不回调/延迟超时，以及有音频但无视频帧；验证保全路径没有调用 cancelWriting、原始片段不被删除、返回 URL 可读。

**证据级别：** 源码与 Apple cancelWriting 文档共同确认；未在 macOS 实际执行删除实验。

### R02 · P0 · 迟到的停止/完成回调未绑定会话，可清理下一场录音

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:503–558`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:564–575`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:654–679`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:682–737`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:824–852`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:213–216`

**问题与影响：** captureGeneration 在采集启动侧有使用，但 completeWriter、writer.finishWriting 回调及 8 秒/20 秒兜底不校验所属停止操作。completeWriter 用的是当前 self.writer。resetLocked 又将 isStopping、finishResumed、didFinalizeWriter 清零。录音 A 经兜底完成后启动 B，A 的迟到回调仍可 finalize/reset B；旧 resume 也会读写 B 的共享 finishResumed。Controller 的过期启动分支还会无条件 engine.cancel()，没有 expectedSessionID。

**解决方案：** 使用独立 SessionContext 与 FinishContext，保存 sessionID、operationID、writer、stream、manifest、segments、一次性 continuation gate。每个回调先验证身份，再触碰状态；旧回调最多完成旧上下文，不得访问当前 writer。超时计时器应取消或失效化。cancel/stop API 接收 expectedSessionID。恢复操作另设 recoveryGeneration，不能只用录制 generation。

**回归验证：** A 的 stopCapture 延迟超过 8 秒，A 先经兜底完成，启动 B 后释放旧回调；再对 writer 回调和超时回调做同样测试。B 的 writer、文件、UI、continuation 必须完全不变。

**证据级别：** 源码可达竞态；未执行完整调度故障注入。

### R03 · P1 · withTimeout 并非硬截止时间，底层 continuation 不返回时仍会一直等

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:186–204`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:255–280`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1494–1511`

**问题与影响：** withThrowingTaskGroup 的作用域退出会等待全部子任务。抛出超时和 cancelAll 不会自动恢复悬挂的 CheckedContinuation；stop 的 operation 没有取消处理。start 的取消处理又投递到可能被阻塞的同一 queue。原始 helper 的独立 Swift 实验：超时 50 ms、底层回调 400 ms，实际约 401 ms 后才返回超时。cancel() 本身没有超时。

**解决方案：** 在回调桥接层用锁/actor 保护单次完成 gate，让回调、超时、取消竞争恢复同一个 continuation。超时必须能结束等待者，不依赖不可合作的底层工作完成。底层迟到清理隔离在旧 SessionContext 中，和 R02 一起实现。不能仅在 catch 再补 cancelAll。必要时将不能中断的原生操作隔离到独立执行单元，但不要宣称 Task.cancel 能终止同步框架调用。

**回归验证：** 运行 TimeoutProbe.swift；修复版应在设定容差内返回。再测试回调永久不来、超时与回调同时发生、取消先于注册、回调晚于新会话等情况，确保恰好恢复一次。

**证据级别：** 已执行原始 helper 的 Swift 6.2.1/Linux 实验；这不是 macOS 端到端测试。

### R04 · P1 · 同步采集启停会堵住 writer/健康检查队列，超时看门狗也可能失效

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:327–338`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:536–558`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1309–1317`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:46–85`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:209–250`

**问题与影响：** 初次 microphone.start 在录音引擎 queue 上直接运行，内部最终同步 startRunning；stop 用 captureQueue.sync 等待 stopLocked，内部又有 stopRunning。健康检查 timer 和部分取消/超时工作同样运行在引擎 queue。任一原生启停阻塞时，writer、健康检查、保存兜底可能一起无法执行。Apple 明确 startRunning/stopRunning 为阻塞操作；有一个 serial queue 并不等于拥有独立监督能力。

**解决方案：** 采集配置/原生启停仅在采集 owner 队列执行，以异步确认通知 supervisor，禁止 writer 队列 sync 等它。writer 独立拥有可保全数据；watchdog 使用不依赖受监控队列的单调时钟/执行上下文。超时后隔离旧采集对象，不要让 supervisor 为等待清理而再次阻塞。

**回归验证：** 用假的 capture backend 将 start/stop 阻塞 60 秒；监督器仍按截止时间变化状态，已有片段仍可封口/登记，UI 不永久停留 preparing/finishing。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R05 · P1 · 启动回调被当作真实恢复，断流可无限续命

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:355–370`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:403–424`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:484–491`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1198–1209`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1339–1382`

**问题与影响：** 麦克风仅在 start/rebuild 成功后就 emit(.recovered)，并非等到稳定音频；引擎收到它后清除 stallBeganAt，并把 lastReceived 与 lastAppended 都设为 now。流重建成功也这样做。于是“重启调用成功但始终没有样本”可每约 6 秒重复一次，30 秒内不到 8 次，不触发重试窗口上限；15 秒断流上限始终被重置。忠实逻辑模型运行 120 秒，实际样本 0，重启 20 次，仍未 failed。另外 failureTimeout 从首次发现 stall 起算，没有重置时也约需断流 20–21 秒才停止。

**解决方案：** 将 restarting、awaitingSamples、healthy 分离。lastReceived 只能由本代真实 sample 更新；lastAppended 只能由 append 成功更新。以 lastGoodSample/lastGoodCommit 设置每轨绝对失败截止时间，不能因“API 调用成功”重置；连续有效样本或稳定时段后才宣布 recovered。暂停/唤醒的宽限期单独建模，不伪造收样时间。

**回归验证：** 重启 API 始终成功但永久无样本，必须在定义的总断流上限内安全停止；只回一个样本后再断流也不得无限延期。见 logic_probes.py。

**证据级别：** 源码确认；已运行注明假设的状态机模型，未执行真实蓝牙/USB 测试。

### R06 · P1 · SCStream 停止后的恢复走 updateContentFilter，且多个恢复可重叠

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1224–1282`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1293–1306`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1528–1546`

**问题与影响：** didStopWithError 对非 userStopped 错误统一进入 recoverStreamLocked。有 displayID 和 stream 对象时优先 updateContentFilter，成功后宣布恢复，却没有 startCapture；更新过滤器不是重新启动已停止流的流程。isRecovering 没有作为入口的 single-flight guard。异步 Task 在 await 后才读取 self.stream，且 generation 校验发生在 updateContentFilter 的副作用之后，所以过期/重叠恢复可以改到新对象。

**解决方案：** 区分 stopped/error、live filter update、wake 三种状态。停止的流必须进入可验证的 restart/recreate 流程；活跃流才更新 filter。每次恢复固定 stream identity、session generation、recovery generation；副作用前后均校验，一次只允许一个恢复，合并后续请求，并在收到新样本后成功。停止旧流与启动新流采用明确状态交接。

**回归验证：** 分别注入 didStopWithError、连续显示器变化与唤醒通知；确认停止流实际重新启动；旧 async filter 任务不能修改新会话；不得并发创建多个有效流。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R07 · P1 · 写入卡顿被误修复为采集卡顿

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1055–1097`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1215–1221`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1343–1382`

**问题与影响：** 健康检查能识别 microphone write/system audio write，但两者最终仍进入 recoverAfterInterruptionLocked，只重启麦克风/SCStream。若输入持续有样本，writer 仍是 writing、但 isReadyForMoreMediaData 长期为 false，重连采集并不能修复写入端。恢复又可能改写健康时间戳，让错误掩盖或反复重连；一个轨道故障还可能中断另一个健康轨道。

**解决方案：** 分别维护 receipt stall、conversion stall、writer backpressure、writer failure；按故障层路由。只有收样缺失才重启对应采集源；写入长期无进展进入有界排队、保全、writer rollover/停止；转换失败进入 converter 重建。为每轨保存独立的故障状态与最后成功写入点。

**回归验证：** 持续注入正常样本，同时令 writer input 永久 notReady；应处理 writer 而非无限重启麦克风；第二条健康轨道不应被无故重启。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R08 · P1 · 视频没有进展健康检查，画面停止但音频继续时可漏报

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:934–960`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1343–1356`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:618–625`

**问题与影响：** 视频 append 在 writer 状态、ready、frame status 或 pixel transfer 不满足时直接 return；健康统计仅有麦克风与系统音频。只要两条音频仍进展，即使视频从中途开始完全不写，当前健康检查也不会发现。停止时 !didAppendVideo 仅检查整场是否曾写过视频，不能发现中途冻结。

**解决方案：** 新增视频 receive/有效帧/实际 append/错误计数及 writer heartbeat。区分静态画面、ScreenCaptureKit 的 idle/非 complete 帧与真正采集失败，不能简单使用“5 秒没有新 complete 帧就故障”。由流状态、回调状态、媒体时间与 writer 进展共同判断，并提供明确的视频降级/停止策略。

**回归验证：** 先写 10 秒视频后冻结视频输出，音频持续；应有状态提示并执行预定策略。静态桌面无变化时不能产生误报。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R09 · P1 · 音视频时间戳仍取处理时刻，排队延迟会变成伪断流

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:159–168`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:920–925`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:950–958`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1010–1020`

**问题与影响：** mic tap 已带有 when.hostTime，但写入时没有使用 CMSampleBuffer 的采集 PTS；audio/video 都调用当前 hostClock 的 writerPTS。音频还用 50 ms 阈值决定是否补静音，否则接到 nextAudioPTS。CPU/磁盘造成的队列延迟因此可能被写成静音空洞；突发交付时重新贴到 cursor，真实小丢块又可能被压缩。这不是“保留采集时钟”，只是“使用单调时钟读取处理时间”。

**解决方案：** 从 sampleBuffer 读取真实 PTS；明确各 backend 的时钟域，必要时转换到共享 host-clock 时间基准。会话 origin、暂停扣除与 segment origin 分层且跨轨一致；重采样输出由帧数维护 duration/cursor。队列延迟只影响延迟指标，不应改变媒体时序。丢帧/缺样按真实 PTS 和显式策略处理，不用 50 ms 到达时间阈值掩盖。

**回归验证：** 同一批样本保持 PTS 不变，分别即时、延迟、批量交付；三种输出的媒体时间必须一致。再测试 21 ms 丢块、双轨不同延迟、暂停恢复与长录制。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R10 · P1 · 补静音没有提交进度反馈，可重复写时间戳或伪造写入健康

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1013–1027`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1055–1074`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1100–1145`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:635–639`

**问题与影响：** appendSilence 返回 Void，只局部更新 pts，不更新 nextAudioPTS、lastAppended、每轨已写标志。若补静音成功一部分后背压，随后真实 buffer 被丢弃，下一次会从旧 cursor 重补，造成重叠 PTS。静音麦克风分支更会在零样本 append 成功时，仍推进 nextAudioPTS 并更新 lastAppended。永久断流后停止也没有按统一终点处理尾部缺口，仅对从未有样本的轨道塞 2048 帧。

**解决方案：** 统一真实音频、补静音、mute silence、converter flush 的提交入口，返回实际成功写入的帧数和 lastCommittedPTS；每次 append 成功立即原子更新 cursor、轨道标志、健康状态。未写的部分留待重试，不可虚报。停止时以明确的 sessionEnd 和缺口策略处理尾部，不能用固定短静音代表整段缺失。

**回归验证：** 在一半 gap 填充后注入背压，检查无重复/倒退 PTS；mute 时 writer 永久 notReady，lastAppended 不得刷新；终段永久断流的时长/缺口必须符合策略。见 logic_probes.py。

**证据级别：** 源码确认；已运行 cursor/health 提交逻辑模型，未执行实际编码器写入。

### R11 · P1 · 新 writer 片段没有独立时间原点，且已写标志沿用上一片段

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:415–421`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:920–925`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1386–1423`
- `Sources/PalmierPro/Workbench/Recording/RecordingAudioMixer.swift:101–132`

**问题与影响：** rotateWriter 清空 nextAudioPTS、重置 didStartSession，但没有为新片段建立 local origin，也没有重置 didAppendMedia/Video/Microphone/SystemAudio。新 writer startSession(.zero) 后继续使用整场 PTS。例如录到 600 秒换段，新片段首个样本仍接近 600 秒。拼接又取每段 [0, asset.duration] 顺序累加；这可能加入大的前导空段、重复计算偏移或插入非法 track range。具体导出表现需实测，时间模型不一致本身已可由代码确认。

**解决方案：** 定义 session-global PTS 与 segment-local PTS：local = global - segment.globalStart；所有轨道共享 segment origin。每段独立重置 append flags、统计、writer 状态。journal 记录 globalStart、local time range、实际轨道；拼接依据该时间线及 track.timeRange，而非简单累加文件 duration。

**回归验证：** 在 10 分钟时强制换段再录 20 秒，检查总时长约为 620 秒而不是包含第二段额外前导空白；再测新片段完全无样本、双轨不同起点、连续换段。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R12 · P1 · 创建下一片段失败时，停止路径忽略之前已保留的片段

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1386–1423`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:569–574`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:842–852`

**问题与影响：** rotateWriter 在安装新 writer 前令 self.writer=nil；installWriter 抛错后只恢复 outputURL 并 emit failed。Controller 保存时 finalizeWriter 的 guard 发现 writer=nil，就 reset 并返回 emptyRecording；completedSegments 也被清空。原始片段可能还在磁盘，但正常保存链路没有交付它们。旧 writer 的 finish 回调也只日志记录，没有形成可等待的“片段已封口”状态。

**解决方案：** rollover 做成事务：封口/保全旧片段并持久化索引，尝试新片段，成功后切换 activeWriter；失败也保留独立于 writer 引用的可恢复片段集合。stop 即使没有 active writer，也必须能输出所有已保全片段。对 failed/unknown/writing writer 分别处理，不用 finish 回调日志冒充 sealed 状态。

**回归验证：** 写满一段后令新 URL 创建、编码器初始化或 startWriting 失败；停止结果应保留/登记旧段，不得只报 emptyRecording。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R13 · P1 · 最需要恢复的 failed 保全文件会被启动扫描器过滤掉

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1432–1437`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionManifest.swift:3–14`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionManifest.swift:62–89`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:637–644`

**问题与影响：** preserveOutputIfNeeded 把 manifest 写成 failed，而 recoverInterruptedSessions 只接受 inProgress。所以写入失败、异常保全的片段恰好会被跳过。manifest 还是单文件结构，没有分段序号、时序与交接状态；Controller 每次只 stage recovered.first，没有统一展示一个会话的所有片段。已用原始扫描器实测 failed 候选被排除。

**解决方案：** 建立会话级 journal，记录所有 segment、顺序、globalStart、状态、完整性检查、导出/导入确认。扫描 inProgress、failed、pendingFinalize、pendingImport 等所有未完成交接状态。按 session 分组，展示/恢复全部有效片段；不要把 failed 视为不可恢复。写 journal 失败必须影响保存状态，不能只有日志。

**回归验证：** 同时创建 inProgress 与 failed 候选，均进入待校验队列；同一会话多段与多场未完成会话全部可发现；坏 manifest 不影响其他会话。见 ManifestProbe.swift。

**证据级别：** 已执行原始 manifest 扫描器（仅移除与测试无关的 macOS 磁盘容量辅助函数，Log 为桩）。

### R14 · P1 · 文件存在即被当成保存成功，合并失败还会只交付最后一段

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:731–789`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionManifest.swift:76–79`
- `Sources/PalmierPro/Workbench/Recording/RecordingAudioMixer.swift:103–132`

**问题与影响：** 保全只看 fileExists；重启恢复最多看 size>0，均未检查媒体是否可读。单文件可直接 success；多文件拼接失败则 urls.last fallback，并继续 success。最后一段可能最短甚至损坏，前面的有效内容不会出现在返回结果中；fallbackError 也不再体现。这里不能断言所有原始文件都删除，但可确认“保存成功”与“完整、可播放、包含全部片段”没有对应关系。

**解决方案：** 返回 complete、partial、rawSegments、recoveryRequired 等显式结果，携带有效与失败片段清单、警告和时长。逐段验证轨道/有效时间范围，必要时用 AVAssetReader 检查可解码样本；失败仅隔离该段。合并失败时交付所有有效原始段，不盲选 last。只有已验证且完成持久化交接的产物才允许清理 journal。

**回归验证：** 好前段+坏尾段、任意非空垃圾文件、单段截断、合并失败；不得把坏 URL 无警告标成完整成功。ManifestProbe 实测非媒体 inProgress 文件会被当前扫描器接收。

**证据级别：** 源码确认；非媒体候选被扫描器接收已实测；编码格式校验尚需 macOS。

### R15 · P1 · 保存/恢复到导入之间没有持久化交接，正常退出也可能丢失可发现性

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:777–789`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:343–354`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:637–644`
- `Sources/PalmierPro/Workbench/WorkbenchStore.swift:1940–1944`
- `Sources/PalmierPro/Workbench/WorkbenchStore.swift:1992–2007`
- `Sources/PalmierPro/Workbench/WorkbenchStore.swift:6678–6692`

**问题与影响：** 引擎返回之前已删除 manifest；启动恢复更在 stage 之前删除。stageRecordedMedia 只设置内存 pendingMediaImportURLs；Workbench 保存快照仅 transcriptions/dubs，不包含该待导入状态。用户尚未确认导入就退出/崩溃时，原始媒体可能仍在磁盘，但 manifest 和内存入口都不在，下次恢复扫描找不到它。正常退出完成录制也会走这条链。

**解决方案：** 先持久化 RecordingRegistry/pendingImport 记录，再向 UI stage，最终收到项目或媒体库 durable-commit 确认后才清理恢复 journal。退出路径也只认可 durable ownership transfer，不认可“URL 已放入变量”。重启统一重建待导入列表，导入必须具备幂等 sessionID。

**回归验证：** 在 stage 前后、导入确认前、项目保存前逐点终止进程；每次重启都应找回同一录音且不重复导入。正常 stop 后立即 Cmd-Q 同样测试。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R16 · P1 · 退出等待超时仍允许退出，且等待包含可能很长的合并/混音

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:293–314`
- `Sources/PalmierPro/App/AppDelegate.swift:84–108`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:545–558`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:668–679`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:742–789`
- `Sources/PalmierPro/Workbench/Recording/RecordingAudioMixer.swift:138–150`
- `Sources/PalmierPro/Workbench/Recording/RecordingModels.swift:197–201`

**问题与影响：** prepareForTermination 25 秒后只日志，不返回失败；AppDelegate 随后仍 reply(true)。停止过程可能先等 stream 8 秒、再等 writer 20 秒，本身已超过 25 秒；后续 concatenate/mix 是 export，没有同等明确的截止时间。reset 已提前执行，原 writer 的兜底不再覆盖这些后处理。退出可能打断未封口/未交接的数据，即使 shouldTerminate 接入点本身正确。

**解决方案：** 退出拆成“快速保全原始段并持久化 journal”和“可恢复后处理”。前者提供明确 safeToQuit/outcome；未达到最低保全条件时拒绝或延后退出并提示。合并、混音、增强等不应是唯一保存路径，应保存可恢复任务并下次启动续做。预算统一按绝对截止时间分配，不独立堆叠相互矛盾的超时。

**回归验证：** 导出持续 60 秒时退出，必须已经能从 durable journal 重启恢复；原始数据未安全登记时不得静默批准退出。注入 8 秒停止+20 秒 writer finish。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R17 · P1 · 麦克风状态跨队列未统一隔离，排队样本没有 session/backend generation

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:46–104`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:140–175`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:236–240`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:416–430`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:327–338`

**问题与影响：** start 直接在调用队列修改 onSample、isStoppingCapture、captureToken 等；restart 在 captureQueue；tap/output 回调又读取它们。部分数据字段只有 @unchecked Sendable，并无实际隔离。tap 排队块和 CaptureSessionSink 都通过 self 的当前 callback 交付样本，没有携带录制 generation；旧样本/旧 noteStableAudio 在快速启停后有机会被算入新会话，甚至重置新会话重试计数。

**解决方案：** 生命周期可变状态由一个 owner 隔离；实时线程仅接触线程安全的必要标记/缓冲。每个样本信封固定 sessionID、backendGeneration、采集 PTS；输出层校验后才写入。停止先 fence 旧代，再 drain/discard 旧代队列；不要重用旧代计数对象。闭包捕获该代 handler，而非临时读取 self.onSample。

**回归验证：** 延迟 A 的 tap/output/stable 回调，停止 A 后启动 B 再释放；B 不得接收旧样本或重置计数。配合 Thread Sanitizer 与高频启停/插拔压力测试。

**证据级别：** 源码存在跨队列可变状态和无代际样本；具体竞态须 Thread Sanitizer/调度注入验证。

### R18 · P2 · 24 块上限只限制 PCM 块，丢块事件队列仍可能无界增长

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:140–168`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:434–451`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:461–486`

**问题与影响：** 达到 maxPendingTapBuffers 后，每次丢块仍向 captureQueue 投递 droppedTapBuffers+=1 和 logTapBackpressureIfNeeded 两个任务。所谓日志只发一次的判断发生在入队之后，因此阻塞时仍可积累大量控制任务。tap 还逐块分配 AVAudioPCMBuffer，拷贝失败直接打日志；这只是部分减轻实时线程工作，不是完整有界/实时安全桥接。

**解决方案：** 使用预分配 buffer pool 或 SPSC ring，统一数据与控制消息的容量/合并策略。丢块用原子累计计数，低频由非实时队列采样上报，禁止每个丢块继续排队。审核所有 backend 到 writer 的桥接边界，并将 RT drop 计数纳入终止诊断。

**回归验证：** 持续阻塞消费者并高频供样，观察数据、控制队列和常驻内存均有上界；确认实时回调中无日志、动态扩容与不可控工作。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R19 · P2 · 重采样器在格式切换与结束 flush 时仍可能残留、错位或漏掉尾音

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/RecordingAudioTranscoder.swift:39–99`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1133–1145`

**问题与影响：** 相同非 canonical 格式跨块保留 converter 是进步，但 canonical 快捷分支直接 return，未处理已有 converter。A(非 canonical)→canonical→A 可重新使用旧状态；切换到另一非 canonical 格式又直接替换 converter，没有处理旧延迟数据。flush 只 convert 一次，没有 drain 到 endOfStream；写入处忽略 ready 和 append 返回值，也不更新 cursor/flags。具体尾音数量依实际 converter 状态而定，不应宣称每次都会丢。

**解决方案：** 把格式/设备代际变化视为显式转换边界，按策略 drain 或丢弃并记录 discontinuity；canonical 路径也要处理旧状态。为 converter 输出建立带时间戳的有界 FIFO；结束时按状态循环 drain，在截止时间内提交并核对 append 结果。flush、静音与常规音频使用同一个提交函数，避免静音期间泄入旧的有声尾样本。

**回归验证：** 44.1 kHz mono→48 kHz stereo→44.1 kHz mono、短片尾脉冲、停止时背压、静音后停止；比较总帧数、尾脉冲位置和静音边界。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R20 · P1 · 所选显示器消失后自动改录其他屏幕，存在隐私边界改变

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1293–1306`

**问题与影响：** rebuildContentFilter 在找不到 currentDisplayID 时静默选 content.displays.first 并更新 currentDisplayID。拔掉原先选择的外接屏后，恢复可能改录包含私人内容的另一屏；区域模式还会沿用原来的 sourceRect。这里仅指所选 display/region 的 fallback，不是声称 window 模式会直接变成全屏录制。

**解决方案：** 将用户选定的 capture target 视为权限/意图边界。目标不可用时暂停并保全，提示重新选择；不得静默切到另一屏。用户确认后重新计算 region、尺寸、DPI、排除应用规则并记录 source-switch 事件；后台音频恢复和视频目标选择分开设计。

**回归验证：** 外接屏显示公共内容、内屏显示私人内容；拔掉外接屏，结果不得包含内屏。区域分辨率/DPI 改变也不能扩大未授权范围。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R21 · P2 · 显式麦克风选择仍可能在准备阶段被静默替换，运行中配置也会被刷新修改

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/RecordingAudioDevices.swift:103–128`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:85–95`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:159–164`

**问题与影响：** 底层给显式设备绑定 UID 的方向正确，但 resolvedMicrophone 在显式 UID 不在 devices 时返回默认/第一台/系统默认。start 使用缓存 devices 再做一次解析；枚举未完成或设备短暂缺席都可能改变用户选择。refreshDevices 异步返回后不检查 phase，会修改 configuration，而引擎可能已经使用旧 request，造成 UI/日志和实际设备不一致。

**解决方案：** 区分显式 UID 与跟随系统默认的策略；显式设备暂不可用应报错/等待用户选择，不自动替换。start 等待新枚举结果并冻结 activeConfiguration；运行中刷新设备列表不得修改 active request。日志读取不可变活动会话快照，不读可编辑配置。

**回归验证：** 保存显式 USB 麦克风，启动时延迟设备枚举或暂时断连；不得自动改成内置麦克风。录制期间刷新设备列表，实际 UID、UI 与停止日志应一致。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

### R22 · P2 · 最终停止原因与健康计数未形成一致的诊断记录

**代码位置**

- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:317–324`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:598–617`
- `Sources/PalmierPro/Workbench/Recording/RecordingSessionController.swift:647–656`
- `Sources/PalmierPro/Workbench/Recording/RecordingModels.swift:153–176`
- `Sources/PalmierPro/Workbench/Recording/ScreenCaptureRecordingEngine.swift:1088–1096`
- `Sources/PalmierPro/Workbench/Recording/MicrophoneCaptureEngine.swift:150–151`

**问题与影响：** runtime failed 和系统 userStopped 会先记录真实原因，再调用 finish(discard:false)，后者又统一写 user stop。按最后一条 stop 日志排查会被误导。RecordingSessionDiagnostics 仅包含音量档位；failedAppends、conversionFailures、tap 丢块和最后真实收样/写入时间没有进入终态结果，无法凭结束摘要判断丢音发生在哪层。

**解决方案：** 引入结构化 StopReason、primaryError、finishError、outcome。终态事件只形成一条权威汇总，保存 session/operation/source UID、每轨最后样本 PTS 与 append PTS、样本/字节/丢块/失败计数、重启次数、segment 清单、保存与恢复结果。系统事件不得伪装成 user stop；正常监控日志与终态摘要分开。

**回归验证：** 分别触发用户 stop、discard、系统 stop、麦克风失联、writer failure、退出超时；确保终态原因准确且存在可用健康计数。

**证据级别：** 源码控制流确认；尚未执行 macOS 媒体框架故障注入。

## 对上一轮 14 项修复的验收对应

| 上轮条目 | 本次判断 | 对应问题 |
|---|---|---|
| 1 麦克风连续失败/滑动窗口 | 窗口已实现，但恢复成功证据与绝对截止时间不可靠 | R04、R05、R17 |
| 2 AVCaptureSession 观察/恢复 | 有观察与重建，但初次启停队列、阻塞隔离和代际还未闭环 | R04、R17 |
| 3 SCStream didStopWithError | 已处理，但 stopped 流可能只更新 filter、并发恢复未隔离 | R02、R06 |
| 4 按轨健康检查 | 有音频监控，真实进度被伪造，写入问题路由错误，视频遗漏 | R05、R07、R08、R10 |
| 5 阻止空闲睡眠/唤醒检查 | 已见实现；不据此保证强制睡眠、合盖后的媒体连续性 | R04、R06、R09；需平台实测 |
| 6 fragments/失败保全/重启恢复 | 不可验收为可靠保全，存在删文件、片段时间线及索引/交接漏洞 | R01、R11–R16 |
| 7 正常退出先保存 | shouldTerminate 接入正确，但超时仍退出、尚未持久化交接 | R15、R16 |
| 8 PTS/补静音/静音写零 | 不可验收为正确时间线；仍读处理时钟、提交进度错误 | R09–R11 |
| 9 converter 跨块状态 | 正常连续输入有改进，格式切换/flush 仍需补齐 | R19 |
| 10 显式设备绑定 UID | 底层绑定有实现，上层仍可能静默替换选择 | R21 |
| 11 tap 复制/有界队列 | PCM 待处理块有上限，但控制消息和实时工作未完整有界化 | R18 |
| 12 audio-only minimumFrameInterval=1s | 源码已见设置；没有将其当作确定剩余漏洞 | 需长录制回归 |
| 13 generation/启停和 finish timeout | 有部分保护，停止回调和真正截止时间仍有关键缺口 | R02–R04、R17 |
| 14 UUID 文件名/拒绝覆盖 | 源码已见 UUID 短 token 与存在性拒绝；不是本次主要风险 | 应保留，补并发创建测试 |

## 建议修复顺序

### 第一批：防止修复过程反而丢数据

优先 R01、R02、R03、R12–R16。先保证非 discard 不破坏唯一原件、旧回调不接触新会话、每一段都有 durable owner、失败不能报完整成功。数据保全优先于自动重连和后台导出。

### 第二批：恢复必须由真实媒体进度证明

处理 R04–R08、R17。把 supervisor、capture lifecycle、writer ownership 分开。恢复是 `starting → awaitingSamples → healthy`，不是 API 回调成功即 healthy；按收样/转换/写入层分别恢复，并有不能被成功回调重置的失败截止时间。

### 第三批：时间线、实时性、边界与诊断

处理 R09–R11、R18–R22。基于真实采样 PTS；所有样本走统一提交入口；全局/片段时间线分层；实时桥接全路径有界；设备/屏幕选择不静默改变；终态诊断可核验。

## 最小结构调整

建议明确以下职责，名称可按项目风格调整：

```text
RecordingSupervisor
  └─ SessionContext(sessionID, immutableConfig, overallDeadline)
      ├─ CaptureContext(backendGeneration, nativeObject, awaitingSamples)
      ├─ TrackProgress(actualReceivePTS, actualCommitPTS, drops, failures)
      ├─ WriterSegment(index, globalStart, localCursor, sealedState)
      └─ FinishContext(operationID, capturedWriter, singleResumeGate)

Durable recording journal
  capturing → pendingFinalize → rawSaved → pendingExport → pendingImport → registered
```

关键不变量：非明确 discard 不删除唯一原件；旧 generation 不产生新会话副作用；每个 continuation 恰好完成一次；健康时间戳来自事实而非意图；每轨 PTS 单调且仅按成功提交前进；媒体在磁盘存在不等于可播放；UI 已拿到 URL 不等于持久化交接成功。

## macOS 15.7.3 发布前故障注入门槛

除每条发现附带的专用用例外，至少覆盖：USB/蓝牙多次插拔及默认设备切换；强制睡眠/唤醒和外接屏断连；音频-only 长录制与音视频双轨长录制；start/stop/finish 回调延迟或永不返回；writer notReady、append false、磁盘逼近阈值及真实写满；10 分钟后 rollover；好段加坏尾段；快速连续开始/取消；stop 后立即退出；后处理期间退出；逐个 journal 交接点终止进程。

每个用例必须同时核验 UI 状态、实际音视频时长、PTS、可解码样本、原始文件与 journal、重启恢复结果、最终日志。仅验证“编译通过”“没崩溃”“按钮变回 Record”或“文件大于零”都不足以验证数据完整性。

`movieFragmentInterval = 10s` 确实存在，但本次没有验证每种实际容器/编码组合在 kill 后可恢复到哪个边界。应对 m4a、mp4、mov 分别在片段边界前后杀进程，并实际解析/解码；不能把设置该参数等同于“最多只丢最后 10 秒”的保证。

`copyPCMBuffer`（MicrophoneCaptureEngine.swift:461–486）按 channel pointer 连续拷贝 frameLength，没有显式处理交错/stride。实际 tap 输入是否会出现该格式需确认；应补多声道/交错格式测试并考虑按 AudioBufferList.mDataByteSize 复制。本报告未据此断言当前设备必然越界或崩溃。

## 外部 API 契约核对

以下为 Apple 官方 API 资料，源码结论本身仍以附件行号为准。

- AVAssetWriter.cancelWriting：创建过的输出文件会被删除。`https://developer.apple.com/documentation/avfoundation/avassetwriter/cancelwriting%28%29`
- withThrowingTaskGroup：取消的子任务也必须结束，作用域才能返回。`https://developer.apple.com/documentation/swift/withthrowingtaskgroup%28of%3Areturning%3Aisolation%3Abody%3A%29`
- AVCaptureSession.startRunning / stopRunning：同步阻塞语义。`https://developer.apple.com/documentation/avfoundation/avcapturesession`；`https://developer.apple.com/documentation/avfoundation/avcapturesession/stoprunning%28%29`

这些资料与独立实验不能取代实际部署版本的 framework 回归测试，也不能确定最初那位用户的根因。
