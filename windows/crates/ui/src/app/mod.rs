//! The app: its state, the work it runs in the background, and every view.
//!
//! `App` is the store: the project list, the viewer, the popups and the dialogs. Models that run work in the
//! background (the viewer, each project) own their jobs and report back through events, which the app drains every
//! frame; views are functions that draw the state and change it directly.

pub mod branch_actions;
pub mod change_tree;
pub mod commands;
pub mod commit_actions;
pub mod dialog;
pub mod edits;
pub mod file_tree;
pub mod git_graph;
pub mod history_actions;
pub mod history_edit_actions;
pub mod jobs;
pub mod partial;
pub mod project;
pub mod project_tree;
pub mod search;
pub mod settings;
pub mod stash_actions;
pub mod terminal;
pub mod update;
pub mod viewer;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use change_tree::ChangeRow;
use dialog::DialogRequest;
use file_tree::TreeRow;
use jobs::Jobs;
use project::{Project, ProjectEvent, ProjectId, ProjectTab};
use settings::{Appearance, Settings};
use viewer::{Viewer, ViewerEvent};

use crate::core::diff::{DiffRequest, Source};
use crate::core::git::{self, FileChange};
use crate::core::lang::l;
use crate::core::lf;
use crate::geom::Point;
use crate::platform::{Platform, Program};
use crate::theme::Theme;
use crate::ui::{Id, Ui};

/// Something to run with the whole app, handed back by a model that cannot reach it.
pub type AppCallback = Box<dyn FnOnce(&mut App)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Popup {
    QuickOpen,
    FindInPath,
    GoToLine,
    Keymap,
    Settings,
    /// Branches and the commit graph, dropped down from the branch button.
    GitGraph,
    /// A question or notice (`App::dialog`).
    Dialog,
}

/// The widgets the app moves the keyboard to by name.
pub mod ids {
    use crate::ui::Id;

    pub fn canvas() -> Id {
        Id::new("canvas")
    }
    pub fn tree() -> Id {
        Id::new("tree")
    }
    pub fn list() -> Id {
        Id::new("list")
    }
    pub fn log_files() -> Id {
        Id::new("log-files")
    }
    pub fn commit_message() -> Id {
        Id::new("commit-message")
    }
    pub fn find_field() -> Id {
        Id::new("find-field")
    }
    /// The query field of whichever popup is open.
    pub fn popup_field() -> Id {
        Id::new("popup-field")
    }
    pub fn graph() -> Id {
        Id::new("git-graph")
    }
    pub fn graph_branches() -> Id {
        Id::new("git-graph-branches")
    }
    pub fn dialog() -> Id {
        Id::new("dialog")
    }
    /// A terminal pane's keyboard focus.
    pub fn terminal(id: crate::terminal::SessionId) -> Id {
        Id::new("terminal").with(id)
    }
}

/// A button offered next to a toast, e.g. "Undo".
pub struct ToastAction {
    pub title: String,
    pub handler: AppCallback,
}

pub struct Toast {
    pub text: String,
    pub action: Option<ToastAction>,
    pub until: Instant,
}

/// A context menu, or a menu dropped down from a button.
pub struct Menu {
    /// Where it opens (window coordinates, its top left).
    pub at: Point,
    pub items: Vec<MenuItem>,
    pub hovered: Option<usize>,
    /// How far a menu taller than the window is scrolled.
    pub scroll: crate::widgets::Scroll,
    /// An item to bring into view on the next frame: the one the keyboard moved to, or the current choice.
    pub reveal: Option<usize>,
}

impl Menu {
    pub fn new(at: Point, items: Vec<MenuItem>) -> Self {
        Menu { at, items, hovered: None, scroll: Default::default(), reveal: None }
    }
}

pub struct MenuItem {
    pub title: String,
    pub shortcut: String,
    pub enabled: bool,
    pub checked: bool,
    pub separator: bool,
    pub action: Option<AppCallback>,
}

impl MenuItem {
    pub fn new(title: impl Into<String>, action: impl FnOnce(&mut App) + 'static) -> Self {
        MenuItem { title: title.into(), shortcut: String::new(), enabled: true, checked: false, separator: false, action: Some(Box::new(action)) }
    }

    pub fn separator() -> Self {
        MenuItem { title: String::new(), shortcut: String::new(), enabled: false, checked: false, separator: true, action: None }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.enabled = !disabled;
        self
    }

    pub fn checked(mut self, checked: bool) -> Self {
        self.checked = checked;
        self
    }

    pub fn shortcut(mut self, shortcut: impl Into<String>) -> Self {
        self.shortcut = shortcut.into();
        self
    }
}

/// What the app needs the window or the system for, done at the end of the frame.
pub enum PlatformRequest {
    PickFolder { title: String, then: Box<dyn FnOnce(&mut App, PathBuf)> },
    OpenUrl(String),
    Reveal(PathBuf),
    Copy(String),
    /// Flash the taskbar button: a terminal rang while DiffCode was behind other windows.
    Attention,
    /// Drag these files out of the window.
    DragFiles(Vec<PathBuf>),
    Quit,
}

/// One rollback or delete that can still be taken back.
pub struct UndoItem {
    pub record: crate::core::working_tree::Record,
    pub project: ProjectId,
    /// What it was, for the toast: "Rolled back 3 files".
    pub summary: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecentFile {
    pub project: ProjectId,
    pub path: String,
}

pub struct App {
    pub settings: Settings,
    pub viewer: Viewer,
    pub projects: Vec<Project>,
    pub selected: Option<ProjectId>,
    next_project_id: ProjectId,
    /// The work tree that was selected when DiffCode last quit, until git lists it again.
    awaited_selection: Option<PathBuf>,
    pub jobs: Jobs<App>,
    pub popup: Option<Popup>,
    pub sidebar_visible: bool,
    pub list_visible: bool,
    pub toast: Option<Toast>,
    pub dialog: Option<DialogRequest>,
    pub dialog_focus: bool,
    pub menu: Option<Menu>,
    pub memory_mb: f64,
    memory_read: Option<Instant>,
    pub recent: Vec<RecentFile>,
    /// Rollbacks and deletes that can still be undone, oldest first.
    pub undo_stack: Vec<UndoItem>,
    /// One edit at a time: a second click while git is still working is ignored.
    pub is_applying_edit: bool,
    pub requests: Vec<PlatformRequest>,
    /// Where the keyboard goes at the start of the next frame.
    pub focus_request: Option<Id>,
    /// The widget with the keyboard, as of the start of this frame.
    pub focus: Option<Id>,
    /// Where the keyboard was before a popup opened, to give it back.
    focus_before_popup: Option<Id>,
    panels_before_maximize: Option<(bool, bool)>,
    /// The change under the pointer when the viewer's context menu opened.
    pub context_hunk: Option<usize>,
    pub system_dark: bool,
    pub window_visible: bool,
    started: bool,
    pub go_to_line: crate::text_field::TextField,
    pub settings_open_section: usize,
    pub quick_open: search::QuickOpen,
    pub find_in_path: search::FindInPath,
    pub git_graph: git_graph::GitGraph,
    pub terminals: terminal::Terminals,
    /// Where each project's branch label sits in the sidebar, for the Git graph to hang from.
    pub branch_label_anchors: HashMap<ProjectId, Point>,
    /// When Shift was last pressed on its own, for double Shift.
    pub last_shift: Option<Instant>,
    /// A clipboard command picked in a menu, for the canvas to run where the clipboard is.
    pub pending_clipboard: Option<ClipboardCommand>,
    /// The keymap reference's filter.
    pub keymap_filter: crate::text_field::TextField,
    /// The user agreed to quit and lose what could not be saved.
    pub quit_confirmed: bool,
    /// No Git was found: the window shows how to get it.
    pub git_missing: bool,
    /// What the views remember between frames (scroll positions and the like).
    pub views: crate::views::ViewState,
    /// A folder is being dragged over the window.
    pub drop_targeted: bool,
    /// Width the window's caption buttons take at the right of the top bar (0 with a system title bar).
    pub caption_width: f32,
    /// Newer releases (Windows only).
    pub update: update::Updates,
    /// The default monospace face and the installed ones, for the font settings; read when Settings opens.
    pub font_choices: Option<(String, Vec<String>)>,
    /// The app's icon for the welcome screen, with the pixel size it was picked for.
    pub app_icon: Option<(u32, crate::paint::ImageSource)>,
    /// When to search the Log, once typing in its search field pauses.
    pub log_search_at: Option<(ProjectId, Instant)>,
    /// The system's language is Chinese (for the Language setting's System choice).
    pub system_chinese: bool,
    /// The window has the keyboard (a bell elsewhere flashes the taskbar).
    pub window_active: bool,
    /// The quit under way is a restart: DiffCode opens again once it has closed.
    pub restarting: bool,
}

impl App {
    pub fn new(settings: Settings) -> Self {
        let mut viewer = Viewer::default();
        viewer.unified = settings.unified;
        App {
            settings,
            viewer,
            projects: Vec::new(),
            selected: None,
            next_project_id: 1,
            awaited_selection: None,
            jobs: Jobs::default(),
            popup: None,
            sidebar_visible: true,
            list_visible: true,
            toast: None,
            dialog: None,
            dialog_focus: false,
            menu: None,
            memory_mb: 0.0,
            memory_read: None,
            recent: Vec::new(),
            undo_stack: Vec::new(),
            is_applying_edit: false,
            requests: Vec::new(),
            focus_request: None,
            focus: None,
            focus_before_popup: None,
            panels_before_maximize: None,
            context_hunk: None,
            system_dark: true,
            window_visible: true,
            started: false,
            go_to_line: Default::default(),
            settings_open_section: 0,
            quick_open: Default::default(),
            find_in_path: Default::default(),
            git_graph: Default::default(),
            terminals: Default::default(),
            branch_label_anchors: HashMap::new(),
            last_shift: None,
            pending_clipboard: None,
            keymap_filter: Default::default(),
            quit_confirmed: false,
            git_missing: false,
            views: Default::default(),
            drop_targeted: false,
            caption_width: 0.0,
            update: Default::default(),
            font_choices: None,
            app_icon: None,
            log_search_at: None,
            system_chinese: false,
            window_active: true,
            restarting: false,
        }
    }

