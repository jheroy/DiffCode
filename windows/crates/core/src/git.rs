//! Thin wrapper around the `git` executable, plus the parsers for its output.
//!
//! Shelling out keeps DiffCode tiny (no libgit2) and guarantees results match what the user sees on the
//! command line. Every call sets `GIT_OPTIONAL_LOCKS=0` so a background refresh never takes the index lock
//! away from the user's own git. All calls block: the app runs them on worker threads.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::remote::{self, RepoOperation};
use crate::text_codec;
use crate::util::{natural_cmp, split_max, split_nul, split_nul_keep_empty};
use crate::wsl;

/// SHA of git's well-known empty tree; used as the base of a repo with no commits.
pub const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// git ran and exited with a status the caller did not accept.
    Failed { status: i32, message: String },
    /// git could not be started at all (not installed, bad directory).
    Spawn(String),
    /// The caller cancelled the run.
    Cancelled,
}

impl Error {
    pub fn message(&self) -> String {
        match self {
            Error::Failed { status, message } => {
                if message.is_empty() { format!("git exited with status {status}") } else { message.clone() }
            }
            Error::Spawn(m) => m.clone(),
            Error::Cancelled => "cancelled".to_string(),
        }
    }

    pub fn status(&self) -> Option<i32> {
        match self {
            Error::Failed { status, .. } => Some(*status),
            _ => None,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

// MARK: - Locating git

static EXECUTABLE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// The git binary, found on first use.
pub fn executable() -> PathBuf {
    let mut slot = EXECUTABLE.lock().unwrap();
    if let Some(p) = slot.as_ref() {
        return p.clone();
    }
    let found = locate_executable();
    *slot = Some(found.clone());
    found
}

/// Looks again, after the user installed git.
pub fn relocate_executable() {
    *EXECUTABLE.lock().unwrap() = None;
}

/// True when a git binary exists where we would run it.
pub fn is_available() -> bool {
    let exe = executable();
    exe.is_absolute() && exe.is_file()
}

fn locate_executable() -> PathBuf {
    for candidate in candidates() {
        if candidate.is_file() {
            return candidate;
        }
    }
    // Let the OS search the PATH when it runs it.
    PathBuf::from(if cfg!(windows) { "git.exe" } else { "git" })
}

/// Real git binaries, in the order a shell would most likely find them.
pub fn candidates() -> Vec<PathBuf> {
    let mut list = Vec::new();
    let exe_name = if cfg!(windows) { "git.exe" } else { "git" };
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(exe_name);
            // Skip WindowsApps' zero-byte app-execution aliases and the like.
            if candidate.is_file() {
                list.push(candidate);
            }
        }
    }
    if cfg!(windows) {
        for var in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
            if let Some(base) = std::env::var_os(var) {
                list.push(PathBuf::from(base).join("Git").join("cmd").join("git.exe"));
            }
        }
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            list.push(PathBuf::from(local).join("Programs").join("Git").join("cmd").join("git.exe"));
        }
    } else {
        for p in [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/usr/bin/git",
        ] {
            list.push(PathBuf::from(p));
        }
    }
    list
}

/// What DiffCode's own process starts with but the programs it runs must not see.
const OWN_PROCESS_ONLY_KEYS: &[&str] = &["MallocSpaceEfficient"];

/// The app's environment as handed to child processes: git, the terminal's shell.
pub fn child_environment() -> Vec<(String, String)> {
    std::env::vars().filter(|(k, _)| !OWN_PROCESS_ONLY_KEYS.contains(&k.as_str())).collect()
}

fn base_environment() -> &'static Vec<(String, String)> {
    static ENV: OnceLock<Vec<(String, String)>> = OnceLock::new();
    ENV.get_or_init(|| {
        let mut env: Vec<(String, String)> = child_environment()
            .into_iter()
            .filter(|(k, _)| !matches!(k.as_str(), "GIT_OPTIONAL_LOCKS" | "GIT_TERMINAL_PROMPT" | "GIT_PAGER" | "LC_ALL"))
            .collect();
        env.push(("GIT_OPTIONAL_LOCKS".into(), "0".into()));
        env.push(("GIT_TERMINAL_PROMPT".into(), "0".into()));
        env.push(("GIT_PAGER".into(), "cat".into()));
        env.push(("LC_ALL".into(), "C".into()));
        env
    })
}

const BASE_ARGS: &[&str] = &["--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=false"];

// MARK: - Cancellation

/// Lets another thread stop a running git (or any child) process.
#[derive(Clone, Default)]
pub struct CancelToken(Arc<CancelInner>);

#[derive(Default)]
struct CancelInner {
    cancelled: AtomicBool,
    pid: Mutex<Option<u32>>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::SeqCst);
        if let Some(pid) = *self.0.pid.lock().unwrap() {
            terminate(pid);
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::SeqCst)
    }

    fn attach(&self, pid: u32) {
        *self.0.pid.lock().unwrap() = Some(pid);
        if self.is_cancelled() {
            terminate(pid);
        }
    }

    fn detach(&self) {
        *self.0.pid.lock().unwrap() = None;
    }
}

#[cfg(unix)]
fn terminate(pid: u32) {
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
}

#[cfg(windows)]
fn terminate(pid: u32) {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};
    unsafe {
        let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
        if !handle.is_null() {
            TerminateProcess(handle, 1);
            CloseHandle(handle);
        }
    }
}

