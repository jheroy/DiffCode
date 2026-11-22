//! Branches, remotes, git's interrupted operations and conflicts. Each runs git as the user would in a terminal;
//! nothing here forces anything (no `--force`, no `reset --hard`).

use std::path::{Path, PathBuf};

use crate::git::{self, cmd, parse_log, run, run_string, Commit, Result, LOG_FORMAT};
use crate::lang::l;

/// What git is in the middle of: a merge, rebase, cherry-pick or revert that stopped for the user to resolve conflicts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RepoOperation {
    Merge,
    Rebase,
    CherryPick,
    Revert,
}

impl RepoOperation {
    /// "Merging", for the banner over the Changes list.
    pub fn title(self) -> String {
        match self {
            RepoOperation::Merge => l("Merging", "正在合并"),
            RepoOperation::Rebase => l("Rebasing", "正在变基"),
            RepoOperation::CherryPick => l("Cherry-picking", "正在拣选"),
            RepoOperation::Revert => l("Reverting", "正在还原"),
        }
    }

    /// The git command that continues or abandons it.
    pub fn command(self) -> &'static str {
        match self {
            RepoOperation::Merge => "merge",
            RepoOperation::Rebase => "rebase",
            RepoOperation::CherryPick => "cherry-pick",
            RepoOperation::Revert => "revert",
        }
    }
}

/// How a pull joins the branch with what came in, when they have both moved on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PullMode {
    /// Whatever the user's git settings say (`pull.rebase`, `pull.ff`).
    Configured,
    Merge,
    Rebase,
}

/// The repository's own directory: `.git`, or a linked worktree's directory inside the main one.
pub fn git_directory(dir: &Path) -> Option<PathBuf> {
    let out = run_string(dir, ["rev-parse", "--absolute-git-dir"]).ok()?;
    let p = out.trim();
    if p.is_empty() { None } else { Some(git::path_from_git(dir, p)) }
}

/// What git is in the middle of, from the marker files it keeps in its directory.
pub fn operation(git_directory: &Path) -> Option<RepoOperation> {
    let exists = |name: &str| git_directory.join(name).exists();
    if exists("rebase-merge") || exists("rebase-apply") {
        return Some(RepoOperation::Rebase);
    }
    if exists("MERGE_HEAD") {
        return Some(RepoOperation::Merge);
    }
    if exists("CHERRY_PICK_HEAD") {
        return Some(RepoOperation::CherryPick);
    }
    if exists("REVERT_HEAD") {
        return Some(RepoOperation::Revert);
    }
    None
}

/// The message git prepared for the commit that finishes a merge (`MERGE_MSG`), without its comment lines.
pub fn prepared_message(git_directory: &Path) -> Option<String> {
    let text = std::fs::read_to_string(git_directory.join("MERGE_MSG")).ok()?;
    let kept: Vec<&str> = text.split('\n').filter(|l| !l.starts_with('#')).collect();
    let message = kept.join("\n").trim().to_string();
    if message.is_empty() { None } else { Some(message) }
}

// MARK: Branches

/// Why `name` cannot be a new branch, or None when it can. Mirrors `git check-ref-format --branch`, without a process.
pub fn branch_name_problem(name: &str, existing: &std::collections::HashSet<String>) -> Option<String> {
    let trimmed = name.trim_matches(' ');
    if trimmed.is_empty() {
        return Some(l("Type a name", "请输入名称"));
    }
    if existing.contains(trimmed) {
        return Some(crate::lf!("A branch named “{trimmed}” already exists", "已有名为“{trimmed}”的分支"));
    }
    let bad = trimmed.starts_with('-')
        || trimmed.starts_with('/')
        || trimmed.ends_with('/')
        || trimmed.ends_with('.')
        || trimmed.ends_with(".lock")
        || trimmed.contains("..")
        || trimmed.contains("//")
        || trimmed.contains("@{")
        || trimmed == "@"
        || trimmed == "HEAD"
        || trimmed.split('/').any(|p| p.starts_with('.'))
        || trimmed.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7F || " ~^:?*[\\".contains(c));
    if bad { Some(l("Not a valid branch name", "不是有效的分支名")) } else { None }
}

