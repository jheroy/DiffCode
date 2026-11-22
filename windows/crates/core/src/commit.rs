//! Committing the files ticked in the Changes list (whole, or only some of their lines), and taking that commit back.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;

use crate::diff::{self, join_repo_path, Hunk};
use crate::git::{self, ChangeKind, FileChange};
use crate::lang::l;
use crate::lf;
use crate::text_codec;
use crate::working_tree::{git_paths, line_ranges, make_backup_directory, Failure, Result};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitResult {
    pub hash: String,
    /// The first commit of the repository: undoing it leaves the branch unborn.
    pub is_root: bool,
    pub file_count: usize,
    pub message: String,
    /// The commit this one replaced (Amend): undoing brings it back.
    pub amended: Option<String>,
}

impl CommitResult {
    pub fn short_hash(&self) -> &str {
        &self.hash[..self.hash.len().min(7)]
    }
}

/// Removes a directory when dropped.
struct TempDir(std::path::PathBuf);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn path_arg(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn trimmed_message(message: &str) -> Result<String> {
    let text = message.trim();
    if text.is_empty() {
        return Err(Failure::new(l("Write a commit message first.", "先写提交说明。")));
    }
    Ok(text.to_string())
}

/// The paths a commit of `changes` takes: a rename brings its old path along, or the old file's removal would stay behind.
fn commit_paths<'a>(changes: impl IntoIterator<Item = &'a FileChange>) -> Vec<String> {
    let mut paths = Vec::new();
    for change in changes {
        paths.push(change.path.clone());
        if change.kind == ChangeKind::Renamed {
            if let Some(old) = &change.old_path {
                paths.push(old.clone());
            }
        }
    }
    paths
}

/// HEAD's hash; fails when the branch has no commit yet.
pub fn head(root: &Path) -> git::Result<String> {
    Ok(git::run_string(root, ["rev-parse", "--verify", "HEAD"])?.trim().to_string())
}

/// The commit an amend replaces: HEAD, which must exist.
fn amend_target(root: &Path) -> Result<String> {
    head(root).map_err(|_| Failure::new(l("There is no commit to amend yet.", "还没有可以修改的提交。")))
}

fn is_root_commit(hash: &str, root: &Path) -> Result<bool> {
    let line = git::run_string(root, ["rev-list", "--parents", "-n", "1", hash])?;
    Ok(line.split_whitespace().count() <= 1)
}

/// Commits exactly `changes`, as they are on disk.
///
/// Uses `git commit --only`, so whatever else is staged stays staged and out of this commit.
/// New files are added first (and taken out of the index again if the commit fails, e.g. a hook refuses it).
/// With `amend`, replaces the last commit with one that has these changes too, and this message;
/// with no changes, only the message changes.
pub fn commit(message: &str, changes: &[FileChange], amend: bool, root: &Path) -> Result<CommitResult> {
    let text = trimmed_message(message)?;
    if changes.is_empty() && !amend {
        return Err(Failure::new(l("Tick the files to commit first.", "先勾选要提交的文件。")));
    }
    let amended = if amend { Some(amend_target(root)?) } else { None };
    let paths = commit_paths(changes);
    let untracked: Vec<String> =
        changes.iter().filter(|c| c.kind == ChangeKind::Untracked).map(|c| c.path.clone()).collect();

    let directory = TempDir(make_backup_directory()?);
    let message_file = directory.0.join("message");
    let paths_file = directory.0.join("paths");
    std::fs::write(&message_file, format!("{text}\n"))?;
    // NUL-separated, so any file name is passed exactly; no command line is long enough to matter.
    let mut list = paths.join("\0").into_bytes();
    list.push(0);
    std::fs::write(&paths_file, list)?;

    git_paths(&["add"], &untracked, root, &[])?;
    let mut args: Vec<String> = vec![
        "--literal-pathspecs".into(),
        "commit".into(),
        "--quiet".into(),
        "--only".into(),
        format!("--file={}", path_arg(&message_file)),
    ];
    if amend {
        args.push("--amend".into());
    }
    // Amending with no files: `--only` and no paths takes nothing that is staged, just the new message.
    if !paths.is_empty() {
        args.push(format!("--pathspec-from-file={}", path_arg(&paths_file)));
        args.push("--pathspec-file-nul".into());
    }
    if let Err(e) = git::run(root, args) {
        let _ = git_paths(&["rm", "--cached", "-q", "--ignore-unmatch"], &untracked, root, &[]);
        return Err(e.into());
    }
    let hash = head(root)?;
    let is_root = is_root_commit(&hash, root)?;
    Ok(CommitResult { hash, is_root, file_count: changes.len(), message: text, amended })
}