    pub fn current_project(&self) -> Option<&Project> {
        let id = self.selected?;
        self.projects.iter().find(|p| p.id == id)
    }

    pub fn current_project_mut(&mut self) -> Option<&mut Project> {
        let id = self.selected?;
        self.projects.iter_mut().find(|p| p.id == id)
    }

    pub fn project(&self, id: ProjectId) -> Option<&Project> {
        self.projects.iter().find(|p| p.id == id)
    }

    pub fn project_mut(&mut self, id: ProjectId) -> Option<&mut Project> {
        self.projects.iter_mut().find(|p| p.id == id)
    }

    /// Runs `f` with the current project and the rest of the app.
    pub fn with_current<R>(&mut self, f: impl FnOnce(&mut App, ProjectId) -> R) -> Option<R> {
        let id = self.selected?;
        Some(f(self, id))
    }

    pub fn is_dark(&self) -> bool {
        match self.settings.appearance {
            Appearance::System => self.system_dark,
            Appearance::Light => false,
            Appearance::Dark => true,
        }
    }

    // MARK: Lifecycle

    fn bootstrap(&mut self, platform: &mut dyn Platform) {
        let waker = platform.waker();
        self.jobs.set_waker(waker.clone());
        self.terminals.set_waker(waker.clone());
        self.viewer.jobs.set_waker(waker);
        for path in self.settings.projects.clone() {
            if path.is_dir() {
                self.install(path);
            }
        }
        let last = self.settings.selected_project.clone();
        // A work tree was selected: it is listed once its repository has been asked for its work trees.
        if last.as_ref().is_some_and(|l| !self.projects.iter().any(|p| same_path(&p.url, l))) {
            self.awaited_selection = last.clone();
        }
        self.selected = self.projects.iter().find(|p| Some(&p.url) == last.as_ref()).or(self.projects.first()).map(|p| p.id);
        for p in &mut self.projects {
            p.refresh();
        }
        self.sync_viewer();
        // Without Git there is nothing to show; the panels make way for how to get it.
        self.git_missing = !git::is_available();
        self.start_updates(platform.http_get());
    }

    /// Looks for Git again (after installing it).
    pub fn check_git_again(&mut self) {
        git::relocate_executable();
        self.git_missing = !git::is_available();
        if !self.git_missing {
            for p in &mut self.projects {
                p.refresh();
            }
        }
    }

    fn install(&mut self, url: PathBuf) -> ProjectId {
        let id = self.next_project_id;
        self.next_project_id += 1;
        let mut project = Project::new(id, url);
        if let Some(waker) = self.jobs.waker() {
            project.jobs.set_waker(waker);
        }
        project.start_watching();
        self.projects.push(project);
        id
    }

    pub fn persist_projects(&mut self) {
        // Work trees listed by git are not the user's list: they come back from git.
        self.settings.projects = self.projects.iter().filter(|p| !p.is_derived).map(|p| p.url.clone()).collect();
        self.settings.selected_project = self.current_project().map(|p| p.url.clone());
        // Only what is still listed, so the setting does not grow with every folder ever collapsed.
        let listed = self.project_keys();
        self.settings.collapsed.retain(|c| listed.contains(&project_tree::key(c)));
        self.settings.save();
    }

    /// Runs what finished in the background and what models asked for. Returns when something next wants to run.
    fn tick(&mut self) -> Option<Instant> {
        Jobs::run(self, |a| &mut a.jobs);
        self.tick_updates();
        let mut next = self.viewer.tick();
        let visible = self.window_visible;
        let selected = self.selected;
        for p in &mut self.projects {
            // How often a repository that cannot be watched (inside WSL) is looked at: the one on screen often enough
            // to follow an agent at work, the others for their counts in the list.
            let poll_every = Duration::from_secs(if Some(p.id) == selected { 2 } else { 10 });
            if let Some(t) = p.tick(visible, poll_every) {
                next = Some(next.map_or(t, |n| n.min(t)));
            }
        }
        self.drain_events();
        if let Some(toast) = &self.toast {
            if toast.until <= Instant::now() {
                self.toast = None;
            } else {
                next = Some(next.map_or(toast.until, |n| n.min(toast.until)));
            }
        }
        next
    }

    /// Handles what the viewer and the projects reported.
    pub fn drain_events(&mut self) {
        for _ in 0..4 {
            let viewer_events = std::mem::take(&mut self.viewer.events);
            let mut project_events = Vec::new();
            for p in &mut self.projects {
                for e in std::mem::take(&mut p.events) {
                    project_events.push((p.id, e));
                }
            }
            if viewer_events.is_empty() && project_events.is_empty() {
                break;
            }
            for e in viewer_events {
                self.viewer_event(e);
            }
            for (id, e) in project_events {
                match e {
                    ProjectEvent::Refreshed => self.project_did_refresh(id),
                    ProjectEvent::Callback(f) => f(self),
                }
            }
        }
    }

    fn viewer_event(&mut self, event: ViewerEvent) {
        match event {
            ViewerEvent::Toast(text) => self.show_toast(text),
            ViewerEvent::Exit => {
                // Escape returns to wherever the file was picked: the tree, the commit's file list in Log, else the
                // changes list.
                let (browsing, log) = self.current_project().map_or((false, false), |p| (p.browsed_path.is_some(), p.tab == ProjectTab::Log));
                if browsing && self.sidebar_visible {
                    self.focus_tree();
                } else if log && self.list_visible {
                    self.focus_request = Some(ids::log_files());
                } else {
                    self.focus_list();
                }
            }
            ViewerEvent::StepFile(delta) => {
                if !self.step_file(delta) {
                    self.viewer.land_on_last_hunk = false;
                    self.show_toast(if delta > 0 { l("No more changed files", "没有更多变更文件了") } else { l("Already at the first file", "已经是第一个文件") });
                }
            }
            ViewerEvent::DocumentChanged => self.viewer_document_changed(),
            ViewerEvent::FileWritten(root) => {
                // A save shows in the Changes list straight away, without waiting for the file watcher.
                if let Some(p) = self.projects.iter_mut().find(|p| p.url == root) {
                    p.refresh();
                }
            }
            ViewerEvent::RevertHunk(index) => self.rollback_hunk(index),
            ViewerEvent::ToggleCommitHunk(index) => self.toggle_commit_hunk(index),
            ViewerEvent::OpenAnnotation(entry) => self.open_annotation(entry),
            ViewerEvent::ContextMenu { at, hunk } => {
                self.context_hunk = hunk;
                let items = self.viewer_context_menu();
                if !items.is_empty() {
                    self.menu = Some(Menu::new(at, items));
                }
            }
            ViewerEvent::FocusCanvas => self.focus_viewer(),
        }
    }

