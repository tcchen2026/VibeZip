# VibeZip design documents

VibeZip is a 7-Zip fork with a native macOS archive manager. Its purpose is to
make large and nested archives usable through a familiar file manager with one or two browser panes, with explicit folder authorization and a path to Mac App Store
distribution. The app uses the archive engine directly and follows the macOS app
language, with English as its fallback.

These documents describe the implementation in this repository and the reasons
for its main design choices. Sections named **Open work** identify capabilities
or release tasks that are not complete. The Mac App Store is a distribution
target, not a statement that the current build has been submitted or approved.

| Document | Read when changing |
| --- | --- |
| [Architecture](architecture.md) | Module boundaries, sessions, threading, metadata or native integration |
| [Archive operations](archive-operations.md) | Nested archives, extraction, updates, cancellation or data integrity |
| [Sandbox and security](sandbox-and-security.md) | Folder authorization, file access, preview, passwords or local data |
| [Interface](interface.md) | Navigation, search, commands, dialogs, progress or visual layout |
| [ZIP filenames](zip-filenames.md) | Legacy filename decoding or the ZIP handler extension |
| [Development and release](development.md) | Builds, focused verification, source packaging or release preparation |
| [DMG distribution](distribution.md) | Manual GitHub Actions builds, signing secrets, notarization and sandbox verification |
| [Design integration](design-integration.md) | Complete imported reference and the shipping UI's integration status |

The project purpose, design principles and source map are summarized in
[AGENTS.md](../AGENTS.md). User-facing instructions are in the
[macOS README](../macOS/README.md).

## Keeping these documents useful

Describe observable behavior and ownership boundaries, and link to the relevant
source. When a behavior changes, update its document in the same change. Keep
implementation limits distinct from future ideas; no benchmark or release
guarantee should be inferred from a design goal.

Examples should use generated fixtures or generic filenames. Keep credentials,
local machine paths, private archives, operation logs and discussion transcripts
out of public documentation and test fixtures.
