//! One terminal: a shell on a pseudo-console (ConPTY on Windows, a pty elsewhere), its screen kept by
//! alacritty_terminal, and how keys, the mouse and pasted text reach the program.
//!
//! The screen lives behind a lock the reading thread also takes; the interface locks it only to draw and to act.

use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc};
use std::time::Instant;

pub use alacritty_terminal::event::Event as TermEvent;
use alacritty_terminal::event::{EventListener, Notify, OnResize, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, Msg, Notifier};
pub use alacritty_terminal::grid::{Dimensions, Scroll};
pub use alacritty_terminal::index::{Column, Line, Point as GridPoint, Side};
pub use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
pub use alacritty_terminal::term::cell::Flags;
pub use alacritty_terminal::term::TermMode;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::tty;
pub use alacritty_terminal::vte::ansi::{Color as TermColor, CursorShape, NamedColor, Rgb};
use alacritty_terminal::vte::ansi::{Processor, StdSyncHandler};

use crate::app::project::ProjectId;
use crate::core::lf;
use crate::input::{Key, Modifiers, MouseButton};
use crate::platform::Waker;

pub type SessionId = u64;

/// Lines of history per terminal: each costs memory for every column whether used or not.
pub const SCROLLBACK_LINES: usize = 2000;

/// Hands the reading thread's news to the interface, and wakes it.
#[derive(Clone)]
pub struct Listener {
    id: SessionId,
    tx: mpsc::Sender<(SessionId, TermEvent)>,
    waker: Option<Waker>,
}

impl EventListener for Listener {
    fn send_event(&self, event: TermEvent) {
        let _ = self.tx.send((self.id, event));
        if let Some(wake) = &self.waker {
            wake();
        }
    }
}

struct GridSize {
    columns: usize,
    lines: usize,
}

impl Dimensions for GridSize {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.columns
    }
}

// MARK: - Shell

/// Which shell runs, for its name and how it wants paths quoted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shell {
    pub program: String,
    pub args: Vec<String>,
    pub kind: ShellKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellKind {
    PowerShell,
    Cmd,
    Posix,
}

impl Shell {
    /// PowerShell 7 when it is installed, else Windows PowerShell, else the command prompt. Elsewhere the user's shell.
    pub fn default_shell() -> Shell {
        if cfg!(windows) {
            for (exe, kind) in [("pwsh.exe", ShellKind::PowerShell), ("powershell.exe", ShellKind::PowerShell)] {
                if let Some(path) = find_on_path(exe) {
                    return Shell { program: path.to_string_lossy().into_owned(), args: vec!["-NoLogo".into()], kind };
                }
            }
            let cmd = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into());
            Shell { program: cmd, args: Vec::new(), kind: ShellKind::Cmd }
        } else {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
            Shell { program: shell, args: vec!["-l".into()], kind: ShellKind::Posix }
        }
    }

    /// The shell for a terminal in `directory`: inside WSL, the distro's own shell, started in that folder.
    pub fn for_directory(directory: &Path) -> Shell {
        match crate::core::wsl::location(directory) {
            Some(at) => Shell { program: "wsl.exe".into(), args: vec!["-d".into(), at.distro, "--cd".into(), at.linux], kind: ShellKind::Posix },
            None => Shell::default_shell(),
        }
    }

    /// The program's name without its folder or `.exe`; a distro's shell goes by the distro, which says more than "wsl".
    pub fn name(&self) -> String {
        let name = process_name(&self.program);
        if name.eq_ignore_ascii_case("wsl") {
            if let [flag, distro, ..] = self.args.as_slice() {
                if flag == "-d" {
                    return distro.clone();
                }
            }
        }
        name
    }

    /// Quotes `text` so this shell reads it back as one word. Plain paths are left as they are.
    pub fn quote(&self, text: &str) -> String {
        let safe = |c: char| c.is_ascii_alphanumeric() || "_./\\-+@:,%=".contains(c);
        if !text.is_empty() && text.chars().all(safe) {
            return text.to_string();
        }
        match self.kind {
            ShellKind::PowerShell => format!("'{}'", text.replace('\'', "''")),
            ShellKind::Cmd => format!("\"{}\"", text.replace('"', "")),
            ShellKind::Posix => format!("'{}'", text.replace('\'', "'\\''")),
        }
    }
}

