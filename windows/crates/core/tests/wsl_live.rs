//! Against a real WSL distro with git in it (issue #7), so ignored by default. On Windows:
//!
//! ```text
//! set DIFFCODE_WSL_SHARE=\\wsl.localhost\Ubuntu\home\me\scratch
//! cargo test -p diffcode-core --test wsl_live -- --ignored --nocapture
//! ```
//!
//! The folder must exist; each test makes its own repository in it and removes it afterwards.
#![cfg(windows)]

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use diffcode_core::commit::{self, ChangeLine, PartialFile};
use diffcode_core::git::{self, ChangeKind};
use diffcode_core::{remote, watcher};

fn share() -> PathBuf {
    PathBuf::from(std::env::var("DIFFCODE_WSL_SHARE").expect("set DIFFCODE_WSL_SHARE to a folder inside a distro"))
}

/// A new, empty folder on the share, removed again when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let dir = share().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        Scratch(dir)
    }
    fn sibling(&self, suffix: &str) -> PathBuf {
        let mut name = self.0.file_name().unwrap().to_os_string();
        name.push(suffix);
        self.0.with_file_name(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
        let _ = std::fs::remove_dir_all(self.sibling("-wt"));
    }
}

fn change<'a>(status: &'a git::RepoStatus, path: &str) -> &'a git::FileChange {
    status.changes.iter().find(|c| c.path == path).unwrap_or_else(|| panic!("no {path} in {:?}", status.changes))
}

#[test]
#[ignore]
fn a_repository_in_a_distro_works_through_wsl() {
    let scratch = Scratch::new("live");
    let dir = scratch.0.clone();
    std::fs::write(dir.join("src/main.rs"), "one\ntwo\nthree\n").unwrap();
    std::fs::create_dir_all(dir.join("docs")).unwrap();
    std::fs::write(dir.join("docs/说明 1.md"), "中文\n").unwrap();
    git::run(&dir, ["init", "-q", "-b", "main"]).unwrap();

    // Found, from a folder inside it, under the path the user opened.
    assert_eq!(git::repository_root(&dir.join("src")).as_deref(), Some(dir.as_path()));
    assert_eq!(git::refusal(&dir, &[]), None);
    let git_directory = remote::git_directory(&dir).expect("git directory");
    assert!(git_directory.join("HEAD").is_file(), "{git_directory:?}");

    // The first commit: message and path list are files in Windows' temp folder, which git reaches under /mnt.
    let status = git::status(&dir, Some(&git_directory)).unwrap();
    assert_eq!(status.changes.len(), 2, "{:?}", status.changes);
    assert!(status.changes.iter().all(|c| c.kind == ChangeKind::Untracked));
    let first = commit::commit("First", &status.changes, false, &dir).unwrap();
    assert!(first.is_root);
    assert_eq!(git::blob("HEAD", "docs/说明 1.md", &dir).as_deref(), Some("中文\n".as_bytes()));

    // A change, counted.
    std::fs::write(dir.join("src/main.rs"), "one\n2\nthree\nfour\n").unwrap();
    let status = git::status(&dir, Some(&git_directory)).unwrap();
    let main = change(&status, "src/main.rs").clone();
    assert_eq!((main.kind, main.additions, main.deletions), (ChangeKind::Modified, Some(2), Some(1)));

    // Part of it committed: DiffCode's own index goes to git as GIT_INDEX_FILE, translated by WSLENV.
    let excluded = HashSet::from([ChangeLine { removed: false, line: 3, text: "four".into() }]);
    commit::commit_partial("Part", &[], &[PartialFile { change: main, excluded }], false, &dir).unwrap();
    assert_eq!(git::blob("HEAD", "src/main.rs", &dir).as_deref(), Some("one\n2\nthree\n".as_bytes()));
    let status = git::status(&dir, Some(&git_directory)).unwrap();
    let left = change(&status, "src/main.rs");
    assert_eq!((left.additions, left.deletions), (Some(1), Some(0)), "only the line left out is still a change");

    let history = git::log(&dir, 0, 10, "", false, None).unwrap();
    assert_eq!(history.iter().map(|c| c.subject.as_str()).collect::<Vec<_>>(), ["Part", "First"]);

    // A linked work tree, made with its share path: git lists it inside the distro, the app gets the share path back.
    let linked = scratch.sibling("-wt");
    git::run(&dir, ["worktree".to_string(), "add".into(), "-q".into(), "-b".into(), "feature".into(), linked.to_string_lossy().into_owned()])
        .unwrap();
    let paths: Vec<PathBuf> = git::worktrees(&dir).into_iter().map(|w| w.path).collect();
    assert_eq!(paths, [dir.clone(), linked.clone()]);
    assert_eq!(git::repository_root(&linked).as_deref(), Some(linked.as_path()));
    let linked_git = remote::git_directory(&linked).expect("linked git directory");
    assert!(linked_git.join("HEAD").is_file(), "{linked_git:?}");
}

#[test]
#[ignore]
fn a_folder_on_the_share_that_is_no_repository_is_just_that() {
    let scratch = Scratch::new("plain");
    assert_eq!(git::repository_root(&scratch.0), None);
    assert_eq!(git::refusal(&scratch.0, &[]), None);
}

#[test]
#[ignore]
fn a_distro_that_is_not_there_is_said_readably() {
    let error = git::run(Path::new(r"\\wsl.localhost\NoSuchDistro\home"), ["status"]).unwrap_err().message();
    println!("missing distro: {error}");
    assert!(!error.trim().is_empty());
    assert!(!error.contains('\0'), "{error:?}");
}

#[test]
#[ignore]
fn the_watcher_hears_a_change_on_the_share() {
    let scratch = Scratch::new("watch");
    let (tx, rx) = mpsc::channel();
    let _watcher = watcher::FileWatcher::new(&scratch.0, move |paths, _| {
        let _ = tx.send(paths);
    })
    .expect("watching the share");
    std::thread::sleep(Duration::from_millis(500));
    std::fs::write(scratch.0.join("src/new.rs"), "x\n").unwrap();
    let heard = rx.recv_timeout(Duration::from_secs(5));
    println!("watcher: {heard:?}");
    assert!(heard.is_ok(), "no event within 5 s");
}