    /// The memory readout: how much the process holds right now, read every few seconds.
    fn update_memory(&mut self, platform: &dyn Platform) {
        if self.memory_read.is_some_and(|t| t.elapsed() < Duration::from_secs(3)) {
            return;
        }
        self.memory_read = Some(Instant::now());
        let value = platform.memory_mb();
        if (value - self.memory_mb).abs() >= 0.5 {
            self.memory_mb = value;
        }
    }

    // MARK: Projects

    pub fn present_add_project(&mut self) {
        self.requests.push(PlatformRequest::PickFolder {
            title: l("Choose a Git repository, or a folder containing several", "选择 Git 仓库，或包含多个仓库的文件夹"),
            then: Box::new(|app, path| app.add_projects(vec![path])),
        });
    }

    pub fn add_projects(&mut self, paths: Vec<PathBuf>) {
        self.jobs.spawn(
            move || {
                let mut roots = Vec::new();
                let mut rejected = 0;
                let mut refusal = None;
                for path in paths {
                    let directory = if path.is_dir() {
                        path.clone()
                    } else if path.exists() {
                        path.parent().map(Path::to_path_buf).unwrap_or(path.clone())
                    } else {
                        continue;
                    };
                    // The repository chosen, or those in a plain folder, and the repositories inside them.
                    let found = git::repositories_for(&directory, 3);
                    if found.is_empty() {
                        rejected += 1;
                        if refusal.is_none() {
                            refusal = git::refusal(&directory, &[]);
                        }
                    }
                    roots.extend(found);
                }
                (roots, rejected, refusal)
            },
            |app: &mut App, (roots, rejected, refusal): (Vec<PathBuf>, usize, Option<git::Refusal>)| {
                let mut landed = None;
                for root in roots {
                    if let Some(existing) = app.projects.iter_mut().find(|p| same_path(&p.url, &root)) {
                        // A work tree git listed, now added by hand: it stays whatever happens to the list.
                        existing.is_derived = false;
                        landed = landed.or(Some(existing.id));
                        continue;
                    }
                    let id = app.install(root);
                    if let Some(p) = app.project_mut(id) {
                        p.refresh();
                    }
                    landed = landed.or(Some(id));
                }
                // A work tree just added goes under its repository now, not at that one's next look.
                let mains: Vec<ProjectId> = app.projects.iter().filter(|p| p.worktree_of.is_none()).map(|p| p.id).collect();
                for main in mains {
                    app.sync_worktrees(main, true);
                }
                if let Some(id) = landed {
                    app.select(id);
                } else if let Some(refusal) = refusal {
                    app.show_refusal(refusal);
                } else if rejected > 0 {
                    app.show_toast(l("No Git repository found there", "这里没有找到 Git 仓库"));
                }
                app.persist_projects();
            },
        );
    }

    /// Git's reason for not opening a folder, in place of "No Git repository found there".
    fn show_refusal(&mut self, refusal: git::Refusal) {
        if let Some(command) = refusal.trust_command {
            self.show_toast_action(
                l("Git won't open this repository: it belongs to another user", "Git 拒绝打开这个仓库：它属于另一个用户"),
                l("Copy the command that trusts it", "复制信任它的命令"),
                move |app| app.copy_text(command),
            );
        } else {
            let message = refusal.message;
            self.show_toast_action(
                format!("{}{message}", l("Git can't open this folder: ", "Git 无法打开这个文件夹：")),
                l("Copy", "复制"),
                move |app| app.copy_text(message),
            );
        }
    }

    /// The sidebar's Refresh: the project's changes, and the repositories that appeared inside it since it was
    /// added, put right below it. Only this one looks for repositories; the other refreshes stay as light as they were.
    pub fn refresh_and_discover(&mut self, id: ProjectId) {
        let Some(p) = self.project_mut(id) else { return };
        p.refresh();
        let url = p.url.clone();
        self.sync_worktrees(id, true);
        self.jobs.spawn(
            {
                let url = url.clone();
                move || git::repositories_for(&url, 3)
            },
            move |app: &mut App, found: Vec<PathBuf>| {
                if app.project(id).is_none() {
                    return;
                }
                let below = |p: &Path| {
                    let norm = |p: &Path| p.to_string_lossy().replace('\\', "/").trim_end_matches('/').to_lowercase();
                    norm(p).starts_with(&(norm(&url) + "/"))
                };
                let mut added = 0;
                for root in found {
                    if app.projects.iter().any(|p| same_path(&p.url, &root)) {
                        continue;
                    }
                    let inner = app.install(root);
                    // Below the project and the repositories of its already listed.
                    let count = app.projects.len();
                    if let Some(last) = app.projects[..count - 1].iter().rposition(|p| p.id == id || below(&p.url)) {
                        let project = app.projects.remove(count - 1);
                        app.projects.insert(last + 1, project);
                    }
                    if let Some(p) = app.project_mut(inner) {
                        p.refresh();
                    }
                    added += 1;
                }
                if added == 0 {
                    return;
                }
                app.persist_projects();
                app.show_toast(if added == 1 {
                    l("Added 1 repository found inside", "已添加新发现的 1 个子仓库")
                } else {
                    lf!("Added {added} repositories found inside", "已添加新发现的 {added} 个子仓库")
                });
            },
        );
    }

    pub fn remove_project(&mut self, id: ProjectId) {
        // The work trees listed under it go with it; those the user added stay, on their own.
        let linked: Vec<(ProjectId, bool)> = self.projects.iter().filter(|p| p.worktree_of == Some(id)).map(|p| (p.id, p.is_derived)).collect();
        for (worktree, derived) in linked {
            if let Some(p) = self.project_mut(worktree) {
                p.worktree_of = None;
            }
            if derived {
                self.remove_project(worktree);
            }
        }
        let owner = self.project(id).and_then(|p| p.worktree_of);
        if let Some(p) = self.project_mut(id) {
            p.stop_watching();
        }
        self.remove_terminals_for(id);
        self.projects.retain(|p| p.id != id);
        if self.selected == Some(id) {
            // A work tree that went: back to its repository.
            self.selected = owner.filter(|o| self.project(*o).is_some()).or(self.projects.first().map(|p| p.id));
            self.sync_viewer();
        }
        self.persist_projects();
    }

    // Linked work trees.

    /// A work tree git lists is watched and asked for its status only while its row is in sight or it is selected:
    /// an agent can leave dozens behind, and each would cost a watcher and a `git status` at every change.
    fn update_dormancy(&mut self) {
        let visible: Vec<ProjectId> = self.project_rows().iter().map(|r| self.projects[r.index].id).collect();
        let selected = self.selected;
        for p in self.projects.iter_mut().filter(|p| p.is_derived) {
            let dormant = !visible.contains(&p.id) && Some(p.id) != selected;
            if dormant == p.is_dormant {
                continue;
            }
            p.is_dormant = dormant;
            if dormant {
                p.stop_watching();
            } else {
                p.start_watching();
                p.refresh();
            }
        }
    }