/// Keeps a console window from flashing up for every git run on Windows.
#[cfg(windows)]
pub fn hide_console(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
pub fn hide_console(_cmd: &mut Command) {}

// MARK: - Running

/// One git invocation: `git::cmd(dir, ["status"]).ok(&[0, 1]).run()`.
pub struct Cmd {
    args: Vec<String>,
    dir: PathBuf,
    ok: Vec<i32>,
    env: Vec<(String, String)>,
    stdin: Option<Vec<u8>>,
    cancel: Option<CancelToken>,
}

pub fn cmd<I, S>(dir: &Path, args: I) -> Cmd
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    Cmd {
        args: args.into_iter().map(Into::into).collect(),
        dir: dir.to_path_buf(),
        ok: vec![0],
        env: Vec::new(),
        stdin: None,
        cancel: None,
    }
}

impl Cmd {
    /// Exit statuses that count as success (default: just 0).
    pub fn ok(mut self, statuses: &[i32]) -> Self {
        self.ok = statuses.to_vec();
        self
    }

    /// Added to git's usual environment (`GIT_INDEX_FILE`, `GIT_EDITOR`).
    pub fn env(mut self, key: &str, value: impl Into<String>) -> Self {
        self.env.push((key.to_string(), value.into()));
        self
    }

    pub fn stdin(mut self, data: Vec<u8>) -> Self {
        self.stdin = Some(data);
        self
    }

    pub fn cancel(mut self, token: &CancelToken) -> Self {
        self.cancel = Some(token.clone());
        self
    }

    pub fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }

    fn command(&self) -> Command {
        let wsl = wsl::location(&self.dir);
        let mut c = match &wsl {
            // A repository inside WSL: the distro's own git, in the same folder seen from inside.
            Some(at) => {
                let mut c = Command::new("wsl.exe");
                c.args(at.command_line("git")).args(BASE_ARGS).args(self.args.iter().map(|a| at.linux_argument(a)));
                c
            }
            None => {
                let mut c = Command::new(executable());
                c.args(BASE_ARGS).args(&self.args).current_dir(&self.dir);
                c
            }
        };
        c.env_clear();
        let mut passed: Vec<&str> = Vec::new();
        for (k, v) in base_environment() {
            if !self.env.iter().any(|(ek, _)| ek == k) {
                c.env(k, v);
            }
        }
        for (k, v) in &self.env {
            c.env(k, v);
            passed.push(k);
        }
        if wsl.is_some() {
            // wsl.exe hands the distro only the variables WSLENV names.
            passed.extend(["GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT", "GIT_PAGER", "LC_ALL"]);
            let existing = base_environment().iter().find(|(k, _)| k.eq_ignore_ascii_case("WSLENV")).map(|(_, v)| v.as_str());
            c.env("WSLENV", wsl::environment_list(existing, &passed));
        }
        hide_console(&mut c);
        c
    }

    /// Why the program could not start, said for what it was: git, or wsl.exe for a repository inside WSL.
    fn spawn_error(&self, e: std::io::Error) -> Error {
        if wsl::location(&self.dir).is_some() {
            Error::Spawn(wsl::not_started(&e.to_string()))
        } else {
            Error::Spawn(format!("Could not run git: {e}"))
        }
    }

    /// Runs git and returns stdout. Fails unless the exit status is one of the accepted ones.
    pub fn run(self) -> Result<Vec<u8>> {
        let mut command = self.command();
        command
            .stdin(if self.stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|e| self.spawn_error(e))?;
        if let Some(token) = &self.cancel {
            token.attach(child.id());
        }
        let writer = match (self.stdin, child.stdin.take()) {
            (Some(data), Some(mut pipe)) => Some(std::thread::spawn(move || {
                let _ = pipe.write_all(&data);
            })),
            _ => None,
        };
        // Drain stderr on another thread so a chatty process can't deadlock on a full pipe.
        let mut stderr = child.stderr.take();
        let err_reader = std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(e) = stderr.as_mut() {
                let _ = e.read_to_end(&mut buf);
            }
            buf
        });
        let mut out = Vec::new();
        if let Some(mut so) = child.stdout.take() {
            let _ = so.read_to_end(&mut out);
        }
        let err = err_reader.join().unwrap_or_default();
        if let Some(w) = writer {
            let _ = w.join();
        }
        let status = child.wait().map_err(|e| Error::Spawn(e.to_string()))?;
        if let Some(token) = &self.cancel {
            token.detach();
            if token.is_cancelled() {
                return Err(Error::Cancelled);
            }
        }
        let code = status.code().unwrap_or(-1);
        if self.ok.contains(&code) {
            return Ok(out);
        }
        // wsl.exe's own messages (no such distro, no git there) come in UTF-16.
        let wsl = wsl::location(&self.dir);
        let text = |data: &[u8]| if wsl.is_some() { wsl::decode_output(data) } else { String::from_utf8_lossy(data).into_owned() };
        let mut msg = text(&err).trim().to_string();
        // Some commands report on stdout (a merge's CONFLICT lines); keep that too, briefly.
        let head = text(&out[..out.len().min(4096)]).trim().to_string();
        if !head.is_empty() && (head.contains("CONFLICT") || msg.is_empty()) {
            msg = if msg.is_empty() { head } else { format!("{head}\n{msg}") };
        }
        if let Some(at) = &wsl {
            msg = wsl::explain(&msg, &at.distro);
        }
        Err(Error::Failed { status: code, message: msg })
    }

    pub fn run_string(self) -> Result<String> {
        self.run().map(|d| String::from_utf8_lossy(&d).into_owned())
    }

    /// Streams stdout in chunks. Return `false` from `on_chunk` to stop early (the process is terminated).
    pub fn stream(self, mut on_chunk: impl FnMut(&[u8]) -> bool) -> Result<()> {
        let mut command = self.command();
        command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        let mut child = command.spawn().map_err(|e| self.spawn_error(e))?;
        let token = self.cancel.clone().unwrap_or_default();
        token.attach(child.id());
        let mut stdout = child.stdout.take().expect("piped stdout");
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match stdout.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            if token.is_cancelled() || !on_chunk(&buf[..n]) {
                let _ = child.kill();
                break;
            }
        }
        drop(stdout);
        let _ = child.wait();
        token.detach();
        if token.is_cancelled() {
            return Err(Error::Cancelled);
        }
        Ok(())
    }
}

