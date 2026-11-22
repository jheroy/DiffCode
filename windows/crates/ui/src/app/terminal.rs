//! Every open terminal, grouped by project, and the panel that shows the current project's. Hiding the panel or
//! switching projects never restarts a shell.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::dialog::{DialogItem, DialogRequest, DialogStyle};
use super::project::ProjectId;
use super::{ids, App, PlatformRequest};
use crate::core::lang::l;
use crate::geom::Rect;
use crate::icons::Icon;
use crate::platform::{Platform, Waker};
use crate::terminal::{Session, SessionId, TermEvent};
use crate::ui::Id;

/// The running program's name is checked this often while a terminal is on screen.
const POLL: Duration = Duration::from_millis(1500);

pub struct Terminals {
    pub sessions: Vec<Session>,
    pub visible: bool,
    /// Where each pane was drawn last frame, for files dropped on one.
    pub pane_rects: Vec<(SessionId, Rect)>,
    last_active: HashMap<ProjectId, SessionId>,
    next_id: SessionId,
    tx: mpsc::Sender<(SessionId, TermEvent)>,
    rx: mpsc::Receiver<(SessionId, TermEvent)>,
    waker: Option<Waker>,
    next_poll: Option<Instant>,
    /// The terminal that had the keyboard last frame, for focus reports.
    had_focus: Option<SessionId>,
}

impl Default for Terminals {
    fn default() -> Self {
        let (tx, rx) = mpsc::channel();
        Terminals {
            sessions: Vec::new(),
            visible: false,
            pane_rects: Vec::new(),
            last_active: HashMap::new(),
            next_id: 1,
            tx,
            rx,
            waker: None,
            next_poll: None,
            had_focus: None,
        }
    }
}

impl Terminals {
    pub fn set_waker(&mut self, waker: Waker) {
        self.waker = Some(waker);
    }

    pub fn session(&self, id: SessionId) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == id)
    }

    pub fn session_mut(&mut self, id: SessionId) -> Option<&mut Session> {
        self.sessions.iter_mut().find(|s| s.id == id)
    }

    pub fn for_project(&self, project: ProjectId) -> impl Iterator<Item = &Session> {
        self.sessions.iter().filter(move |s| s.project == project)
    }

    pub fn has_sessions(&self, project: ProjectId) -> bool {
        self.sessions.iter().any(|s| s.project == project)
    }

    pub fn needs_attention(&self, project: ProjectId) -> bool {
        self.sessions.iter().any(|s| s.project == project && s.needs_attention)
    }

    /// The terminal a keyboard focus id stands for.
    pub fn focused(&self, focus: Option<Id>) -> Option<SessionId> {
        let focus = focus?;
        self.sessions.iter().find(|s| ids::terminal(s.id) == focus).map(|s| s.id)
    }

    /// Terminals with a program running in them, for the quit question.
    pub fn busy(&self) -> Vec<&Session> {
        self.sessions.iter().filter(|s| s.is_busy && !s.has_ended).collect()
    }

    pub fn terminate_all(&mut self) {
        for s in &mut self.sessions {
            s.terminate();
        }
    }
}

impl App {
    pub fn has_terminal(&self) -> bool {
        true
    }

    pub fn terminal_has_focus(&self) -> bool {
        self.terminals.focused(self.focus).is_some()
    }

    fn focused_terminal(&self) -> Option<SessionId> {
        self.terminals.focused(self.focus)
    }

    /// The terminal commands act on: the focused one, else the one last used in this project.
    pub fn active_terminal(&self, project: ProjectId) -> Option<SessionId> {
        if let Some(id) = self.focused_terminal().filter(|id| self.terminals.session(*id).is_some_and(|s| s.project == project)) {
            return Some(id);
        }
        if let Some(id) = self.terminals.last_active.get(&project).filter(|id| self.terminals.session(**id).is_some()) {
            return Some(*id);
        }
        self.terminals.for_project(project).last().map(|s| s.id)
    }

    /// Alt+F12, as in the IDE: shows and focuses the terminal, or hides it when it already has the keyboard.
    pub fn toggle_terminal(&mut self) {
        let Some(project) = self.selected else { return };
        let focused_here = self.focused_terminal().and_then(|id| self.terminals.session(id)).is_some_and(|s| s.project == project);
        if self.terminals.visible && focused_here {
            self.hide_terminal();
            return;
        }
        self.terminals.visible = true;
        match self.active_terminal(project) {
            Some(id) => self.focus_terminal_session(id),
            None => {
                self.open_terminal(project, None);
            }
        }
    }