/// `C:\Program Files\PowerShell\7\pwsh.exe` → `pwsh`.
pub fn process_name(path: &str) -> String {
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    let name = name.strip_suffix(".exe").or_else(|| name.strip_suffix(".EXE")).unwrap_or(name);
    name.trim_start_matches('-').to_string()
}

fn find_on_path(exe: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(exe)).find(|p| p.is_file())
}

// MARK: - Session

/// A shell running in a project directory, and the screen that shows it.
pub struct Session {
    pub id: SessionId,
    pub project: ProjectId,
    pub directory: PathBuf,
    pub shell: Shell,
    /// Set by the running program (OSC 0/2); empty until one does.
    pub title: String,
    /// The program in the foreground: the shell itself, or whatever it is running.
    pub process_name: String,
    /// Something other than the shell is in the foreground.
    pub is_busy: bool,
    /// The bell rang while the terminal was not being looked at.
    pub needs_attention: bool,
    /// Share of the panel's width, relative to the other terminals.
    pub weight: f32,
    pub term: Arc<FairMutex<Term<Listener>>>,
    pub pid: Option<u32>,
    pub is_started: bool,
    pub has_ended: bool,
    /// Columns and lines the program was told.
    pub grid: (usize, usize),
    /// A drag that selects is under way.
    pub selecting: bool,
    /// Typed in before the shell started; sent once it has.
    pub pending_input: String,
    /// An input method's composition, shown at the cursor until it is committed.
    pub preedit: String,
    /// Wheel movement not yet worth a whole line.
    pub wheel_rest: f32,
    /// Where the scrollbar's thumb was grabbed, while it is dragged.
    pub scrollbar_grab: Option<f32>,
    /// The cell last reported to a program following the mouse.
    pub mouse_cell: Option<(usize, usize)>,
    notifier: Option<Notifier>,
    listener: Listener,
    started_at: Instant,
}

impl Session {
    pub fn new(id: SessionId, project: ProjectId, directory: PathBuf, tx: mpsc::Sender<(SessionId, TermEvent)>, waker: Option<Waker>) -> Session {
        let listener = Listener { id, tx, waker };
        let config = Config { scrolling_history: SCROLLBACK_LINES, ..Config::default() };
        let term = Term::new(config, &GridSize { columns: 80, lines: 24 }, listener.clone());
        let shell = Shell::for_directory(&directory);
        Session {
            id,
            project,
            directory,
            process_name: shell.name(),
            shell,
            title: String::new(),
            is_busy: false,
            needs_attention: false,
            weight: 1.0,
            term: Arc::new(FairMutex::new(term)),
            pid: None,
            is_started: false,
            has_ended: false,
            grid: (80, 24),
            selecting: false,
            pending_input: String::new(),
            preedit: String::new(),
            wheel_rest: 0.0,
            scrollbar_grab: None,
            mouse_cell: None,
            notifier: None,
            listener,
            started_at: Instant::now(),
        }
    }

    pub fn display_title(&self) -> &str {
        if self.title.is_empty() {
            &self.process_name
        } else {
            &self.title
        }
    }

    /// What the program says it is doing, when that adds something to its name.
    pub fn subtitle(&self) -> &str {
        if self.title == self.process_name {
            ""
        } else {
            &self.title
        }
    }

