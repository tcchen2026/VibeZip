# VibeZip Support

VibeZip is a free archive manager for macOS 26 or later. For help, bug reports or
feature requests, email **[mac-service@vibezip.org](mailto:mac-service@vibezip.org)**.
You can also report reproducible problems in
[GitHub Issues](https://github.com/tcchen2026/VibeZip/issues).

## Reporting a problem

Include your VibeZip version from About VibeZip, your macOS version, the archive
format, the steps that caused the problem and any error message. A small sample
created specifically to reproduce the issue can help. Remove personal information
from screenshots, and do not send archive passwords or confidential files.
GitHub issues are public; use email for information you do not want to post publicly.

## Common questions

### Opening files and granting access

Choose a folder when you first open VibeZip. The app uses macOS App Sandbox and
can access locations you authorize. Editing an archive may require access to its
containing folder so VibeZip can prepare and verify an updated copy before
replacing the original. Manage saved permissions in Settings → Folder Access.

### Creating and editing archives

Select files and use Add to create a ZIP or 7z archive. To add files to an existing
writable archive, open it and drag files or folders from Finder into the file
list. Updates to existing names ask for confirmation. RAR archives and
multivolume archives are read only; VibeZip does not create RAR archives.

### Passwords

Use the archive's existing password to open encrypted content. VibeZip cannot
recover forgotten passwords. Passwords stay in memory and can be cleared from
the Tools menu or by quitting the app.

### Temporary storage

Previewing files and opening nested archives can create temporary copies,
including decrypted files. Settings → General shows their total size and provides
Show Temporary Folder and Clean Temporary Files. Cleanup keeps files that are
still in use. Optional recovery copies are off by default; when enabled, they
also use temporary storage and may be removed by cleanup or macOS.

### Default archive app

Settings → General → Set VibeZip as Default can apply the `.zip/.7z/.rar` preset
or a single format. macOS may ask you to confirm each association.

See the [usage guide](macOS/README.md) and [privacy policy](PRIVACY.md) for details.

## 中文支持

VibeZip 是适用于 macOS 26 及以上版本的免费压缩文件管理工具。
客服邮箱：**[mac-service@vibezip.org](mailto:mac-service@vibezip.org)**。

反馈时请提供 VibeZip 版本、macOS 版本、压缩包格式、操作步骤和错误提示。
截图请遮盖个人信息，不要发送压缩包密码或机密文件。GitHub Issue 为公开内容。

- 首次启动请选择文件夹。编辑压缩包时，可能需要授权其所在文件夹，以便生成和校验更新后的副本。
- 将 Finder 中的文件拖入已打开的可写压缩包即可添加文件。RAR 和分卷压缩包仅支持读取。
- 密码仅保存在内存中，可通过“工具”菜单清除，或退出应用清除；应用无法恢复遗忘的密码。
- 在“设置 → 通用”中查看临时文件占用、打开临时目录或清理未使用的临时文件。
- 可选恢复副本默认关闭，并非永久备份；启用后也可能被临时文件清理或 macOS 移除。
- 在“设置 → 通用”中可将 VibeZip 设为 ZIP、7z、RAR 的默认打开方式。

更多说明见[使用指南](macOS/README.md)和[隐私政策](PRIVACY.md)。