    pub fn hide_terminal(&mut self) {
        if !self.terminals.visible {
            return;
        }
        let had_focus = self.terminal_has_focus();
        self.terminals.visible = false;
        if had_focus {
            self.focus_viewer();
        }
    }

    /// Opens a new terminal beside the others and gives it the keyboard.
    pub fn open_terminal(&mut self, project: ProjectId, directory: Option<PathBuf>) -> Option<SessionId> {
        let directory = directory.or_else(|| self.project(project).map(|p| p.url.clone()))?;
        let id = self.terminals.next_id;
        self.terminals.next_id += 1;
        let session = Session::new(id, project, directory, self.terminals.tx.clone(), self.terminals.waker.clone());
        self.terminals.sessions.push(session);
        self.terminals.visible = true;
        self.focus_terminal_session(id);
        Some(id)
    }

    pub fn open_terminal_in_current_project(&mut self) {
        if let Some(project) = self.selected {
            self.open_terminal(project, None);
        }
    }

    pub fn focus_terminal_session(&mut self, id: SessionId) {
        let Some(s) = self.terminals.session_mut(id) else { return };
        s.needs_attention = false;
        let project = s.project;
        self.terminals.last_active.insert(project, id);
        self.focus_request = Some(ids::terminal(id));
    }

    /// Focus Terminal: the active one, showing the panel if need be.
    pub fn focus_terminal(&mut self) {
        let Some(project) = self.selected else { return };
        self.terminals.visible = true;
        match self.active_terminal(project) {
            Some(id) => self.focus_terminal_session(id),
            None => {
                self.open_terminal(project, None);
            }
        }
    }

    /// With a terminal focused, Alt+Left/Right walks the terminals. Returns whether one had the keyboard.
    pub fn cycle_terminal(&mut self, delta: i32) -> bool {
        let Some(focused) = self.focused_terminal() else { return false };
        let Some(project) = self.terminals.session(focused).map(|s| s.project) else { return false };
        let own: Vec<SessionId> = self.terminals.for_project(project).map(|s| s.id).collect();
        if let Some(index) = own.iter().position(|id| *id == focused) {
            if own.len() > 1 {
                let next = (index as i32 + delta).rem_euclid(own.len() as i32) as usize;
                self.focus_terminal_session(own[next]);
            }
        }
        true
    }

    /// Closes a terminal, asking first when that would end a running program.
    pub fn close_terminal_session(&mut self, id: SessionId) {
        let Some(s) = self.terminals.session(id) else { return };
        if !s.is_busy || s.has_ended {
            self.remove_terminal(id);
            return;
        }
        let item = DialogItem { title: s.process_name.clone(), detail: s.directory.display().to_string(), icon: Some(Icon::WindowConsole), ..Default::default() };
        let mut request = DialogRequest::new(DialogStyle::Caution, Icon::WindowConsole, l("Close this terminal?", "关闭这个终端？"), l("Close Terminal", "关闭终端"))
            .message(l("This program is still running and will be terminated.", "这个程序仍在运行，关闭终端会终止它。"))
            .confirm(move |app| app.remove_terminal(id));
        request.items = vec![item];
        self.ask(request);
    }

    /// Ctrl+Shift+W: closes the focused terminal.
    pub fn close_terminal(&mut self) {
        if let Some(id) = self.focused_terminal() {
            self.close_terminal_session(id);
        }
    }

    /// Clear Terminal (its menu, Find Action): wipes the screen and history, then has the shell draw its prompt again.
    pub fn clear_terminal(&mut self) {
        let id = self.focused_terminal().or_else(|| self.selected.and_then(|p| self.active_terminal(p)));
        if let Some(s) = id.and_then(|id| self.terminals.session(id)) {
            s.clear();
        }
    }

    /// Types `text` into the project's active terminal without running it.
    pub fn type_in_terminal(&mut self, text: &str, project: ProjectId) {
        let id = match self.active_terminal(project) {
            Some(id) => id,
            None => match self.open_terminal(project, None) {
                Some(id) => id,
                None => return,
            },
        };
        self.terminals.visible = true;
        if let Some(s) = self.terminals.session_mut(id) {
            if s.is_started {
                s.write_input(text.as_bytes().to_vec());
            } else {
                s.pending_input.push_str(text);
            }
        }
        self.focus_terminal_session(id);
    }