    /// Launches the shell, sized for the pane it is in, so the first prompt is laid out for it.
    /// A path as this terminal's shell reaches it: a Windows path is put as the distro sees it in a WSL terminal.
    pub fn shell_path(&self, path: &str) -> String {
        crate::core::wsl::location(&self.directory).and_then(|at| at.linux_path(path)).unwrap_or_else(|| path.to_string())
    }

    pub fn start(&mut self, columns: usize, lines: usize, cell: (f32, f32)) {
        if self.is_started {
            return;
        }
        self.is_started = true;
        self.started_at = Instant::now();
        self.resize_grid(columns, lines);
        let directory = if self.directory.is_dir() { self.directory.clone() } else { home_dir() };
        let mut env = std::collections::HashMap::new();
        env.insert("TERM".to_string(), "xterm-256color".to_string());
        env.insert("COLORTERM".to_string(), "truecolor".to_string());
        env.insert("TERM_PROGRAM".to_string(), "DiffCode".to_string());
        env.insert("TERM_PROGRAM_VERSION".to_string(), env!("CARGO_PKG_VERSION").to_string());
        if crate::core::wsl::location(&self.directory).is_some() {
            // A distro's shell sees only the variables WSLENV names.
            let names = ["TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"];
            env.insert("WSLENV".to_string(), crate::core::wsl::environment_list(std::env::var("WSLENV").ok().as_deref(), &names));
        }
        let options = tty::Options {
            shell: Some(tty::Shell::new(self.shell.program.clone(), self.shell.args.clone())),
            working_directory: Some(directory),
            drain_on_exit: false,
            env,
            #[cfg(windows)]
            escape_args: true,
        };
        let size = window_size(columns, lines, cell);
        let pty = match tty::new(&options, size, self.id) {
            Ok(pty) => pty,
            Err(e) => return self.could_not_start(&e.to_string()),
        };
        self.pid = pty_pid(&pty);
        match EventLoop::new(self.term.clone(), self.listener.clone(), pty, false, false) {
            Ok(event_loop) => {
                self.notifier = Some(Notifier(event_loop.channel()));
                event_loop.spawn();
                let pending = std::mem::take(&mut self.pending_input);
                self.write(pending.into_bytes());
            }
            Err(e) => self.could_not_start(&e.to_string()),
        }
    }

    fn could_not_start(&mut self, reason: &str) {
        self.has_ended = true;
        let program = self.shell.program.clone();
        let text = lf!("Could not start {program}: {reason}", "无法启动 {program}：{reason}");
        self.feed(format!("{text}\r\n").as_bytes());
    }

    /// The shell exited. True when the pane should close; false when it failed to start and stays up to say so.
    pub fn exited(&mut self, success: bool) -> bool {
        if self.has_ended {
            return false;
        }
        self.has_ended = true;
        self.notifier = None;
        if !success && self.started_at.elapsed().as_secs_f32() < 1.5 {
            let program = self.shell.program.clone();
            let text = lf!("{program} ended as soon as it started.", "{program} 一启动就退出了。");
            self.feed(format!("\r\n{text}\r\n").as_bytes());
            return false;
        }
        true
    }

    /// Ends the shell and everything it started.
    pub fn terminate(&mut self) {
        self.has_ended = true;
        if let Some(n) = self.notifier.take() {
            let _ = n.0.send(Msg::Shutdown);
        }
    }

    /// Writes to the program: keys, pasted text, the terminal's own replies.
    pub fn write(&self, bytes: impl Into<Vec<u8>>) {
        if let Some(n) = &self.notifier {
            let bytes: Vec<u8> = bytes.into();
            if !bytes.is_empty() {
                n.notify(bytes);
            }
        }
    }

    /// Typing goes to the bottom of the history, where the prompt is.
    pub fn write_input(&self, bytes: impl Into<Vec<u8>>) {
        {
            let mut term = self.term.lock();
            if term.grid().display_offset() != 0 {
                term.scroll_display(Scroll::Bottom);
            }
            term.selection = None;
        }
        self.write(bytes);
    }

