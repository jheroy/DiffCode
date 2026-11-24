//! The popup layer: dims the window and floats the active popup near the top (Search Everywhere, Find in Files, Go
//! to Line, the keymap, the settings); dialogs and the Git graph have their own look.

use super::components::{self, ViewState};
use super::{dialog, git_graph};
use crate::app::commands::{commands, Group};
use crate::app::search::{QuickItem, QuickOpenMode};
use crate::app::settings::{Appearance, Language};
use crate::app::{ids, App, MenuItem, Popup};
use crate::core::history::RefKind;
use crate::core::lang::l;
use crate::core::lf;
use crate::core::util::{file_name, relative_text};
use crate::geom::{Color, Point, Rect, Size};
use crate::icons::Icon;
use crate::input::{Key, Modifiers};
use crate::paint::{ColorRun, Overflow, TextRequest, TextStyle, Weight};
use crate::platform::Platform;
use crate::text_field::{FieldOutcome, TextField};
use crate::ui::{layer, Align, Id, Ui};
use crate::widgets::{icon_button, scroll_area};

pub fn popups(app: &mut App, vs: &mut ViewState, ui: &mut Ui, platform: &mut dyn Platform) {
    let Some(popup) = app.popup else { return };
    match popup {
        Popup::GitGraph => git_graph::git_graph(app, vs, ui, platform),
        Popup::Dialog => dialog::dialog(app, vs, ui, platform),
        _ => {
            let t = ui.theme;
            ui.with_layer(layer::POPUP, |ui| {
                let bounds = ui.bounds();
                ui.fill(bounds, Color::BLACK.alpha(0.22));
                let back = ui.block(Id::new("popup-back"), bounds);
                if back.pressed {
                    app.dismiss_popup(true);
                    return;
                }
                let width = match popup {
                    Popup::QuickOpen => 660.0,
                    Popup::FindInPath => 900.0,
                    Popup::GoToLine => 320.0,
                    Popup::Keymap => 720.0,
                    _ => 460.0,
                };
                let w = t.s(width).min(bounds.w - 48.0);
                let top = if popup == Popup::FindInPath { 56.0 } else { 90.0 };
                let room = Rect::new((bounds.w - w) / 2.0, top, w, (bounds.h - top - 24.0).max(100.0));
                match popup {
                    Popup::QuickOpen => quick_open(app, ui, platform, room),
                    Popup::FindInPath => find_in_path(app, ui, platform, room),
                    Popup::GoToLine => go_to_line(app, ui, platform, room),
                    Popup::Keymap => keymap(app, vs, ui, platform, room),
                    Popup::Settings => settings(app, ui, platform, room),
                    _ => {}
                }
            });
        }
    }
}

/// The panel of a popup: drawn and made to take the mouse.
fn panel(ui: &mut Ui, rect: Rect) {
    let t = ui.theme;
    components::popup_panel(ui, rect, t.s(14.0));
    ui.block(Id::new("popup-panel"), rect);
}

/// A key cap and what it does, in a popup's footer. Returns the x after it.
fn hint(ui: &mut Ui, x: f32, cy: f32, keys: &str, text: &str) -> f32 {
    let t = ui.theme;
    let caps = components::key_caps(ui, x, cy, keys, 10.0);
    let font = t.font(11.0);
    let w = ui.text_width(text, font).ceil();
    ui.label_with(Rect::new(caps.right() + t.s(4.0), cy - t.s(8.0), w + 1.0, t.s(16.0)), text, font, t.text3, Align::Left, Overflow::Clip);
    caps.right() + t.s(4.0) + w + t.s(14.0)
}

/// A small tab in a popup's header (All / Files / Actions). Returns (clicked, width).
fn scope_tab(ui: &mut Ui, id: Id, x: f32, cy: f32, title: &str, selected: bool) -> (bool, f32) {
    let t = ui.theme;
    let font = t.font_w(11.5, if selected { Weight::Semibold } else { Weight::Regular });
    let w = ui.text_width(title, font).ceil() + t.s(16.0);
    let r = Rect::new(x, cy - t.s(11.0), w, t.s(22.0));
    let hit = ui.interact(id, r);
    if selected {
        ui.round(r, t.s(5.0), t.chip);
    } else if hit.hovered {
        ui.round(r, t.s(5.0), t.hover);
    }
    ui.label_with(r, title, font, if selected { t.text } else { t.text2 }, Align::Center, Overflow::Clip);
    (hit.clicked, w)
}

fn scope_tab_width(ui: &mut Ui, title: &str, selected: bool) -> f32 {
    let t = ui.theme;
    ui.text_width(title, t.font_w(11.5, if selected { Weight::Semibold } else { Weight::Regular })).ceil() + t.s(16.0)
}

/// The query field of a popup, borderless in its header.
fn header_field(ui: &mut Ui, platform: &mut dyn Platform, field: &mut TextField, rect: Rect, placeholder: &str, size: f32) -> FieldOutcome {
    let t = ui.theme;
    let id = ids::popup_field();
    if !ui.has_focus(id) && ui.st.focus.is_none() {
        ui.focus(id);
    }
    let outcome = components::field_input(ui, platform, id, field);
    let focused = ui.has_focus(id);
    let r = ui.interact(id, rect);
    if r.hovered {
        ui.set_cursor(crate::paint::CursorIcon::Text);
    }
    field.draw_text(ui, id, rect, placeholder, t.font(size), focused, &r);
    outcome
}

// MARK: - Search Everywhere / Go to File

