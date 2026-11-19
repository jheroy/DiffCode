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
                    HStack(spacing: 0) {
                        if store.sidebarVisible {
                            SidebarView()
                                .frame(width: settings.sidebarWidth)
                                .islandCard(background: .difSidebar)
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
                                        .islandCard(background: .difPanel)
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
                    // The terminals run the full width of the window, under the sidebar too.
                    if let project = store.currentProject, store.terminals.isVisible {
                        // They may take most of the window, but always leave the diff a strip to live in.
                        let ceiling = max(120, Double(proxy.size.height) - 200)
                        HorizontalResizeHandle(height: $settings.terminalHeight, range: 120...ceiling, islandGap: true) { settings.save() }
                        TerminalPanel(project: project)
                            .frame(height: min(settings.terminalHeight, ceiling))
                            .islandCard(background: .difWindow)
                    }
                }
            }
            .padding(IslandStyle.outerPadding)

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