/// Runs git with the given args in `dir` and returns stdout (status 0 only).
pub fn run<I, S>(dir: &Path, args: I) -> Result<Vec<u8>>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    cmd(dir, args).run()
}

pub fn run_string<I, S>(dir: &Path, args: I) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    cmd(dir, args).run_string()
}

// MARK: - Repository discovery

/// The repository root containing `path`, or None when it is not inside a work tree.
pub fn repository_root(path: &Path) -> Option<PathBuf> {
    let out = run_string(path, ["rev-parse", "--show-toplevel"]).ok()?;
    let p = out.trim();
    if p.is_empty() { None } else { Some(path_from_git(path, p)) }
}

/// Why git would not take a folder as a repository, when the reason is not just that there is none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// Git's own words, without "fatal: ".
    pub message: String,
    /// For a repository that belongs to another user: the command git suggests to trust it.
    pub trust_command: Option<String>,
}

/// Asks git why the folder is no repository. None when it simply is none (or is one after all): "No Git repository
/// found there" is then the truth. Otherwise git's reason, such as a repository owned by another user, which git
/// refuses unless trusted with `safe.directory` (issue #7: a repository inside WSL, opened from Windows), or git
/// not starting at all.
pub fn refusal(path: &Path, env: &[(&str, &str)]) -> Option<Refusal> {
    let command = env.iter().fold(cmd(path, ["rev-parse", "--show-toplevel"]), |c, (k, v)| c.env(k, *v));
    match command.run() {
        Ok(_) | Err(Error::Cancelled) => None,
        Err(Error::Spawn(message)) => Some(Refusal { message, trust_command: None }),
        Err(Error::Failed { message, .. }) => parse_refusal(&message),
    }
}

pub fn parse_refusal(text: &str) -> Option<Refusal> {
    let lines: Vec<&str> = text.lines().map(str::trim).collect();
    let first = lines.iter().find(|l| !l.is_empty())?;
    if first.contains("not a git repository") {
        return None;
    }
    let message = first.strip_prefix("fatal: ").or_else(|| first.strip_prefix("error: ")).unwrap_or(first).to_string();
    let trust_command = lines.iter().find(|l| l.starts_with("git config") && l.contains("safe.directory")).map(|l| l.to_string());
    Some(Refusal { message, trust_command })
}

/// git prints Windows paths with forward slashes ("C:/work/app"); turn them into native ones.
pub fn normalize_git_path(p: &str) -> String {
    if cfg!(windows) { p.replace('/', "\\") } else { p.to_string() }
}

/// A path git printed when run in `dir`, as a native path: for a repository inside WSL, git spoke from inside the
/// distro (`/home/me/app`), so it is put back on the share (`\\wsl.localhost\Ubuntu\home\me\app`).
pub fn path_from_git(dir: &Path, p: &str) -> PathBuf {
    match wsl::location(dir) {
        Some(at) if p.starts_with('/') => at.windows_path(p),
        _ => PathBuf::from(normalize_git_path(p)),
    }
}

/// One of a repository's work trees, as `git worktree list` has it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Worktree {
    pub path: PathBuf,
    /// "refs/heads/x"; None when detached or bare.
    pub branch: Option<String>,
    pub is_bare: bool,
    /// Git's record of a work tree whose folder is gone.
    pub is_prunable: bool,
}

/// The repository's work trees, the main one first. Empty when git could not say.
pub fn worktrees(dir: &Path) -> Vec<Worktree> {
    run_string(dir, ["worktree", "list", "--porcelain"]).map(|text| parse_worktrees(&text, |p| path_from_git(dir, p))).unwrap_or_default()
}

pub fn parse_worktrees(text: &str, path: impl Fn(&str) -> PathBuf) -> Vec<Worktree> {
    let mut list: Vec<Worktree> = Vec::new();
    for line in text.lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            list.push(Worktree { path: path(p), ..Default::default() });
        } else if let Some(last) = list.last_mut() {
            if let Some(branch) = line.strip_prefix("branch ") {
                last.branch = Some(branch.to_string());
            } else if line == "bare" {
                last.is_bare = true;
            } else if line.starts_with("prunable") {
                last.is_prunable = true;
            }
        }
    }
    list
}

/// The most repositories one chosen folder adds.
pub const DISCOVERY_LIMIT: usize = 60;

/// The repositories a folder the user chose stands for: the one it is in, or those inside a plain folder
/// (`max_depth` levels down), each followed by the independent repositories inside it (a workspace that is a
/// repository itself, with others in it).
pub fn repositories_for(directory: &Path, max_depth: usize) -> Vec<PathBuf> {
    fn add(repository: PathBuf, found: &mut Vec<PathBuf>) {
        if found.len() >= DISCOVERY_LIMIT || found.contains(&repository) {
            return;
        }
        found.push(repository.clone());
        for inner in repositories_inside(&repository) {
            add(inner, found);
        }
    }
    let mut found = Vec::new();
    match repository_root(directory) {
        Some(root) => add(root, &mut found),
        None => {
            for repository in nested_repositories(directory, max_depth) {
                add(repository, &mut found);
            }
        }
    }
    found
}

