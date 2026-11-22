//! A repository in the sidebar, with its live status and per-project UI state.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::change_tree::{self, ChangeRow};
use super::file_tree::{self, FileTreeIndex, TreeRow};
use super::jobs::Jobs;
use super::AppCallback;
use crate::canvas::Inclusion;
use crate::core::commit::{ChangeLine, CommitResult};
use crate::core::diff::{DiffRequest, Source};
use crate::core::fuzzy::{self, Ranked};
use crate::core::git::{self, ChangeKind, Commit, FileChange, RepoStatus, EMPTY_TREE};
use crate::core::history;
use crate::core::history_edits::{self, StashEntry};
use crate::core::lang::l;
use crate::core::lf;
use crate::core::remote::{self, ConflictBase, RepoOperation};
use crate::core::watcher::FileWatcher;

pub type ProjectId = u64;

/// What the list column shows. The file tree lives in the sidebar and is always there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectTab {
    Changes,
    Log,
}

/// The Log narrowed to one file's commits, or to the commits that changed some of its lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryFilter {
    /// The file's path in `rev`.
    pub path: String,
    /// 1-based lines of the file as `rev` has it; None for the whole file.
    pub lines: Option<(usize, usize)>,
    /// Where the history starts, and where `lines` are counted.
    pub rev: String,
}

impl HistoryFilter {
    pub fn name(&self) -> &str {
        crate::core::util::file_name(&self.path)
    }