fn quick_open(app: &mut App, ui: &mut Ui, platform: &mut dyn Platform, room: Rect) {
    let t = ui.theme;
    let header_h = t.s(52.0);
    let footer_h = t.s(30.0);
    let row_h = t.s(30.0);
    let pad = t.s(6.0);
    let n = app.quick_open.items.len();
    let list_h = if n == 0 { t.s(76.0) } else { (n as f32 * row_h + pad * 2.0).min(t.s(440.0)) };
    let h = (header_h + 1.0 + list_h + 1.0 + footer_h).min(room.h);
    let rect = Rect::new(room.x, room.y, room.w, h).snapped(ui.painter.scale());
    panel(ui, rect);
    let scope = app.quick_open.scope;

    // Keys the field leaves to the list: moving, opening, switching tabs.
    if ui.has_focus(ids::popup_field()) {
        if let Some((key, mods)) = ui.key() {
            let handled = match key {
                Key::Down if mods.none() => {
                    app.move_quick_selection(1);
                    true
                }
                Key::Up if mods.none() => {
                    app.move_quick_selection(-1);
                    true
                }
                Key::PageDown if mods.none() => {
                    app.move_quick_selection(10);
                    true
                }
                Key::PageUp if mods.none() => {
                    app.move_quick_selection(-10);
                    true
                }
                Key::Tab => {
                    app.cycle_quick_open_scope(if mods.shift { -1 } else { 1 });
                    true
                }
                _ => false,
            };
            if handled {
                ui.consume();
            }
        }
    }

    // The header: magnifier, field, spinner, scope tabs.
    let header = Rect::new(rect.x, rect.y, rect.w, header_h);
    let cy = header.center().y;
    let icon = t.s(16.0);
    ui.icon(Icon::Search, Rect::new(header.x + t.s(16.0), cy - icon / 2.0, icon, icon), t.text2);
    let mut right = header.right() - t.s(16.0);
    if matches!(scope, QuickOpenMode::All | QuickOpenMode::Files | QuickOpenMode::Actions) {
        let tabs = [(QuickOpenMode::All, l("All", "全部")), (QuickOpenMode::Files, l("Files", "文件")), (QuickOpenMode::Actions, l("Actions", "操作"))];
        let total: f32 = tabs.iter().map(|(s, title)| scope_tab_width(ui, title, *s == scope)).sum::<f32>() + t.s(2.0) * 2.0;
        let mut x = right - total;
        right = x - t.s(10.0);
        for (s, title) in tabs {
            let (clicked, w) = scope_tab(ui, Id::new("scope").with(title.as_str()), x, cy, &title, s == scope);
            if clicked {
                app.set_quick_open_scope(s);
                app.focus_request = Some(ids::popup_field());
            }
            x += w + t.s(2.0);
        }
    }
    if app.quick_open.is_indexing {
        components::spinner(ui, crate::geom::Point::new(right - t.s(8.0), cy), t.s(6.0), t.text3);
        right -= t.s(24.0);
    }
    let placeholder = match scope {
        QuickOpenMode::All => l("Search files and actions", "搜索文件和操作"),
        QuickOpenMode::Files => l("Go to file — try abbreviations like \"mavm\"", "查找文件 — 支持缩写，例如 mavm"),
        QuickOpenMode::Actions => l("Find an action", "查找操作"),
        QuickOpenMode::Recent => l("Recent files", "最近的文件"),
        QuickOpenMode::Branches => l("Compare the working tree with a branch, tag or commit", "将工作区与分支、标签或提交比较"),
        QuickOpenMode::Stashes => l("Stashes", "Stash 列表"),
    };
    let fx = header.x + t.s(16.0) + icon + t.s(10.0);
    let field_rect = Rect::new(fx, cy - t.s(12.0), (right - fx).max(t.s(60.0)), t.s(24.0));
    let outcome = header_field(ui, platform, &mut app.quick_open.field, field_rect, &placeholder, 16.0);
    match outcome {
        FieldOutcome::Changed => app.update_quick_open(),
        FieldOutcome::Submit => {
            app.activate_quick_item(None);
            return;
        }
        FieldOutcome::Cancel => {
            app.dismiss_popup(true);
            return;
        }
        _ => {}
    }
    ui.hline(rect.x, header.bottom(), rect.w, t.hairline);

    // The list.
    let list = Rect::new(rect.x, header.bottom() + 1.0, rect.w, h - header_h - footer_h - 2.0);
    if n == 0 {
        let text = match scope {
            QuickOpenMode::Branches if app.quick_open.is_indexing => l("Reading branches…", "正在读取分支…"),
            QuickOpenMode::Branches => l("No branches · type a commit hash", "没有分支 · 可输入提交哈希"),
            QuickOpenMode::Stashes if app.quick_open.is_indexing => l("Reading stashes…", "正在读取 stash…"),
            QuickOpenMode::Stashes if app.quick_open.field.text.is_empty() => l("No stashes", "没有 stash"),
            _ if app.quick_open.is_indexing => l("Indexing files…", "正在索引文件…"),
            _ if app.quick_open.field.text.is_empty() => l("Type to search", "输入以搜索"),
            _ => l("Nothing found", "没有找到"),
        };
        ui.label_with(list, &text, t.font(12.5), t.text3, Align::Center, Overflow::Ellipsis);
    } else {
        let content = n as f32 * row_h + pad * 2.0;
        let q = &mut app.quick_open;
        if std::mem::take(&mut q.reveal) {
            q.scroll.reveal(pad + q.selected as f32 * row_h - pad, row_h + pad * 2.0, list.h);
        }
        scroll_area(ui, Id::new("quick-scroll"), list, content, &mut q.scroll);
        let offset = q.scroll.offset;
        let selected = q.selected;
        let items = q.items.clone();
        let current = app.selected;
        let mut activate = None;
        ui.clipped(list, |ui| {
            let first = ((offset - pad) / row_h).floor().max(0.0) as usize;
            let last = (((offset + list.h - pad) / row_h).ceil().max(0.0) as usize).min(n);
            for (i, item) in items.iter().enumerate().take(last).skip(first) {
                let row = Rect::new(list.x, list.y + pad + i as f32 * row_h - offset, list.w, row_h);
                let r = ui.interact(Id::new("quick-row").with(i), row);
                if i == selected {
                    ui.round(row.inset_xy(t.s(6.0), 0.0), t.s(7.0), t.selection);
                } else if r.hovered {
                    ui.round(row.inset_xy(t.s(6.0), 0.0), t.s(7.0), t.hover.alpha(0.6));
                }
                quick_row(app, ui, item, row.inset_xy(t.s(12.0), 0.0), current);
                if r.clicked {
                    activate = Some(i);
                }
            }
        });
        if let Some(i) = activate {
            app.activate_quick_item(Some(i));
            return;
        }
    }

    // The footer.
    let footer = Rect::new(rect.x, rect.bottom() - footer_h, rect.w, footer_h);
    ui.hline(rect.x, footer.y - 1.0, rect.w, t.hairline);
    let fcy = footer.center().y;
    let mut x = footer.x + t.s(14.0);
    x = hint(ui, x, fcy, "↑↓", &l("Navigate", "选择"));
    let tip = match scope {
        QuickOpenMode::Branches => {
            x = hint(ui, x, fcy, "Enter", &l("Compare", "比较"));
            l("Branches compare from where they forked from HEAD · or type a commit", "分支从与 HEAD 的分叉点开始比较 · 也可输入提交哈希")
        }
        QuickOpenMode::Stashes => {
            x = hint(ui, x, fcy, "Enter", &l("View", "查看"));
            l("Apply, pop or drop it from the bar over the list", "在列表上方的横条里应用、弹出或删除")
        }
        _ => {
            x = hint(ui, x, fcy, "Enter", &l("Open", "打开"));
            x = hint(ui, x, fcy, "Tab", &l("Switch tab", "切换标签"));
            l("Tip: add :42 to jump to a line", "提示：末尾加 :42 可直接跳到该行")
        }
    };
    let tw = (footer.right() - t.s(14.0) - x).max(0.0);
    ui.label_with(Rect::new(x, footer.y, tw, footer.h), &tip, t.font(11.0), t.text3, Align::Right, Overflow::Ellipsis);
}