    /// Text as if the program had printed it.
    pub fn feed(&self, bytes: &[u8]) {
        let mut parser: Processor<StdSyncHandler> = Processor::new();
        let mut term = self.term.lock();
        parser.advance(&mut *term, bytes);
    }

    fn resize_grid(&mut self, columns: usize, lines: usize) {
        self.grid = (columns, lines);
        self.term.lock().resize(GridSize { columns, lines });
    }

    /// The pane changed size: the screen reflows and the program is told.
    pub fn resize(&mut self, columns: usize, lines: usize, cell: (f32, f32)) {
        let (columns, lines) = (columns.max(2), lines.max(1));
        if (columns, lines) == self.grid {
            return;
        }
        self.resize_grid(columns, lines);
        if let Some(n) = &mut self.notifier {
            n.on_resize(window_size(columns, lines, cell));
        }
    }

    /// Wipes the screen and history, then asks the shell to draw its prompt again.
    pub fn clear(&self) {
        {
            let mut term = self.term.lock();
            term.selection = None;
            term.scroll_display(Scroll::Bottom);
        }
        self.feed(b"\x1b[H\x1b[2J\x1b[3J");
        match self.shell.kind {
            ShellKind::Cmd => self.write("cls\r"),
            _ => self.write("\x0c"),
        }
    }

    pub fn paste(&self, text: &str) {
        let bracketed = self.term.lock().mode().contains(TermMode::BRACKETED_PASTE);
        self.write_input(paste_bytes(text, bracketed));
    }

    pub fn selected_text(&self) -> Option<String> {
        self.term.lock().selection_to_string().filter(|s| !s.is_empty())
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }

    pub fn scroll(&self, lines: i32) {
        self.term.lock().scroll_display(Scroll::Delta(lines));
    }
}

fn window_size(columns: usize, lines: usize, cell: (f32, f32)) -> WindowSize {
    WindowSize { num_lines: lines as u16, num_cols: columns as u16, cell_width: cell.0.round().max(1.0) as u16, cell_height: cell.1.round().max(1.0) as u16 }
}

#[cfg(windows)]
fn pty_pid(pty: &tty::Pty) -> Option<u32> {
    pty.child_watcher().pid().map(|p| p.get())
}

#[cfg(unix)]
fn pty_pid(pty: &tty::Pty) -> Option<u32> {
    Some(pty.child().id())
}

fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// Whether `path` is inside `root` (for the folder chip on a pane opened elsewhere).
pub fn same_dir(a: &Path, b: &Path) -> bool {
    a == b || a.canonicalize().ok().zip(b.canonicalize().ok()).is_some_and(|(x, y)| x == y)
}

/// The program in the foreground under a shell, from a list of running processes (id, parent id, executable):
/// the deepest of the shell's descendants, the newest of equals, leaving out console hosts. None when the shell has
/// nothing running.
///
/// A distro's shell (`wsl.exe`) never counts as busy: under it are only WSL's own processes (a second `wsl.exe`, then
/// `wslhost.exe`), and what runs inside the distro is no Windows process at all.
pub fn foreground_among(processes: &[(u32, u32, String)], shell: u32) -> Option<String> {
    let is_wsl = processes.iter().any(|(pid, _, name)| *pid == shell && name.eq_ignore_ascii_case("wsl.exe"));
    if is_wsl {
        return None;
    }
    // `wslhost.exe`: WSL's helper under a `wsl` the user ran from another shell, which then goes by "wsl".
    let host = |name: &str| {
        let n = name.to_ascii_lowercase();
        n == "conhost.exe" || n == "openconsole.exe" || n == "wslhost.exe"
    };
    let mut best: Option<(usize, usize)> = None;
    let mut level: Vec<u32> = vec![shell];
    let mut depth = 0;
    let mut seen = std::collections::HashSet::from([shell]);
    while !level.is_empty() && depth < 32 {
        depth += 1;
        let mut next = Vec::new();
        for (i, (pid, parent, name)) in processes.iter().enumerate() {
            if level.contains(parent) && !host(name) && seen.insert(*pid) {
                next.push(*pid);
                if best.is_none_or(|(d, j)| depth > d || (depth == d && i > j)) {
                    best = Some((depth, i));
                }
            }
        }
        level = next;
    }
    let name = &processes[best?.1].2;
    let lower = name.to_ascii_lowercase();
    Some(if lower.ends_with(".exe") { name[..name.len() - 4].to_string() } else { name.clone() })
}