/// The independent repositories in a repository's work tree, by what git says of its folders: one git does not
/// track is a candidate, and an ignored one counts only when it is a repository itself, so nothing is looked for
/// inside `node_modules` and the like. Not submodules (tracked), not hidden folders, and not linked work trees,
/// which belong to a repository rather than stand beside it.
pub fn repositories_inside(repository: &Path) -> Vec<PathBuf> {
    let folders = |ignored: bool| -> Vec<PathBuf> {
        let mut args = vec!["ls-files", "-z", "--others", "--exclude-standard", "--directory", "--no-empty-directory"];
        if ignored {
            args.push("--ignored");
        }
        let output = cmd(repository, args).run().unwrap_or_default();
        output
            .split(|b| *b == 0)
            .filter_map(|entry| entry.strip_suffix(b"/"))
            .map(|entry| String::from_utf8_lossy(entry).into_owned())
            .filter(|path| !path.split('/').any(|part| part.starts_with('.')))
            .map(|path| path.split('/').fold(repository.to_path_buf(), |folder, part| folder.join(part)))
            .collect()
    };
    let mut found = Vec::new();
    for folder in folders(false) {
        if folder.join(".git").exists() {
            if is_independent_repository(&folder) {
                found.push(folder);
            }
        } else {
            found.extend(nested_repositories(&folder, 2).into_iter().filter(|f| is_independent_repository(f)));
        }
    }
    found.extend(folders(true).into_iter().filter(|f| is_independent_repository(f)));
    found.sort_by(|a, b| natural_cmp(&a.to_string_lossy(), &b.to_string_lossy()));
    found
}

/// Whether a folder is a repository of its own: `.git` is a folder, or a file that names one elsewhere
/// (`--separate-git-dir`). A linked work tree's `.git` file points into its repository's `worktrees`.
pub fn is_independent_repository(folder: &Path) -> bool {
    let dot_git = folder.join(".git");
    if dot_git.is_dir() {
        return true;
    }
    std::fs::read_to_string(&dot_git).map(|text| !text.replace('\\', "/").contains("/worktrees/")).unwrap_or(false)
}