/// A changed line of a file, against HEAD: one that HEAD has and the working tree does not (`removed`), or the other
/// way round. Its text comes along, so that a line number that no longer holds it is never trusted.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChangeLine {
    pub removed: bool,
    /// 0-based: in HEAD's version of the file for a removed line, in the working tree's for an added one.
    pub line: usize,
    pub text: String,
}

/// Committing part of a file: some of its changed lines stay out of the commit, and in the working tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartialFile {
    pub change: FileChange,
    pub excluded: HashSet<ChangeLine>,
}

#[derive(Clone, Debug)]
pub struct Sides {
    pub old: Vec<u8>,
    pub new: Vec<u8>,
    pub old_text: Vec<String>,
    pub new_text: Vec<String>,
    /// The exact differences, whitespace included.
    pub hunks: Vec<Hunk>,
}

/// Commits `whole` as they are on disk and `partial` without the lines left out of them; the working tree is not touched.
///
/// The commit is put together in an index of DiffCode's own, started from HEAD, so whatever is staged stays staged
/// and out of it, as with `commit --only`. Afterwards the real index takes what was committed for these paths:
/// the lines left out of a file show as changed still.
/// Nothing happens if a partial file changed in a way its picked lines cannot be found in again.
pub fn commit_partial(
    message: &str,
    whole: &[FileChange],
    partial: &[PartialFile],
    amend: bool,
    root: &Path,
) -> Result<CommitResult> {
    let text = trimmed_message(message)?;
    let amended = if amend { Some(amend_target(root)?) } else { None };
    // Every partial file's content first: if one cannot be worked out, nothing is done.
    let mut contents: Vec<(String, Vec<u8>)> = Vec::new();
    for file in partial {
        let change = &file.change;
        let sides = partial_sides(change, root)?;
        let (lines, lost) = relocate(&file.excluded, &sides.old_text, &sides.new_text, &sides.hunks);
        let data = if lost == 0 { partial_content(&sides.old, &sides.new, &sides.hunks, &lines) } else { None };
        let Some(data) = data else {
            let name = change.name();
            return Err(Failure::new(lf!(
                "“{name}” changed after its lines were picked. Look at it again before committing.",
                "“{name}”在选好行之后又改过了。请再看一眼再提交。"
            )));
        };
        contents.push((change.path.clone(), data));
    }

    let paths = commit_paths(whole.iter().chain(partial.iter().map(|p| &p.change)));
    let partial_paths: Vec<String> = contents.iter().map(|(p, _)| p.clone()).collect();

    let directory = TempDir(make_backup_directory()?);
    let message_file = directory.0.join("message");
    std::fs::write(&message_file, format!("{text}\n"))?;
    let index = directory.0.join("index");
    let index_arg = path_arg(&index);
    let env = [("GIT_INDEX_FILE", index_arg.as_str())];
    let with_index = |args: Vec<String>| {
        let mut c = git::cmd(root, args);
        for (k, v) in env {
            c = c.env(k, v);
        }
        c
    };
    let strings = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();

    let unborn = git::run(root, ["rev-parse", "--verify", "--quiet", "HEAD"]).is_err();
    if unborn {
        with_index(strings(&["read-tree", "--empty"])).run()?;
    } else {
        // Started from a copy of the real index, whose file stamps carry over to the files HEAD has as they are:
        // the commit (and its hooks) then need not read every file of the working tree again.
        let mut started = false;
        if let Ok(real) = git::run_string(root, ["rev-parse", "--git-path", "index"]) {
            let name = real.trim_end_matches(['\r', '\n']);
            let p = git::path_from_git(root, name);
            let real_index = if p.is_absolute() { p } else { root.join(p) };
            if std::fs::copy(&real_index, &index).is_ok()
                && with_index(strings(&["read-tree", "-m", "HEAD"])).run().is_ok()
            {
                started = true;
            }
        }
        if !started {
            let _ = std::fs::remove_file(&index);
            with_index(strings(&["read-tree", "HEAD"])).run()?;
        }
    }

    // The modes HEAD has, for a partial file the working tree no longer has (deleted, in part).
    let head_modes = staged_modes(&partial_paths, root, &env)?;
    git_paths(&["add", "-A"], &paths, root, &env)?;
    let modes = staged_modes(&partial_paths, root, &env)?;
    for (number, (path, data)) in contents.iter().enumerate() {
        let mode = modes.get(path).or_else(|| head_modes.get(path)).map(String::as_str).unwrap_or("100644");
        if mode != "100644" && mode != "100755" {
            let name = crate::util::file_name(path);
            return Err(Failure::new(lf!("“{name}” can only be committed whole.", "“{name}”只能整个提交。")));
        }
        let file = directory.0.join(format!("part{number}"));
        std::fs::write(&file, data)?;
        // `--path`: the content goes through the file's filters (line endings) the way `git add` would take it.
        let hash =
            git::run_string(root, ["hash-object".to_string(), "-w".into(), format!("--path={path}"), path_arg(&file)])?
                .trim()
                .to_string();
        with_index(vec![
            "update-index".into(),
            "--add".into(),
            "--cacheinfo".into(),
            format!("{mode},{hash},{path}"),
        ])
        .run()?;
    }
    let mut args = vec!["commit".to_string(), "--quiet".into(), format!("--file={}", path_arg(&message_file))];
    if amend {
        args.push("--amend".into());
    }
    with_index(args).run()?;

    // The real index follows the commit for these paths (as `commit --only` leaves it); anything else staged stays.
    let _ = git_paths(&["reset", "--quiet"], &paths, root, &[]);
    let hash = head(root)?;
    // An amended first commit is still the first.
    let is_root = unborn || is_root_commit(&hash, root)?;
    Ok(CommitResult { hash, is_root, file_count: whole.len() + partial.len(), message: text, amended })
}

