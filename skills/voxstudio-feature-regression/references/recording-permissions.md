# 录制权限准备与 Computer Use 限制研究

研究日期：2026-10-01。针对同名VoxStudio位于`.build`、`/Applications`或切换签名渠道时的授权混淆。本任务只创建资料，没有改系统权限或实测点击系统授权弹窗。

## 已核实与尚未证明

| 结论 | 依据及限制 |
|---|---|
| System Settings可为具体app开关screen/system audio权限，用“+”选择app加入。 | [Apple支持](https://support.apple.com/en-sg/guide/mac-help/mchld6aa7d23/mac)；screen+audio与仅audio权限不同。 |
| 录制授权会有系统dialog；麦克风另需用户授权。 | [屏幕音频授权](https://support.apple.com/en-nz/guide/mac-help/mchl592e5686/mac)、[AVFoundation授权](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)。 |
| 名称/路径不足以判断身份，code signing requirement同样重要。 | [Apple PPPC](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web)包含标识和code requirement；[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)解释DR。仓库确认过同路径换签名时enabled但preflight失败，见[签名/TCC记录](../../voxstudio-debug-build/references/signing-and-tcc.md)。 |
| 内容选择器授权选中内容，不等于所有模式全局授权。 | [WWDC23 Privacy](https://developer.apple.com/videos/play/wwdc2023/10053/)介绍SCContentSharingPicker；仍须按本app各模式实际检查路径验证。 |
| 无法得出“所有macOS系统弹窗CUA均不能操作”的结论。 | 此次Apple一手资料没有提供这个普遍结论。当前Computer Use具备普通原生窗口AX/截图/点击能力，但未保证系统受保护UI可操作；本任务没有各版本弹窗实测。 |
| 不应以脚本静默修改TCC代替准备。 | Apple PPPC中screen/mic项描述拒绝控制，不能把MDM当作通用静默授权。此流程由人授权并实际验证。 |

具体“无法操作”要记录OS/build、dialog、AX/截图和工具错误/点击无变化的实际现象。没有实测就写“未验证”，不能扩大成平台通则。不要反复点击权限弹窗或绕过系统保护来证明可操作性。

## 先冻结目标身份

1. 记录target绝对路径，默认`/Users/adamwang/Project/subdub/voxella-studio-app/.build/VoxStudio.app`。
2. 退出旧实例，完成选定渠道构建。正常本地录制使用签名Developer ID debug包；ad-hoc不是TCC验收对象。检查：

   ```sh
   codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
   codesign -dv --verbose=4 "$TARGET_APP"
   codesign -dr - "$TARGET_APP"
   ```

   `TARGET_APP`是冻结的绝对路径；只报告必要身份字段，不输出环境secret/profile全文。
3. 启动并核对实际运行可执行路径。若复用了旧同bundle实例，退出所有VoxStudio再打开target。路径、签名模式、Team ID都要匹配；不能用Developer ID grant证明Apple Development/ad-hoc grant。
4. 同一路径换签名也需重核验。路径一致是本测试流程要求，不代表TCC内部仅按路径绑定。

## 人工准备

测试人员在macOS中执行，执行者等待并记录确认：

1. 退出所有VoxStudio。打开System Settings → Privacy & Security → Screen & System Audio Recording。
2. 若界面可查看路径，确认对应冻结target；同名但路径不可核对不算已通过。通过明确选择目标app的文件选择流程人工验证。
3. **路径不一致时删除旧/错误VoxStudio项，再加入待测target。** 使用该OS实际提供的移除控件（如选中后的“−”或可见菜单），只移除此app项。当前UI不支持移除/被管理时记录限制，交给用户/管理员，不reset整个TCC。
4. 点“+”，用文件选择器`⇧⌘G`输入target绝对路径（`.build`可能默认隐藏），选择实际`VoxStudio.app`，设置enabled，确认允许screen+system audio而非仅audio。同bundle合并同一行时记录明确选择路径，继续核签名与实录。
5. 需要mic的case单独在Microphone确认目标授权。纯system audio测试将mic设Off，防止把麦克风录到的声音当system audio。无需mic的case不额外申请。
6. Allow/Continue to Allow/Allow While Using、Quit & Reopen、认证、Touch ID/password等系统弹窗由本人处理，记录实际文字；密码/验证码不发到聊天/报告。USB设备Trust/解锁也交给本人。
7. 退出后从冻结target绝对路径重开；之后不重建/重签。“重启”通常指app；若系统明确要求重启Mac，由测试人员按提示处理并记录。
8. 用户确认下列信息；同一冻结身份与权限状态可复用，不逐case重复询问：

> 已完成本轮录制权限准备：app【绝对路径】，版本/build【值】，签名【值】；Screen & System Audio Recording【enabled，screen+audio】；Microphone【enabled/本轮不用】；旧错误项【无/已移除并加入目标】；系统弹窗【已处理/未出现】；已退出所有VoxStudio并从该路径重新打开。可录制【本轮指定测试窗口/区域/设备】。

人工确认前，相关case记Blocked-Permission，继续独立用例。确认后仍需真实录制证明权限有效。

## 实录验收与故障

- 在获授权测试窗口播放Downloads素材，用已知画面/音频标记。各相关模式录10–20秒，停止后外部播放并ffprobe核验。Display/App/Window/Region分别验收；Mobile Device另核USB、Trust、device audio。
- 必须有真实帧、合理尺寸/时长和所选音源。页面没有权限提示/Settings enabled都不是产物证据。
- 本仓库`RecordingScreenCaptureAuthorization`从target进程调用CGPreflight/CGRequest。另起Swift/Python/helper探测得到的是另一身份权限，不能代替目标检查。
- enabled仍拒绝时查运行路径/签名/DR、当前模式和必要日志。`Failed to match existing code requirement`/`-67050`是仓库已知身份匹配线索；不收集无关个人内容。
- 人工纠正并重启后最多一次受控重测；仍失败则据前置情况记Fail或Blocked-Environment，继续其他用例。不无限remove/re-add，不默认`tccutil reset`，不直接改TCC数据库。
- 如本轮实际发现不可操作dialog，记录OS/build、弹窗类型、工具错误、最后AX/经审查截图、人工处理和后续实录。普通内容选择器与系统隐私授权分别记录。

人工准备是此skill选择的可审查流程，不是对全部macOS弹窗技术能力的断言。
