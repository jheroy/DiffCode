//! DiffCode's platform-neutral core: running git and parsing its output, the diff model, syntax colouring,
//! commits (whole and partial), history and the rest. Nothing here touches a window or an OS API beyond
//! files and processes, so all of it is developed and tested on any machine.

pub mod lang;
pub mod util;
pub mod text_codec;
pub mod git;
pub mod wsl;
pub mod remote;
pub mod syntax;
pub mod text_editing;
pub mod diff;
pub mod working_tree;
pub mod commit;
pub mod history;
pub mod history_edits;
pub mod annotations;
pub mod fuzzy;
pub mod watcher;
pub mod editor_session;