/// `path → mode` of the entries the index has for `paths`.
fn staged_modes(paths: &[String], root: &Path, env: &[(&str, &str)]) -> Result<HashMap<String, String>> {
    let mut modes = HashMap::new();
    for chunk in paths.chunks(400) {
        let mut args: Vec<String> =
            ["--literal-pathspecs", "ls-files", "--stage", "-z", "--"].iter().map(|s| s.to_string()).collect();
        args.extend(chunk.iter().cloned());
        let mut c = git::cmd(root, args);
        for (k, v) in env {
            c = c.env(k, *v);
        }
        let data = c.run()?;
        for record in data.split(|&b| b == 0).filter(|r| !r.is_empty()) {
            // "<mode> <hash> <stage>\t<path>"
            let Some(tab) = record.iter().position(|&b| b == b'\t') else { continue };
            let fields = String::from_utf8_lossy(&record[..tab]);
            let Some(mode) = fields.split(' ').next() else { continue };
            modes.insert(String::from_utf8_lossy(&record[tab + 1..]).into_owned(), mode.to_string());
        }
    }
    Ok(modes)
}

/// Finishes a merge that stopped for conflicts. Git commits a merge whole (it refuses a partial one), so this is
/// what the merge staged, conflicts resolved, plus the ticked files, which are added first.
pub fn commit_merge(message: &str, adding: &[FileChange], root: &Path) -> Result<CommitResult> {
    let text = trimmed_message(message)?;
    let paths = commit_paths(adding);
    let directory = TempDir(make_backup_directory()?);
    let message_file = directory.0.join("message");
    std::fs::write(&message_file, format!("{text}\n"))?;
    // `-A` also takes a ticked file's deletion.
    git_paths(&["add", "-A"], &paths, root, &[])?;
    git::run(root, ["commit".to_string(), "--quiet".into(), format!("--file={}", path_arg(&message_file))])?;
    let hash = head(root)?;
    Ok(CommitResult { hash, is_root: false, file_count: adding.len(), message: text, amended: None })
}

