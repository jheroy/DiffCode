//! Repositories inside WSL, opened from Windows as `\\wsl.localhost\Ubuntu\home\me\app` (issue #7). Git for
//! Windows refuses them, since their files belong to the distro's user, and is slow over the share; so their git
//! runs inside the distro, through `wsl.exe`, with the distro's own configuration, hooks and credentials.
//!
//! Everything that crosses over is translated here: the folder git runs in, file arguments (DiffCode's scratch files
//! under `C:\…` become `/mnt/c/…`), and the paths git prints back (`/home/me/app` becomes the share path again).

use std::path::{Path, PathBuf};

/// A folder inside a WSL distro, as Windows reaches it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Location {
    /// `wsl.localhost` or `wsl$`, kept as the user had it so the paths git prints back match theirs.
    pub host: String,
    pub distro: String,
    /// The same folder inside the distro: `/home/me/app`.
    pub linux: String,
}

/// The distro folder `path` names, if it is one. Only on Windows: elsewhere there is no WSL, and a backslash is
/// just a character in a file name.
pub fn location(path: &Path) -> Option<Location> {
    if !cfg!(windows) {
        return None;
    }
    parse(&path.to_string_lossy())
}

/// `\\wsl.localhost\Ubuntu\home\me` (or `\\wsl$\…`, forward slashes, the `\\?\UNC\` form) as a distro folder.
pub fn parse(path: &str) -> Option<Location> {
    let unified = path.replace('/', "\\");
    let rest = if let Some(r) = unified.strip_prefix("\\\\?\\UNC\\") {
        r
    } else {
        unified.strip_prefix("\\\\")?
    };
    let mut parts = rest.split('\\');
    let host = parts.next()?;
    if !host.eq_ignore_ascii_case("wsl.localhost") && !host.eq_ignore_ascii_case("wsl$") {
        return None;
    }
    let distro = parts.next().filter(|d| !d.is_empty())?;
    let inside: Vec<&str> = parts.filter(|p| !p.is_empty()).collect();
    Some(Location { host: host.to_string(), distro: distro.to_string(), linux: format!("/{}", inside.join("/")) })
}

impl Location {
    /// A path git printed inside the distro, as Windows reaches it: `/home/me/app` → `\\wsl.localhost\Ubuntu\home\me\app`.
    pub fn windows_path(&self, linux: &str) -> PathBuf {
        let inside = linux.trim_start_matches('/').replace('/', "\\");
        let root = format!("\\\\{}\\{}", self.host, self.distro);
        PathBuf::from(if inside.is_empty() { root } else { format!("{root}\\{inside}") })
    }

    /// A Windows path as the distro sees it: a file in this distro by its own path, a drive by its `/mnt` mount.
    /// None for anything else (another distro, a network share), which git there could not reach.
    pub fn linux_path(&self, windows: &str) -> Option<String> {
        if let Some(other) = parse(windows) {
            return other.distro.eq_ignore_ascii_case(&self.distro).then_some(other.linux);
        }
        let bytes = windows.as_bytes();
        if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
            let drive = (bytes[0] as char).to_ascii_lowercase();
            let inside = windows[3..].replace('\\', "/");
            let inside = inside.trim_end_matches('/');
            return Some(if inside.is_empty() { format!("/mnt/{drive}") } else { format!("/mnt/{drive}/{inside}") });
        }
        None
    }

    /// One git argument, with a Windows path in it (`C:\…\message`, `--file=C:\…`) put as the distro sees it.
    /// Everything else (options, revisions, repository-relative paths) passes as it is.
    pub fn linux_argument(&self, argument: &str) -> String {
        if let Some(path) = self.linux_path(argument) {
            return path;
        }
        if let Some((option, value)) = argument.split_once('=') {
            if option.starts_with("--") {
                if let Some(path) = self.linux_path(value) {
                    return format!("{option}={path}");
                }
            }
        }
        argument.to_string()
    }

    /// `wsl.exe` and its arguments that run `program` in this folder, inside the distro.
    pub fn command_line(&self, program: &str) -> Vec<String> {
        ["-d", &self.distro, "--cd", &self.linux, "--exec", program].iter().map(|s| s.to_string()).collect()
    }
}

/// `WSLENV`, which lists the variables `wsl.exe` hands to the distro: `extra` added to what was there. A variable that
/// holds a Windows path (`GIT_INDEX_FILE`) is translated on the way (`/p`); the others go as they are (`/u`).
pub fn environment_list(existing: Option<&str>, extra: &[&str]) -> String {
    let mut list: Vec<String> = existing.unwrap_or("").split(':').filter(|s| !s.is_empty()).map(String::from).collect();
    for name in extra {
        let present = list.iter().any(|item| item.split('/').next().is_some_and(|n| n.eq_ignore_ascii_case(name)));
        if !present {
            let flag = if *name == "GIT_INDEX_FILE" { "/p" } else { "/u" };
            list.push(format!("{name}{flag}"));
        }
    }
    list.join(":")
}

/// What `wsl.exe` printed, readable: it writes its own messages in UTF-16, unlike git.
pub fn decode_output(data: &[u8]) -> String {
    let zeros = data.iter().skip(1).step_by(2).filter(|b| **b == 0).count();
    if data.len() >= 4 && zeros * 2 >= data.len() / 2 {
        let start = if data.starts_with(&[0xFF, 0xFE]) { 2 } else { 0 };
        let units: Vec<u16> = data[start..].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(data).into_owned()
    }
}