fn quick_row(app: &App, ui: &mut Ui, item: &QuickItem, rect: Rect, current: Option<crate::app::project::ProjectId>) {
    let t = ui.theme;
    let cy = rect.center().y;
    let gap = t.s(9.0);
    let slot = t.s(18.0);
    let small_icon = |ui: &mut Ui, icon: Icon, color: Color| {
        let s = t.s(14.0);
        ui.icon(icon, Rect::new(rect.x + (slot - s) / 2.0, cy - s / 2.0, s, s), color);
    };
    let mut right = rect.right();
    match item {
        QuickItem::File { project, path, positions, kind } => {
            components::file_icon(ui, Rect::new(rect.x, rect.y, slot, rect.h), path, 13.0);
            if let Some(k) = kind {
                let w = t.s(12.0);
                ui.label_with(Rect::new(right - w, rect.y, w, rect.h), k.letter(), t.font_w(10.5, Weight::Bold), t.status(Some(*k)), Align::Center, Overflow::Clip);
                right -= w + t.s(6.0);
            }
            if Some(*project) != current {
                if let Some(owner) = app.project(*project) {
                    let w = ui.text_width(&owner.name, t.font(10.5)).ceil().min(t.s(140.0));
                    ui.label_with(Rect::new(right - w, rect.y, w + 1.0, rect.h), &owner.name, t.font(10.5), t.text3, Align::Left, Overflow::Ellipsis);
                    right -= w + t.s(6.0);
                }
            }
            let name = file_name(path);
            let x = rect.x + slot + gap;
            let font = t.font(13.0);
            let nw = ui.text_width(name, font).ceil().min((right - x).max(0.0));
            components::fuzzy_label(ui, Rect::new(x, rect.y, nw + 1.0, rect.h), name, positions, path.len() - name.len(), t.status(*kind), font, Overflow::EllipsisMiddle);
            let directory = path.rfind('/').map(|i| &path[..i]).unwrap_or("");
            let dx = x + nw + gap;
            if !directory.is_empty() && right - dx > t.s(20.0) {
                components::fuzzy_label(ui, Rect::new(dx, rect.y, right - dx - t.s(6.0), rect.h), directory, positions, 0, t.text3, t.font(11.5), Overflow::EllipsisMiddle);
            }
        }
        QuickItem::Action { title, shortcut, icon, .. } => {
            small_icon(ui, *icon, t.text2);
            if !shortcut.is_empty() {
                let w = components::key_caps_width(ui, shortcut, 11.0);
                components::key_caps(ui, right - w, cy, shortcut, 11.0);
                right -= w + t.s(6.0);
            }
            let x = rect.x + slot + gap;
            ui.label(Rect::new(x, rect.y, (right - x).max(0.0), rect.h), title, t.font(13.0), t.text);
        }
        QuickItem::Ref { r, positions } => {
            let icon = match r.kind {
                RefKind::Tag => Icon::Tag,
                RefKind::Remote => Icon::Cloud,
                RefKind::Local => Icon::Branch,
            };
            small_icon(ui, icon, t.text2);
            let date = relative_text(r.date);
            let dw = ui.text_width(&date, t.font(11.0)).ceil();
            ui.label_with(Rect::new(right - dw, rect.y, dw + 1.0, rect.h), &date, t.font(11.0), t.text3, Align::Left, Overflow::Clip);
            right -= dw + t.s(6.0);
            let x = rect.x + slot + gap;
            let font = t.font(13.0);
            let current_label = l("current", "当前");
            let cw = if r.is_head { ui.text_width(&current_label, t.font_w(10.5, Weight::Semibold)).ceil() + gap } else { 0.0 };
            let nw = ui.text_width(&r.short_name, font).ceil().min((right - x - cw).max(0.0));
            components::fuzzy_label(ui, Rect::new(x, rect.y, nw + 1.0, rect.h), &r.short_name, positions, 0, t.text, font, Overflow::EllipsisMiddle);
            if r.is_head {
                ui.label(Rect::new(x + nw + gap, rect.y, cw, rect.h), &current_label, t.font_w(10.5, Weight::Semibold), t.added);
            }
        }
        QuickItem::Revision(text) => {
            small_icon(ui, Icon::Code, t.text2);
            let x = rect.x + slot + gap;
            ui.label(Rect::new(x, rect.y, (right - x).max(0.0), rect.h), &lf!("Compare with commit “{text}”", "与提交“{text}”比较"), t.font(13.0), t.text);
        }
        QuickItem::Stash { entry, positions } => {
            small_icon(ui, Icon::Archive, t.text2);
            let date = relative_text(entry.date);
            let dw = ui.text_width(&date, t.font(11.0)).ceil();
            ui.label_with(Rect::new(right - dw, rect.y, dw + 1.0, rect.h), &date, t.font(11.0), t.text3, Align::Left, Overflow::Clip);
            right -= dw + t.s(6.0);
            let x = rect.x + slot + gap;
            let font = t.font(13.0);
            let title = entry.title();
            let nw = ui.text_width(title, font).ceil().min((right - x).max(0.0));
            components::fuzzy_label(ui, Rect::new(x, rect.y, nw + 1.0, rect.h), title, positions, 0, t.text, font, Overflow::Ellipsis);
            let mut parts = Vec::new();
            if let Some(b) = entry.branch() {
                parts.push(lf!("on {b}", "在 {b}"));
            }
            if entry.untracked.is_some() {
                parts.push(l("with new files", "含新文件"));
            }
            let dx = x + nw + gap;
            if !parts.is_empty() && right - dx > t.s(20.0) {
                ui.label(Rect::new(dx, rect.y, right - dx - t.s(6.0), rect.h), &parts.join(" · "), t.font(11.5), t.text3);
            }
        }
        QuickItem::StashChanges { count } => {
            small_icon(ui, Icon::ArrowDownload, t.accent);
            let x = rect.x + slot + gap;
            let title = l("Stash Local Changes…", "Stash 本地改动…");
            let font = t.font(13.0);
            let w = ui.text_width(&title, font).ceil();
            ui.label_with(Rect::new(x, rect.y, w + 1.0, rect.h), &title, font, t.text, Align::Left, Overflow::Clip);
            let files = if *count == 1 { l("1 file", "1 个文件") } else { lf!("{count} files", "{count} 个文件") };
            ui.label(Rect::new(x + w + gap, rect.y, (right - x - w - gap).max(0.0), rect.h), &files, t.font(11.5), t.text3);
        }
    }
}

// MARK: - Find in Files