/// Takes back a commit made here: the branch moves back one commit and the changes stay, staged.
/// Refuses when anything has happened since (a new commit, a checkout) or the commit was pushed.
pub fn undo_commit(result: &CommitResult, root: &Path) -> Result<()> {
    let current = git::run_string(root, ["rev-parse", "HEAD"]).ok().map(|s| s.trim().to_string());
    if current.as_deref() != Some(result.hash.as_str()) {
        return Err(Failure::new(l(
            "HEAD has moved since that commit, so it was left alone.",
            "这次提交之后 HEAD 已经变了，所以没有撤销。",
        )));
    }
    let remote = git::run_string(root, ["branch", "-r", "--contains", &result.hash])?;
    if !remote.trim().is_empty() {
        return Err(Failure::new(l(
            "That commit has already been pushed, so it was left alone.",
            "这次提交已经推送到远程，所以没有撤销。",
        )));
    }
    if let Some(amended) = &result.amended {
        // The commit that was amended comes back; what the amend added stays, staged.
        git::run(root, ["reset", "--soft", "--quiet", amended])?;
    } else if result.is_root {
        git::run(root, ["update-ref", "-d", "HEAD", &result.hash])?;
    } else {
        git::run(root, ["reset".to_string(), "--soft".into(), "--quiet".into(), format!("{}^", result.hash)])?;
    }
    Ok(())
}

// MARK: - Partial files

/// The two versions a local change compares, as the viewer has them: HEAD's (none for a new file) and the
/// working tree's (none for a deleted one).
pub fn partial_sides(change: &FileChange, root: &Path) -> Result<Sides> {
    let has_old = !matches!(change.kind, ChangeKind::Added | ChangeKind::Untracked);
    let has_new = change.kind != ChangeKind::Deleted;
    let name = change.name();
    let mut old = Vec::new();
    let mut new = Vec::new();
    if has_old {
        old = git::blob("HEAD", change.old_path.as_deref().unwrap_or(&change.path), root)
            .ok_or_else(|| Failure::new(lf!("HEAD has no “{name}”.", "HEAD 里没有“{name}”。")))?;
    }
    if has_new {
        let full = join_repo_path(root, &change.path);
        let is_file = std::fs::symlink_metadata(&full).map(|m| m.file_type().is_file()).unwrap_or(false);
        new = if is_file { std::fs::read(&full).ok() } else { None }
            .ok_or_else(|| Failure::new(lf!("“{name}” can only be committed whole.", "“{name}”只能整个提交。")))?;
    }
    if diff::is_utf16(&old) || diff::is_utf16(&new) {
        return Err(Failure::new(l("UTF-16 files can only be committed whole.", "UTF-16 文件只能整个提交。")));
    }
    let old_text = text_codec::split_lines(&text_codec::decode(&old));
    let new_text = text_codec::split_lines(&text_codec::decode(&new));
    let hunks = if !has_old {
        if new_text.is_empty() {
            Vec::new()
        } else {
            vec![Hunk::lines(0, 0, 0, new_text.len())]
        }
    } else if !has_new {
        if old_text.is_empty() {
            Vec::new()
        } else {
            vec![Hunk::lines(0, old_text.len(), 0, 0)]
        }
    } else {
        diff::compute_hunks(Some(&old), Some(&new), false).ok_or_else(|| {
            Failure::new(lf!("Could not compare “{name}” with HEAD.", "无法把“{name}”和 HEAD 比较。"))
        })?
    };
    Ok(Sides { old, new, old_text, new_text, hunks })
}

/// Finds the lines of `excluded` in the two versions as they are now: the working tree's may have been edited since
/// they were picked, moving its lines. An added line is looked for nearby by its text.
///
/// Returns the lines where they are now, and how many could not be found. A removed line that is no longer a change
/// (put back in the working tree) is simply dropped: it stays either way.
pub fn relocate(
    excluded: &HashSet<ChangeLine>,
    old: &[String],
    new: &[String],
    hunks: &[Hunk],
) -> (HashSet<ChangeLine>, usize) {
    if excluded.is_empty() {
        return (HashSet::new(), 0);
    }
    let mut removed_lines = BTreeSet::new();
    let mut added_lines = BTreeSet::new();
    for hunk in hunks {
        removed_lines.extend(hunk.left_start..hunk.left_end());
        added_lines.extend(hunk.right_start..hunk.right_end());
    }
    let mut result = HashSet::new();
    let mut lost = 0;
    let mut missing: Vec<&ChangeLine> = Vec::new();
    for line in excluded {
        if line.removed {
            if old.get(line.line) != Some(&line.text) {
                lost += 1;
                continue;
            }
            if removed_lines.contains(&line.line) {
                result.insert(line.clone());
            }
        } else if new.get(line.line) == Some(&line.text) && added_lines.contains(&line.line) {
            result.insert(line.clone());
        } else {
            missing.push(line);
        }
    }
    if missing.is_empty() {
        return (result, lost);
    }
    // Where each text is an added line now, for the lines that moved.
    let wanted: HashSet<&str> = missing.iter().map(|l| l.text.as_str()).collect();
    let mut places: HashMap<&str, Vec<usize>> = HashMap::new();
    for &index in &added_lines {
        if let Some(text) = new.get(index) {
            if wanted.contains(text.as_str()) {
                places.entry(text.as_str()).or_default().push(index);
            }
        }
    }
    let mut taken: HashSet<usize> = result.iter().filter(|l| !l.removed).map(|l| l.line).collect();
    missing.sort_by_key(|l| l.line);
    for line in missing {
        let nearest = places
            .get(line.text.as_str())
            .and_then(|candidates| {
                candidates.iter().copied().filter(|i| !taken.contains(i)).min_by_key(|&i| i.abs_diff(line.line))
            });
        let Some(nearest) = nearest else {
            lost += 1;
            continue;
        };
        taken.insert(nearest);
        result.insert(ChangeLine { removed: false, line: nearest, text: line.text.clone() });
    }
    (result, lost)
}