/// A failure of `wsl.exe` itself, said plainly: no git in the distro is the likely one.
pub fn explain(message: &str, distro: &str) -> String {
    let text = message.trim();
    if text.contains("execvpe(git) failed") || text.contains("execvp(git) failed") || text.contains("git: not found") {
        return crate::lf!(
            "Git isn't installed in {distro}. Install it there, for example with \"sudo apt install git\".",
            "{distro} 里没有安装 Git。请在其中安装，例如运行 \"sudo apt install git\"。"
        );
    }
    text.to_string()
}

/// How a program Windows could not start is described, when it was `wsl.exe`.
pub fn not_started(error: &str) -> String {
    crate::lf!("WSL is not available on this PC ({error}).", "这台电脑上没有可用的 WSL（{error}）。")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ubuntu() -> Location {
        parse(r"\\wsl.localhost\Ubuntu\home\me\app").unwrap()
    }

    #[test]
    fn distro_folders_are_recognised_in_every_spelling() {
        assert_eq!(ubuntu(), Location { host: "wsl.localhost".into(), distro: "Ubuntu".into(), linux: "/home/me/app".into() });
        assert_eq!(parse(r"\\wsl$\Debian\srv\x\").unwrap().linux, "/srv/x");
        assert_eq!(parse("//wsl.localhost/Ubuntu-24.04/home").unwrap().distro, "Ubuntu-24.04");
        assert_eq!(parse(r"\\?\UNC\WSL.LOCALHOST\Ubuntu\home\me").unwrap().linux, "/home/me");
        assert_eq!(parse(r"\\wsl.localhost\Ubuntu").unwrap().linux, "/");
        for other in [r"C:\work\app", r"\\server\share\app", r"\\wsl.localhost\", "/home/me", r"\\wsl.localhostx\U\a"] {
            assert_eq!(parse(other), None, "{other}");
        }
    }

    #[test]
    fn paths_cross_both_ways() {
        let at = ubuntu();
        assert_eq!(at.windows_path("/home/me/app/.git"), PathBuf::from(r"\\wsl.localhost\Ubuntu\home\me\app\.git"));
        assert_eq!(at.windows_path("/"), PathBuf::from(r"\\wsl.localhost\Ubuntu"));
        let dollar = parse(r"\\wsl$\Ubuntu\home").unwrap();
        assert_eq!(dollar.windows_path("/home/me/wt"), PathBuf::from(r"\\wsl$\Ubuntu\home\me\wt"));
        assert_eq!(at.linux_path(r"C:\Users\me\AppData\Local\Temp\diffcode-1\message").as_deref(), Some("/mnt/c/Users/me/AppData/Local/Temp/diffcode-1/message"));
        assert_eq!(at.linux_path("D:/").as_deref(), Some("/mnt/d"));
        assert_eq!(at.linux_path(r"\\wsl$\ubuntu\tmp\x").as_deref(), Some("/tmp/x"));
        assert_eq!(at.linux_path(r"\\wsl.localhost\Debian\tmp\x"), None);
        assert_eq!(at.linux_path("src/main.rs"), None);
    }

    #[test]
    fn only_file_arguments_are_translated() {
        let at = ubuntu();
        assert_eq!(at.linux_argument(r"--file=C:\Temp\d\message"), "--file=/mnt/c/Temp/d/message");
        assert_eq!(at.linux_argument(r"--pathspec-from-file=C:\Temp\d\paths"), "--pathspec-from-file=/mnt/c/Temp/d/paths");
        assert_eq!(at.linux_argument(r"C:\Temp\d\part0"), "/mnt/c/Temp/d/part0");
        for same in ["--path=src/a.rs", "HEAD~1", "-U0", "--format=%H %s", "src/C:/odd", "core.quotepath=false", "-m"] {
            assert_eq!(at.linux_argument(same), same);
        }
        assert_eq!(at.command_line("git"), ["-d", "Ubuntu", "--cd", "/home/me/app", "--exec", "git"]);
    }

    #[test]
    fn work_trees_git_lists_inside_the_distro_are_put_on_the_share() {
        let at = parse(r"\\wsl$\Ubuntu\home\me\app").unwrap();
        let text = "worktree /home/me/app\nHEAD 1\nbranch refs/heads/main\n\nworktree /home/me/agent-1\nHEAD 2\nbranch refs/heads/agent-1\n";
        let list = crate::git::parse_worktrees(text, |p| at.windows_path(p));
        let paths: Vec<PathBuf> = list.into_iter().map(|w| w.path).collect();
        assert_eq!(paths, [PathBuf::from(r"\\wsl$\Ubuntu\home\me\app"), PathBuf::from(r"\\wsl$\Ubuntu\home\me\agent-1")]);
    }

    #[test]
    fn the_environment_list_keeps_what_was_there() {
        assert_eq!(environment_list(None, &["LC_ALL", "GIT_INDEX_FILE"]), "LC_ALL/u:GIT_INDEX_FILE/p");
        assert_eq!(environment_list(Some("USERPROFILE/p:LC_ALL"), &["LC_ALL", "GIT_PAGER"]), "USERPROFILE/p:LC_ALL:GIT_PAGER/u");
    }

    #[test]
    fn wsl_messages_are_read_in_either_encoding() {
        let utf16: Vec<u8> = "There is no distribution with the supplied name.\r\n".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(decode_output(&utf16).trim(), "There is no distribution with the supplied name.");
        assert_eq!(decode_output("fatal: not a git repository\n".as_bytes()), "fatal: not a git repository\n");
        assert!(explain("<3>WSL (12) ERROR: CreateProcessCommon:640: execvpe(git) failed: No such file or directory", "Ubuntu").contains("sudo apt install git"));
    }
}
