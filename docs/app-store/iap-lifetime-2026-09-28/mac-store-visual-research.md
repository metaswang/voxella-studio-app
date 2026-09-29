# VoxStudio Lifetime 图片改版调研

调研日期：2026-09-28。审核提交继续暂停。

## 范围与观察方法

通过 Apple 的公开 Mac App Store 商品页查看前三张 Mac 截图，并保存浏览器截图。以下观察针对公开商品页素材；无法从这些页面确认开发者在 App Store Connect 的可选 IAP Image 字段中上传了什么。没有获取这些产品的转化率数据，设计判断不构成转化提升的测量结果。

| 样本 | 公开页面的视觉做法 | 可用于 VoxStudio 的设计原则 |
| --- | --- | --- |
| [Whisper Transcription / MacWhisper](https://apps.apple.com/us/app/whisper-transcription/id1668083311?platform=mac) | 用桌面窗口展示可编辑转录、项目列表、双语翻译；统一风景背景。 | 直接呈现声音转为可使用的文字这一结果，功能有具体载体。 |
| [DaVinci Resolve](https://apps.apple.com/us/app/davinci-resolve/id571213070?mt=12) | 用电影画面、多轨时间线、波形和剪辑界面呈现视频制作工作。 | 把成品画面与创作过程放在一起，使用户理解工具用途。 |
| [Screen Studio Kit: Screenshots](https://apps.apple.com/us/app/screen-studio-kit-screenshots/id6796242724?mt=12) | 用简短标题、实际编辑器和完成的设备展示图讲清用途；说明文案明确一次购买解锁的能力。 | 先表达创作结果，再说明买断价值；同时参考其温暖中性底色和清晰层次。 |

浏览器证据：research-whisper-mac.jpg、research-davinci-mac.jpg、research-screen-studio-kit-mac.jpg。

## Apple 对此字段的规则

来源：[Promoting your Apple In-App Purchases](https://developer.apple.com/app-store/promoting-in-app-purchases/)、[In-App Purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)、[Promote In-App Purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/promote-in-app-purchases)。

- IAP 宣传图规格：1024×1024，JPG 或 PNG，72 dpi、RGB、扁平化，外框没有预制圆角。
- Apple 建议宣传图不要使用截图、不要与应用图标混淆，也建议不要在图上叠加文字。图片通常以小尺寸显示；左下角可能覆盖应用图标。
- 公开 Mac 商品页的截图可以使用实际界面和文案，但不应把这种做法直接照搬为 IAP 宣传图。
- 当前内购推广说明标记为 iOS。上传该图片不代表会在 Mac App Store 获得与 iOS 相同的推广展示。
- Review Information 截图仅供审核，不在商店展示。用户提供的带价格截图保持为该字段的审核素材。

## 改版方向

以“视频成品 + 声音波形 + 转录/字幕”为主视觉，用小型无限符号作为终身使用权的辅助线索。采用温暖明亮的底色及鲜明的媒体内容，以适应小尺寸展示。制作原创编辑插画，避免做成虚构的软件界面或应用图标。

终身买断、无限新项目、免费软件升级由对应商品名称与描述说明。Lifetime 不包含云端 AI 点数，宣传图不表达无限云端生成或全包服务。

## 生成记录

- 使用内置 imagegen 工具，生成新图；不直接使用竞品截图作为输入。
- 完整提示词：lifetime-creative-v2-prompt.txt。
- 新图使用独立版本文件，保留原图及原审核截图。
- 该调研与生图不恢复提交审核。

## 最终文件与检查

- 新图：lifetime-creative-v2-1024.png，1024×1024 PNG、RGB、无透明通道、72 dpi、外框直角。
- imagegen 原始输出为 1254×1254；用 sips 进行等比例尺寸规范化，不增加、删除或重绘图内元素。
- 原始生成文件保留：/Users/adamwang/.codex/generated_images/01a0e5bf-e48a-79a3-ab1b-dcc396579300/exec-499e9dba-a1ac-42a2-83e8-daf5b351815f.png。
- 已目视确认：主视觉为视频、音频波形、转录/字幕符号；无限符号为辅助标记；无文字、价格、云端 AI 无限额度承诺或完整虚构应用窗口。
- 本轮交付为新生成的本地素材，尚未上传替换 App Store Connect 中的旧宣传图。未发送审核。