    /// Looks at the repository's work trees again when the folder git keeps them in has changed (or `force`), and
    /// lists them under it: new ones appear, removed ones go. Nothing is created, removed or switched in git.
    pub fn sync_worktrees(&mut self, id: ProjectId, force: bool) {
        let Some(main) = self.project(id) else { return };
        if main.worktree_of.is_some() {
            return;
        }
        let Some(git_directory) = main.git_directory().map(Path::to_path_buf) else { return };
        let url = main.url.clone();
        let seen = main.worktrees_stamp;
        // Work trees whose folder was deleted without telling git: the folder is the truth.
        let gone: Vec<ProjectId> =
            self.projects.iter().filter(|p| p.is_derived && p.worktree_of == Some(id) && !p.url.is_dir()).map(|p| p.id).collect();
        for worktree in gone {
            self.remove_project(worktree);
        }
        let stamp = std::fs::metadata(git_directory.join("worktrees")).and_then(|m| m.modified()).ok();
        if !force && seen == Some(stamp) {
            return;
        }
        if let Some(p) = self.project_mut(id) {
            p.worktrees_stamp = Some(stamp);
        }
        // Never had any, and has none: nothing to ask git.
        if stamp.is_none() && !self.projects.iter().any(|p| p.worktree_of == Some(id)) {
            return;
        }
        self.jobs.spawn(
            move || git::worktrees(&url),
            move |app: &mut App, list: Vec<git::Worktree>| {
                // Only the main work tree lists the others: opened alone, a linked one stays alone.
                let Some(main) = app.project(id) else { return };
                if !list.first().is_some_and(|first| same_path(&first.path, &main.url)) {
                    return;
                }
                let wanted: Vec<PathBuf> =
                    list.iter().skip(1).filter(|w| !w.is_bare && !w.is_prunable && w.path.is_dir()).map(|w| w.path.clone()).collect();
                let stale: Vec<(ProjectId, bool)> = app
                    .projects
                    .iter()
                    .filter(|p| p.worktree_of == Some(id) && !wanted.iter().any(|w| same_path(w, &p.url)))
                    .map(|p| (p.id, p.is_derived))
                    .collect();
                for (worktree, derived) in stale {
                    if let Some(p) = app.project_mut(worktree) {
                        p.worktree_of = None;
                    }
                    if derived {
                        app.remove_project(worktree);
                    }
                }
                for path in wanted {
                    if let Some(existing) = app.projects.iter_mut().find(|p| same_path(&p.url, &path)) {
                        // One the user added: shown under its repository, and still theirs.
                        if existing.id != id {
                            existing.worktree_of = Some(id);
                        }
                        continue;
                    }
                    let awaited = app.awaited_selection.as_ref().is_some_and(|a| same_path(a, &path));
                    let worktree = app.install_dormant(path, id);
                    if awaited {
                        app.awaited_selection = None;
                        app.select(worktree);
                    }
                }
                app.update_dormancy();
            },
        );
    }

    /// A work tree git lists: awake for its first status; `update_dormancy` puts it to sleep when out of sight.
    fn install_dormant(&mut self, url: PathBuf, owner: ProjectId) -> ProjectId {
        let id = self.next_project_id;
        self.next_project_id += 1;
        let mut project = Project::new(id, url);
        if let Some(waker) = self.jobs.waker() {
            project.jobs.set_waker(waker);
        }
        project.worktree_of = Some(owner);
        project.is_derived = true;
        // Its status once, so that a folded repository counts its changes; then asleep unless in sight.
        project.start_watching();
        project.refresh();
        self.projects.push(project);
        id
    }

    // The projects as a tree.

    fn project_keys(&self) -> Vec<String> {
        self.projects.iter().map(|p| project_tree::key(&p.url)).collect()
    }

    /// For each project, the one it sits under: the repository of a work tree, or the listed folder it is inside.
    fn project_parents(&self) -> Vec<Option<usize>> {
        project_tree::parents(&self.project_keys(), &self.project_owners())
    }

    fn project_owners(&self) -> Vec<Option<usize>> {
        self.projects.iter().map(|p| p.worktree_of.and_then(|o| self.projects.iter().position(|q| q.id == o))).collect()
    }

    fn collapsed_keys(&self) -> Vec<String> {
        self.settings.collapsed.iter().map(|p| project_tree::key(p)).collect()
    }

    /// The sidebar's rows: a repository inside another one listed sits under it.
    pub fn project_rows(&self) -> Vec<project_tree::Row> {
        project_tree::rows(&self.project_keys(), &self.project_owners(), &self.collapsed_keys())
    }

    pub fn is_collapsed(&self, id: ProjectId) -> bool {
        self.project(id).is_some_and(|p| self.collapsed_keys().contains(&project_tree::key(&p.url)))
    }

    /// The projects next to this one under the same parent, in order (itself included).
    fn siblings(&self, id: ProjectId) -> Vec<ProjectId> {
        let parents = self.project_parents();
        let Some(index) = self.projects.iter().position(|p| p.id == id) else { return Vec::new() };
        (0..self.projects.len()).filter(|i| parents[*i] == parents[index]).map(|i| self.projects[i].id).collect()
    }

    pub fn can_move_project(&self, id: ProjectId, delta: isize) -> bool {
        let siblings = self.siblings(id);
        siblings.iter().position(|s| *s == id).is_some_and(|p| {
            let target = p as isize + delta;
            target >= 0 && target < siblings.len() as isize
        })
    }

    /// Up or down among the projects at its level; those inside it follow, being shown under it wherever it is.
    pub fn move_project(&mut self, id: ProjectId, delta: isize) {
        if !self.can_move_project(id, delta) {
            return;
        }
        let siblings = self.siblings(id);
        let position = siblings.iter().position(|s| *s == id).unwrap_or(0);
        let other = siblings[(position as isize + delta) as usize];
        let Some(from) = self.projects.iter().position(|p| p.id == id) else { return };
        let p = self.projects.remove(from);
        let to = self.projects.iter().position(|p| p.id == other).unwrap_or(0);
        self.projects.insert(if delta < 0 { to } else { to + 1 }, p);
        self.persist_projects();
    }

    /// The changes in the repositories folded away under a collapsed project, to count with its own.
    pub fn hidden_changes(&self, id: ProjectId) -> usize {
        if !self.is_collapsed(id) {
            return 0;
        }
        let Some(index) = self.projects.iter().position(|p| p.id == id) else { return 0 };
        project_tree::descendants(index, &self.project_parents()).into_iter().map(|i| self.projects[i].changes().len()).sum()
    }

    pub fn toggle_collapsed(&mut self, id: ProjectId) {
        let Some(url) = self.project(id).map(|p| p.url.clone()) else { return };
        let key = project_tree::key(&url);
        if self.is_collapsed(id) {
            self.settings.collapsed.retain(|c| project_tree::key(c) != key);
        } else {
            self.settings.collapsed.push(url);
            // The selection would vanish with the rows: it moves to the project folded.
            let index = self.projects.iter().position(|p| p.id == id).unwrap_or(0);
            let under = project_tree::descendants(index, &self.project_parents());
            if under.iter().any(|i| Some(self.projects[*i].id) == self.selected) {
                self.select(id);
            }
        }
        self.update_dormancy();
        self.persist_projects();
    }

    pub fn select(&mut self, id: ProjectId) {
        // Chosen from elsewhere (Quick Open, a new repository found): it must be in sight.
        if let Some(index) = self.projects.iter().position(|p| p.id == id) {
            let keys = self.project_keys();
            let above: Vec<String> = project_tree::ancestors(index, &self.project_parents()).into_iter().map(|i| keys[i].clone()).collect();
            self.settings.collapsed.retain(|c| !above.contains(&project_tree::key(c)));
        }
        if self.selected != Some(id) {
            self.selected = Some(id);
            self.persist_projects();
        }
        self.update_dormancy();
        if let Some(p) = self.project_mut(id) {
            p.refresh();
        }
        self.sync_viewer();
    }

    pub fn select_project_offset(&mut self, offset: isize) {
        if self.projects.is_empty() {
            return;
        }
        let n = self.projects.len() as isize;
        let index = self.projects.iter().position(|p| Some(p.id) == self.selected).unwrap_or(0) as isize;
        let id = self.projects[((index + offset) % n + n) as usize % n as usize].id;
        self.select(id);
    }

    pub fn refresh_current(&mut self) {
        let Some(p) = self.current_project_mut() else { return };
        p.invalidate_files();
        p.refresh();
        if p.tab == ProjectTab::Log {
            p.load_log(true, 0, None);
        }
        self.viewer.reload();
    }

    fn project_did_refresh(&mut self, id: ProjectId) {
        self.sync_worktrees(id, false);
        if Some(id) != self.selected {
            return;
        }
        if self.sidebar_visible {
            if let Some(p) = self.project_mut(id) {
                p.load_tree();
            }
        }
        self.sync_viewer();
    }