/// Repositories directly inside a plain folder (handy for multi-repo workspaces).
pub fn nested_repositories(path: &Path, max_depth: usize) -> Vec<PathBuf> {
    let mut found = Vec::new();
    fn scan(dir: &Path, depth: usize, max_depth: usize, found: &mut Vec<PathBuf>) {
        if depth > max_depth {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut dirs: Vec<PathBuf> = entries
            .filter_map(|e| e.ok())
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .map(|e| e.path())
            .collect();
        dirs.sort_by(|a, b| {
            natural_cmp(
                &a.file_name().unwrap_or_default().to_string_lossy(),
                &b.file_name().unwrap_or_default().to_string_lossy(),
            )
        });
        for entry in dirs {
            if entry.join(".git").exists() {
                found.push(entry);
            } else {
                scan(&entry, depth + 1, max_depth, found);
            }
            if found.len() >= DISCOVERY_LIMIT {
                return;
            }
        }
    }
    scan(path, 1, max_depth, &mut found);
    found
}

// MARK: - Status

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChangeKind {
    Modified,
    Added,
    Deleted,
    Renamed,
    Untracked,
    Conflicted,
}

impl ChangeKind {
    pub fn letter(self) -> &'static str {
        match self {
            ChangeKind::Modified => "M",
            ChangeKind::Added => "A",
            ChangeKind::Deleted => "D",
            ChangeKind::Renamed => "R",
            ChangeKind::Untracked => "U",
            ChangeKind::Conflicted => "!",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FileChange {
    pub path: String,
    pub old_path: Option<String>,
    pub kind: ChangeKind,
    pub is_submodule: bool,
    pub additions: Option<usize>,
    pub deletions: Option<usize>,
}

impl FileChange {
    pub fn new(path: impl Into<String>, old_path: Option<String>, kind: ChangeKind) -> Self {
        FileChange { path: path.into(), old_path, kind, is_submodule: false, additions: None, deletions: None }
    }

    pub fn name(&self) -> &str {
        crate::util::file_name(&self.path)
    }

    pub fn directory(&self) -> &str {
        crate::util::parent_dir(&self.path)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RepoStatus {
    pub branch: Option<String>,
    pub head_oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: usize,
    pub behind: usize,
    pub is_initial: bool,
    pub changes: Vec<FileChange>,
    /// A merge, rebase, cherry-pick or revert that stopped for the user.
    pub operation: Option<RepoOperation>,
}

impl RepoStatus {
    pub fn conflict_count(&self) -> usize {
        self.changes.iter().filter(|c| c.kind == ChangeKind::Conflicted).count()
    }

    pub fn short_head(&self) -> String {
        self.head_oid.as_deref().map(|h| h.chars().take(7).collect()).unwrap_or_default()
    }
}

pub fn status(dir: &Path, git_directory: Option<&Path>) -> Result<RepoStatus> {
    let data = run(dir, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])?;
    let mut status = parse_status(&data);
    if let Some(gd) = git_directory {
        status.operation = remote::operation(gd);
    }
    if !status.changes.is_empty() {
        apply_numstat(&mut status, dir);
    }
    Ok(status)
}

/// Parses `git status --porcelain=v2 --branch -z`.
pub fn parse_status(data: &[u8]) -> RepoStatus {
    let mut status = RepoStatus::default();
    let tokens = split_nul(data);
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        i += 1;
        let Some(first) = token.chars().next() else { continue };
        match first {
            '#' => {
                let parts = split_max(token, ' ', 2);
                if parts.len() < 3 {
                    continue;
                }
                match parts[1].as_str() {
                    "branch.oid" => {
                        if parts[2] == "(initial)" {
                            status.is_initial = true;
                        } else {
                            status.head_oid = Some(parts[2].clone());
                        }
                    }
                    "branch.head" => {
                        status.branch = if parts[2] == "(detached)" { None } else { Some(parts[2].clone()) };
                    }
                    "branch.upstream" => status.upstream = Some(parts[2].clone()),
                    "branch.ab" => {
                        for piece in parts[2].split(' ') {
                            if let Some(n) = piece.strip_prefix('+') {
                                status.ahead = n.parse().unwrap_or(0);
                            }
                            if let Some(n) = piece.strip_prefix('-') {
                                status.behind = n.parse().unwrap_or(0);
                            }
                        }
                    }
                    _ => {}
                }
            }
            '1' => {
                // 1 XY sub mH mI mW hH hI path
                let f = split_max(token, ' ', 8);
                if f.len() != 9 {
                    continue;
                }
                let mut c = FileChange::new(f[8].clone(), None, kind_from_xy(&f[1]));
                c.is_submodule = f[2].starts_with('S');
                status.changes.push(c);
            }
            '2' => {
                // 2 XY sub mH mI mW hH hI Xscore path <NUL> origPath
                let f = split_max(token, ' ', 9);
                let orig = tokens.get(i).cloned();
                i += 1;
                if f.len() != 10 {
                    continue;
                }
                let mut k = kind_from_xy(&f[1]);
                let mut old = orig;
                // A copy leaves the source in place, so present it as a plain addition.
                if f[8].starts_with('C') {
                    k = ChangeKind::Added;
                    old = None;
                } else if k == ChangeKind::Modified {
                    k = ChangeKind::Renamed;
                }
                let mut c = FileChange::new(f[9].clone(), old, k);
                c.is_submodule = f[2].starts_with('S');
                status.changes.push(c);
            }
            'u' => {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = split_max(token, ' ', 10);
                if f.len() != 11 {
                    continue;
                }
                status.changes.push(FileChange::new(f[10].clone(), None, ChangeKind::Conflicted));
            }
            '?' => {
                status.changes.push(FileChange::new(token.get(2..).unwrap_or("").to_string(), None, ChangeKind::Untracked));
            }
            _ => {}
        }
    }
    status.changes.sort_by(|a, b| natural_cmp(&a.path, &b.path));
    status
}

/// Collapses the index (X) and worktree (Y) columns into one HEAD-vs-worktree verdict.
fn kind_from_xy(xy: &str) -> ChangeKind {
    let chars: Vec<char> = xy.chars().collect();
    if chars.len() != 2 {
        return ChangeKind::Modified;
    }
    let (x, y) = (chars[0], chars[1]);
    if x == 'U' || y == 'U' {
        return ChangeKind::Conflicted;
    }
    if y == 'D' || x == 'D' {
        return ChangeKind::Deleted;
    }
    if x == 'A' {
        return ChangeKind::Added;
    }
    if x == 'R' {
        return ChangeKind::Renamed;
    }
    ChangeKind::Modified
}

fn apply_numstat(status: &mut RepoStatus, dir: &Path) {
    let base = if status.is_initial { EMPTY_TREE } else { "HEAD" };
    let stats = run(dir, ["diff", "--numstat", "-z", "-M", base]).map(|d| parse_numstat(&d)).unwrap_or_default();
    for change in status.changes.iter_mut() {
        if let Some(&(a, d)) = stats.get(&change.path) {
            change.additions = Some(a);
            change.deletions = Some(d);
        } else if change.kind == ChangeKind::Untracked {
            // Untracked files are invisible to `git diff`; their lines are counted directly.
            if let Some(lines) = line_count(&dir.join(&change.path)) {
                change.additions = Some(lines);
                change.deletions = Some(0);
            }
        }
    }
}

/// Lines in a text file of up to 512 KB; None for anything bigger, binary or unreadable.
pub fn line_count(path: &Path) -> Option<usize> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > 512 * 1024 {
        return None;
    }
    let data = std::fs::read(path).ok()?;
    if text_codec::looks_binary(&data) {
        return None;
    }
    Some(line_count_of(&data))
}

/// Lines as git counts them: a last line without a newline counts, a final newline adds none.
pub fn line_count_of(data: &[u8]) -> usize {
    let mut lines = data.iter().filter(|&&b| b == b'\n').count();
    if let Some(&last) = data.last() {
        if last != b'\n' {
            lines += 1;
        }
    }
    lines
}

/// Parses `git diff --numstat -z`. Renames are emitted as `a\tb\t\0old\0new\0`.
pub fn parse_numstat(data: &[u8]) -> HashMap<String, (usize, usize)> {
    let mut result = HashMap::new();
    let tokens = split_nul_keep_empty(data);
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        i += 1;
        let f = split_max(token, '\t', 2);
        if f.len() != 3 {
            continue;
        }
        let mut path = f[2].clone();
        if path.is_empty() && i + 1 < tokens.len() {
            path = tokens[i + 1].clone();
            i += 2;
        }
        // "-" marks binary.
        if let (Ok(a), Ok(d)) = (f[0].parse::<usize>(), f[1].parse::<usize>()) {
            result.insert(path, (a, d));
        }
    }
    result
}

// MARK: - Log

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Commit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    /// Seconds since 1970.
    pub date: i64,
    pub refs: Vec<String>,
    pub subject: String,
    pub body: String,
}

impl Commit {
    pub fn short_hash(&self) -> String {
        self.hash.chars().take(7).collect()
    }

    pub fn is_merge(&self) -> bool {
        self.parents.len() > 1
    }
}

/// One commit's fields, separated by 0x1f; `LOG_FORMAT` ends each record with 0x1e.
pub const LOG_FIELDS: &str = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s";
pub const LOG_FORMAT: &str = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e";