fn find_in_path(app: &mut App, ui: &mut Ui, platform: &mut dyn Platform, room: Rect) {
    let t = ui.theme;
    let h = t.s(640.0).min(room.h);
    let rect = Rect::new(room.x, room.y, room.w, h).snapped(ui.painter.scale());
    panel(ui, rect);
    let row_h = t.s(24.0);
    let pad = t.s(4.0);

    if ui.has_focus(ids::popup_field()) || ui.has_focus(Id::new("find-mask")) {
        if let Some((key, mods)) = ui.key() {
            let delta = match key {
                Key::Down if mods.none() => Some(1),
                Key::Up if mods.none() => Some(-1),
                Key::PageDown if mods.none() => Some(10),
                Key::PageUp if mods.none() => Some(-10),
                _ => None,
            };
            if let Some(d) = delta {
                ui.consume();
                app.move_find_selection(d);
            }
        }
    }

    // The query and the options.
    let header = Rect::new(rect.x, rect.y, rect.w, t.s(52.0));
    let cy = header.center().y;
    let icon = t.s(16.0);
    ui.icon(Icon::Search, Rect::new(header.x + t.s(16.0), cy - icon / 2.0, icon, icon), t.text2);
    let options = [
        ("Aa", l("Match case", "区分大小写"), app.find_in_path.options.case_sensitive),
        ("W", l("Whole words", "全词匹配"), app.find_in_path.options.whole_word),
        (".*", l("Regular expression", "正则表达式"), app.find_in_path.options.regex),
    ];
    let ow = t.s(28.0);
    let mut x = header.right() - t.s(16.0) - (ow * 3.0 + t.s(10.0) * 2.0);
    let options_x = x;
    for (i, (label, tip, on)) in options.iter().enumerate() {
        let b = Rect::new(x, cy - t.s(12.0), ow, t.s(24.0));
        let r = ui.interact(Id::new("find-option").with(i), b);
        ui.round(b, t.s(6.0), if *on { t.selection } else if r.hovered { t.hover.over(t.chip) } else { t.chip });
        ui.label_with(b, label, t.mono(12.0).weight(Weight::Semibold), if *on { t.accent } else { t.text2 }, Align::Center, Overflow::Clip);
        ui.tooltip(&r, tip);
        if r.clicked {
            let o = &mut app.find_in_path.options;
            match i {
                0 => o.case_sensitive = !o.case_sensitive,
                1 => o.whole_word = !o.whole_word,
                _ => o.regex = !o.regex,
            }
            app.search_in_files();
            app.focus_request = Some(ids::popup_field());
        }
        x += ow + t.s(10.0);
    }
    let fx = header.x + t.s(16.0) + icon + t.s(10.0);
    let field_rect = Rect::new(fx, cy - t.s(12.0), (options_x - t.s(10.0) - fx).max(t.s(60.0)), t.s(24.0));
    match header_field(ui, platform, &mut app.find_in_path.field, field_rect, &l("Find in files", "在文件中查找"), 16.0) {
        FieldOutcome::Changed => app.find_in_path_changed(),
        FieldOutcome::Submit => {
            app.activate_find_hit();
            return;
        }
        FieldOutcome::Cancel => {
            app.dismiss_popup(true);
            return;
        }
        _ => {}
    }

    // The file mask, the scope and the count.
    let bar = Rect::new(rect.x + t.s(16.0), header.bottom(), rect.w - t.s(32.0), t.s(24.0));
    let mask = Rect::new(bar.x, bar.y, t.s(190.0), bar.h);
    ui.round(mask, t.s(6.0), t.chip);
    let mi = t.s(12.0);
    ui.icon(Icon::Document, Rect::new(mask.x + t.s(8.0), mask.center().y - mi / 2.0, mi, mi), t.text3);
    let mask_id = Id::new("find-mask");
    let outcome = components::field_input(ui, platform, mask_id, &mut app.find_in_path.mask);
    let inner = mask.inset_by(t.s(8.0) + mi + t.s(5.0), 0.0, t.s(8.0), 0.0);
    let focused = ui.has_focus(mask_id);
    let r = ui.interact(mask_id, inner);
    app.find_in_path.mask.draw_text(ui, mask_id, inner, &l("File mask, e.g. *.kt", "文件过滤，例如 *.kt"), t.font(12.0), focused, &r);
    match outcome {
        FieldOutcome::Submit | FieldOutcome::Changed => app.find_in_path_changed(),
        FieldOutcome::Cancel => {
            app.dismiss_popup(true);
            return;
        }
        _ => {}
    }
    let mut x = mask.right() + t.s(10.0);
    if app.projects.len() > 1 {
        let all = app.find_in_path.all_projects;
        let (a, w) = scope_tab(ui, Id::new("find-this"), x, bar.center().y, &l("This Project", "当前项目"), !all);
        x += w + t.s(2.0);
        let (b, _) = scope_tab(ui, Id::new("find-all"), x, bar.center().y, &l("All Projects", "所有项目"), all);
        if a || b {
            app.find_in_path.all_projects = b;
            app.search_in_files();
            app.focus_request = Some(ids::popup_field());
        }
    }
    let f = &app.find_in_path;
    let summary = if let Some(e) = &f.error {
        e.clone()
    } else if f.hits.is_empty() {
        String::new()
    } else {
        let count = if f.truncated { format!("{}+", f.hits.len()) } else { f.hits.len().to_string() };
        let files = f.file_count;
        match (f.hits.len() == 1 && !f.truncated, files == 1) {
            (true, _) => l("1 match in 1 file", "1 个文件中有 1 处匹配"),
            (false, true) => lf!("{count} matches in 1 file", "1 个文件中有 {count} 处匹配"),
            (false, false) => lf!("{count} matches in {files} files", "{files} 个文件中有 {count} 处匹配"),
        }
    };
    let sw = ui.text_width(&summary, t.font(11.5)).ceil();
    ui.label_with(Rect::new(bar.right() - sw, bar.y, sw + 1.0, bar.h), &summary, t.font(11.5), if f.error.is_some() { t.removed } else { t.text3 }, Align::Left, Overflow::Clip);
    if f.is_searching {
        components::spinner(ui, crate::geom::Point::new(bar.right() - sw - t.s(14.0), bar.center().y), t.s(6.0), t.text3);
    }

    // The hits.
    let list_top = bar.bottom() + t.s(10.0);
    ui.hline(rect.x, list_top, rect.w, t.hairline);
    let list = Rect::new(rect.x, list_top + 1.0, rect.w, t.s(236.0).min(rect.h * 0.4));
    let n = app.find_in_path.hits.len();
    let content = n as f32 * row_h + pad * 2.0;
    {
        let f = &mut app.find_in_path;
        if std::mem::take(&mut f.reveal) {
            f.scroll.reveal(f.selected as f32 * row_h, row_h + pad * 2.0, list.h);
        }
        scroll_area(ui, Id::new("find-scroll"), list, content, &mut f.scroll);
    }
    let offset = app.find_in_path.scroll.offset;
    let selected = app.find_in_path.selected;
    let all_projects = app.find_in_path.all_projects && app.projects.len() > 1;
    let mut pick = None;
    let mut open = false;
    ui.clipped(list, |ui| {
        let first = ((offset - pad) / row_h).floor().max(0.0) as usize;
        let last = (((offset + list.h - pad) / row_h).ceil().max(0.0) as usize).min(n);
        for i in first..last {
            let hit = &app.find_in_path.hits[i];
            let row = Rect::new(list.x, list.y + pad + i as f32 * row_h - offset, list.w, row_h);
            let r = ui.interact(Id::new("find-row").with(i), row);
            if i == selected {
                ui.round(row.inset_xy(t.s(6.0), 0.0), t.s(6.0), t.selection);
            } else if r.hovered {
                ui.round(row.inset_xy(t.s(6.0), 0.0), t.s(6.0), t.hover.alpha(0.6));
            }
            let inner = row.inset_xy(t.s(14.0), 0.0);
            let mut right = inner.right();
            let line = hit.line.to_string();
            let lw = t.s(34.0).max(ui.text_width(&line, t.mono(11.0)).ceil());
            ui.label_with(Rect::new(right - lw, row.y, lw, row.h), &line, t.mono(11.0), t.text3, Align::Right, Overflow::Clip);
            right -= lw + t.s(10.0);
            let path = hit.path.as_str();
            let path_w = ui.text_width(path, t.font(11.5)).ceil().min(t.s(280.0));
            ui.label_with(Rect::new(right - path_w, row.y, path_w + 1.0, row.h), path, t.font(11.5), t.text2, Align::Right, Overflow::EllipsisMiddle);
            right -= path_w + t.s(10.0);
            if all_projects {
                if let Some(p) = app.project(hit.project) {
                    let pw = ui.text_width(&p.name, t.font(10.5)).ceil().min(t.s(120.0));
                    ui.label_with(Rect::new(right - pw, row.y, pw + 1.0, row.h), &p.name, t.font(10.5), t.text3, Align::Left, Overflow::Ellipsis);
                    right -= pw + t.s(10.0);
                }
            }
            snippet(ui, Rect::new(inner.x, row.y, (right - inner.x).max(0.0), row.h), &hit.text, hit.found.clone());
            ui.tooltip(&r, &hit.path);
            if r.pressed {
                pick = Some(i);
                open = r.double_clicked;
            }
        }
    });
    if let Some(i) = pick {
        app.select_find_hit(i);
        app.focus_request = Some(ids::popup_field());
        if open {
            app.activate_find_hit();
            return;
        }
    }

    // The preview.
    let path_bar = Rect::new(rect.x, list.bottom(), rect.w, t.s(26.0));
    ui.hline(rect.x, path_bar.y, rect.w, t.hairline);
    ui.fill(path_bar.inset_by(1.0, 1.0, 1.0, 0.0), t.panel.alpha(0.6));
    if !app.find_in_path.preview_path.is_empty() {
        let path = app.find_in_path.preview_path.clone();
        components::file_icon(ui, Rect::new(path_bar.x + t.s(12.0), path_bar.y, t.s(14.0), path_bar.h), &path, 11.0);
        ui.label_with(
            Rect::new(path_bar.x + t.s(32.0), path_bar.y, path_bar.w - t.s(44.0), path_bar.h),
            &path,
            t.font(11.5),
            t.text2,
            Align::Left,
            Overflow::EllipsisMiddle,
        );
    }
    let footer_h = t.s(30.0);
    let preview = Rect::new(rect.x + 1.0, path_bar.bottom(), rect.w - 2.0, rect.bottom() - footer_h - 1.0 - path_bar.bottom());
    if app.find_in_path.preview.document().is_some() && preview.h > 10.0 {
        let actions = app.find_in_path.preview.show(ui, Id::new("find-preview"), preview, false);
        let _ = actions;
    } else {
        ui.fill(preview, t.window);
        let text = if app.find_in_path.field.text.chars().count() < 2 {
            l("Type at least two characters", "至少输入两个字符")
        } else if app.find_in_path.is_searching {
            String::new()
        } else {
            l("No matches", "没有匹配项")
        };
        ui.label_with(preview, &text, t.font(12.5), t.text3, Align::Center, Overflow::Ellipsis);
    }
    let footer = Rect::new(rect.x, rect.bottom() - footer_h, rect.w, footer_h);
    ui.hline(rect.x, footer.y - 1.0, rect.w, t.hairline);
    let fcy = footer.center().y;
    let mut x = footer.x + t.s(14.0);
    x = hint(ui, x, fcy, "↑↓", &l("Navigate", "选择"));
    x = hint(ui, x, fcy, "Enter", &l("Open in viewer", "在查看器中打开"));
    hint(ui, x, fcy, "Esc", &l("Close", "关闭"));
}