    // MARK: Viewer synchronisation

    /// Points the viewer at whatever the current project's selection implies: the file being browsed by path if there
    /// is one, otherwise the selection of the list column.
    pub fn sync_viewer(&mut self) {
        let Some(id) = self.selected else {
            self.viewer.clear();
            return;
        };
        let head = self.project(id).and_then(|p| p.status.head_oid.clone());
        self.viewer.set_base_stamp(head.clone());
        let ignore_ws = self.settings.ignore_whitespace;
        let p = self.project(id).expect("project");
        if let Some(path) = p.browsed_path.clone() {
            let request = self.worktree_request(&path, p);
            if request.source == Source::File && !crate::core::diff::join_repo_path(&p.url, &path).exists() {
                // Deleted and committed, or gone with a checkout: nothing left to follow.
                self.project_mut(id).expect("project").browsed_path = None;
            } else {
                // The same file, as a diff while it has local changes (an agent or an editor touched it) and as a
                // plain file once it has none.
                self.mark_in_changes(&path, id);
                if Some(&request) == self.viewer.request.as_ref() {
                    self.viewer.reload_if_stale(head);
                } else {
                    let same = self.viewer.request.as_ref().is_some_and(|r| r.path == path && r.root == request.root);
                    self.viewer.open(request, None, same);
                }
                return;
            }
        }
        let p = self.project(id).expect("project");
        match p.tab {
            ProjectTab::Changes => {
                if p.comparison.is_some() {
                    self.sync_comparison(id);
                    return;
                }
                if let Some(sel) = p.selected_change_id.clone() {
                    if !sel.starts_with("f:") {
                        return; // a folder or group row; leave the viewer alone
                    }
                    if let Some(change) = p.changes().iter().find(|c| ChangeRow::file_id(&c.path) == sel).cloned() {
                        self.show_change(&change, id);
                        return;
                    }
                    // The file being edited left the list (typed back to what HEAD has): it stays on screen, and comes
                    // back into the list with the next keystroke that changes it.
                    if self.viewer.is_editing(&p.url, &sel[2..]) {
                        self.viewer.reload_if_stale(head);
                        return;
                    }
                }
                let ordered = change_tree::ordered_files(p.changes(), self.settings.flat_list, &p.filter.text, true);
                if let Some(first) = ordered.first().cloned() {
                    self.project_mut(id).expect("project").selected_change_id = Some(ChangeRow::file_id(&first.path));
                    self.show_change(&first, id);
                } else {
                    let (loaded, url) = (p.has_loaded, p.url.clone());
                    self.project_mut(id).expect("project").selected_change_id = None;
                    if loaded || self.viewer.request.as_ref().is_none_or(|r| r.root != url) {
                        self.viewer.clear();
                    }
                }
            }
            ProjectTab::Log => {
                if p.commits.is_empty() && !p.is_loading_log {
                    self.project_mut(id).expect("project").load_log(true, 0, None);
                }
                let p = self.project(id).expect("project");
                let shown = p.selected_commit().and_then(|commit| {
                    let file_id = p.selected_commit_file_id.as_ref()?;
                    let change = p.commit_files.iter().find(|c| ChangeRow::file_id(&c.path) == *file_id)?;
                    Some(p.request_in_commit(change, commit, ignore_ws))
                });
                match shown {
                    Some(request) => self.viewer.open(request, None, false),
                    None => {
                        // Keep showing the previous commit's diff while the next one loads.
                        let showing_commit = self.viewer.request.as_ref().is_some_and(|r| r.root == p.url && matches!(r.source, Source::Commit { .. }));
                        if !showing_commit || p.selected_commit().is_none() {
                            self.viewer.clear();
                        }
                    }
                }
            }
        }
    }

    fn show_change(&mut self, change: &FileChange, id: ProjectId) {
        let Some(p) = self.project(id) else { return };
        let request = p.request_for(change, self.settings.ignore_whitespace);
        if Some(&request) == self.viewer.request.as_ref() {
            let head = p.status.head_oid.clone();
            self.viewer.reload_if_stale(head);
        } else {
            // Same file, different status (e.g. untracked → added): keep the reader's place.
            let same = self.viewer.request.as_ref().is_some_and(|r| r.path == request.path && r.root == request.root);
            self.viewer.open(request, None, same);
        }
    }

    pub fn change_selection_changed(&mut self, id: ProjectId) {
        if Some(id) != self.selected {
            return;
        }
        let Some(p) = self.project(id) else { return };
        if p.tab != ProjectTab::Changes {
            return;
        }
        let Some(sel) = p.selected_change_id.clone() else { return };
        let Some(change) = p.changes().iter().find(|c| ChangeRow::file_id(&c.path) == sel).cloned() else { return };
        // Picking another change ends browsing; the highlight following the browsed file does not.
        if p.browsed_path.as_deref() != Some(change.path.as_str()) {
            self.project_mut(id).expect("project").browsed_path = None;
        }
        self.show_change(&change, id);
        self.note_recent(id, &change.path);
        self.follow(&change.path, id);
    }

    pub fn commit_selection_changed(&mut self, id: ProjectId) {
        let Some(p) = self.project_mut(id) else { return };
        p.load_selected_commit(Box::new(move |app: &mut App| {
            if Some(id) == app.selected && app.project(id).is_some_and(|p| p.tab == ProjectTab::Log) {
                app.sync_viewer();
            }
        }));
    }

    pub fn commit_file_selection_changed(&mut self, id: ProjectId) {
        if Some(id) != self.selected || self.project(id).is_none_or(|p| p.tab != ProjectTab::Log) {
            return;
        }
        self.sync_viewer();
        if self.project(id).is_some_and(|p| p.browsed_path.is_none()) {
            if let Some(path) = self.viewer.request.as_ref().map(|r| r.path.clone()) {
                self.follow(&path, id);
            }
        }
    }

    /// The user picked a commit or one of its files: the viewer goes back to following the Log.
    pub fn picked_in_log(&mut self, id: ProjectId, commit_changed: bool) {
        let Some(p) = self.project_mut(id) else { return };
        if p.browsed_path.is_none() {
            return;
        }
        p.browsed_path = None;
        // A click on the row that is already selected changes nothing, so nothing else would bring its diff back.
        if commit_changed {
            self.commit_selection_changed(id);
        } else {
            self.commit_file_selection_changed(id);
        }
    }

    /// Keeps the Changes list's highlight on the file the viewer shows, or on nothing when that file has no changes.
    fn mark_in_changes(&mut self, path: &str, id: ProjectId) {
        let Some(p) = self.project_mut(id) else { return };
        if p.tab != ProjectTab::Changes {
            return;
        }
        let file_id = ChangeRow::file_id(path);
        if p.comparison.is_some() {
            if p.compare_changes.iter().any(|c| c.path == path) {
                for a in change_tree::ancestors(path, &p.compare_collapsed) {
                    p.compare_collapsed.remove(&a);
                }
                p.compare_selected_id = Some(file_id);
            } else {
                p.compare_selected_id = None;
            }
            return;
        }
        if p.changes().iter().any(|c| c.path == path) {
            for a in change_tree::ancestors(path, &p.collapsed) {
                p.collapsed.remove(&a);
            }
            p.selected_change_id = Some(file_id);
        } else {
            p.selected_change_id = None;
        }
    }

    /// "Always Select Opened File": the tree follows whatever the viewer shows.
    pub(super) fn follow(&mut self, path: &str, id: ProjectId) {
        if !self.settings.follow_file || !self.sidebar_visible {
            return;
        }
        let Some(p) = self.project_mut(id) else { return };
        if p.tree_selected_id.as_deref() != Some(TreeRow::file_id(path).as_str()) {
            p.reveal_in_tree(path, false);
        }
    }

    // MARK: File tree

    /// How `path` is shown from the working tree: a diff while it has local changes, otherwise the file itself. While
    /// the Changes tab compares with another commit, the diff is against that commit.
    fn worktree_request(&self, path: &str, p: &Project) -> DiffRequest {
        let ignore_ws = self.settings.ignore_whitespace;
        if p.tab == ProjectTab::Changes {
            if let Some(comparison) = &p.comparison {
                if let Some(change) = p.compared_change(path) {
                    return p.request_compared(change, comparison, ignore_ws);
                }
                return p.file_request(path);
            }
        }
        if let Some(change) = p.changes().iter().find(|c| c.path == path) {
            return p.request_for(change, ignore_ws);
        }
        p.file_request(path)
    }