    /// "Main.kt", "Main.kt:12-20".
    pub fn label(&self) -> String {
        match self.lines {
            None => self.name().to_string(),
            Some((a, b)) if b > a => format!("{}:{a}-{b}", self.name()),
            Some((a, _)) => format!("{}:{a}", self.name()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComparisonEnd {
    pub target: String,
    pub title: String,
    pub hash: String,
}

/// The Changes tab comparing the working tree with another commit or branch instead of HEAD: everything that changed
/// since then, committed or not, as when reviewing what an agent did. Or two commits compared with each other.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Comparison {
    /// What was picked: a full ref name or a commit hash. Resolved again on each refresh, since a branch moves.
    pub target: String,
    /// "main", "a1b2c3d".
    pub title: String,
    /// Compare with where HEAD and `target` forked, so commits made on `target` since then do not show, reversed.
    pub fork_point: bool,
    /// The commit compared with.
    pub base: String,
    /// The newer end, when two commits are compared; None for the working tree.
    pub other: Option<ComparisonEnd>,
    /// The stash shown, when the list holds what a stash put aside (against the commit it was made on).
    pub stash: Option<StashEntry>,
}

impl Comparison {
    /// The commit on the right, or None for the working tree.
    pub fn head(&self) -> Option<&str> {
        self.other.as_ref().map(|o| o.hash.as_str())
    }
}

pub enum ProjectEvent {
    /// A status refresh (or a comparison) finished.
    Refreshed,
    /// Something to run with the app (a Log page loaded, a commit's files arrived).
    Callback(AppCallback),
}

pub const LOG_PAGE_SIZE: usize = 200;

pub struct Project {
    pub id: ProjectId,
    pub url: PathBuf,
    pub name: String,
    /// A linked work tree shown under its repository: the project of the main work tree.
    pub worktree_of: Option<ProjectId>,
    /// Listed because git has it as a work tree, not because the user added it: never saved, and gone with the work tree.
    pub is_derived: bool,
    /// Folded away in the sidebar (only a derived work tree is): no watching and no status until it is in sight.
    pub is_dormant: bool,
    /// When the folder git keeps its work trees in last changed, as of the last look at them (None: never looked).
    pub worktrees_stamp: Option<Option<std::time::SystemTime>>,
    pub jobs: Jobs<Project>,
    pub events: Vec<ProjectEvent>,

    pub status: RepoStatus,
    pub has_loaded: bool,
    pub is_refreshing: bool,
    pub error_message: Option<String>,

    pub tab: ProjectTab,

    // Local changes.
    pub selected_change_id: Option<String>,
    /// Every selected row of the Changes list, for commands that act on several files. Includes `selected_change_id`.
    pub selected_change_ids: HashSet<String>,
    pub collapsed: HashSet<String>,
    pub filter: crate::text_field::TextField,

    // Commit.
    /// Ticks the user changed. Everything else follows the default: tracked changes ticked, unversioned files not.
    pub commit_overrides: HashMap<String, bool>,
    /// Changed lines left out of the next commit, by file: the rest of a ticked file goes in.
    pub excluded_lines: HashMap<String, HashSet<ChangeLine>>,
    pub commit_message: crate::text_field::TextField,
    pub is_committing: bool,
    /// The last commit made here in this session, while it can still be undone.
    pub last_commit: Option<CommitResult>,
    /// The next commit replaces the last one (Amend), starting from its message.
    pub amend: bool,
    /// Remote branches that already have the commit Amend would replace.
    pub amend_pushed_to: Vec<String>,
    /// What was in the message box before Amend filled in the last commit's message, and that message.
    pub amend_draft: Option<(String, String)>,

    // Branches and remotes.
    /// What is running against the repository's branches or remotes, shown by the branch: "Pushing…".
    pub activity: Option<String>,
    /// A network operation, which can be stopped; a checkout runs to its end.
    pub activity_cancel: Option<git::CancelToken>,
    /// `.git`, or a linked worktree's own directory, where git keeps the marker of a merge in progress.
    git_directory: Option<PathBuf>,
    /// What the left side shows for a file in conflict.
    pub conflict_base: ConflictBase,
    /// The merge message put in the box, so that it goes again if the merge is abandoned rather than committed.
    prefilled_message: Option<String>,

    /// A file opened by its path (from the tree or a search) rather than picked in the Changes or Log list.
    /// The viewer keeps following it: a diff while it has local changes, the plain file otherwise.
    pub browsed_path: Option<String>,

    // Files.
    pub tree_selected_id: Option<String>,
    pub tree_expanded: HashSet<String>,
    pub tree_filter: crate::text_field::TextField,
    pub tree_matches: Vec<Ranked>,
    pub tree_version: u64,
    pub is_loading_tree: bool,
    /// Set to scroll the tree to its selection.
    pub tree_reveal: bool,
    /// The row that was just located, highlighted briefly.
    pub tree_flash: Option<(String, Instant)>,

    // Log.
    pub commits: Vec<Commit>,
    /// Every selected commit (Ctrl+click), for comparing two. Includes `selected_commit_id`.
    pub selected_commit_ids: HashSet<String>,
    pub log_query: crate::text_field::TextField,
    pub log_all_branches: bool,
    /// A branch or tag whose history the Log lists instead of HEAD's (a full ref name), picked in the Git graph.
    pub log_ref: Option<String>,
    pub has_more_commits: bool,
    pub is_loading_log: bool,
    pub selected_commit_id: Option<String>,
    pub commit_files: Vec<FileChange>,
    pub commit_body: String,
    pub selected_commit_file_id: Option<String>,
    pub commit_collapsed: HashSet<String>,
    pub log_stale: bool,

    // History.
    /// The Log lists this file's (or these lines') commits instead of a branch's.
    pub history: Option<HistoryFilter>,
    /// The path the history's file had in each commit listed (it may have been renamed).
    pub history_paths: HashMap<String, String>,

    // Comparison.
    /// The Changes tab lists what differs from this commit instead of the local changes.
    pub comparison: Option<Comparison>,
    pub compare_changes: Vec<FileChange>,
    pub compare_selected_id: Option<String>,
    pub compare_collapsed: HashSet<String>,
    pub is_loading_compare: bool,
    pub compare_error: Option<String>,

    watcher: Option<FileWatcher>,
    /// A repository inside WSL: Windows hears of no change on a distro's share, so its status is asked for again every
    /// few seconds instead of watched (issue #7).
    polls: bool,
    /// Look again at the next tick, whatever the interval: the window came back to the front.
    poll_due: bool,
    refresh_running: bool,
    refresh_queued: bool,
    refresh_at: Option<Instant>,
    last_refresh: Option<Instant>,
    log_generation: u64,
    commit_generation: u64,
    compare_generation: u64,
    file_index: Option<std::sync::Arc<Vec<String>>>,
    file_index_stale: bool,
    file_index_running: bool,
    /// Wanted the file list while it was being read: run again once it is in.
    file_index_waiters: Vec<Box<dyn FnOnce(&mut Project, std::sync::Arc<Vec<String>>)>>,
    tree_index: Option<FileTreeIndex>,
    /// The tree's paths, shared with the thread that filters them.
    tree_paths: std::sync::Arc<Vec<String>>,
    tree_running: bool,
    tree_reload_queued: bool,
    tree_stamp: Option<String>,
    tree_force_reload: bool,
    tree_filter_generation: u64,
    /// Set while the window is hidden; the refresh runs when it comes back.
    pub needs_refresh_when_visible: bool,
}

impl Project {
    pub fn new(id: ProjectId, url: PathBuf) -> Self {
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| url.display().to_string());
        Project {
            id,
            url,
            name,
            jobs: Jobs::default(),
            events: Vec::new(),
            status: RepoStatus::default(),
            has_loaded: false,
            is_refreshing: false,
            error_message: None,
            tab: ProjectTab::Changes,
            selected_change_id: None,
            selected_change_ids: HashSet::new(),
            collapsed: HashSet::new(),
            filter: Default::default(),
            commit_overrides: HashMap::new(),
            excluded_lines: HashMap::new(),
            commit_message: crate::text_field::TextField::multiline(),
            is_committing: false,
            last_commit: None,
            amend: false,
            amend_pushed_to: Vec::new(),
            amend_draft: None,
            activity: None,
            activity_cancel: None,
            git_directory: None,
            worktree_of: None,
            is_derived: false,
            is_dormant: false,
            worktrees_stamp: None,
            conflict_base: ConflictBase::Head,
            prefilled_message: None,
            browsed_path: None,
            tree_selected_id: None,
            tree_expanded: HashSet::new(),
            tree_filter: Default::default(),
            tree_matches: Vec::new(),
            tree_version: 0,
            is_loading_tree: false,
            tree_reveal: false,
            tree_flash: None,
            commits: Vec::new(),
            selected_commit_ids: HashSet::new(),
            log_query: Default::default(),
            log_all_branches: false,
            log_ref: None,
            has_more_commits: true,
            is_loading_log: false,
            selected_commit_id: None,
            commit_files: Vec::new(),
            commit_body: String::new(),
            selected_commit_file_id: None,
            commit_collapsed: HashSet::new(),
            log_stale: false,
            history: None,
            history_paths: HashMap::new(),
            comparison: None,
            compare_changes: Vec::new(),
            compare_selected_id: None,
            compare_collapsed: HashSet::new(),
            is_loading_compare: false,
            compare_error: None,
            watcher: None,
            polls: false,
            poll_due: false,
            refresh_running: false,
            refresh_queued: false,
            refresh_at: None,
            last_refresh: None,
            log_generation: 0,
            commit_generation: 0,
            compare_generation: 0,
            file_index: None,
            file_index_stale: true,
            file_index_running: false,
            file_index_waiters: Vec::new(),
            tree_index: None,
            tree_paths: Default::default(),
            tree_running: false,
            tree_reload_queued: false,
            tree_stamp: None,
            tree_force_reload: false,
            tree_filter_generation: 0,
            needs_refresh_when_visible: false,
        }
    }

    pub fn changes(&self) -> &[FileChange] {
        &self.status.changes
    }

    pub fn git_directory(&self) -> Option<&Path> {
        self.git_directory.as_deref()
    }

    /// Runs what finished in the background, and what is due. Returns when it next wants to run. A repository that
    /// cannot be watched is looked at again every `poll_every`.
    pub fn tick(&mut self, visible: bool, poll_every: Duration) -> Option<Instant> {
        Jobs::run(self, |p| &mut p.jobs);
        if self.refresh_at.is_some_and(|t| t <= Instant::now()) {
            self.refresh_at = None;
            if visible {
                self.refresh();
            } else {
                self.needs_refresh_when_visible = true;
            }
        }
        // Not while a refresh runs: its end wakes the loop, and a deadline already past would spin it.
        let polling = self.polls && !self.is_dormant && self.has_loaded && !self.refresh_running && self.refresh_at.is_none();
        let mut poll_at = None;
        if polling && visible {
            let at = if self.poll_due { Instant::now() } else { self.last_refresh.map_or_else(Instant::now, |t| t + poll_every) };
            if at <= Instant::now() {
                self.poll_due = false;
                self.run_refresh(true);
            } else {
                poll_at = Some(at);
            }
        }
        if self.tree_flash.as_ref().is_some_and(|(_, at)| at.elapsed() >= Duration::from_millis(900)) {
            self.tree_flash = None;
        }
        let flash = self.tree_flash.as_ref().map(|(_, at)| *at + Duration::from_millis(900));
        [self.refresh_at, flash, poll_at].into_iter().flatten().min()
    }

    /// The window came back to the front: a repository that is not watched is looked at straight away, for what changed
    /// while the user was elsewhere.
    pub fn poll_soon(&mut self) {
        if self.polls {
            self.poll_due = true;
        }
    }

    // MARK: Commit ticks

    /// Whether `change` goes into the next commit.
    pub fn is_included(&self, change: &FileChange) -> bool {
        self.commit_overrides.get(&change.path).copied().unwrap_or(change.kind != ChangeKind::Untracked)
    }

    pub fn included_changes(&self) -> Vec<FileChange> {
        self.changes().iter().filter(|c| self.is_included(c)).cloned().collect()
    }

    /// A file's tick in the Changes list: mixed when some of its lines stay out of the commit.
    pub fn inclusion(&self, change: &FileChange) -> Inclusion {
        if !self.is_included(change) {
            return Inclusion::Off;
        }
        if self.excluded_lines.get(&change.path).is_some_and(|e| !e.is_empty()) {
            Inclusion::Mixed
        } else {
            Inclusion::On
        }
    }

    /// Ticks or unticks whole files: lines picked in them before are forgotten.
    pub fn set_included(&mut self, included: bool, changes: &[FileChange]) {
        for change in changes {
            let standard = change.kind != ChangeKind::Untracked;
            if included == standard {
                self.commit_overrides.remove(&change.path);
            } else {
                self.commit_overrides.insert(change.path.clone(), included);
            }
            self.excluded_lines.remove(&change.path);
        }
    }

    /// "main", "origin/main", "v1.0" for the Log's branch filter.
    pub fn log_ref_label(&self) -> Option<String> {
        self.log_ref.as_ref().map(|r| {
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
                if let Some(rest) = r.strip_prefix(prefix) {
                    return rest.to_string();
                }
            }
            r.clone()
        })
    }

    pub fn branch_label(&self) -> String {
        if let Some(b) = &self.status.branch {
            return b.clone();
        }
        if let Some(h) = &self.status.head_oid {
            return h.chars().take(7).collect();
        }
        if self.status.is_initial {
            l("no commits", "无提交")
        } else {
            "—".to_string()
        }
    }

    // MARK: Watching and refresh

    pub fn start_watching(&mut self) {
        if self.watcher.is_some() || self.polls || self.is_dormant {
            return;
        }
        // A watch on the share would start and never report anything.
        if crate::core::wsl::location(&self.url).is_some() {
            self.polls = true;
            return;
        }
        let poster = self.jobs.poster();
        self.watcher = FileWatcher::new(&self.url, move |_, git_state_changed| {
            poster.post(move |p: &mut Project| {
                p.file_index_stale = true;
                if git_state_changed && !p.commits.is_empty() {
                    p.log_stale = true;
                }
                p.schedule_refresh();
            });
        })
        .ok();
    }

    pub fn stop_watching(&mut self) {
        self.watcher = None;
        self.polls = false;
    }

    /// Coalesces bursts of file events (a build can produce thousands) into at most about one refresh a second.
    pub fn schedule_refresh(&mut self) {
        if self.refresh_at.is_some() {
            return;
        }
        let since = self.last_refresh.map_or(Duration::from_secs(10), |t| t.elapsed());
        let delay = Duration::from_millis(250).max(Duration::from_secs(1).saturating_sub(since));
        self.refresh_at = Some(Instant::now() + delay);
    }

    pub fn refresh(&mut self) {
        self.run_refresh(false);
    }

    /// `quietly`: a look taken every few seconds shows no spinner, which would otherwise blink all the time.
    fn run_refresh(&mut self, quietly: bool) {
        if self.is_dormant {
            return;
        }
        if self.refresh_running {
            self.refresh_queued = true;
            return;
        }
        self.refresh_running = true;
        self.is_refreshing = !quietly;
        self.needs_refresh_when_visible = false;
        let url = self.url.clone();
        let known = self.git_directory.clone();
        self.jobs.spawn(
            move || {
                let directory = known.or_else(|| remote::git_directory(&url));
                let status = git::status(&url, directory.as_deref());
                let prepared = directory.as_deref().and_then(remote::prepared_message);
                (directory, status, prepared)
            },
            |p: &mut Project, (directory, status, prepared): (Option<PathBuf>, git::Result<RepoStatus>, Option<String>)| {
                p.git_directory = directory;
                match status {
                    Ok(fresh) => {
                        // A merge that stopped for conflicts has its commit message ready; it goes in the box, as in the IDE.
                        let merging = fresh.operation == Some(RepoOperation::Merge);
                        if merging && p.status.operation != Some(RepoOperation::Merge) && p.commit_message.text.trim().is_empty() {
                            if let Some(prepared) = prepared {
                                p.commit_message.set_text(&prepared);
                                p.prefilled_message = Some(prepared);
                            }
                        } else if !merging {
                            if let Some(prefilled) = p.prefilled_message.take() {
                                if p.commit_message.text == prefilled {
                                    p.commit_message.set_text("");
                                }
                            }
                        }
                        // Ticks of files that are no longer changed mean nothing, and must not come back if the file
                        // changes again.
                        let paths: HashSet<&str> = fresh.changes.iter().map(|c| c.path.as_str()).collect();
                        p.commit_overrides.retain(|k, _| paths.contains(k.as_str()));
                        p.excluded_lines.retain(|k, _| paths.contains(k.as_str()));
                        if fresh != p.status {
                            // Unwatched, a different status is the only sign that files came or went, or that HEAD
                            // moved (a commit or a checkout in a terminal).
                            if p.polls {
                                p.file_index_stale = true;
                                let moved = fresh.head_oid != p.status.head_oid || fresh.branch != p.status.branch;
                                if moved && !p.commits.is_empty() {
                                    p.log_stale = true;
                                }
                            }
                            p.status = fresh;
                        }
                        p.error_message = None;
                    }
                    Err(error) => p.error_message = Some(error.message()),
                }
                p.has_loaded = true;
                p.is_refreshing = false;
                p.last_refresh = Some(Instant::now());
                p.refresh_running = false;
                if p.log_stale && p.tab == ProjectTab::Log {
                    p.log_stale = false;
                    p.load_log(true, 0, None);
                }
                // Files edited, or a commit made: what differs from the commit compared with changes too.
                // Two commits compared with each other stay as they are.
                if p.comparison.as_ref().is_some_and(|c| c.other.is_none()) {
                    p.load_comparison();
                }
                p.events.push(ProjectEvent::Refreshed);
                if p.refresh_queued {
                    p.refresh_queued = false;
                    p.schedule_refresh();
                }
            },
        );
    }

    // MARK: Requests

    pub fn request_for(&self, change: &FileChange, ignore_whitespace: bool) -> DiffRequest {
        let base = if change.kind == ChangeKind::Conflicted {
            self.conflict_base.rev().to_string()
        } else if self.status.is_initial {
            EMPTY_TREE.to_string()
        } else {
            "HEAD".to_string()
        };
        DiffRequest {
            root: self.url.clone(),
            path: change.path.clone(),
            old_path: change.old_path.clone(),
            kind: Some(change.kind),
            source: Source::Worktree { base },
            ignore_whitespace,
        }
    }

    pub fn request_in_commit(&self, change: &FileChange, commit: &Commit, ignore_whitespace: bool) -> DiffRequest {
        DiffRequest {
            root: self.url.clone(),
            path: change.path.clone(),
            old_path: change.old_path.clone(),
            kind: Some(change.kind),
            source: Source::Commit { hash: commit.hash.clone(), parent: commit.parents.first().cloned() },
            ignore_whitespace,
        }
    }

    pub fn request_compared(&self, change: &FileChange, comparison: &Comparison, ignore_whitespace: bool) -> DiffRequest {
        let mut source = match comparison.head() {
            Some(head) => Source::Commit { hash: head.to_string(), parent: Some(comparison.base.clone()) },
            None => Source::Worktree { base: comparison.base.clone() },
        };
        // A stash's new files are in a commit of their own.
        if change.kind == ChangeKind::Untracked {
            if let Some(untracked) = comparison.stash.as_ref().and_then(|s| s.untracked.clone()) {
                source = Source::Commit { hash: untracked, parent: Some(comparison.base.clone()) };
            }
        }
        DiffRequest {
            root: self.url.clone(),
            path: change.path.clone(),
            old_path: change.old_path.clone(),
            kind: Some(change.kind),
            source,
            ignore_whitespace,
        }
    }

    pub fn file_request(&self, path: &str) -> DiffRequest {
        DiffRequest { root: self.url.clone(), path: path.to_string(), old_path: None, kind: None, source: Source::File, ignore_whitespace: false }
    }

    pub fn selected_commit(&self) -> Option<&Commit> {
        let id = self.selected_commit_id.as_ref()?;
        self.commits.iter().find(|c| &c.hash == id)
    }

    // MARK: Log

    /// `at_least`: load this many commits in one go, so a commit picked further down (in the Git graph) is in the list.
    /// `completion` runs once the page is in place, unless a newer load replaced this one.
    pub fn load_log(&mut self, reset: bool, at_least: usize, completion: Option<AppCallback>) {
        if self.is_loading_log && !reset {
            return;
        }
        self.log_generation += 1;
        let generation = self.log_generation;
        self.is_loading_log = true;
        let skip = if reset { 0 } else { self.commits.len() };
        let query = self.log_query.text.clone();
        let all = self.log_all_branches;
        let reference = self.log_ref.clone();
        let filter = self.history.clone();
        let limit = LOG_PAGE_SIZE.max(at_least);
        let knows_paths = !self.history_paths.is_empty();
        let url = self.url.clone();
        self.jobs.spawn(
            move || {
                let mut paths = HashMap::new();
                let page = if let Some(filter) = filter {
                    if let Some(lines) = filter.lines {
                        // `git log -L` cannot name the file in each commit; the file's own history can.
                        if reset || !knows_paths {
                            let scope = vec![filter.rev.clone()];
                            if let Ok((_, p)) = history::file_history(&filter.path, &url, 0, 5000, "", &scope) {
                                paths = p;
                            }
                        }
                        history::line_history(&filter.path, lines, &filter.rev, &url, skip, limit, &query).unwrap_or_default()
                    } else {
                        // From the commit asked for (a file deleted since, say), otherwise from what the Log lists.
                        let scope: Vec<String> = if filter.rev != "HEAD" {
                            vec![filter.rev.clone()]
                        } else if all {
                            vec!["--all".to_string()]
                        } else {
                            reference.clone().into_iter().collect()
                        };
                        match history::file_history(&filter.path, &url, skip, limit, &query, &scope) {
                            Ok((commits, p)) => {
                                paths = p;
                                commits
                            }
                            Err(_) => Vec::new(),
                        }
                    }
                } else {
                    git::log(&url, skip, limit, &query, all, reference.as_deref()).unwrap_or_default()
                };
                (page, paths)
            },
            move |p: &mut Project, (page, paths): (Vec<Commit>, HashMap<String, String>)| {
                if p.log_generation != generation {
                    return;
                }
                if reset {
                    p.history_paths = paths;
                    p.commits = page.clone();
                } else {
                    for (k, v) in paths {
                        p.history_paths.entry(k).or_insert(v);
                    }
                    let known: HashSet<String> = p.commits.iter().map(|c| c.hash.clone()).collect();
                    p.commits.extend(page.iter().filter(|c| !known.contains(&c.hash)).cloned());
                }
                p.has_more_commits = page.len() >= limit;
                p.is_loading_log = false;
                if reset && p.selected_commit().is_none() {
                    p.selected_commit_id = p.commits.first().map(|c| c.hash.clone());
                    p.selected_commit_ids = p.selected_commit_id.iter().cloned().collect();
                    // A new commit is picked: its files come next (a completion given does that itself).
                    if completion.is_none() {
                        let id = p.id;
                        p.events.push(ProjectEvent::Callback(Box::new(move |app: &mut super::App| app.commit_selection_changed(id))));
                    }
                }
                if let Some(c) = completion {
                    p.events.push(ProjectEvent::Callback(c));
                }
            },
        );
    }

    /// Loads the file list of the selected commit. `completion` runs once the list is in place.
    pub fn load_selected_commit(&mut self, completion: AppCallback) {
        self.commit_generation += 1;
        let generation = self.commit_generation;
        let Some(commit) = self.selected_commit().cloned() else {
            self.commit_files.clear();
            self.commit_body.clear();
            self.selected_commit_file_id = None;
            self.events.push(ProjectEvent::Callback(completion));
            return;
        };
        let url = self.url.clone();
        self.jobs.spawn(
            {
                let commit = commit.clone();
                move || (git::commit_files(&commit, &url).unwrap_or_default(), git::commit_body(&commit.hash, &url))
            },
            move |p: &mut Project, (files, body): (Vec<FileChange>, String)| {
                if p.commit_generation != generation || p.selected_commit_id.as_deref() != Some(commit.hash.as_str()) {
                    return;
                }
                p.commit_files = files;
                p.commit_body = body;
                // A file's history shows that file in each commit, under whatever name it had there.
                if let Some(filter) = &p.history {
                    let path = p.history_paths.get(&commit.hash).cloned().unwrap_or_else(|| filter.path.clone());
                    let file = p.commit_files.iter().find(|f| f.path == path).or_else(|| {
                        p.commit_files.iter().find(|f| f.old_path.as_deref() == Some(path.as_str()) || f.path == filter.path)
                    });
                    if let Some(file) = file {
                        p.selected_commit_file_id = Some(ChangeRow::file_id(&file.path));
                        p.events.push(ProjectEvent::Callback(completion));
                        return;
                    }
                }
                let keep = p
                    .selected_commit_file_id
                    .clone()
                    .filter(|id| p.commit_files.iter().any(|f| ChangeRow::file_id(&f.path) == *id));
                p.selected_commit_file_id = keep.or_else(|| {
                    change_tree::ordered_files(&p.commit_files, false, "", false).first().map(|f| ChangeRow::file_id(&f.path))
                });
                p.events.push(ProjectEvent::Callback(completion));
            },
        );
    }

    // MARK: Comparison

    /// Lists what differs from the commit compared with, resolving it again first: a branch may have moved, and a fork
    /// point moves with HEAD.
    pub fn load_comparison(&mut self) {
        self.compare_generation += 1;
        let generation = self.compare_generation;
        let Some(comparison) = self.comparison.clone() else {
            self.compare_changes.clear();
            self.is_loading_compare = false;
            return;
        };
        if self.compare_changes.is_empty() {
            self.is_loading_compare = true;
        }
        let url = self.url.clone();
        self.jobs.spawn(
            {
                let comparison = comparison.clone();
                move || {
                    let mut current = comparison.clone();
                    let resolved = if comparison.fork_point {
                        history::merge_base("HEAD", &comparison.target, &url)
                    } else {
                        history::resolve_commit(&comparison.target, &url)
                    };
                    if let Some(r) = &resolved {
                        current.base = r.clone();
                    }
                    if let Some(other) = &comparison.other {
                        if let Some(hash) = history::resolve_commit(&other.target, &url) {
                            if let Some(o) = current.other.as_mut() {
                                o.hash = hash;
                            }
                        }
                    }
                    let files = match &comparison.stash {
                        Some(stash) => history_edits::stash_files(stash, &url).ok(),
                        None => history::compare_files(&current.base, current.head(), &url).ok(),
                    };
                    (current, resolved.is_some(), files)
                }
            },
            move |p: &mut Project, (current, resolved, files): (Comparison, bool, Option<Vec<FileChange>>)| {
                if p.compare_generation != generation {
                    return;
                }
                let Some(active) = p.comparison.clone() else { return };
                if active.target != comparison.target || active.fork_point != comparison.fork_point {
                    return;
                }
                if current != active {
                    p.comparison = Some(current);
                }
                let title = &comparison.title;
                match files {
                    Some(files) => {
                        if files != p.compare_changes {
                            p.compare_changes = files;
                        }
                        p.compare_error = (!resolved).then(|| {
                            lf!("{title} no longer exists · showing the last commit found", "{title} 已不存在 · 显示的是上次找到的提交")
                        });
                    }
                    None => p.compare_error = Some(lf!("Could not compare with {title}", "无法与 {title} 比较")),
                }
                p.is_loading_compare = false;
                p.events.push(ProjectEvent::Refreshed);
            },
        );
    }

    /// The compared file shown for `path` while comparing.
    pub fn compared_change(&self, path: &str) -> Option<&FileChange> {
        self.compare_changes.iter().find(|c| c.path == path)
    }

    // MARK: File index (Go to File)

    /// Every file in the repository: `then` runs with the list, at once when it is fresh, otherwise once it is read.
    pub fn with_files(&mut self, then: impl FnOnce(&mut Project, std::sync::Arc<Vec<String>>) + 'static) {
        if let Some(list) = self.file_index.clone().filter(|_| !self.file_index_stale) {
            then(self, list);
            return;
        }
        self.file_index_waiters.push(Box::new(then));
        if self.file_index_running {
            return;
        }
        self.file_index_running = true;
        let url = self.url.clone();
        self.jobs.spawn(
            move || git::list_files(&url),
            |p: &mut Project, list: Vec<String>| {
                let list = std::sync::Arc::new(list);
                p.file_index = Some(list.clone());
                p.file_index_stale = false;
                p.file_index_running = false;
                for waiter in std::mem::take(&mut p.file_index_waiters) {
                    waiter(p, list.clone());
                }
            },
        );
    }

    pub fn cached_files(&self) -> Option<&[String]> {
        self.file_index.as_deref().map(|v| v.as_slice())
    }

    /// Forces the next file listing, and the tree, to list the repository again.
    pub fn invalidate_files(&mut self) {
        self.file_index_stale = true;
        self.tree_force_reload = true;
    }

    // MARK: File tree

    /// Changes whenever the set of files in the working tree may have: HEAD moved, or something was added, removed,
    /// renamed or is untracked. Edits to tracked files leave it alone, so an agent rewriting files never makes the
    /// tree list the repository again.
    fn listing_stamp(&self) -> String {
        let mut stamp = self.status.head_oid.clone().unwrap_or_else(|| "-".into());
        for change in self.changes().iter().filter(|c| c.kind != ChangeKind::Modified) {
            stamp.push_str(&format!("\n{} {}", change.kind.letter(), change.path));
        }
        stamp
    }

    /// Builds the tree from the current file listing; does nothing when the tree is already up to date. Waits for the
    /// first status, which the listing is keyed on; the refresh that delivers it calls again.
    pub fn load_tree(&mut self) {
        if !self.has_loaded {
            return;
        }
        let stamp = self.listing_stamp();
        if self.tree_index.is_some() && !self.tree_force_reload && Some(&stamp) == self.tree_stamp.as_ref() {
            return;
        }
        if self.tree_running {
            self.tree_reload_queued = true;
            return;
        }
        if self.tree_index.is_some() {
            self.file_index_stale = true;
        }
        self.tree_force_reload = false;
        self.tree_stamp = Some(stamp);
        self.is_loading_tree = self.tree_index.is_none();
        self.tree_running = true;
        let first = self.tree_index.is_none();
        self.with_files(move |p, list| {
            let same = p.tree_index.as_ref().is_some_and(|i| i.paths == *list);
            if same {
                p.tree_loaded(first);
                return;
            }
            let list = (*list).clone();
            p.jobs.spawn(
                move || FileTreeIndex::new(list),
                move |p: &mut Project, index: FileTreeIndex| {
                    p.tree_paths = std::sync::Arc::new(index.paths.clone());
                    p.tree_index = Some(index);
                    p.tree_version += 1;
                    if !p.tree_filter.text.is_empty() {
                        p.update_tree_filter();
                    }
                    p.tree_loaded(first);
                },
            );
        });
    }

    fn tree_loaded(&mut self, first: bool) {
        self.is_loading_tree = false;
        self.tree_running = false;
        // A file located before the tree existed can only be scrolled to now.
        if first && self.tree_selected_id.is_some() {
            self.tree_reveal = true;
        }
        if self.tree_reload_queued {
            self.tree_reload_queued = false;
            self.load_tree();
        }
    }

    pub fn tree_index(&self) -> Option<&FileTreeIndex> {
        self.tree_index.as_ref()
    }

    /// The rows the tree shows right now: the fuzzy matches while filtering, otherwise the open directories.
    pub fn tree_rows(&self) -> Vec<TreeRow> {
        let Some(index) = &self.tree_index else { return Vec::new() };
        if !self.tree_filter.text.trim().is_empty() {
            return file_tree::match_rows(&self.tree_matches, self.changes());
        }
        file_tree::rows(index, &self.tree_expanded, self.changes())
    }

    pub fn update_tree_filter(&mut self) {
        self.tree_filter_generation += 1;
        let generation = self.tree_filter_generation;
        let query = self.tree_filter.text.trim().to_string();
        if query.is_empty() || self.tree_index.is_none() {
            self.tree_matches.clear();
            return;
        }
        let paths = self.tree_paths.clone();
        self.jobs.spawn(
            move || fuzzy::rank(&query, &paths, 200, || false),
            move |p: &mut Project, ranked: Vec<Ranked>| {
                if p.tree_filter_generation != generation {
                    return;
                }
                // Keep the selection on a visible row so Enter always opens something.
                if !ranked.iter().any(|r| Some(TreeRow::file_id(&r.path)) == p.tree_selected_id) {
                    p.tree_selected_id = ranked.first().map(|r| TreeRow::file_id(&r.path));
                }
                p.tree_matches = ranked;
            },
        );
    }

    /// Opens the directories above `path`, selects it and scrolls it into view. Returns false when the working tree
    /// has no such file.
    pub fn reveal_in_tree(&mut self, path: &str, flash: bool) -> bool {
        if let Some(index) = &self.tree_index {
            if !index.set.contains(path) {
                return false;
            }
        }
        if !self.tree_filter.text.is_empty() {
            self.tree_filter.set_text("");
            self.tree_matches.clear();
        }
        for directory in file_tree::ancestors(path) {
            self.tree_expanded.insert(directory);
        }
        let id = TreeRow::file_id(path);
        self.tree_selected_id = Some(id.clone());
        self.tree_reveal = true;
        if flash {
            self.tree_flash = Some((id, Instant::now()));
        }
        true
    }
}
