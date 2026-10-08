use super::*;

impl Native {
    /// Local terminal topology is presented by the app, rather than an external server.
    pub fn external(&self) -> bool {
        false
    }

    /// c1654cc TerminalBackend.scroll is a renderer operation; native has no scrollback copy.
    pub fn seek(&mut self, io: &mut dyn Io, _terminal: Id, _offset: u64, done: Done<()>) {
        deferred(done)(io, Err(error("layout_app_owned", "")));
    }

    /// Existing terminals keep their process when reordered; the app owns native splits/tabs.
    pub fn place(&mut self, io: &mut dyn Io, node: Id, destination: &Place, done: Done<()>) {
        match destination {
            Place::Before { parent, before } => self.r#move(io, node, *parent, *before, done),
            _ => deferred(done)(io, Err(error("layout_app_owned", ""))),
        }
    }
}