    /// The user picked a row in the tree.
    pub fn tree_selection_changed(&mut self, id: ProjectId) {
        if Some(id) != self.selected {
            return;
        }
        let Some(sel) = self.project(id).and_then(|p| p.tree_selected_id.clone()) else { return };
        if let Some(path) = sel.strip_prefix("f:") {
            self.browse(path.to_string(), id, None);
        }
    }

    /// Alt+F1: select the file on screen in the tree, with its folders opened and scrolled into view.
    pub fn locate_in_tree(&mut self) {
        let Some(id) = self.selected else { return };
        let url = self.project(id).map(|p| p.url.clone());
        let path = self.viewer.request.as_ref().filter(|r| Some(&r.root) == url.as_ref()).map(|r| r.path.clone());
        let Some(path) = path else {
            self.focus_tree();
            return;
        };
        if self.project_mut(id).is_some_and(|p| p.reveal_in_tree(&path, true)) {
            self.focus_tree();
        } else {
            self.show_toast(l("This file is not in the working tree", "这个文件不在当前工作区里"));
        }
    }

    pub fn set_tab(&mut self, tab: ProjectTab) {
        self.list_visible = true;
        if let Some(p) = self.current_project_mut() {
            if p.tab != tab {
                p.tab = tab;
                p.browsed_path = None;
                self.sync_viewer();
            }
        }
        self.focus_list();
    }

    /// Moves to the next/previous file in the active list. Returns false at either end.
    pub fn step_file(&mut self, delta: i32) -> bool {
        let Some(id) = self.selected else { return false };
        let flat = self.settings.flat_list;
        let p = self.project(id).expect("project");
        let listed = if p.comparison.is_some() { &p.compare_changes } else { &p.status.changes };
        if let Some(path) = p.browsed_path.clone() {
            if !(p.tab == ProjectTab::Changes && listed.iter().any(|c| c.path == path)) {
                // Browsing a file the list column does not hold: walk the files the tree shows.
                let files: Vec<TreeRow> = p.tree_rows().into_iter().filter(|r| !r.is_directory).collect();
                if files.is_empty() {
                    return false;
                }
                let current = files.iter().position(|r| r.path == path).or_else(|| files.iter().position(|r| Some(&r.id) == p.tree_selected_id.as_ref()));
                let index = current.map_or(if delta > 0 { 0 } else { files.len() as i64 - 1 }, |c| c as i64 + delta as i64);
                if index < 0 || index >= files.len() as i64 {
                    return false;
                }
                let target = files[index as usize].id.clone();
                self.project_mut(id).expect("project").tree_selected_id = Some(target);
                self.tree_selection_changed(id);
                return true;
            }
        }
        let p = self.project(id).expect("project");
        match p.tab {
            ProjectTab::Changes if p.comparison.is_some() => {
                let files = change_tree::ordered_files(&p.compare_changes, flat, &p.filter.text, true);
                let Some(target) = neighbour(&files, p.compare_selected_id.as_deref(), delta) else { return false };
                let p = self.project_mut(id).expect("project");
                for a in change_tree::ancestors(&target.path, &p.compare_collapsed) {
                    p.compare_collapsed.remove(&a);
                }
                p.compare_selected_id = Some(ChangeRow::file_id(&target.path));
                self.compare_selection_changed(id);
            }
            ProjectTab::Changes => {
                let files = change_tree::ordered_files(p.changes(), flat, &p.filter.text, true);
                let Some(target) = neighbour(&files, p.selected_change_id.as_deref(), delta) else { return false };
                let p = self.project_mut(id).expect("project");
                for a in change_tree::ancestors(&target.path, &p.collapsed) {
                    p.collapsed.remove(&a);
                }
                p.selected_change_id = Some(ChangeRow::file_id(&target.path));
                p.selected_change_ids = [ChangeRow::file_id(&target.path)].into_iter().collect();
                self.change_selection_changed(id);
            }
            ProjectTab::Log => {
                let files = change_tree::ordered_files(&p.commit_files, flat, "", false);
                let Some(target) = neighbour(&files, p.selected_commit_file_id.as_deref(), delta) else { return false };
                let p = self.project_mut(id).expect("project");
                for a in change_tree::ancestors(&target.path, &p.commit_collapsed) {
                    p.commit_collapsed.remove(&a);
                }
                p.selected_commit_file_id = Some(ChangeRow::file_id(&target.path));
                self.commit_file_selection_changed(id);
            }
        }
        true
    }

    /// Opens a file by path (from a search): as a diff when it has local changes, otherwise as a plain file.
    pub fn open_file(&mut self, id: ProjectId, path: String, line: Option<usize>) {
        if self.selected != Some(id) {
            self.selected = Some(id);
            self.persist_projects();
        }
        self.browse(path.clone(), id, line);
        self.follow(&path, id);
    }

    fn browse(&mut self, path: String, id: ProjectId, line: Option<usize>) {
        self.note_recent(id, &path);
        let head = self.project(id).and_then(|p| p.status.head_oid.clone());
        if let Some(p) = self.project_mut(id) {
            p.browsed_path = Some(path.clone());
        }
        self.viewer.set_base_stamp(head);
        self.mark_in_changes(&path, id);
        let Some(p) = self.project(id) else { return };
        let request = self.worktree_request(&path, p);
        let same = self.viewer.request.as_ref().is_some_and(|r| r.path == path && r.root == p.url);
        self.viewer.open(request, line, same && line.is_none());
    }

    pub fn note_recent(&mut self, id: ProjectId, path: &str) {
        let entry = RecentFile { project: id, path: path.to_string() };
        self.recent.retain(|r| *r != entry);
        self.recent.insert(0, entry);
        self.recent.truncate(40);
    }

    // MARK: Panels and focus

    pub fn change_interface_font_size(&mut self, delta: f32) {
        let (lo, hi) = settings::UI_FONT_RANGE;
        let size = (self.settings.ui_font_size + delta).clamp(lo, hi);
        if size != self.settings.ui_font_size {
            self.settings.ui_font_size = size;
            self.settings.save();
        }
    }

    /// A font family picked in Settings for code; None puts back the default face.
    pub fn choose_code_font(&mut self, family: Option<String>) {
        if family != self.settings.code_font {
            self.settings.code_font = family;
            self.settings.save();
        }
    }

    pub fn change_code_font_size(&mut self, delta: f32) {
        let (lo, hi) = settings::CODE_FONT_RANGE;
        let size = (self.settings.font_size + delta).clamp(lo, hi);
        if size != self.settings.font_size {
            self.settings.font_size = size;
            self.settings.save();
        }
    }

    pub fn toggle_unified(&mut self) {
        self.settings.unified = !self.settings.unified;
        self.settings.save();
        self.viewer.set_unified(self.settings.unified);
    }

    pub fn toggle_whitespace(&mut self) {
        self.settings.ignore_whitespace = !self.settings.ignore_whitespace;
        self.settings.save();
        self.viewer.set_ignore_whitespace(self.settings.ignore_whitespace);
    }

    pub fn toggle_sidebar(&mut self) {
        self.sidebar_visible = !self.sidebar_visible;
    }

    /// Alt+0 / Alt+9: show that tool window, or hide the list if it is already showing it.
    pub fn toggle_tab(&mut self, tab: ProjectTab) {
        let Some(p) = self.current_project() else { return };
        if self.list_visible && p.tab == tab {
            // As in the IDE: the first press brings the keyboard to the tool window, the next one hides it.
            let in_list = self.focus.is_some_and(|f| f == ids::list() || f == ids::log_files());
            if in_list {
                self.list_visible = false;
                self.focus_viewer();
            } else {
                self.focus_list();
            }
        } else {
            self.list_visible = true;
            self.set_tab(tab);
        }
    }

    /// Alt+1, the IDE's Project tool window: the file tree in the sidebar. Pressed again with the tree focused, it hides
    /// the sidebar.
    pub fn toggle_file_tree(&mut self) {
        if self.current_project().is_none() {
            self.toggle_sidebar();
            return;
        }
        if self.sidebar_visible && self.focus == Some(ids::tree()) {
            self.sidebar_visible = false;
            self.focus_viewer();
        } else {
            self.focus_tree();
        }
    }