/// - `reference`: a full ref name (`refs/heads/x`) whose history to list instead of HEAD's. Ignored with `all_branches`.
pub fn log(
    dir: &Path,
    skip: usize,
    limit: usize,
    query: &str,
    all_branches: bool,
    reference: Option<&str>,
) -> Result<Vec<Commit>> {
    let scope: Vec<String> = if all_branches {
        vec!["--all".into()]
    } else {
        reference.map(|r| vec![r.to_string()]).unwrap_or_default()
    };
    let mut args: Vec<String> = vec![
        "log".into(),
        format!("--format={LOG_FORMAT}"),
        "--decorate=full".into(),
        format!("--skip={skip}"),
        format!("--max-count={limit}"),
        "--date-order".into(),
    ];
    args.extend(scope.iter().cloned());
    let q = query.trim();
    if !q.is_empty() {
        // Match the subject/body or the author, case-insensitively.
        args.extend(["-i".into(), "--fixed-strings".into(), format!("--grep={q}")]);
    }
    let data = cmd(dir, args).ok(&[0, 128]).run()?;
    let mut commits = parse_log(&data);
    if !q.is_empty() && skip == 0 {
        // A query that looks like a hash should also find that commit; author matches are merged in too.
        if q.len() >= 4 && q.chars().all(|c| c.is_ascii_hexdigit()) {
            if let Ok(hit) = run(dir, ["log", "-1", &format!("--format={LOG_FORMAT}"), "--decorate=full", q]) {
                let direct = parse_log(&hit);
                commits.retain(|c| !direct.iter().any(|d| d.hash == c.hash));
                let mut merged = direct;
                merged.extend(commits);
                commits = merged;
            }
        }
        let mut author_args: Vec<String> = vec![
            "log".into(),
            format!("--format={LOG_FORMAT}"),
            "--decorate=full".into(),
            format!("--max-count={limit}"),
            "-i".into(),
            format!("--author={q}"),
        ];
        author_args.extend(scope);
        if let Ok(by_author) = run(dir, author_args) {
            let seen: HashSet<String> = commits.iter().map(|c| c.hash.clone()).collect();
            commits.extend(parse_log(&by_author).into_iter().filter(|c| !seen.contains(&c.hash)));
            commits.sort_by_key(|c| std::cmp::Reverse(c.date));
        }
    }
    Ok(commits)
}

pub fn parse_log(data: &[u8]) -> Vec<Commit> {
    data.split(|&b| b == 0x1e).filter(|r| !r.is_empty()).filter_map(parse_commit).collect()
}

/// One record of `LOG_FIELDS`.
pub fn parse_commit(record: &[u8]) -> Option<Commit> {
    let fields: Vec<String> = record.split(|&b| b == 0x1f).map(|f| String::from_utf8_lossy(f).into_owned()).collect();
    if fields.len() < 7 {
        return None;
    }
    let hash = fields[0].trim().to_string();
    if hash.len() < 7 {
        return None;
    }
    let refs = fields[5].split(',').map(|r| r.trim().to_string()).filter(|r| !r.is_empty()).collect();
    Some(Commit {
        hash,
        parents: fields[1].split(' ').filter(|p| !p.is_empty()).map(str::to_string).collect(),
        author: fields[2].clone(),
        email: fields[3].clone(),
        date: fields[4].trim().parse().unwrap_or(0),
        refs,
        subject: fields[6].clone(),
        body: String::new(),
    })
}

pub fn commit_body(hash: &str, dir: &Path) -> String {
    run_string(dir, ["log", "-1", "--format=%B", hash]).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// Files touched by a commit, compared against its first parent (or the empty tree for a root commit).
pub fn commit_files(commit: &Commit, dir: &Path) -> Result<Vec<FileChange>> {
    let base = commit.parents.first().map(String::as_str).unwrap_or(EMPTY_TREE);
    let names = run(dir, ["diff", "--name-status", "-z", "-M", base, &commit.hash])?;
    let stats = run(dir, ["diff", "--numstat", "-z", "-M", base, &commit.hash]).map(|d| parse_numstat(&d)).unwrap_or_default();
    let mut changes = parse_name_status(&names);
    for c in changes.iter_mut() {
        if let Some(&(a, d)) = stats.get(&c.path) {
            c.additions = Some(a);
            c.deletions = Some(d);
        }
    }
    Ok(changes)
}

/// Parses `git diff --name-status -z`: `M\0path\0`, `R100\0old\0new\0`.
pub fn parse_name_status(data: &[u8]) -> Vec<FileChange> {
    let tokens = split_nul(data);
    let mut changes = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        let code = &tokens[i];
        i += 1;
        let Some(letter) = code.chars().next() else { break };
        if i >= tokens.len() {
            break;
        }
        match letter {
            'R' => {
                if i + 1 >= tokens.len() {
                    break;
                }
                changes.push(FileChange::new(tokens[i + 1].clone(), Some(tokens[i].clone()), ChangeKind::Renamed));
                i += 2;
            }
            'C' => {
                if i + 1 >= tokens.len() {
                    break;
                }
                changes.push(FileChange::new(tokens[i + 1].clone(), None, ChangeKind::Added));
                i += 2;
            }
            'A' => {
                changes.push(FileChange::new(tokens[i].clone(), None, ChangeKind::Added));
                i += 1;
            }
            'D' => {
                changes.push(FileChange::new(tokens[i].clone(), None, ChangeKind::Deleted));
                i += 1;
            }
            'U' => {
                changes.push(FileChange::new(tokens[i].clone(), None, ChangeKind::Conflicted));
                i += 1;
            }
            _ => {
                changes.push(FileChange::new(tokens[i].clone(), None, ChangeKind::Modified));
                i += 1;
            }
        }
    }
    changes.sort_by(|a, b| natural_cmp(&a.path, &b.path));
    changes
}