pub fn switch_branch(name: &str, dir: &Path) -> Result<()> {
    run(dir, ["switch", "--quiet", "--no-guess", name]).map(|_| ())
}

/// Creates `name` at `start` (HEAD when None) and switches to it.
pub fn create_branch(name: &str, start: Option<&str>, dir: &Path) -> Result<()> {
    let mut args = vec!["switch", "--quiet", "--no-track", "-c", name];
    if let Some(s) = start {
        args.push(s);
    }
    run(dir, args).map(|_| ())
}

/// A local branch following the remote branch `remote` ("origin/feature"), switched to.
pub fn track_branch(remote: &str, local: &str, dir: &Path) -> Result<()> {
    run(dir, ["switch", "--quiet", "-c", local, "--track", remote]).map(|_| ())
}

/// Checks out a commit with no branch (a detached HEAD), to look at or build an old version.
pub fn detach(commit: &str, dir: &Path) -> Result<()> {
    run(dir, ["switch", "--quiet", "--detach", commit]).map(|_| ())
}

/// The files a checkout refused to overwrite, from git's message; empty when that was not why it failed.
pub fn overwritten_files(message: &str) -> Vec<String> {
    if !message.contains("would be overwritten by") {
        return Vec::new();
    }
    let mut files = Vec::new();
    let mut listing = false;
    for line in message.split('\n') {
        if line.contains("would be overwritten by") {
            listing = true;
            continue;
        }
        if !listing {
            continue;
        }
        if line.starts_with('\t') {
            files.push(line.trim().to_string());
        } else if !files.is_empty() {
            break;
        }
    }
    files
}

// MARK: Stash (for a checkout that carries the local changes over)

pub fn stash(message: &str, dir: &Path) -> Result<()> {
    run(dir, ["stash", "push", "--quiet", "--message", message]).map(|_| ())
}

pub fn unstash(dir: &Path) -> Result<()> {
    run(dir, ["stash", "pop", "--quiet"]).map(|_| ())
}

// MARK: Remotes

pub fn remotes(dir: &Path) -> Vec<String> {
    run_string(dir, ["remote"])
        .unwrap_or_default()
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

/// Brings every remote's branches up to date, dropping the ones deleted there.
pub fn fetch(dir: &Path, cancel: Option<&git::CancelToken>) -> Result<()> {
    let mut c = cmd(dir, ["fetch", "--all", "--prune", "--quiet"]);
    if let Some(t) = cancel {
        c = c.cancel(t);
    }
    c.run().map(|_| ())
}

/// - `autostash`: puts local changes aside first and back afterwards.
pub fn pull(mode: PullMode, autostash: bool, dir: &Path, cancel: Option<&git::CancelToken>) -> Result<()> {
    let mut args = vec!["pull", "--quiet"];
    match mode {
        PullMode::Configured => {}
        PullMode::Merge => args.push("--no-rebase"),
        PullMode::Rebase => args.push("--rebase"),
    }
    // A merge commit takes git's own message; there is no editor to ask.
    if mode != PullMode::Rebase {
        args.push("--no-edit");
    }
    if autostash {
        args.push("--autostash");
    }
    let mut c = cmd(dir, args).env("GIT_EDITOR", "true").env("GIT_MERGE_AUTOEDIT", "no");
    if let Some(t) = cancel {
        c = c.cancel(t);
    }
    c.run().map(|_| ())
}

/// Pushes the current branch to its upstream, or to `remote` under its own name (then tracked from there).
pub fn push(branch: &str, set_upstream_to: Option<&str>, dir: &Path, cancel: Option<&git::CancelToken>) -> Result<()> {
    let mut args: Vec<String> = vec!["push".into(), "--quiet".into()];
    if let Some(remote) = set_upstream_to {
        args.extend(["--set-upstream".into(), remote.to_string(), format!("HEAD:refs/heads/{branch}")]);
    }
    let mut c = cmd(dir, args);
    if let Some(t) = cancel {
        c = c.cancel(t);
    }
    c.run().map(|_| ())
}

/// Commits a push would send: those not on the upstream, or with none, those on no branch of `remote`.
pub fn outgoing_commits(upstream: Option<&str>, remote: Option<&str>, dir: &Path, limit: usize) -> Vec<Commit> {
    let mut args: Vec<String> = vec!["log".into(), format!("--format={LOG_FORMAT}"), format!("--max-count={limit}")];
    if upstream.is_some() {
        args.push("@{upstream}..HEAD".into());
    } else if let Some(r) = remote {
        args.extend(["HEAD".into(), "--not".into(), format!("--remotes={r}")]);
    } else {
        args.push("HEAD".into());
    }
    run(dir, args).map(|d| parse_log(&d)).unwrap_or_default()
}

/// Why a push was turned away, in git's words: the remote has commits the branch does not.
pub fn is_rejected_as_behind(message: &str) -> bool {
    message.contains("[rejected]") && (message.contains("non-fast-forward") || message.contains("fetch first"))
}

// MARK: Interrupted operations

pub fn continue_operation(operation: RepoOperation, dir: &Path) -> Result<()> {
    // The commit message is git's own, as prepared; no editor opens.
    cmd(dir, [operation.command(), "--continue"]).env("GIT_EDITOR", "true").run().map(|_| ())
}

pub fn abort_operation(operation: RepoOperation, dir: &Path) -> Result<()> {
    run(dir, [operation.command(), "--abort"]).map(|_| ())
}

// MARK: - Conflicts

/// The two versions of a file in conflict: HEAD's, and the one being merged in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictSide {
    Ours,
    Theirs,
}