    pub fn focus_tree(&mut self) {
        self.sidebar_visible = true;
        if let Some(p) = self.current_project_mut() {
            p.load_tree();
            p.tree_reveal = true;
        }
        self.focus_request = Some(ids::tree());
    }

    pub fn toggle_maximize_viewer(&mut self) {
        match self.panels_before_maximize {
            Some((sidebar, list)) if !self.sidebar_visible && !self.list_visible => {
                self.sidebar_visible = sidebar;
                self.list_visible = list;
                self.panels_before_maximize = None;
            }
            _ => {
                self.panels_before_maximize = Some((self.sidebar_visible, self.list_visible));
                self.sidebar_visible = false;
                self.list_visible = false;
            }
        }
    }

    pub fn focus_list(&mut self) {
        self.list_visible = true;
        self.focus_request = Some(ids::list());
    }

    pub fn focus_viewer(&mut self) {
        self.focus_request = Some(ids::canvas());
    }

    // MARK: Popups

    pub fn present(&mut self, kind: Popup) {
        if self.popup.is_none() {
            self.focus_before_popup = self.focus;
        }
        // Another popup over an unanswered question cancels the question, so whoever asked hears back.
        if self.popup == Some(Popup::Dialog) && kind != Popup::Dialog {
            if let Some(cancel) = self.dialog.take().and_then(|d| d.on_cancel) {
                cancel(self);
            }
        }
        self.menu = None;
        if kind == Popup::Settings {
            // Fonts installed since it was last open show too.
            self.font_choices = None;
        }
        self.popup = Some(kind);
    }

    pub fn dismiss_popup(&mut self, restore_focus: bool) {
        if self.popup.is_none() {
            return;
        }
        let unanswered = if self.popup == Some(Popup::Dialog) { self.dialog.take() } else { None };
        self.dialog = None;
        self.popup = None;
        if restore_focus {
            self.focus_request = self.focus_before_popup.or(Some(ids::canvas()));
        }
        if let Some(cancel) = unanswered.and_then(|d| d.on_cancel) {
            cancel(self);
        }
    }

    pub fn show_toast(&mut self, text: impl Into<String>) {
        self.toast = Some(Toast { text: text.into(), action: None, until: Instant::now() + Duration::from_millis(2600) });
    }

    pub fn show_toast_action(&mut self, text: impl Into<String>, title: impl Into<String>, handler: impl FnOnce(&mut App) + 'static) {
        // Long enough to reach for the button.
        self.toast = Some(Toast {
            text: text.into(),
            action: Some(ToastAction { title: title.into(), handler: Box::new(handler) }),
            until: Instant::now() + Duration::from_secs(6),
        });
    }

    pub fn dismiss_toast(&mut self) {
        self.toast = None;
    }

    pub fn show_go_to_line(&mut self) {
        if !self.viewer.is_text_document() {
            return;
        }
        let line = self.viewer.canvas.current_line_number();
        self.go_to_line.set_text(&line.to_string());
        self.go_to_line.select_all();
        self.present(Popup::GoToLine);
    }

    // MARK: File actions

    pub fn current_file_path(&self) -> Option<PathBuf> {
        self.viewer.request.as_ref().map(|r| crate::core::diff::join_repo_path(&r.root, &r.path))
    }

    pub fn copy_path(&mut self, with_line: bool) {
        let Some(request) = &self.viewer.request else { return };
        let mut text = request.path.clone();
        if with_line {
            text = format!("{text}:{}", self.viewer.canvas.current_line_number());
        }
        self.requests.push(PlatformRequest::Copy(text.clone()));
        self.show_toast(lf!("Copied {text}", "已复制 {text}"));
    }

    pub fn reveal_in_explorer(&mut self) {
        let Some(path) = self.current_file_path() else { return };
        self.requests.push(PlatformRequest::Reveal(path));
    }

    /// The local change the viewer is showing, if that is what it shows.
    pub fn viewer_change(&self, id: ProjectId) -> Option<FileChange> {
        let p = self.project(id)?;
        let request = self.viewer.request.as_ref()?;
        if request.root != p.url || !request.is_against_head() {
            return None;
        }
        p.changes().iter().find(|c| c.path == request.path).cloned()
    }

    pub fn viewer_context_menu(&mut self) -> Vec<MenuItem> {
        if self.viewer.request.is_none() {
            return Vec::new();
        }
        let mut items = Vec::new();
        if self.viewer.canvas.edit_selection().is_some() {
            items.push(MenuItem::new(l("Cut", "剪切"), |app| app.canvas_clipboard(ClipboardCommand::Cut)).shortcut("Ctrl+X"));
            items.push(MenuItem::new(l("Copy", "复制"), |app| app.canvas_clipboard(ClipboardCommand::Copy)).shortcut("Ctrl+C"));
            items.push(MenuItem::new(l("Paste", "粘贴"), |app| app.canvas_clipboard(ClipboardCommand::Paste)).shortcut("Ctrl+V"));
            items.push(MenuItem::separator());
        } else if self.viewer.canvas.selected_text().is_some() {
            items.push(MenuItem::new(l("Copy", "复制"), |app| app.canvas_clipboard(ClipboardCommand::Copy)).shortcut("Ctrl+C"));
            items.push(MenuItem::separator());
        }
        if let Some(id) = self.selected {
            if let Some(change) = self.viewer_change(id) {
                let mut added = false;
                if self.viewer.can_revert_hunks() {
                    if let Some(hunk) = self.context_hunk {
                        items.push(MenuItem::new(l("Rollback This Change", "回滚这一处变更"), move |app| app.rollback_hunk(hunk)));
                        added = true;
                    }
                }
                if edits::can_rollback(&change) {
                    let c = change.clone();
                    items.push(MenuItem::new(l("Rollback File…", "回滚整个文件…"), move |app| app.rollback(vec![c], id, true)));
                    added = true;
                }
                if edits::can_delete(&change) {
                    let c = change.clone();
                    items.push(MenuItem::new(l("Delete File…", "删除文件…"), move |app| app.delete(vec![c], id, true)));
                    added = true;
                }
                if added {
                    items.push(MenuItem::separator());
                }
                if self.add_commit_pick_items(&mut items, id) {
                    items.push(MenuItem::separator());
                }
            }
            self.add_history_items(&mut items, id);
        }
        items.push(MenuItem::new(l("Select in File Tree", "在文件树中定位"), |app| app.locate_in_tree()).shortcut("Alt+F1"));
        if self.has_terminal() {
            items.push(MenuItem::new(l("Insert Path into Terminal", "把路径插入终端"), |app| app.insert_reference_in_terminal()).shortcut("Ctrl+Alt+T"));
        }
        items.push(MenuItem::new(l("Reveal in File Explorer", "在资源管理器中显示"), |app| app.reveal_in_explorer()));
        items.push(MenuItem::separator());
        items.push(MenuItem::new(l("Copy Path", "复制路径"), |app| app.copy_path(false)).shortcut("Ctrl+Shift+C"));
        items.push(MenuItem::new(l("Copy Path with Line Number", "复制路径和行号"), |app| app.copy_path(true)).shortcut("Ctrl+Alt+Shift+C"));
        items
    }

    /// A clipboard command from a menu, run on the canvas at the end of the frame (where the clipboard is).
    pub fn canvas_clipboard(&mut self, command: ClipboardCommand) {
        self.pending_clipboard = Some(command);
    }

}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardCommand {
    Cut,
    Copy,
    Paste,
}

fn same_path(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| p.to_string_lossy().replace('\\', "/").trim_end_matches('/').to_lowercase();
    norm(a) == norm(b)
}

fn neighbour(files: &[FileChange], selected: Option<&str>, delta: i32) -> Option<FileChange> {
    if files.is_empty() {
        return None;
    }
    let index = match files.iter().position(|f| Some(ChangeRow::file_id(&f.path).as_str()) == selected) {
        Some(current) => current as i64 + delta as i64,
        None if delta > 0 => 0,
        None => files.len() as i64 - 1,
    };
    (index >= 0 && index < files.len() as i64).then(|| files[index as usize].clone())
}

impl Program for App {
    fn theme(&mut self, system_dark: bool) -> Theme {
        self.system_dark = system_dark;
        let mut theme = Theme::new(self.is_dark(), self.settings.ui_font_size, self.settings.font_size);
        theme.code_family = self.settings.code_font.as_deref().map(Arc::from);
        theme.terminal_family = self.settings.terminal_font.as_deref().map(Arc::from);
        theme
    }