    /// A path, quoted for the shell, typed into the terminal.
    pub fn insert_path_in_terminal(&mut self, path: &str, project: ProjectId) {
        let quoted = match self.active_terminal(project).and_then(|id| self.terminals.session(id)) {
            Some(s) => s.shell.quote(&s.shell_path(path)),
            None => crate::terminal::Shell::default_shell().quote(path),
        };
        self.type_in_terminal(&format!("{quoted} "), project);
    }

    /// Ctrl+Alt+T: types the file on screen, with the selected lines if any, into the terminal, ready for an agent.
    pub fn insert_reference_in_terminal(&mut self) {
        let Some(project) = self.selected else { return };
        let Some(request) = self.viewer.request.as_ref() else { return };
        if self.project(project).is_none_or(|p| p.url != request.root) {
            return;
        }
        let mut text = match self.active_terminal(project).and_then(|id| self.terminals.session(id)) {
            Some(s) => s.shell.quote(&request.path),
            None => crate::terminal::Shell::default_shell().quote(&request.path),
        };
        if let Some((first, last)) = self.viewer.canvas.selected_line_range() {
            text += &if last > first { format!(":{first}-{last}") } else { format!(":{first}") };
        }
        self.type_in_terminal(&format!("{text} "), project);
    }

    fn remove_terminal(&mut self, id: SessionId) {
        if let Some(s) = self.terminals.session_mut(id) {
            s.terminate();
        }
        self.terminal_ended(id);
    }

    /// The shell exited, or the terminal was closed: the pane goes and the keyboard moves on.
    fn terminal_ended(&mut self, id: SessionId) {
        let Some(index) = self.terminals.sessions.iter().position(|s| s.id == id) else { return };
        let was_focused = self.focused_terminal() == Some(id);
        let project = self.terminals.sessions[index].project;
        self.terminals.sessions.remove(index);
        if self.terminals.last_active.get(&project) == Some(&id) {
            self.terminals.last_active.remove(&project);
        }
        if let Some(next) = self.terminals.for_project(project).last().map(|s| s.id) {
            if was_focused {
                self.focus_terminal_session(next);
            }
        } else if self.selected == Some(project) {
            self.terminals.visible = false;
            if was_focused {
                self.focus_viewer();
            }
        }
    }

    /// A project is going: its terminals end with it.
    pub fn remove_terminals_for(&mut self, project: ProjectId) {
        for s in self.terminals.sessions.iter_mut().filter(|s| s.project == project) {
            s.terminate();
        }
        self.terminals.sessions.retain(|s| s.project != project);
        self.terminals.last_active.remove(&project);
    }

    /// A font family picked in Settings for terminals; None puts back the default face.
    pub fn choose_terminal_font(&mut self, family: Option<String>) {
        if family != self.settings.terminal_font {
            self.settings.terminal_font = family;
            self.settings.save();
        }
    }

    pub fn change_terminal_font_size(&mut self, delta: f32) {
        let (lo, hi) = super::settings::TERMINAL_FONT_RANGE;
        let size = (self.settings.terminal_font_size + delta).clamp(lo, hi);
        if size != self.settings.terminal_font_size {
            self.settings.terminal_font_size = size;
            self.settings.save();
        }
    }