/// Blob contents at `rev:path`, or None when the path does not exist in that revision.
pub fn blob(rev: &str, path: &str, dir: &Path) -> Option<Vec<u8>> {
    run(dir, ["cat-file".to_string(), "blob".to_string(), format!("{rev}:{path}")]).ok()
}

/// Every tracked and untracked-but-not-ignored file, relative to the repository root.
pub fn list_files(dir: &Path) -> Vec<String> {
    let Ok(data) = run(dir, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut files = Vec::new();
    for token in data.split(|&b| b == 0).filter(|t| !t.is_empty()) {
        let path = String::from_utf8_lossy(token).into_owned();
        if seen.insert(path.clone()) {
            files.push(path);
        }
    }
    files
}

// MARK: - Grep

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct GrepHit {
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GrepOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub regex: bool,
    pub file_mask: String,
}

/// Streams `git grep` matches. Covers tracked and untracked files while honouring .gitignore.
pub fn grep(
    pattern: &str,
    options: &GrepOptions,
    dir: &Path,
    limit: usize,
    cancel: Option<&CancelToken>,
    mut on_hits: impl FnMut(Vec<GrepHit>),
) -> Result<()> {
    let mut args: Vec<String> =
        ["grep", "-n", "--column", "-I", "--untracked", "--null", "--no-color"].iter().map(|s| s.to_string()).collect();
    args.push(if options.regex { "-E".into() } else { "-F".into() });
    if !options.case_sensitive {
        args.push("-i".into());
    }
    if options.whole_word {
        args.push("-w".into());
    }
    args.push("-e".into());
    args.push(pattern.to_string());
    let masks: Vec<&str> =
        options.file_mask.split([',', ' ', ';']).filter(|m| !m.is_empty()).collect();
    if !masks.is_empty() {
        args.push("--".into());
        for m in masks {
            args.push(if m.contains('*') || m.contains('/') { m.to_string() } else { format!("*{m}*") });
        }
    }
    let mut pending: Vec<u8> = Vec::new();
    let mut total = 0usize;
    let mut c = cmd(dir, args);
    if let Some(t) = cancel {
        c = c.cancel(t);
    }
    c.stream(|chunk| {
        pending.extend_from_slice(chunk);
        let mut hits = Vec::new();
        // Records are newline-terminated; hold back a trailing partial record for the next chunk.
        let mut cursor = 0;
        while let Some(nl) = pending[cursor..].iter().position(|&b| b == b'\n') {
            let record = &pending[cursor..cursor + nl];
            cursor += nl + 1;
            if let Some(hit) = parse_grep_record(record) {
                hits.push(hit);
                total += 1;
                if total >= limit {
                    break;
                }
            }
        }
        pending.drain(..cursor);
        if !hits.is_empty() {
            on_hits(hits);
        }
        total < limit
    })
}

/// One `--null` record: `path\0line\0column\0text`.
pub fn parse_grep_record(record: &[u8]) -> Option<GrepHit> {
    let mut parts = record.splitn(4, |&b| b == 0);
    let path = parts.next()?;
    let line: usize = std::str::from_utf8(parts.next()?).ok()?.parse().ok()?;
    let column: usize = std::str::from_utf8(parts.next()?).ok()?.parse().ok()?;
    let mut text = parts.next()?;
    if text.last() == Some(&b'\r') {
        text = &text[..text.len() - 1];
    }
    // Minified files can put megabytes on one line; keep only a window around the match.
    let mut col = column;
    if text.len() > 400 {
        let start = column.saturating_sub(1).saturating_sub(120);
        let end = text.len().min(start + 400);
        text = &text[start..end];
        col = column - start;
    }
    Some(GrepHit {
        path: String::from_utf8_lossy(path).into_owned(),
        line,
        column: col,
        text: String::from_utf8_lossy(text).into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn work_trees_are_read_from_git() {
        let text = "worktree /w/ws\nHEAD 4d15\nbranch refs/heads/main\n\nworktree /w/ws-fix\nHEAD 4d15\nbranch refs/heads/fix\n\n\
worktree /w/gone\nHEAD 4d15\ndetached\nprunable gitdir file points to non-existent location\n\nworktree /w/bare\nbare\n";
        let list = parse_worktrees(text, |p| PathBuf::from(normalize_git_path(p)));
        assert_eq!(list.len(), 4);
        assert_eq!(list[1].branch.as_deref(), Some("refs/heads/fix"));
        assert!(list[2].is_prunable && list[2].branch.is_none());
        assert!(list[3].is_bare);
    }

    /// Issue #7: a repository git refuses (here one it takes for another user's) says why, instead of "none there".
    #[test]
    fn a_refused_repository_says_why() {
        if !is_available() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let repository = dir.path().join("repository");
        let plain = dir.path().join("plain");
        std::fs::create_dir_all(&repository).unwrap();
        std::fs::create_dir_all(&plain).unwrap();
        cmd(&repository, ["init", "-q"]).run().unwrap();
        // Without the machine's own settings: GitHub's Windows runners trust every folder (`safe.directory = *`).
        let empty = dir.path().join("empty.gitconfig");
        std::fs::write(&empty, "").unwrap();
        let empty = empty.to_string_lossy().into_owned();
        let isolated = [("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", empty.as_str()), ("GIT_TEST_ASSUME_DIFFERENT_OWNER", "1")];
        let refused = refusal(&repository, &isolated).expect("refused");
        assert!(refused.message.starts_with("detected dubious ownership"), "{refused:?}");
        assert!(refused.trust_command.unwrap().starts_with("git config --global --add safe.directory"));
        // A repository git takes, and a folder that is none, have nothing to explain.
        assert_eq!(refusal(&repository, &[]), None);
        assert_eq!(refusal(&plain, &[]), None);
        assert_eq!(parse_refusal("fatal: something else went wrong\r\n").map(|r| r.message), Some("something else went wrong".into()));
    }

    /// Issue #5: a workspace that is a repository itself, with others in it.
    #[test]
    fn a_repository_brings_the_repositories_inside_it() {
        if !is_available() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let workspace = base.join("workspace");
        let git = |at: &Path, args: &[&str]| {
            std::fs::create_dir_all(at).unwrap();
            let identity = ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"];
            cmd(at, identity.iter().chain(args).copied()).run().unwrap();
        };
        std::fs::create_dir_all(workspace.join("docs")).unwrap();
        git(&workspace, &["init", "-q", "-b", "main"]);
        std::fs::write(workspace.join(".gitignore"), "api/\nweb/\nnode_modules/\nvendor/\n").unwrap();
        std::fs::write(workspace.join("docs").join("readme.md"), "# Docs\n").unwrap();
        git(&workspace, &["add", "-A"]);
        git(&workspace, &["commit", "-q", "-m", "Workspace"]);
        let repository = |path: &str| git(&path.split('/').fold(workspace.clone(), |p, part| p.join(part)), &["init", "-q", "-b", "main"]);
        // Ignored repositories, one not ignored below a tracked folder, one below an untracked folder.
        for path in ["api", "web", "docs/handbook", "tools/deep/thing"] {
            repository(path);
        }
        // A repository inside a repository found, and one in a folder that one ignores.
        std::fs::write(workspace.join("api").join(".gitignore"), "build/\n").unwrap();
        for path in ["api/services/core", "api/build"] {
            repository(path);
        }
        // Not looked for: below an ignored folder that is no repository, in a hidden folder, a linked work tree.
        for path in ["vendor/dependency", "node_modules/package", ".cache/clone"] {
            repository(path);
        }
        git(&workspace, &["worktree", "add", "-q", "linked", "-b", "linked"]);

        let names = |found: Vec<PathBuf>| -> Vec<String> {
            found
                .iter()
                .map(|p| p.canonicalize().unwrap().strip_prefix(&base).unwrap().to_string_lossy().replace('\\', "/"))
                .collect()
        };
        let expected = [
            "workspace",
            "workspace/api",
            "workspace/api/build",
            "workspace/api/services/core",
            "workspace/docs/handbook",
            "workspace/tools/deep/thing",
            "workspace/web",
        ];
        assert_eq!(names(repositories_for(&workspace, 3)), expected);
        assert_eq!(names(repositories_for(&workspace.join("docs"), 3)), expected);
        assert_eq!(names(repositories_for(&base, 3)), expected);
        assert_eq!(names(repositories_for(&workspace.join("web"), 3)), ["workspace/web"]);
    }

    #[test]
    fn parses_porcelain_v2() {
        let data = b"# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0\
1 .M N... 100644 100644 100644 aaa bbb src/b.kt\0\
2 R. N... 100644 100644 100644 aaa bbb R100 new.kt\0old.kt\0\
u UU N... 100644 100644 100644 100644 a b c conflict.txt\0\
? untracked file.txt\0";
        let s = parse_status(data);
        assert_eq!(s.branch.as_deref(), Some("main"));
        assert_eq!(s.head_oid.as_deref(), Some("abc123"));
        assert_eq!((s.ahead, s.behind), (2, 1));
        let kinds: Vec<_> = s.changes.iter().map(|c| (c.path.as_str(), c.kind)).collect();
        assert_eq!(
            kinds,
            vec![
                ("conflict.txt", ChangeKind::Conflicted),
                ("new.kt", ChangeKind::Renamed),
                ("src/b.kt", ChangeKind::Modified),
                ("untracked file.txt", ChangeKind::Untracked),
            ]
        );
        assert_eq!(s.changes[1].old_path.as_deref(), Some("old.kt"));
    }

    #[test]
    fn parses_numstat_with_renames() {
        let data = b"3\t1\ta.kt\0-\t-\timg.png\0" as &[u8];
        let mut v = data.to_vec();
        v.extend_from_slice(b"2\t0\t\0old.kt\0new.kt\0");
        let m = parse_numstat(&v);
        assert_eq!(m.get("a.kt"), Some(&(3, 1)));
        assert_eq!(m.get("new.kt"), Some(&(2, 0)));
        assert!(!m.contains_key("img.png"));
    }

    #[test]
    fn parses_grep_records() {
        let hit = parse_grep_record(b"src/a.kt\x0012\x005\x00  val x = 1\r").unwrap();
        assert_eq!((hit.path.as_str(), hit.line, hit.column, hit.text.as_str()), ("src/a.kt", 12, 5, "  val x = 1"));
    }

    #[test]
    fn parses_log_records() {
        let rec = b"0123456789abcdef\x1fp1 p2\x1fAda\x1fada@example.com\x1f1700000000\x1fHEAD -> refs/heads/main, tag: refs/tags/v1\x1fSubject\x1e";
        let commits = parse_log(rec);
        assert_eq!(commits.len(), 1);
        assert_eq!(commits[0].parents, vec!["p1", "p2"]);
        assert_eq!(commits[0].refs, vec!["HEAD -> refs/heads/main", "tag: refs/tags/v1"]);
        assert!(commits[0].is_merge());
    }

    #[test]
    fn line_counts_like_git() {
        assert_eq!(line_count_of(b"a\nb"), 2);
        assert_eq!(line_count_of(b"a\nb\n"), 2);
        assert_eq!(line_count_of(b""), 0);
    }
}
