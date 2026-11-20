import SwiftUI

/// What the Mac App Store edition shows when the sandbox stands in the way. The direct download never shows these.

/// A project whose folder the sandbox does not open (any more): one click asks for it.
struct AccessNeededView: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        NoticeView(symbol: "lock.fill",
                   title: L("\(appName) needs access to \(project.name)", "\(appName) 需要访问 \(project.name)"),
                   detail: L("The App Store version can open only the folders you choose. Choose this repository's folder, or a folder above it to cover several repositories at once.",
                             "App Store 版只能打开你选择过的文件夹。请选择这个仓库所在的文件夹，或者选它的上级文件夹，一次覆盖多个仓库。"),
                   note: project.url.path) {
            NoticeButton(title: L("Grant Access…", "授权访问…"), symbol: "lock.open", isPrimary: true) { store.grantAccess(to: project) }
            NoticeButton(title: L("Remove from List", "从列表移除"), symbol: "minus.circle") { store.remove(project) }
        }
    }
}

/// No git the sandbox lets the app run. The system's /usr/bin/git only forwards to the developer tools, and refuses
/// in the sandbox, so the tools themselves have to be installed.
struct GitMissingView: View {
    @Environment(AppStore.self) private var store
    @State private var copied = false

    var body: some View {
        NoticeView(symbol: "shippingbox",
                   title: L("\(appName) needs Git", "\(appName) 需要 Git"),
                   detail: L("It uses the Git in Apple's Command Line Tools (or Xcode, or Homebrew). To install them, open Terminal and run the command below, then check again.",
                             "DiffCode 使用 Apple 命令行工具（或 Xcode、Homebrew）里的 Git。请打开“终端”运行下面的命令安装，装好后再检查一次。"),
                   note: "xcode-select --install") {
            NoticeButton(title: copied ? L("Copied · Paste It in Terminal", "已复制 · 在终端里粘贴") : L("Copy Command and Open Terminal", "复制命令并打开终端"),
                         symbol: "terminal", isPrimary: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("xcode-select --install", forType: .string)
                copied = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            NoticeButton(title: L("Check Again", "重新检查"), symbol: "arrow.clockwise") { checkAgain() }
        }
        // Back from installing them: no need to look for the button.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkAgain() }
    }

    private func checkAgain() {
        Git.relocateExecutable()
        store.gitMissing = !Git.isAvailable
        if !store.gitMissing { store.projects.forEach { $0.refresh() } }
    }
}

/// A centered notice with a couple of buttons, in the style of the welcome screen.
private struct NoticeView<Buttons: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var note: String?
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.ui(size: 40, weight: .light))
                .foregroundStyle(Color.difText3)
            VStack(spacing: 8) {
                Text(title)
                    .font(.ui(size: 17, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.ui(size: 12, design: .monospaced))
                        .foregroundStyle(Color.difText2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                }
            }
            .frame(maxWidth: 440)
            HStack(spacing: 10) { buttons() }
                .titlebarClickGuard()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
    }
}

private struct NoticeButton: View {
    let title: String
    let symbol: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.ui(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isPrimary ? Color.difSelection : Color.difChip))
            .foregroundStyle(Color.difText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