impl ConflictSide {
    pub fn flag(self) -> &'static str {
        if self == ConflictSide::Ours { "--ours" } else { "--theirs" }
    }
}

/// Tells git a file in conflict is resolved, as it now is on disk.
pub fn mark_resolved(paths: &[String], dir: &Path) -> Result<()> {
    let mut args: Vec<String> = vec!["--literal-pathspecs".into(), "add".into(), "--".into()];
    args.extend(paths.iter().cloned());
    run(dir, args).map(|_| ())
}

/// Resolves a file in conflict by taking one side whole.
pub fn take_side(side: ConflictSide, path: &str, dir: &Path) -> Result<()> {
    run(dir, ["--literal-pathspecs", "checkout", side.flag(), "--", path])?;
    mark_resolved(&[path.to_string()], dir)
}

/// Whether `data` still has git's conflict markers in it (a line starting with `<<<<<<< ` or `>>>>>>> `).
pub fn has_conflict_markers(data: &[u8]) -> bool {
    let mut at_line_start = true;
    for (index, &byte) in data.iter().enumerate() {
        if at_line_start && (byte == b'<' || byte == b'>') {
            let end = (index + 8).min(data.len());
            let run = &data[index..end];
            if run.len() == 8
                && run[..7].iter().all(|&b| b == byte)
                && matches!(run[7], b' ' | b'\n' | b'\r')
            {
                return true;
            }
        }
        at_line_start = byte == b'\n';
    }
    false
}

/// One conflict git wrote into a file: HEAD's lines, the base's (with `merge.conflictStyle = diff3`), the incoming
/// lines, between marker lines. Line numbers are 0-based rows of the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConflictBlock {
    /// The `<<<<<<<` line.
    pub start: usize,
    /// The `|||||||` line, when the common ancestor's lines are shown too.
    pub base: Option<usize>,
    /// The `=======` line.
    pub middle: usize,
    /// The `>>>>>>>` line.
    pub end: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictChoice {
    Ours,
    Theirs,
    Both,
}

impl ConflictBlock {
    pub fn ours(&self) -> std::ops::Range<usize> {
        (self.start + 1)..self.base.unwrap_or(self.middle)
    }

    pub fn theirs(&self) -> std::ops::Range<usize> {
        (self.middle + 1)..self.end
    }