// MARK: - Input

/// What a key press sends to the program, xterm style. None for keys whose text arrives as typed text.
pub fn key_bytes(key: Key, mods: Modifiers, mode: TermMode) -> Option<Vec<u8>> {
    let app_cursor = mode.contains(TermMode::APP_CURSOR);
    // xterm's modifier parameter: 1 + Shift + 2·Alt + 4·Ctrl.
    let m = 1 + u8::from(mods.shift) + 2 * u8::from(mods.alt) + 4 * u8::from(mods.ctrl);
    let cursor = |c: char| -> Vec<u8> {
        if m > 1 {
            format!("\x1b[1;{m}{c}").into_bytes()
        } else if app_cursor {
            format!("\x1bO{c}").into_bytes()
        } else {
            format!("\x1b[{c}").into_bytes()
        }
    };
    let tilde = |n: u8| -> Vec<u8> {
        if m > 1 {
            format!("\x1b[{n};{m}~").into_bytes()
        } else {
            format!("\x1b[{n}~").into_bytes()
        }
    };
    let alt = |bytes: &[u8]| -> Vec<u8> {
        let mut out = Vec::with_capacity(bytes.len() + 1);
        if mods.alt {
            out.push(0x1b);
        }
        out.extend_from_slice(bytes);
        out
    };
    Some(match key {
        Key::Up => cursor('A'),
        Key::Down => cursor('B'),
        Key::Right => cursor('C'),
        Key::Left => cursor('D'),
        Key::Home => cursor('H'),
        Key::End => cursor('F'),
        Key::Insert => tilde(2),
        Key::Delete => tilde(3),
        Key::PageUp => tilde(5),
        Key::PageDown => tilde(6),
        Key::F(n @ 1..=4) => {
            let c = (b'P' + n - 1) as char;
            if m > 1 {
                format!("\x1b[1;{m}{c}").into_bytes()
            } else {
                format!("\x1bO{c}").into_bytes()
            }
        }
        Key::F(n @ 5..=12) => tilde([15, 17, 18, 19, 20, 21, 23, 24][(n - 5) as usize]),
        Key::F(_) => return None,
        Key::Enter => alt(b"\r"),
        Key::Tab if mods.shift => b"\x1b[Z".to_vec(),
        Key::Tab => alt(b"\t"),
        Key::Backspace => alt(if mods.ctrl { b"\x08" } else { b"\x7f" }),
        Key::Escape => alt(b"\x1b"),
        Key::Space if mods.ctrl => alt(b"\x00"),
        Key::Space if mods.alt => b"\x1b ".to_vec(),
        Key::Space => return None,
        Key::Char(c) if mods.ctrl && !mods.alt => {
            let byte = match c {
                'a'..='z' => c as u8 - b'a' + 1,
                '@' | '2' => 0,
                '[' | '3' => 27,
                '\\' | '4' => 28,
                ']' | '5' => 29,
                '^' | '6' => 30,
                '_' | '-' | '/' | '7' => 31,
                '8' => 127,
                _ => return None,
            };
            vec![byte]
        }
        Key::Char(c) if mods.alt && !mods.ctrl => {
            let c = if mods.shift { c.to_ascii_uppercase() } else { c };
            let mut out = vec![0x1b];
            let mut buf = [0u8; 4];
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            out
        }
        Key::Char(_) | Key::Shift => return None,
    })
}