    fn frame(&mut self, ui: &mut Ui, platform: &mut dyn Platform) {
        if !self.started {
            self.started = true;
            self.bootstrap(platform);
        }
        if let Some(Event::FocusChanged(active)) = &ui.event {
            self.window_active = *active;
        }
        if let Some(Event::FocusChanged(true)) = &ui.event {
            // Back from installing Git: no need to look for the button.
            if self.git_missing {
                self.check_git_again();
            }
            for p in &mut self.projects {
                p.poll_soon();
            }
        }
        if let Some(Event::FocusChanged(false)) = &ui.event {
            // Typing goes to the file when the window loses the keyboard, as the IDE does.
            self.viewer.save_edits();
        }
        if let Some(Event::FilesHover(at)) = &ui.event {
            self.drop_targeted = at.is_some();
        }
        if let Some(Event::Files(paths)) = &ui.event {
            self.drop_targeted = false;
            let paths = paths.clone();
            // Dropped on a terminal: typed in as quoted paths. Anywhere else: added as projects.
            let mouse = ui.mouse();
            let pane = self.terminals.visible.then(|| self.terminals.pane_rects.iter().find(|(_, r)| r.contains(mouse)).map(|(id, _)| *id)).flatten();
            match pane.and_then(|id| self.terminals.session(id)) {
                Some(s) => {
                    let text: Vec<String> = paths.iter().map(|p| s.shell.quote(&p.to_string_lossy())).collect();
                    let id = s.id;
                    s.write_input(format!("{} ", text.join(" ")).into_bytes());
                    self.focus_terminal_session(id);
                }
                None => self.add_projects(paths),
            }
        }
        if let Some(id) = self.focus_request.take() {
            ui.focus(id);
        }
        self.focus = ui.st.focus;
        let mut next = self.tick();
        if self.find_in_path.search_at.is_some_and(|t| t <= Instant::now()) {
            self.search_in_files();
            next = self.tick().or(next);
        }
        if let Some((id, at)) = self.log_search_at {
            if at <= Instant::now() {
                self.log_search_at = None;
                if let Some(p) = self.project_mut(id) {
                    p.load_log(true, 0, None);
                }
            }
        }
        self.update_memory(platform);
        self.update_commit_ticks();
        self.drain_terminal_events();
        self.poll_terminals(platform);
        commands::handle_shortcuts(self, ui);
        crate::views::root(self, ui, platform);
        self.drain_events();
        if let Some(id) = self.focus_request.take() {
            ui.focus(id);
            ui.request_repaint();
        }
        if let Some(t) = next.or_else(|| self.tick_deadline()) {
            ui.repaint_after(t.saturating_duration_since(Instant::now()).max(Duration::from_millis(1)));
        }
        if self.jobs.busy() || self.viewer.jobs.busy() || self.viewer.is_loading {
            // Spinners keep turning while work runs.
            ui.repaint_after(Duration::from_millis(80));
        }
        for request in std::mem::take(&mut self.requests) {
            match request {
                PlatformRequest::PickFolder { title, then } => {
                    if let Some(path) = platform.pick_folder(&title) {
                        then(self, path);
                    }
                }
                PlatformRequest::OpenUrl(url) => platform.open_url(&url),
                PlatformRequest::Reveal(path) => platform.reveal(&path),
                PlatformRequest::Copy(text) => platform.clipboard().set(&text),
                PlatformRequest::Attention => platform.request_attention(),
                PlatformRequest::DragFiles(paths) => platform.drag_files(paths),
                PlatformRequest::Quit => {
                    self.terminals.terminate_all();
                    platform.quit();
                }
            }
        }
        let title = match (self.current_project(), &self.viewer.request) {
            (Some(p), Some(r)) => format!("{} — {} — DiffCode", crate::core::util::file_name(&r.path), p.name),
            (Some(p), None) => format!("{} — DiffCode", p.name),
            _ => "DiffCode".to_string(),
        };
        platform.set_title(&title);
    }

    fn close_requested(&mut self, platform: &mut dyn Platform) -> bool {
        let _ = platform;
        let allowed = self.quit_requested();
        if allowed {
            self.terminals.terminate_all();
        }
        allowed
    }

    fn window_placement(&self) -> Option<(i32, i32, i32, i32, bool)> {
        self.settings.window
    }

    fn save_window_placement(&mut self, placement: (i32, i32, i32, i32, bool)) {
        self.settings.window = Some(placement);
        self.settings.save();
    }
}

impl App {
    /// The next moment something is due without an event: a search after typing stops.
    fn tick_deadline(&self) -> Option<Instant> {
        let log = self.log_search_at.map(|(_, at)| at);
        [self.find_in_path.search_at, log, self.terminal_deadline()].into_iter().flatten().min()
    }

    /// The language picked differs from the one the interface was started in.
    pub fn language_needs_restart(&self) -> bool {
        self.settings.language.is_chinese(self.system_chinese) != crate::core::lang::is_chinese()
    }

    /// Starts DiffCode again (to show another language), once what is unsaved is saved.
    pub fn restart(&mut self) {
        self.restarting = true;
        if self.quit_requested() {
            self.quit_agreed();
        }
    }

    /// The quit (or restart) was agreed to: close without asking twice, and open again for a restart.
    pub fn quit_agreed(&mut self) {
        if std::mem::take(&mut self.restarting) {
            if let Ok(exe) = std::env::current_exe() {
                // Tells the new copy to wait for this one to close rather than hand over to it.
                let _ = std::process::Command::new(exe).arg("--relaunch").spawn();
            }
        }
        self.quit_confirmed = true;
        self.requests.push(PlatformRequest::Quit);
    }

    /// The window is closing. Typing not yet written goes to the file; if it cannot (or could not, in a file left
    /// since), the window stays open and asks rather than lose it.
    pub fn quit_requested(&mut self) -> bool {
        if self.quit_confirmed {
            return true;
        }
        let mut unsaved: Vec<dialog::DialogItem> = self
            .viewer
            .unsaved_names()
            .into_iter()
            .map(|name| dialog::DialogItem { title: name, icon: Some(crate::icons::Icon::DocumentText), ..Default::default() })
            .collect();
        if !self.viewer.save_edits() {
            if let Some(path) = self.viewer.request.as_ref().map(|r| r.path.clone()) {
                let name = crate::core::util::file_name(&path).to_string();
                unsaved.insert(0, dialog::DialogItem { title: name, icon: Some(crate::icons::Icon::DocumentText), ..Default::default() });
            }
        }
        let restarting = self.restarting;
        if unsaved.is_empty() {
            // Terminals still running a program are asked about next.
            if let Some(request) = self.busy_terminals_question(restarting) {
                self.ask(request.confirm(|app| app.quit_agreed()).cancel(|app| app.restarting = false));
                return false;
            }
            self.persist_projects();
            return true;
        }
        let (title, message, confirm) = if restarting {
            (
                l("Restart DiffCode? Your latest changes could not be saved.", "重启 DiffCode？最近的修改没能保存。"),
                l("Restarting discards them.", "重启会丢弃这些修改。"),
                l("Restart Anyway", "仍然重启"),
            )
        } else {
            (
                l("Quit DiffCode? Your latest changes could not be saved.", "退出 DiffCode？最近的修改没能保存。"),
                l("Quitting discards them.", "退出会丢弃这些修改。"),
                l("Quit Anyway", "仍然退出"),
            )
        };
        let mut request = DialogRequest::new(dialog::DialogStyle::Caution, crate::icons::Icon::Warning, title, confirm)
            .message(message)
            .confirm(|app| app.quit_agreed())
            .cancel(|app| app.restarting = false);
        request.items = unsaved;
        self.ask(request);
        false
    }
}

use crate::input::Event;