    /// Every complete conflict in `lines`, in order. A marker line is seven of its character, then a space or nothing.
    pub fn find<S: AsRef<str>>(lines: &[S]) -> Vec<ConflictBlock> {
        fn marker(line: &str, ch: u8) -> bool {
            let b = line.as_bytes();
            if b.len() < 7 || !b[..7].iter().all(|&c| c == ch) {
                return false;
            }
            b.len() == 7 || b[7] == b' ' || b[7] == b'\r'
        }
        let mut blocks = Vec::new();
        let (mut start, mut base, mut middle): (Option<usize>, Option<usize>, Option<usize>) = (None, None, None);
        for (index, line) in lines.iter().enumerate() {
            let line = line.as_ref();
            let Some(&first) = line.as_bytes().first() else { continue };
            if !matches!(first, b'<' | b'|' | b'=' | b'>') {
                continue;
            }
            if marker(line, b'<') {
                start = Some(index);
                base = None;
                middle = None;
            } else if start.is_some() && middle.is_none() && base.is_none() && marker(line, b'|') {
                base = Some(index);
            } else if start.is_some() && middle.is_none() && marker(line, b'=') {
                middle = Some(index);
            } else if let (Some(s), Some(m)) = (start, middle) {
                if marker(line, b'>') {
                    blocks.push(ConflictBlock { start: s, base, middle: m, end: index });
                    start = None;
                    base = None;
                    middle = None;
                }
            }
        }
        blocks
    }

    /// The lines that replace the whole block for `choice`.
    pub fn resolution<S: AsRef<str>>(&self, choice: ConflictChoice, lines: &[S]) -> Vec<String> {
        let take = |r: std::ops::Range<usize>| lines[r].iter().map(|s| s.as_ref().to_string()).collect::<Vec<_>>();
        match choice {
            ConflictChoice::Ours => take(self.ours()),
            ConflictChoice::Theirs => take(self.theirs()),
            ConflictChoice::Both => {
                let mut v = take(self.ours());
                v.extend(take(self.theirs()));
                v
            }
        }
    }
}

/// Which version of a file in conflict the left side of the viewer shows; the right side is the file itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConflictBase {
    Head,
    Base,
    Incoming,
}

impl ConflictBase {
    pub const ALL: [ConflictBase; 3] = [ConflictBase::Head, ConflictBase::Base, ConflictBase::Incoming];

    /// For `git cat-file`: HEAD's version, or the index stage git keeps for the conflict (1 base, 3 incoming).
    pub fn rev(self) -> &'static str {
        match self {
            ConflictBase::Head => "HEAD",
            ConflictBase::Base => ":1",
            ConflictBase::Incoming => ":3",
        }
    }

    pub fn title(self) -> String {
        match self {
            ConflictBase::Head => "HEAD".to_string(),
            ConflictBase::Base => l("Base", "共同祖先"),
            ConflictBase::Incoming => l("Incoming", "传入"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn branch_names() {
        let existing: HashSet<String> = ["main".to_string()].into();
        assert!(branch_name_problem("feature/x", &existing).is_none());
        assert!(branch_name_problem("main", &existing).is_some());
        assert!(branch_name_problem("a..b", &existing).is_some());
        assert!(branch_name_problem("x.lock", &existing).is_some());
        assert!(branch_name_problem("has space", &existing).is_some());
        assert!(branch_name_problem("", &existing).is_some());
    }

    #[test]
    fn conflict_blocks() {
        let lines = ["a", "<<<<<<< HEAD", "ours", "||||||| base", "base", "=======", "theirs", ">>>>>>> branch", "z"];
        let blocks = ConflictBlock::find(&lines);
        assert_eq!(blocks, vec![ConflictBlock { start: 1, base: Some(3), middle: 5, end: 7 }]);
        assert_eq!(blocks[0].resolution(ConflictChoice::Both, &lines), vec!["ours", "theirs"]);
        assert!(has_conflict_markers(b"x\n<<<<<<< HEAD\n"));
        assert!(!has_conflict_markers(b"x <<<<<<< HEAD\n"));
    }

    #[test]
    fn overwritten_list() {
        let msg = "error: Your local changes to the following files would be overwritten by checkout:\n\ta.kt\n\tb.kt\nPlease commit";
        assert_eq!(overwritten_files(msg), vec!["a.kt", "b.kt"]);
    }
}