/// One hit's line: the match highlighted, what comes before it trimmed so it shows.
fn snippet(ui: &mut Ui, rect: Rect, text: &str, found: Option<std::ops::Range<usize>>) {
    let t = ui.theme;
    let font = t.code_font().size(12.0 * t.scale);
    let text: String = text.chars().take(400).collect();
    let mut runs = vec![ColorRun { range: 0..text.len() as u32, color: t.text2 }];
    if let Some(f) = found.filter(|f| f.end <= text.len() && text.is_char_boundary(f.start) && text.is_char_boundary(f.end)) {
        runs.push(ColorRun { range: f.start as u32..f.end as u32, color: t.text });
        // The match's own background.
        let mut style = TextStyle::new(font);
        style.max_width = Some(rect.w.max(1.0));
        style.overflow = Overflow::Ellipsis;
        let layout = ui.layout(TextRequest { text: std::sync::Arc::from(text.as_str()), style, runs: runs.clone(), bold_ranges: Vec::new() });
        let y = rect.y + ((rect.h - layout.size().h) / 2.0).round();
        for r in layout.range_rects(f.clone()) {
            ui.round(Rect::new(rect.x + r.x, y + r.y, r.w, r.h), t.s(2.0), Color::hexa(0xE8B339, 0.38));
        }
        ui.draw_layout(&layout, rect, t.text2, Align::Left);
        return;
    }
    ui.label_runs(rect, &text, font, t.text2, runs);
}

// MARK: - Go to Line

fn go_to_line(app: &mut App, ui: &mut Ui, platform: &mut dyn Platform, room: Rect) {
    let t = ui.theme;
    let rect = Rect::new(room.x, room.y, room.w, t.s(48.0)).snapped(ui.painter.scale());
    panel(ui, rect);
    let total = app.viewer.document().map(|d| d.right.len()).unwrap_or(0);
    let cy = rect.center().y;
    let icon = t.s(15.0);
    ui.icon(Icon::ArrowRight, Rect::new(rect.x + t.s(16.0), cy - icon / 2.0, icon, icon), t.text2);
    let fx = rect.x + t.s(16.0) + icon + t.s(10.0);
    let field = Rect::new(fx, cy - t.s(11.0), rect.right() - t.s(16.0) - fx, t.s(22.0));
    match header_field(ui, platform, &mut app.go_to_line, field, &lf!("Line number (1–{total})", "行号 (1–{total})"), 15.0) {
        FieldOutcome::Submit => {
            let text = app.go_to_line.text.clone();
            let digits = text.split(':').next().unwrap_or(&text).trim().to_string();
            app.dismiss_popup(false);
            if let Ok(line) = digits.parse::<usize>() {
                app.viewer.reveal(line);
            }
            app.focus_viewer();
        }
        FieldOutcome::Cancel => app.dismiss_popup(true),
        _ => {}
    }
}

// MARK: - Keymap