/// Pasted text: line breaks as Enter, and fenced when the program asked to tell a paste from typing.
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    if bracketed {
        // The fence's own markers cannot come from inside the paste.
        let clean = text.replace("\x1b[201~", "").replace('\x1b', "");
        format!("\x1b[200~{clean}\x1b[201~").into_bytes()
    } else {
        text.replace("\r\n", "\r").replace('\n', "\r").into_bytes()
    }
}

/// A mouse report for a program that asked for the mouse. `button`: None for movement with nothing held.
#[allow(clippy::too_many_arguments)]
pub fn mouse_report(mode: TermMode, button: Option<MouseButton>, wheel: Option<bool>, pressed: bool, motion: bool, column: usize, line: usize, mods: Modifiers) -> Option<Vec<u8>> {
    let mut code: u8 = match (wheel, button) {
        (Some(up), _) => {
            if up {
                64
            } else {
                65
            }
        }
        (None, Some(MouseButton::Left)) => 0,
        (None, Some(MouseButton::Middle)) => 1,
        (None, Some(MouseButton::Right)) => 2,
        (None, None) => 3,
        _ => return None,
    };
    if motion {
        code += 32;
    }
    code += 4 * u8::from(mods.shift) + 8 * u8::from(mods.alt) + 16 * u8::from(mods.ctrl);
    let (x, y) = (column + 1, line + 1);
    if mode.contains(TermMode::SGR_MOUSE) {
        let end = if pressed || wheel.is_some() { 'M' } else { 'm' };
        return Some(format!("\x1b[<{code};{x};{y}{end}").into_bytes());
    }
    // The original encoding: one byte each, and no telling which button went up.
    if x > 222 || y > 222 {
        return None;
    }
    let code = if !pressed && wheel.is_none() { 3 + (code & !3) } else { code };
    Some(vec![0x1b, b'[', b'M', 32 + code, 32 + x as u8, 32 + y as u8])
}

// MARK: - Colours

/// The terminal's palette: a background, a foreground and the 16 ANSI colours, in DiffCode's own light and dark.
pub struct Palette {
    pub background: u32,
    pub foreground: u32,
    pub cursor: u32,
    pub selection: (u32, f32),
    pub ansi: [u32; 16],
}

impl Palette {
    pub fn new(dark: bool) -> Palette {
        if dark {
            Palette {
                background: 0x1E1F22,
                foreground: 0xBCBEC4,
                cursor: 0x548AF7,
                selection: (0x2F65CA, 0.55),
                ansi: [
                    0x2B2D30, 0xF75464, 0x6AAB73, 0xD6BF55, 0x56A8F5, 0xC77DBB, 0x2AACB8, 0xBCBEC4, 0x6F737A, 0xFA6675, 0x7EC482, 0xE0CE6B, 0x70B7FF,
                    0xD897CE, 0x4FC4CF, 0xF0F1F2,
                ],
            }
        } else {
            Palette {
                background: 0xFFFFFF,
                foreground: 0x1F2329,
                cursor: 0x3574F0,
                selection: (0x3574F0, 0.28),
                ansi: [
                    0x1F2329, 0xC7392F, 0x1E8A34, 0x9A7300, 0x1F5FD0, 0x9A3FA6, 0x17858A, 0x8C8F99, 0x5A5E69, 0xE5534B, 0x2DA44E, 0xB8860B, 0x3574F0,
                    0xB85CC4, 0x1BA3A8, 0xA2A6B3,
                ],
            }
        }
    }

    /// Colour `index` of the 256: the 16 above, then xterm's 6×6×6 cube and grey ramp.
    pub fn indexed(&self, index: u8) -> u32 {
        match index {
            0..=15 => self.ansi[index as usize],
            16..=231 => {
                let i = index - 16;
                let level = |v: u8| if v == 0 { 0 } else { 55 + 40 * v as u32 };
                (level(i / 36) << 16) | (level((i / 6) % 6) << 8) | level(i % 6)
            }
            _ => {
                let v = 8 + 10 * (index - 232) as u32;
                (v << 16) | (v << 8) | v
            }
        }
    }

