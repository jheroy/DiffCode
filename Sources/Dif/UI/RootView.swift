import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var settings = store.settings
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        if store.sidebarVisible {
                            SidebarView()
                                .frame(width: settings.sidebarWidth)
                                .transition(.move(edge: .leading))
                            ResizeHandle(width: $settings.sidebarWidth, range: Settings.sidebarRange, islandGap: true) { settings.save() }
                        }
                        if store.gitMissing {
                            GitMissingView()
                                .islandCard(background: .difWindow)
                        } else if let project = store.currentProject {
                            if project.needsAccess {
                                AccessNeededView(project: project)
                                    .islandCard(background: .difWindow)
                            } else {
                                if store.listVisible {
                                    ProjectPanel(project: project)
                                        .frame(width: settings.listWidth)
                                    ResizeHandle(width: $settings.listWidth, range: 236...620, islandGap: true) { settings.save() }
                                }
                                ViewerPanel(project: project)
                                    .islandCard(background: .difWindow)
                            }
                        } else {
                            WelcomeView()
                                .islandCard(background: .difWindow)
                        }
                    }
                    // Never taller than the terminals leave room for, nor wider than the window. Whatever cannot
                    // shrink that far is cut at the bottom or the right, rather than pushing the terminals off the
                    // window or sideways, and the other columns down from the top.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    // The terminals run the full width of the window, under the sidebar too.
                    if let project = store.currentProject, store.terminals.isVisible {
                        // They may take most of the window, but always leave the columns above what they cannot do
                        // without: the sidebar's least is the most of them, and the diff gets a strip as wide.
                        let ceiling = max(120, Double(proxy.size.height - SidebarView.minimumHeight(titlebar: store.titlebarHeight) - IslandStyle.gap))
                        HorizontalResizeHandle(height: $settings.terminalHeight, range: 120...ceiling, islandGap: true) { settings.save() }
                        TerminalPanel(project: project)
                            .frame(height: min(settings.terminalHeight, ceiling))
                            .islandCard(background: .difWindow)
                    }
                }
            }
            .padding(IslandStyle.outerPadding)

            if let session = store.mergeSession {
                ThreeWayMergeView(session: session)
                    .zIndex(5)
            }

            if let popup = store.popup {
                PopupLayer(popup: popup)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
                    .zIndex(10)
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text(toast)
                            .font(.ui(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.difText)
                        if let action = store.toastAction {
                            Button {
                                store.dismissToast()
                                action.handler()
                            } label: {
                                Text(action.title)
                                    .font(.ui(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.difAccent)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.difElevated).shadow(color: .black.opacity(0.3), radius: 12, y: 4))
                    .overlay(Capsule().strokeBorder(Color.difHairline, lineWidth: 1))
                    .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Only a toast with a button takes clicks; a plain one never gets in the way of what is under it.
                .allowsHitTesting(store.toastAction != nil)
                .zIndex(20)
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.difAccent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.difAccent.opacity(0.08))
                    .padding(10)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }
        }
        .background {
            Color.difIslandFrame
            WindowDragArea()
        }
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.fileURL(from: provider) { urls.append(url) }
                }
                store.addProjects(urls)
            }
            return true
        }
    }
}

extension RootView {
    /// The file a dropped item stands for.
    @MainActor
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