fn keymap(app: &mut App, vs: &mut ViewState, ui: &mut Ui, platform: &mut dyn Platform, room: Rect) {
    let t = ui.theme;
    let h = t.s(668.0).min(room.h);
    let rect = Rect::new(room.x, room.y, room.w, h).snapped(ui.painter.scale());
    panel(ui, rect);
    let header = Rect::new(rect.x, rect.y, rect.w, t.s(48.0));
    let cy = header.center().y;
    let title = l("Keymap", "快捷键");
    let tf = t.font_w(15.0, Weight::Semibold);
    let tw = ui.text_width(&title, tf).ceil();
    ui.label_with(Rect::new(header.x + t.s(20.0), header.y, tw + 1.0, header.h), &title, tf, t.text, Align::Left, Overflow::Clip);
    let sub = l("Aligned with the IDE's Windows keymap", "与 IDE 的 Windows 键位保持一致");
    let esc_w = components::key_caps_width(ui, "Esc", 11.0);
    components::key_caps(ui, header.right() - t.s(20.0) - esc_w, cy, "Esc", 11.0);
    // A filter, for finding a key quickly.
    let fw = t.s(180.0);
    let field = Rect::new(header.right() - t.s(20.0) - esc_w - t.s(12.0) - fw, cy - t.s(13.0), fw, t.s(26.0));
    let sx = header.x + t.s(20.0) + tw + t.s(10.0);
    ui.label(Rect::new(sx, header.y, (field.x - t.s(10.0) - sx).max(0.0), header.h), &sub, t.font(11.5), t.text3);
    let id = ids::popup_field();
    if ui.st.focus.is_none() {
        ui.focus(id);
    }
    if components::search_field(ui, platform, id, field, &mut app.keymap_filter, &l("Filter", "筛选"), 12.0) == FieldOutcome::Cancel {
        app.dismiss_popup(true);
        return;
    }
    if ui.take_key(Key::Escape, Modifiers::NONE) {
        app.dismiss_popup(true);
        return;
    }
    ui.hline(rect.x, header.bottom(), rect.w, t.hairline);

    let filter = app.keymap_filter.text.trim().to_lowercase();
    let list = commands(app);
    let has_terminal = app.has_terminal();
    let rows_for = |group: Group| -> Vec<(String, String)> {
        list.iter()
            .filter(|c| c.group == group)
            .map(|c| (c.title.replace('…', ""), c.shortcut_label()))
            .filter(|(_, s)| !s.is_empty())
            .collect()
    };
    let extras = vec![
        (l("Find in File", "在文件中查找"), "Ctrl+F".to_string()),
        (l("Next / Previous Occurrence", "下一个 / 上一个匹配"), "F3 / Shift+F3".to_string()),
        (l("Top / Bottom of File", "文件开头 / 末尾"), "Ctrl+Home / Ctrl+End".to_string()),
        (l("Delete Line", "删除行"), "Ctrl+Y".to_string()),
        (l("Redo", "重做"), "Ctrl+Shift+Z".to_string()),
        (l("Back to the File List", "回到文件列表"), "Esc".to_string()),
        (l("Zoom Text", "缩放文字"), "Ctrl+Wheel".to_string()),
    ];
    let mut left: Vec<(String, Vec<(String, String)>)> = vec![(Group::Navigate.title(), rows_for(Group::Navigate))];
    if has_terminal {
        let mut rows = rows_for(Group::Terminal);
        rows.push((l("Next / Previous Terminal (when focused)", "下一个 / 上一个终端（聚焦时）"), "Alt+→ / Alt+←".to_string()));
        rows.push((l("Copy / Paste in Terminal", "终端内复制 / 粘贴"), "Ctrl+Shift+C / V".to_string()));
        left.push((Group::Terminal.title(), rows));
    }
    let right = vec![
        (Group::View.title(), rows_for(Group::View)),
        (Group::Git.title(), rows_for(Group::Git)),
        (Group::File.title(), rows_for(Group::File)),
        (l("In the viewer", "查看器内"), extras),
    ];
    let keep = |sections: Vec<(String, Vec<(String, String)>)>| -> Vec<(String, Vec<(String, String)>)> {
        sections
            .into_iter()
            .map(|(title, rows)| {
                let rows: Vec<(String, String)> = if filter.is_empty() {
                    rows
                } else {
                    rows.into_iter().filter(|(a, b)| a.to_lowercase().contains(&filter) || b.to_lowercase().contains(&filter)).collect()
                };
                (title, rows)
            })
            .filter(|(_, rows)| !rows.is_empty())
            .collect()
    };
    let left = keep(left);
    let right = keep(right);
    let row_h = t.s(25.0);
    let label_h = t.s(22.0);
    let section_gap = t.s(18.0);
    let height_of = |sections: &[(String, Vec<(String, String)>)]| -> f32 {
        sections.iter().map(|(_, rows)| label_h + rows.len() as f32 * row_h + section_gap).sum::<f32>()
    };
    let body = Rect::new(rect.x, header.bottom() + 1.0, rect.w, rect.h - header.h - 1.0);
    let pad = t.s(20.0);
    let content = height_of(&left).max(height_of(&right)) + pad * 2.0;
    let scroll = vs.scroll(Id::new("keymap-scroll"));
    scroll_area(ui, Id::new("keymap-scroll"), body, content, scroll);
    let offset = scroll.offset;
    let col_w = (body.w - pad * 2.0 - t.s(28.0)) / 2.0;
    ui.clipped(body, |ui| {
        for (c, sections) in [left, right].into_iter().enumerate() {
            let x = body.x + pad + c as f32 * (col_w + t.s(28.0));
            let mut y = body.y + pad - offset;
            for (title, rows) in sections {
                components::section_label(ui, x, y + label_h / 2.0, col_w, &title);
                y += label_h;
                for (name, keys) in rows {
                    let kw = components::key_caps_width(ui, &keys, 11.0);
                    components::key_caps(ui, x + col_w - kw, y + row_h / 2.0, &keys, 11.0);
                    ui.label(Rect::new(x, y, (col_w - kw - t.s(12.0)).max(0.0), row_h), &name, t.font(12.5), t.text2);
                    y += row_h;
                }
                y += section_gap;
            }
        }
    });
    if left_empty(&filter, content, pad) {
        ui.label_with(body, &l("No shortcut matches", "没有匹配的快捷键"), t.font(12.5), t.text3, Align::Center, Overflow::Ellipsis);
    }
}

fn left_empty(filter: &str, content: f32, pad: f32) -> bool {
    !filter.is_empty() && content <= pad * 2.0 + 0.5
}

// MARK: - Settings