    /// A cell colour as RGB, with colours the program set (OSC 4/10/11) taking precedence.
    pub fn resolve(&self, color: TermColor, overrides: &alacritty_terminal::term::color::Colors) -> u32 {
        let rgb = |c: Rgb| ((c.r as u32) << 16) | ((c.g as u32) << 8) | c.b as u32;
        match color {
            TermColor::Spec(c) => rgb(c),
            TermColor::Indexed(i) => overrides[i as usize].map(rgb).unwrap_or_else(|| self.indexed(i)),
            TermColor::Named(n) => {
                if let Some(c) = overrides[n as usize] {
                    return rgb(c);
                }
                let idx = n as usize;
                match n {
                    NamedColor::Foreground | NamedColor::BrightForeground => self.foreground,
                    NamedColor::Background => self.background,
                    NamedColor::Cursor => self.cursor,
                    NamedColor::DimForeground => mix(self.foreground, self.background, 0.35),
                    _ if idx < 16 => self.ansi[idx],
                    // Dim black … dim white follow the cursor in the enum.
                    _ => {
                        let base = idx.saturating_sub(NamedColor::DimBlack as usize).min(7);
                        mix(self.ansi[base], self.background, 0.35)
                    }
                }
            }
        }
    }

    /// The reply to a program asking for colour `index` (OSC 4/10/11/12).
    pub fn rgb(&self, index: usize) -> Rgb {
        let c = match index {
            0..=255 => self.indexed(index as u8),
            256 => self.foreground,
            257 => self.background,
            258 => self.cursor,
            _ => self.foreground,
        };
        Rgb { r: (c >> 16) as u8, g: (c >> 8) as u8, b: c as u8 }
    }
}