/// What a commit takes of a file when the lines of `excluded` stay out of it: the working tree's version (`new`),
/// with each of those lines the way HEAD's (`old`) has it. A removed line stays; an added one does not come.
///
/// Within a change the two sides go row by row, so a modified line that stays out keeps its place among the lines
/// that go in. Bytes are copied as they are, so encodings and line endings stay what they were.
/// Returns None when `hunks` do not fit the two versions, or a line of `excluded` does not hold its text.
pub fn partial_content(old: &[u8], new: &[u8], hunks: &[Hunk], excluded: &HashSet<ChangeLine>) -> Option<Vec<u8>> {
    if diff::is_utf16(old) || diff::is_utf16(new) {
        return None;
    }
    let old_lines = line_ranges(old);
    let new_lines = line_ranges(new);
    let old_text = text_codec::split_lines(&text_codec::decode(old));
    let new_text = text_codec::split_lines(&text_codec::decode(new));
    if old_text.len() != old_lines.len() || new_text.len() != new_lines.len() {
        return None;
    }
    let mut kept = HashSet::new();
    let mut dropped = HashSet::new();
    for line in excluded {
        let text = if line.removed { &old_text } else { &new_text };
        if text.get(line.line) != Some(&line.text) {
            return None;
        }
        if line.removed {
            kept.insert(line.line);
        } else {
            dropped.insert(line.line);
        }
    }

    // Only a file's last line may lack its line break; one that is no longer last gets one, in the file's style.
    let has_crlf = |d: &[u8]| d.windows(2).any(|w| w == b"\r\n");
    let newline: &[u8] = if has_crlf(new) || (!new.contains(&b'\n') && has_crlf(old)) { b"\r\n" } else { b"\n" };
    let mut result = Vec::with_capacity(new.len());
    let mut open = false;
    let mut put = |data: &[u8], range: &std::ops::Range<usize>| {
        if open {
            result.extend_from_slice(newline);
        }
        let bytes = &data[range.clone()];
        result.extend_from_slice(bytes);
        open = bytes.last() != Some(&b'\n');
    };

    let (mut old_pos, mut new_pos) = (0usize, 0usize);
    for hunk in hunks {
        if hunk.left_start < old_pos
            || hunk.right_start < new_pos
            || hunk.left_start - old_pos != hunk.right_start - new_pos
            || hunk.left_end() > old_lines.len()
            || hunk.right_end() > new_lines.len()
        {
            return None;
        }
        for range in &new_lines[new_pos..hunk.right_start] {
            put(new, range);
        }
        for row in 0..hunk.left_count.max(hunk.right_count) {
            if row < hunk.left_count && kept.contains(&(hunk.left_start + row)) {
                put(old, &old_lines[hunk.left_start + row]);
            }
            if row < hunk.right_count && !dropped.contains(&(hunk.right_start + row)) {
                put(new, &new_lines[hunk.right_start + row]);
            }
        }
        old_pos = hunk.left_end();
        new_pos = hunk.right_end();
    }
    if old_lines.len() - old_pos != new_lines.len() - new_pos {
        return None;
    }
    for range in &new_lines[new_pos..] {
        put(new, range);
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::working_tree::tests::{repo, sh};

    fn added(line: usize, text: &str) -> ChangeLine {
        ChangeLine { removed: false, line, text: text.into() }
    }

    fn removed(line: usize, text: &str) -> ChangeLine {
        ChangeLine { removed: true, line, text: text.into() }
    }

    #[test]
    fn partial_content_keeps_left_out_lines() {
        let old = b"a\nb\nc\n";
        let new = b"a\nB\nc\nd\n";
        let hunks = vec![Hunk::lines(1, 1, 1, 1), Hunk::lines(3, 0, 3, 1)];
        // Leave out the added "d": only the b → B change goes in.
        let ex: HashSet<_> = [added(3, "d")].into_iter().collect();
        assert_eq!(partial_content(old, new, &hunks, &ex).unwrap(), b"a\nB\nc\n");
        // Leave out the change of b: b stays, B does not come.
        let ex: HashSet<_> = [removed(1, "b"), added(1, "B")].into_iter().collect();
        assert_eq!(partial_content(old, new, &hunks, &ex).unwrap(), b"a\nb\nc\nd\n");
        // A line that no longer holds its text: nothing.
        let ex: HashSet<_> = [added(3, "x")].into_iter().collect();
        assert!(partial_content(old, new, &hunks, &ex).is_none());
    }

    #[test]
    fn relocate_follows_moved_lines() {
        let new: Vec<String> = ["new top", "a", "B", "c", "d"].iter().map(|s| s.to_string()).collect();
        let old: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        let hunks = vec![Hunk::lines(0, 0, 0, 1), Hunk::lines(1, 1, 2, 1), Hunk::lines(3, 0, 4, 1)];
        let ex: HashSet<_> = [added(3, "d"), removed(1, "b")].into_iter().collect();
        let (lines, lost) = relocate(&ex, &old, &new, &hunks);
        assert_eq!(lost, 0);
        assert!(lines.contains(&added(4, "d")));
        assert!(lines.contains(&removed(1, "b")));
    }

    #[test]
    fn commit_partial_and_undo() {
        if !git::is_available() {
            return;
        }
        let dir = repo();
        let root = dir.path();
        std::fs::write(root.join("f.txt"), "a\nb\nc\n").unwrap();
        sh(root, &["add", "."]);
        sh(root, &["commit", "-q", "-m", "init"]);
        std::fs::write(root.join("f.txt"), "a\nB\nc\nd\n").unwrap();
        std::fs::write(root.join("other.txt"), "o\n").unwrap();
        let status = git::status(root, None).unwrap();
        let f = status.changes.iter().find(|c| c.path == "f.txt").unwrap().clone();
        let other = status.changes.iter().find(|c| c.path == "other.txt").unwrap().clone();
        let partial = PartialFile { change: f, excluded: [added(3, "d")].into_iter().collect() };
        let result = commit_partial("Part", &[other], &[partial], false, root).unwrap();
        assert!(!result.is_root);
        assert_eq!(sh(root, &["show", "HEAD:f.txt"]), "a\nB\nc\n");
        assert_eq!(sh(root, &["show", "HEAD:other.txt"]), "o\n");
        // The working tree is untouched and the left-out line still shows as a change.
        assert_eq!(std::fs::read_to_string(root.join("f.txt")).unwrap(), "a\nB\nc\nd\n");
        let after = git::status(root, None).unwrap();
        assert_eq!(after.changes.len(), 1);
        assert_eq!(after.changes[0].path, "f.txt");

        undo_commit(&result, root).unwrap();
        assert_eq!(sh(root, &["log", "--format=%s"]).trim(), "init");
    }

    #[test]
    fn whole_commit_takes_only_the_ticked_files() {
        if !git::is_available() {
            return;
        }
        let dir = repo();
        let root = dir.path();
        std::fs::write(root.join("a.txt"), "a\n").unwrap();
        std::fs::write(root.join("b.txt"), "b\n").unwrap();
        sh(root, &["add", "b.txt"]);
        let status = git::status(root, None).unwrap();
        let a = status.changes.iter().find(|c| c.path == "a.txt").unwrap().clone();
        let result = commit("First\n\n", &[a], false, root).unwrap();
        assert!(result.is_root);
        assert_eq!(result.message, "First");
        assert_eq!(sh(root, &["show", "--name-only", "--format=", "HEAD"]).trim(), "a.txt");
        // b.txt stays staged and out of the commit.
        assert!(sh(root, &["diff", "--cached", "--name-only"]).contains("b.txt"));
        undo_commit(&result, root).unwrap();
        assert!(git::run(root, ["rev-parse", "--verify", "--quiet", "HEAD"]).is_err());
    }
}