fn settings(app: &mut App, ui: &mut Ui, platform: &mut dyn Platform, room: Rect) {
    let t = ui.theme;
    let restart = app.language_needs_restart();
    let updates = app.updates_supported();
    if app.font_choices.is_none() {
        app.font_choices = Some(platform.monospace_families());
    }
    let rows = if app.has_terminal() { 8.0 } else { 6.0 } + if updates { 1.0 } else { 0.0 };
    let h = t.s(48.0) + 1.0 + t.s(20.0) * 2.0 + rows * t.s(28.0) + (rows - 1.0) * t.s(16.0)
        + if restart { t.s(32.0) } else { 0.0 }
        + if updates { t.s(32.0) } else { 0.0 };
    let rect = Rect::new(room.x, room.y, room.w, h.min(room.h)).snapped(ui.painter.scale());
    panel(ui, rect);
    if ui.take_key(Key::Escape, Modifiers::NONE) {
        app.dismiss_popup(true);
        return;
    }
    let header = Rect::new(rect.x, rect.y, rect.w, t.s(48.0));
    ui.label(header.inset_xy(t.s(20.0), 0.0), &l("Settings", "设置"), t.font_w(15.0, Weight::Semibold), t.text);
    let esc_w = components::key_caps_width(ui, "Esc", 11.0);
    components::key_caps(ui, header.right() - t.s(20.0) - esc_w, header.center().y, "Esc", 11.0);
    ui.hline(rect.x, header.bottom(), rect.w, t.hairline);

    let body = Rect::new(rect.x + t.s(20.0), header.bottom() + 1.0 + t.s(20.0), rect.w - t.s(40.0), rect.h);
    let row_h = t.s(28.0);
    let mut y = body.y;
    let row = |ui: &mut Ui, y: &mut f32, title: &str| -> Rect {
        let r = Rect::new(body.x, *y, body.w, row_h);
        ui.label(Rect::new(r.x, r.y, r.w * 0.45, r.h), title, t.font(13.0), t.text2);
        *y += row_h + t.s(16.0);
        r
    };
    let control_w = t.s(240.0);

    let r = row(ui, &mut y, &l("Appearance", "外观"));
    let titles: Vec<String> = Appearance::ALL.iter().map(|a| a.title()).collect();
    let current = Appearance::ALL.iter().position(|a| *a == app.settings.appearance).unwrap_or(0);
    if let Some(i) = segmented(ui, Id::new("set-appearance"), Rect::new(r.right() - control_w, r.y, control_w, r.h), &titles, current) {
        app.settings.appearance = Appearance::ALL[i];
        app.settings.save();
    }

    let r = row(ui, &mut y, &l("Language", "语言"));
    let titles: Vec<String> = Language::ALL.iter().map(|a| a.title()).collect();
    let current = Language::ALL.iter().position(|a| *a == app.settings.language).unwrap_or(0);
    if let Some(i) = segmented(ui, Id::new("set-language"), Rect::new(r.right() - control_w, r.y, control_w, r.h), &titles, current) {
        app.settings.language = Language::ALL[i];
        app.settings.save();
    }
    if restart {
        let line = Rect::new(body.x, y - t.s(10.0), body.w, t.s(24.0));
        let button = l("Restart Now", "立即重启");
        let bf = t.font_w(11.0, Weight::Semibold);
        let bw = ui.text_width(&button, bf).ceil() + t.s(18.0);
        let b = Rect::new(line.right() - bw, line.center().y - t.s(11.0), bw, t.s(22.0));
        let hit = ui.interact(Id::new("restart"), b);
        ui.round(b, t.s(6.0), t.accent.alpha(if hit.hovered { 0.85 } else { 1.0 }));
        ui.label_with(b, &button, bf, Color::WHITE, Align::Center, Overflow::Clip);
        let note = l("Shows after DiffCode restarts", "重启 DiffCode 后生效");
        let nw = ui.text_width(&note, t.font(11.5)).ceil();
        ui.label_with(Rect::new(b.x - t.s(8.0) - nw, line.y, nw + 1.0, line.h), &note, t.font(11.5), t.text3, Align::Left, Overflow::Clip);
        if hit.clicked {
            app.restart();
            return;
        }
        y += t.s(32.0);

    }

    let r = row(ui, &mut y, &l("Code font", "代码字体"));
    let picked = app.settings.code_font.clone();
    if let Some(at) = font_button(ui, Id::new("set-code-font"), Rect::new(r.right() - control_w, r.y, control_w, r.h), app.font_choices.as_ref(), picked.as_deref()) {
        let items = font_menu(app.font_choices.as_ref(), picked.as_deref(), App::choose_code_font);
        app.open_choice_menu(at, items);
    }
    let r = row(ui, &mut y, &l("Code font size", "代码字号"));
    if let Some(d) = stepper(ui, Id::new("set-code"), r, app.settings.font_size, "Ctrl+Shift+,", "Ctrl+Shift+.") {
        app.change_code_font_size(d);
    }
    let r = row(ui, &mut y, &l("Interface font size", "界面字号"));
    if let Some(d) = stepper(ui, Id::new("set-ui"), r, app.settings.ui_font_size, &l("Smaller", "减小"), &l("Larger", "增大")) {
        app.change_interface_font_size(d);
    }
    if app.has_terminal() {
        let r = row(ui, &mut y, &l("Terminal font", "终端字体"));
        let picked = app.settings.terminal_font.clone();
        if let Some(at) = font_button(ui, Id::new("set-terminal-font"), Rect::new(r.right() - control_w, r.y, control_w, r.h), app.font_choices.as_ref(), picked.as_deref()) {
            let items = font_menu(app.font_choices.as_ref(), picked.as_deref(), App::choose_terminal_font);
            app.open_choice_menu(at, items);
        }
        let r = row(ui, &mut y, &l("Terminal font size", "终端字号"));
        if let Some(d) = stepper(ui, Id::new("set-terminal"), r, app.settings.terminal_font_size, &l("Smaller", "减小"), &l("Larger", "增大")) {
            app.change_terminal_font_size(d);
        }
    }
    let r = row(ui, &mut y, &l("Default view", "默认视图"));
    let titles = vec![l("Side-by-side", "并排"), l("Unified", "合并")];
    let current = usize::from(app.settings.unified);
    if let Some(i) = segmented(ui, Id::new("set-view"), Rect::new(r.right() - control_w, r.y, control_w, r.h), &titles, current) {
        if (i == 1) != app.settings.unified {
            app.toggle_unified();
        }
    }

    if updates {
        let r = row(ui, &mut y, &l("Check for updates", "检查更新"));
        let titles = vec![l("Automatically", "自动"), l("Manually", "手动")];
        let current = usize::from(!app.settings.check_updates);
        if let Some(i) = segmented(ui, Id::new("set-updates"), Rect::new(r.right() - control_w, r.y, control_w, r.h), &titles, current) {
            app.settings.check_updates = i == 0;
            app.settings.save();
            if app.settings.check_updates {
                app.check_for_updates(false);
            }
        }
        // Where things stand, and the one thing to do about it.
        let current = crate::app::update::CURRENT;
        let (note, button, enabled) = if app.update.checking {
            (l("Checking…", "正在检查…"), l("Check Now", "立即检查"), false)
        } else if let Some(release) = &app.update.available {
            let v = &release.version;
            (lf!("DiffCode {v} is available", "DiffCode {v} 已发布"), l("Download…", "下载…"), true)
        } else {
            let note = match &app.update.last {
                Some(Err(e)) => lf!("Couldn't check: {e}", "检查失败：{e}"),
                Some(Ok(())) => lf!("DiffCode {current} is up to date", "DiffCode {current} 已是最新版本"),
                None => lf!("This is DiffCode {current}", "当前版本 {current}"),
            };
            (note, l("Check Now", "立即检查"), true)
        };
        let line = Rect::new(body.x, y - t.s(10.0), body.w, t.s(24.0));
        let bf = t.font_w(11.0, Weight::Semibold);
        let bw = ui.text_width(&button, bf).ceil() + t.s(18.0);
        let b = Rect::new(line.right() - bw, line.center().y - t.s(11.0), bw, t.s(22.0));
        let hit = ui.interact(Id::new("check-updates"), b);
        let offer = app.update.available.is_some() && !app.update.checking;
        if offer {
            ui.round(b, t.s(6.0), t.accent.alpha(if hit.hovered { 0.85 } else { 1.0 }));
            ui.label_with(b, &button, bf, Color::WHITE, Align::Center, Overflow::Clip);
        } else {
            ui.round(b, t.s(6.0), if hit.hovered && enabled { t.hover } else { t.text.alpha(0.06) });
            ui.label_with(b, &button, bf, if enabled { t.text } else { t.text3 }, Align::Center, Overflow::Clip);
        }
        let nw = (b.x - t.s(8.0) - line.x).max(0.0);
        ui.label_with(Rect::new(line.x, line.y, nw, line.h), &note, t.font(11.5), t.text3, Align::Right, Overflow::Ellipsis);
        if hit.clicked && enabled {
            if offer {
                app.show_update_dialog();
            } else {
                app.check_for_updates(true);
            }
        }
    }
}