/// `a` moved `t` of the way to `b`.
pub fn mix(a: u32, b: u32, t: f32) -> u32 {
    let ch = |s: u32| {
        let (x, y) = (((a >> s) & 0xFF) as f32, ((b >> s) & 0xFF) as f32);
        ((x + (y - x) * t).round() as u32) << s
    };
    ch(16) | ch(8) | ch(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreground_is_the_deepest_child() {
        let p = |pid: u32, parent: u32, name: &str| (pid, parent, name.to_string());
        let list = vec![p(10, 1, "pwsh.exe"), p(11, 1, "conhost.exe"), p(20, 10, "node.exe"), p(30, 20, "git.exe"), p(31, 10, "OpenConsole.exe")];
        assert_eq!(foreground_among(&list, 10).as_deref(), Some("git"));
        assert_eq!(foreground_among(&list[..2], 10), None);
        let list = vec![p(10, 1, "cmd.exe"), p(20, 10, "a.exe"), p(21, 10, "b.EXE")];
        assert_eq!(foreground_among(&list, 10).as_deref(), Some("b"));
        // As WSL 3 starts a distro's shell, seen on a real PC.
        let list = vec![p(10, 1, "wsl.exe"), p(11, 10, "conhost.exe"), p(20, 10, "wsl.exe"), p(30, 20, "wslhost.exe"), p(40, 30, "conhost.exe")];
        assert_eq!(foreground_among(&list, 10), None, "a WSL terminal");
        let mut from_pwsh = vec![p(5, 1, "pwsh.exe")];
        from_pwsh.extend(list.iter().map(|(pid, parent, name)| (*pid, if *parent == 1 { 5 } else { *parent }, name.clone())));
        assert_eq!(foreground_among(&from_pwsh, 5).as_deref(), Some("wsl"), "wsl run from PowerShell");
    }

    #[test]
    fn a_distro_shell_is_named_after_the_distro() {
        let wsl = Shell { program: "wsl.exe".into(), args: vec!["-d".into(), "Ubuntu-24.04".into(), "--cd".into(), "/home/me".into()], kind: ShellKind::Posix };
        assert_eq!(wsl.name(), "Ubuntu-24.04");
        let pwsh = Shell { program: r"C:\Program Files\PowerShell\7\pwsh.exe".into(), args: vec!["-NoLogo".into()], kind: ShellKind::PowerShell };
        assert_eq!(pwsh.name(), "pwsh");
    }

    #[test]
    fn keys_follow_xterm() {
        let normal = TermMode::empty();
        assert_eq!(key_bytes(Key::Up, Modifiers::NONE, normal), Some(b"\x1b[A".to_vec()));
        assert_eq!(key_bytes(Key::Up, Modifiers::NONE, TermMode::APP_CURSOR), Some(b"\x1bOA".to_vec()));
        assert_eq!(key_bytes(Key::Left, Modifiers::CTRL, normal), Some(b"\x1b[1;5D".to_vec()));
        assert_eq!(key_bytes(Key::Char('c'), Modifiers::CTRL, normal), Some(vec![3]));
        assert_eq!(key_bytes(Key::Char('b'), Modifiers::ALT, normal), Some(b"\x1bb".to_vec()));
        assert_eq!(key_bytes(Key::F(5), Modifiers::NONE, normal), Some(b"\x1b[15~".to_vec()));
        assert_eq!(key_bytes(Key::Tab, Modifiers::SHIFT, normal), Some(b"\x1b[Z".to_vec()));
        assert_eq!(key_bytes(Key::Char('a'), Modifiers::NONE, normal), None);
    }

    #[test]
    fn pastes_are_fenced_when_asked() {
        assert_eq!(paste_bytes("a\nb", false), b"a\rb".to_vec());
        assert_eq!(paste_bytes("a\x1b[201~b", true), b"\x1b[200~ab\x1b[201~".to_vec());
    }

    #[test]
    fn shells_quote_their_own_way() {
        let ps = Shell { program: "pwsh.exe".into(), args: vec![], kind: ShellKind::PowerShell };
        let cmd = Shell { program: "cmd.exe".into(), args: vec![], kind: ShellKind::Cmd };
        let sh = Shell { program: "/bin/zsh".into(), args: vec![], kind: ShellKind::Posix };
        assert_eq!(ps.quote("src/main.rs"), "src/main.rs");
        assert_eq!(ps.quote("a b's"), "'a b''s'");
        assert_eq!(cmd.quote("a b"), "\"a b\"");
        assert_eq!(sh.quote("a b's"), "'a b'\\''s'");
        assert_eq!(process_name(r"C:\Program Files\PowerShell\7\pwsh.exe"), "pwsh");
        assert_eq!(process_name("-zsh"), "zsh");
    }

    #[test]
    fn mouse_reports() {
        let sgr = TermMode::SGR_MOUSE | TermMode::MOUSE_REPORT_CLICK;
        assert_eq!(mouse_report(sgr, Some(MouseButton::Left), None, true, false, 4, 2, Modifiers::NONE), Some(b"\x1b[<0;5;3M".to_vec()));
        assert_eq!(mouse_report(sgr, Some(MouseButton::Left), None, false, false, 4, 2, Modifiers::NONE), Some(b"\x1b[<0;5;3m".to_vec()));
        assert_eq!(mouse_report(sgr, None, Some(true), true, false, 0, 0, Modifiers::NONE), Some(b"\x1b[<64;1;1M".to_vec()));
    }

    #[test]
    fn palette_cube() {
        let p = Palette::new(true);
        assert_eq!(p.indexed(16), 0x000000);
        assert_eq!(p.indexed(231), 0xFFFFFF);
        assert_eq!(p.indexed(232), 0x080808);
    }
}