    /// News from the shells: output to show, titles, bells, clipboard requests, exits.
    pub fn drain_terminal_events(&mut self) {
        let focused = self.focused_terminal();
        while let Ok((id, event)) = self.terminals.rx.try_recv() {
            match event {
                TermEvent::Title(title) => {
                    if let Some(s) = self.terminals.session_mut(id) {
                        s.title = title;
                    }
                }
                TermEvent::ResetTitle => {
                    if let Some(s) = self.terminals.session_mut(id) {
                        s.title.clear();
                    }
                }
                TermEvent::Bell => {
                    let looked_at = focused == Some(id) && self.window_active;
                    if !looked_at {
                        if let Some(s) = self.terminals.session_mut(id) {
                            s.needs_attention = true;
                        }
                        // A bell is how a coding agent says "your turn": nudge the taskbar when DiffCode is behind.
                        if !self.window_active {
                            self.requests.push(PlatformRequest::Attention);
                        }
                    }
                }
                // A program put text on the clipboard (OSC 52): how an agent's "copy" works.
                TermEvent::ClipboardStore(_, text) => self.requests.push(PlatformRequest::Copy(text)),
                TermEvent::PtyWrite(text) => {
                    if let Some(s) = self.terminals.session(id) {
                        s.write(text.into_bytes());
                    }
                }
                TermEvent::ColorRequest(index, format) => {
                    let palette = crate::terminal::Palette::new(self.is_dark());
                    if let Some(s) = self.terminals.session(id) {
                        s.write(format(palette.rgb(index)).into_bytes());
                    }
                }
                TermEvent::TextAreaSizeRequest(format) => {
                    if let Some(s) = self.terminals.session(id) {
                        let (columns, lines) = s.grid;
                        let size = alacritty_terminal::event::WindowSize { num_lines: lines as u16, num_cols: columns as u16, cell_width: 8, cell_height: 16 };
                        s.write(format(size).into_bytes());
                    }
                }
                TermEvent::ChildExit(status) => {
                    let close = self.terminals.session_mut(id).is_some_and(|s| s.exited(status.success()));
                    if close {
                        self.terminal_ended(id);
                    }
                }
                TermEvent::Exit => {
                    let close = self.terminals.session_mut(id).is_some_and(|s| s.exited(true));
                    if close {
                        self.terminal_ended(id);
                    }
                }
                TermEvent::ClipboardLoad(..) | TermEvent::MouseCursorDirty | TermEvent::CursorBlinkingChange | TermEvent::Wakeup => {}
            }
        }
        // Focus in and out, for programs that asked to know.
        if focused != self.terminals.had_focus {
            for (id, report) in [(self.terminals.had_focus, b"\x1b[O"), (focused, b"\x1b[I")] {
                if let Some(s) = id.and_then(|id| self.terminals.session(id)) {
                    if s.mode().contains(crate::terminal::TermMode::FOCUS_IN_OUT) {
                        s.write(report.to_vec());
                    }
                }
            }
            if let Some(s) = focused.and_then(|id| self.terminals.session_mut(id)) {
                s.needs_attention = false;
                let (project, id) = (s.project, s.id);
                self.terminals.last_active.insert(project, id);
            }
            self.terminals.had_focus = focused;
        }
    }

    /// Which program each visible terminal is running, checked only while one of the current project's is on screen.
    pub fn poll_terminals(&mut self, platform: &mut dyn Platform) {
        let Some(project) = self.selected else { return };
        if !self.terminals.visible || !self.terminals.has_sessions(project) {
            self.terminals.next_poll = None;
            return;
        }
        let now = Instant::now();
        if self.terminals.next_poll.is_some_and(|t| t > now) {
            return;
        }
        self.terminals.next_poll = Some(now + POLL);
        for s in self.terminals.sessions.iter_mut().filter(|s| s.project == project && !s.has_ended) {
            let Some(pid) = s.pid else { continue };
            match platform.foreground_process(pid) {
                Some(name) => {
                    s.is_busy = true;
                    s.process_name = name;
                }
                None => {
                    s.is_busy = false;
                    s.process_name = s.shell.name();
                }
            }
        }
    }

    /// When the next check of the running programs is due.
    pub fn terminal_deadline(&self) -> Option<Instant> {
        self.terminals.next_poll
    }

    /// The quit question for terminals still running programs. None when there are none.
    pub fn busy_terminals_question(&self, restarting: bool) -> Option<DialogRequest> {
        let busy = self.terminals.busy();
        if busy.is_empty() {
            return None;
        }
        let items: Vec<DialogItem> = busy
            .iter()
            .map(|s| DialogItem {
                title: s.process_name.clone(),
                detail: self.project(s.project).map(|p| p.name.clone()).unwrap_or_else(|| s.directory.display().to_string()),
                icon: Some(Icon::WindowConsole),
                ..Default::default()
            })
            .collect();
        let n = busy.len();
        let title = match (restarting, n == 1) {
            (false, true) => l("Quit DiffCode? A terminal is still running a program.", "退出 DiffCode？还有一个终端正在运行程序。"),
            (false, false) => crate::core::lf!("Quit DiffCode? {n} terminals are still running programs.", "退出 DiffCode？还有 {n} 个终端正在运行程序。"),
            (true, true) => l("Restart DiffCode? A terminal is still running a program.", "重启 DiffCode？还有一个终端正在运行程序。"),
            (true, false) => crate::core::lf!("Restart DiffCode? {n} terminals are still running programs.", "重启 DiffCode？还有 {n} 个终端正在运行程序。"),
        };
        let mut request = DialogRequest::new(DialogStyle::Caution, Icon::Warning, title, if restarting { l("Restart", "重启") } else { l("Quit", "退出") })
            .message(if restarting { l("Restarting terminates them.", "重启会终止它们。") } else { l("Quitting terminates them.", "退出会终止它们。") });
        request.items = items;
        Some(request)
    }
}
