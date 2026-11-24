# 官网下载版发布（Developer ID + Sparkle + Cloudflare R2）

两条线分开：

| 命令 | 做什么 | 产物（`dist/macos/`） |
| --- | --- | --- |
| `./build_macos.sh` | 构建、Developer ID 签名（由内向外，不用 `--deep`）、Hardened Runtime、公证并装订；再打 root-based `.pkg`，同样签名公证 | `DiffCode.app`、`DiffCode.app.zip`、`DiffCode-<版本>.pkg`、`SHA256SUMS.txt` |
| `./upgrade_macos.sh` | （默认先重新构建）用 Sparkle 私钥签 `.app.zip`，生成 `appcast.xml`，上传到 R2，再从公网下载回来校验 | 远端 `diffcode/macos/stable/appcast.xml` 和 `DiffCode-<版本>-<build>.app.zip` |

## 第一次使用

1. `release/macos/.macos.env`：从 `.macos.env.example` 复制，填团队、公证 API Key、R2 桶和 access key（同一个桶可以放几个应用，各用各的 `R2_PREFIX` 目录）。文件被 git 忽略，权限建议 600。
2. `release/macos/AppInfo.local.env`：从 `AppInfo.local.env.example` 复制，填 Sparkle 的 `SUFeedURL` 和 `SUPublicEDKey`，构建时写进 Info.plist。EdDSA 私钥放在登录钥匙串里（Sparkle 的 `generate_keys` 生成，钥匙串条目名为 `https://sparkle-project.org`）。第一次签名时 macOS 会弹窗问是否允许 `sign_update` 读取钥匙串，点「始终允许」。
3. 公证 Key：`NOTARY_KEY_PATH` 是相对路径时按 `.macos.env` 所在目录解析；`.p8` 放在仓库外时，用 `SHARED_NOTARY_KEY_PATH` 写它的绝对路径。不要把 `.p8` 复制进仓库。

## 发一个新版本

1. 改 `release/version.env`：`MARKETING_VERSION` 和 `BUILD_NUMBER` 都要比线上大（脚本会下载线上 appcast 比较，不大就失败；紧急情况 `SKIP_REMOTE_VERSION_CHECK=1`）。
2. 可选：写更新说明 `release/macos/release-notes/<版本>.html`，用 `RELEASE_NOTES_FILE=…` 传入。
3. `DRY_RUN=1 ./upgrade_macos.sh` 先看一遍签名和 appcast；没问题再 `./upgrade_macos.sh`。
4. 首次下载的用户用 `DiffCode-<版本>.pkg`（或 `DiffCode.app.zip`）；装好后的版本会自己从 appcast 更新。

线上 appcast：<https://r2-public.nanshanbei.com/diffcode/macos/stable/appcast.xml>（0.1.0 (1) 于 2026-11-13 发布；0.2.0 (2) 于 2026-11-14 发布；0.3.0 (3) 于 2026-11-14 发布；0.3.1 (4) 于 2026-11-15 发布；0.3.2 (5) 于 2026-11-16 发布，Intel 版从这一版开始（更新源 `diffcode/macos/stable-intel/appcast.xml`）；0.4.0 (7) 于 2026-11-17 发布；0.4.1 (8) 于 2026-11-18 发布；0.4.2 (9) 于 2026-11-18 发布；0.4.3 (10) 于 2026-11-18 发布；0.4.4 (11) 于 2026-11-20 发布；当前是 0.4.5 (12)，2026-11-22 发布，更新说明见 `release-notes/0.4.5.html`；GitHub Release 上传同一份 zip 和 pkg，固定文件名 `DiffCode.zip` / `DiffCode.pkg`，Intel 版是 `DiffCode-Intel.zip` / `DiffCode-Intel.pkg`，Windows 的安装包、zip 和 `SHA256SUMS-windows.txt` 由 `.github/workflows/windows.yml` 在发布后自动附加，见 `windows/PORTING.md`）。

## Intel 版

Apple Silicon 版只含 arm64，Intel Mac 打不开。Intel 版单独构建、单独发布，Apple Silicon 版不因此变大：

1. `ARCH=x86_64 ./build_macos.sh`：产物在 `dist/macos-intel/`，同样签名、公证、装订。
2. `DRY_RUN=1 ARCH=x86_64 ./upgrade_macos.sh`，没问题再 `ARCH=x86_64 ./upgrade_macos.sh`：发布到 Intel 自己的更新源，R2 前缀是 `R2_PREFIX` 后面加 `-intel`（线上是 `diffcode/macos/stable-intel/appcast.xml`），Intel 版应用的 `SUFeedURL` 指向这里。规则见 `release/macos/scripts/arch_lane.sh`。
3. GitHub Release 上的文件名固定为 `DiffCode-Intel.pkg` / `DiffCode-Intel.zip`，校验和与 Apple Silicon 版的写在同一个 `SHA256SUMS.txt` 里。

## 脚本会拦下的问题

- 应用里没有 `SUFeedURL` / `SUPublicEDKey`（发出去就再也收不到更新），或 `SUFeedURL` 和这次要发布的 appcast 地址不一致。
- `R2_PREFIX` 为空：appcast 会落到桶的根目录，桶里放着别的应用时可能覆盖它们的文件。
- Sparkle 签名和应用内置的 `SUPublicEDKey` 不是一对（`verify_ed_signature.swift` 独立校验，`sign_update --verify` 发现不了这种情况）。
- 应用没公证、没装订，或 zip 里的不是 `dist/macos` 里这个版本。
- 构建出的架构不对（`lipo -archs`），或要把一种架构的应用发到另一种架构的更新源：Intel 用户会被「更新」成打不开的版本，反过来也一样。
- 链接了 Homebrew 的动态库、带 `get-task-allow`、`Installer.xpc` 被沙盒化、嵌套组件不是本团队签名。
- 上传后公网 appcast 指向的文件不对、长度不符、签名校验失败。

App Store 版不走这里，见 `release/appstore/`。