/// The default monospace face and the installed ones (`App::font_choices`).
type FontChoices = (String, Vec<String>);

/// What a font setting shows: the family picked, marked when it is no longer installed, or "Default (…)".
fn font_title(choices: Option<&FontChoices>, picked: Option<&str>) -> String {
    match picked {
        None => match choices.map(|(default, _)| default.as_str()).filter(|d| !d.is_empty()) {
            Some(default) => lf!("Default ({default})", "默认（{default}）"),
            None => l("Default", "默认"),
        },
        Some(name) if choices.is_some_and(|(_, list)| !list.is_empty() && !list.iter().any(|f| f == name)) => {
            lf!("{name} (not installed)", "{name}（未安装）")
        }
        Some(name) => name.to_string(),
    }
}

/// A button that drops down the list of fonts. Returns where the menu opens, when clicked.
fn font_button(ui: &mut Ui, id: Id, rect: Rect, choices: Option<&FontChoices>, picked: Option<&str>) -> Option<Point> {
    let t = ui.theme;
    let rect = Rect::new(rect.x, rect.center().y - t.s(12.0), rect.w, t.s(24.0));
    let hit = ui.interact(id, rect);
    ui.round(rect, t.s(6.0), if hit.hovered { t.hover } else { t.text.alpha(0.08) });
    let chevron = t.s(12.0);
    let text = Rect::new(rect.x + t.s(10.0), rect.y, rect.w - t.s(24.0) - chevron, rect.h);
    ui.label_with(text, &font_title(choices, picked), t.font(11.5), t.text, Align::Left, Overflow::Ellipsis);
    ui.icon(Icon::ChevronDown, Rect::new(rect.right() - t.s(10.0) - chevron, rect.center().y - chevron / 2.0, chevron, chevron), t.text2);
    hit.clicked.then(|| Point::new(rect.x, rect.bottom() + t.s(4.0)))
}

/// "Default" and the installed monospace families, the one in use ticked. A family picked once and uninstalled since
/// stays at the end, marked, so it can be seen and changed; the code falls back to the default face meanwhile.
fn font_menu(choices: Option<&FontChoices>, picked: Option<&str>, choose: fn(&mut App, Option<String>)) -> Vec<MenuItem> {
    let mut items = vec![MenuItem::new(font_title(choices, None), move |app| choose(app, None)).checked(picked.is_none())];
    let list = choices.map(|(_, list)| list.as_slice()).unwrap_or_default();
    let missing = picked.filter(|p| !list.iter().any(|f| f == p));
    if !list.is_empty() || missing.is_some() {
        items.push(MenuItem::separator());
    }
    for name in list.iter().map(String::as_str).chain(missing) {
        let family = name.to_string();
        items.push(MenuItem::new(font_title(choices, Some(name)), move |app| choose(app, Some(family))).checked(picked == Some(name)));
    }
    items
}

/// A segmented control. Returns the segment clicked.
fn segmented(ui: &mut Ui, id: Id, rect: Rect, titles: &[String], current: usize) -> Option<usize> {
    let t = ui.theme;
    let rect = Rect::new(rect.x, rect.center().y - t.s(12.0), rect.w, t.s(24.0));
    ui.round(rect, t.s(6.0), t.text.alpha(0.08));
    let w = (rect.w - t.s(4.0)) / titles.len() as f32;
    let mut picked = None;
    for (i, title) in titles.iter().enumerate() {
        let r = Rect::new(rect.x + t.s(2.0) + i as f32 * w, rect.y + t.s(2.0), w, rect.h - t.s(4.0));
        let hit = ui.interact(id.with(i), r);
        if i == current {
            ui.painter.shadow(r, t.s(5.0), t.s(2.0), Color::BLACK.alpha(0.12));
            ui.round(r, t.s(5.0), t.elevated);
        } else if hit.hovered {
            ui.round(r, t.s(5.0), t.hover);
        }
        ui.label_with(r, title, t.font_w(11.5, if i == current { Weight::Medium } else { Weight::Regular }), if i == current { t.text } else { t.text2 }, Align::Center, Overflow::Ellipsis);
        if hit.clicked && i != current {
            picked = Some(i);
        }
    }
    picked
}

/// − value + . Returns the step clicked.
fn stepper(ui: &mut Ui, id: Id, row: Rect, value: f32, down: &str, up: &str) -> Option<f32> {
    let t = ui.theme;
    let size = Size::new(t.s(26.0), t.s(24.0));
    let cy = row.center().y;
    let plus = Rect::new(row.right() - size.w, cy - size.h / 2.0, size.w, size.h);
    let text = Rect::new(plus.x - t.s(8.0) - t.s(44.0), row.y, t.s(44.0), row.h);
    let minus = Rect::new(text.x - t.s(8.0) - size.w, cy - size.h / 2.0, size.w, size.h);
    let mut out = None;
    if icon_button(ui, id.with("minus"), minus, Icon::Subtract, down, true, false).clicked {
        out = Some(-1.0);
    }
    ui.label_with(text, &format!("{} pt", value.round() as i32), t.font(12.5), t.text, Align::Center, Overflow::Clip);
    if icon_button(ui, id.with("plus"), plus, Icon::Add, up, true, false).clicked {
        out = Some(1.0);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn choices() -> FontChoices {
        ("Cascadia Mono".into(), vec!["Cascadia Mono".into(), "Consolas".into(), "MesloLGS NF".into()])
    }

    fn noop(_: &mut App, _: Option<String>) {}

    #[test]
    fn names_the_default_face() {
        assert!(font_title(Some(&choices()), None).contains("Cascadia Mono"));
        assert_eq!(font_title(Some(&choices()), Some("MesloLGS NF")), "MesloLGS NF");
        // Before the list is read, a picked name is shown as it is.
        assert_eq!(font_title(None, Some("MesloLGS NF")), "MesloLGS NF");
    }

    #[test]
    fn lists_the_fonts_with_the_pick_ticked() {
        let items = font_menu(Some(&choices()), Some("Consolas"), noop);
        let titles: Vec<&str> = items.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles[2..], ["Cascadia Mono", "Consolas", "MesloLGS NF"]);
        assert!(items[1].separator);
        let ticked: Vec<usize> = items.iter().enumerate().filter(|(_, i)| i.checked).map(|(n, _)| n).collect();
        assert_eq!(ticked, [3]);
        assert!(font_menu(Some(&choices()), None, noop)[0].checked);
    }

    /// A family picked once and uninstalled since stays in the menu, marked and ticked, so it can be changed.
    #[test]
    fn keeps_an_uninstalled_pick_at_the_end() {
        let items = font_menu(Some(&choices()), Some("Fira Code"), noop);
        let last = items.last().unwrap();
        assert!(last.checked && last.title.starts_with("Fira Code") && last.title != "Fira Code");
        assert_eq!(items.iter().filter(|i| i.checked).count(), 1);
        assert_eq!(font_title(Some(&choices()), Some("Fira Code")), last.title);
    }
}
