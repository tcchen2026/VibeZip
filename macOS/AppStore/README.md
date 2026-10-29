# VibeZip App Store 提交资料

本次提交采用免费定价，暂不在法国分发。当前已生成的安装包为版本 **2026.10.29**、
构建 **3**，对应应用源码提交 `92053c9`。这些资料用于填写 App Store Connect；
保存仓库文档不会自动修改商店记录或发布应用。

## 基本信息

| 字段 | 填写内容 |
| --- | --- |
| App 名称 | VibeZip |
| 平台 | macOS |
| 版本 | 2026.10.29 |
| 构建版本 | 选择已完成处理的构建 3 |
| Bundle ID | org.vibezip.swift |
| 主要类别 | 工具（Utilities），与安装包一致 |
| 次要类别 | 可留空 |
| 主要语言 | 建议英语（美国）；使用已有 App 记录的设置 |
| 本地化 | 英语、简体中文、日语、韩语 |
| 价格 | 免费 |
| 法国分发 | 否；同时在“定价与销售范围”中取消法国 |
| 客服邮箱 | mac-service@vibezip.org |
| 登录 | 不需要 |
| 内购或订阅 | 无 |
| 发布方式 | 建议手动发布，审核通过后由你点击发布 |
| 版权 | 当前应用元数据为 `2026 VibeZip contributors`；提交前确认应填的实际权利人名称 |

SKU 和 Apple ID 沿用已创建的 App 记录，不需要重新创建。App Store 的版权字段会自动添加
版权符号。名称及副标题最多 30 字符；见 [App 信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)。

## 网址

文档需发布到公开仓库的 `main` 分支后，以下地址才可用于提交；使用未登录的浏览器确认能打开。

| 字段 | URL |
| --- | --- |
| 技术支持网址 | https://github.com/tcchen2026/VibeZip/blob/main/SUPPORT.md |
| 隐私政策网址 | https://github.com/tcchen2026/VibeZip/blob/main/PRIVACY.md |
| 营销网址（可选） | https://github.com/tcchen2026/VibeZip |

支持页面包含真实客服邮箱。无需为这些页面另行购买域名。

## 商店文案

按对应字段复制下列纯文本文件中的内容，不要把字段标题一起粘贴。

- [英语](en-US.txt)
- [简体中文](zh-Hans.txt)
- [日语](ja.txt)
- [韩语](ko.txt)

推广文本最多 170 字符，描述最多 4,000 字符，关键词最多 100 个 UTF-8 字节。
首次发布没有“此版本的新增内容”字段。见 [平台版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

## App 隐私与年龄分级

按当前应用行为填写 **“不收集数据”**：文件、密码和预览均在本机处理，无应用内分析统计、
广告或网络上传。自行发送的客服邮件和公开 GitHub Issue 已在隐私政策中单独说明。
Apple 将仅在设备上处理、未传出的信息与数据收集区分；见
[App 隐私说明](https://developer.apple.com/app-store/app-privacy-details/)。

年龄分级问卷中，当前应用没有广告、聊天、社交内容、面向其他用户发布内容的功能、
内置任意网页浏览、购买随机物品或赌博，也没有提供成人、暴力、医疗健康等内容。
这些项目按“无”或“否”填写；家长控制和年龄验证也选“否”。本地预览用户自己的文件
不构成面向公众的用户内容分发，GitHub 链接由外部浏览器打开。最终年龄分级由系统生成，
不将本应用设置为儿童专用 App。见
[年龄分级定义](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)。

## 加密申报

本次法国分发选择“否”，并保持销售地区设置一致。当前加密类型的技术建议是
“代替或补充 Apple 操作系统加密的标准算法”，这不是已获批准的出口分类或豁免。
应用使用内置 7-Zip 实现进行压缩包加解密，包含 AES，也兼容 ZipCrypto 和旧版 RAR
加密内容；如审核要求算法清单，应完整提供这些内容，不能写成“仅使用 Apple 系统加密”
或“仅包含 AES”。是否需补充材料以完整问卷和 Apple 的个案要求为准。
本次没有预填 CCATS、法国声明编号或 `ITSEncryptionExportComplianceCode`。

法国声明与发行地区的关系见
[Apple 加密文稿要求](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)。
未来开放法国前，需重新完成相关申报和文稿步骤。

## App 审核信息

“需要登录”不勾选。将 [英文审核说明](review-notes.txt) 粘贴到备注字段；
[演示压缩包](review-sample.zip) 可作为审核附件，包含公开演示文本和一个嵌套 ZIP，无需密码。

审核联系人姓名和带国际区号的电话号码由你在 App Store Connect 中填写，不存入公开仓库。
审核邮箱可填 `mac-service@vibezip.org`。备注字段最多 4,000 字节；见
[审核信息字段](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

## 截图

至少上传 1 张、最多 10 张实际应用截图，PNG 或 JPEG，不能带 Alpha 通道或透明度。
Mac 支持 1280×800、1440×900、2560×1600 或 2880×1800 像素；建议统一使用 2560×1600。
见 [Apple 截屏规范](https://developer.apple.com/cn/help/app-store-connect/reference/app-information/screenshot-specifications/)。

建议准备以下三个场景，使用演示文件并隐藏个人目录和信息：

1. 已打开 ZIP 的详情视图，展示文件列表和地址栏。
2. 双面板，一侧是压缩包，另一侧是已授权的目标文件夹。
3. 嵌套 ZIP 和文本预览。

这些截图尚需从应用实际界面采集；文案不替代截图。App 预览视频可留空。

## 提交前由账户持有人完成

- 填写审核联系人姓名和电话，确认版权主体以及适用的许可协议；保留应用已有 LGPL 和第三方许可声明。
- 上传实际截图，确认支持和隐私链接无需登录即可访问。
- 确认免费价格和最终销售地区，排除法国；其他地区的账户或上架资格按 App Store Connect 的实际要求处理。
- 若向其他欧盟国家分发，按真实经营情况填写 DSA 经营者身份，不能仅因免费就判断为非经营者。
  见 [Apple 欧盟 DSA 要求](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)。
- 在 App Store Connect 中选择处理完成的构建 3，完成页面要求的项目后添加至审核并提交；上传安装包本身不会发布 App。
