//! Tmux's checksummed tiled geometry; weights and paths retain native identity.
use crate::mux::error;
pub use dispatch_helper_core::api::Axis;
pub use dispatch_helper_core::api::Error;
use dispatch_helper_core::api::Split;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Content {
    Pane(u32),
    Split(Axis, Vec<Layout>),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    pub width: u32,
    pub height: u32,
    pub x: u32,
    pub y: u32,
    pub content: Content,
}
#[derive(Clone, Copy)]
pub(crate) struct Bounds {
    pub low: u32,
    pub high: u32,
    pub pane: u32,
    pub size: u32,
}
impl Layout {
    pub(crate) fn bounds(&self, axis: Axis) -> Bounds {
        match &self.content {
            Content::Pane(pane) => {
                let (low, size) = if axis == Axis::Columns {
                    (self.x, self.width)
                } else {
                    (self.y, self.height)
                };
                Bounds {
                    low,
                    high: low + size,
                    pane: *pane,
                    size,
                }
            }
            Content::Split(_, children) => children
                .iter()
                .map(|child| child.bounds(axis))
                .reduce(|first, second| {
                    let low = first.low.min(second.low);
                    let edge = if first.high > second.high {
                        first
                    } else {
                        second
                    };
                    Bounds { low, ..edge }
                })
                .unwrap(),
        }
    }
    pub fn excluding(&self, panes: &std::collections::BTreeSet<u32>) -> Option<Self> {
        let content = match &self.content {
            Content::Pane(pane) => {
                return (!panes.contains(pane)).then(|| self.clone());
            }
            Content::Split(axis, children) => {
                let mut children: Vec<_> = children
                    .iter()
                    .filter_map(|child| child.excluding(panes))
                    .collect();
                match children.len() {
                    0 => return None,
                    1 => return children.pop(),
                    _ => Content::Split(*axis, children),
                }
            }
        };
        Some(Self {
            content,
            ..self.clone()
        })
    }
    pub fn split(
        &self,
        path: &mut Vec<usize>,
        id: &mut impl FnMut(&Content, &[usize], usize) -> u64,
    ) -> Split {
        match &self.content {
            Content::Pane(_) => Split::Leaf(id(&self.content, path, 0)),
            Content::Split(axis, children) => {
                let mut children: Vec<_> = children
                    .iter()
                    .enumerate()
                    .map(|(index, child)| {
                        path.push(index);
                        let split = child.split(path, id);
                        path.pop();
                        (
                            if *axis == Axis::Columns {
                                child.width
                            } else {
                                child.height
                            },
                            split,
                        )
                    })
                    .collect();
                let (mut extent, mut tree) = children.pop().unwrap();
                for (offset, (weight, child)) in children.into_iter().enumerate().rev() {
                    tree = Split::Branch {
                        id: id(&self.content, path, offset),
                        axis: *axis,
                        children: vec![(weight, child), (extent, tree)],
                    };
                    extent += weight + 1;
                }
                tree
            }
        }
    }
    pub fn pane(&self, id: u32) -> Option<&Self> {
        match &self.content {
            Content::Pane(pane) => (*pane == id).then_some(self),
            Content::Split(_, children) => children.iter().find_map(|child| child.pane(id)),
        }
    }
    pub fn ids(&self) -> Vec<u32> {
        match &self.content {
            Content::Pane(pane) => vec![*pane],
            Content::Split(_, children) => children.iter().flat_map(Self::ids).collect(),
        }
    }
    pub fn parse(value: &str) -> Result<Self, Error> {
        let bytes = value.as_bytes();
        let checksum = u16::from_str_radix(value.get(..4).ok_or_else(|| error("malformed"))?, 16)
            .map_err(|_| error("malformed"))?;
        let body = bytes
            .get(5..)
            .filter(|b| !b.is_empty())
            .ok_or_else(|| error("malformed"))?;
        if bytes.get(4) != Some(&b',')
            || body
                .iter()
                .fold(0u16, |v, b| v.rotate_right(1).wrapping_add(u16::from(*b)))
                != checksum
        {
            return Err(error("malformed"));
        }
        struct Parser<'a> {
            bytes: &'a [u8],
            at: usize,
        }
        impl Parser<'_> {
            fn take(&mut self, byte: u8) -> bool {
                let yes = self.bytes.get(self.at) == Some(&byte);
                self.at += usize::from(yes);
                yes
            }
            fn number(&mut self) -> Result<u32, Error> {
                let count = self.bytes[self.at..]
                    .iter()
                    .take_while(|b| b.is_ascii_digit())
                    .count();
                let value = std::str::from_utf8(&self.bytes[self.at..self.at + count])
                    .map_err(|_| error("malformed"))?
                    .parse::<u32>()
                    .map_err(|_| error("malformed"))?;
                self.at += count;
                if value > 1_000_000 {
                    return Err(error("malformed"));
                }
                Ok(value)
            }
            fn after(&mut self, separator: u8) -> Result<u32, Error> {
                if !self.take(separator) {
                    return Err(error("malformed"));
                }
                self.number()
            }
            fn node(&mut self, depth: u8) -> Result<Layout, Error> {
                if depth >= 64 {
                    return Err(error("malformed"));
                }
                let width = self.number()?;
                let height = self.after(b'x')?;
                if width == 0 || height == 0 {
                    return Err(error("malformed"));
                }
                let x = self.after(b',')?;
                let y = self.after(b',')?;
                let content = if self.take(b',') {
                    Content::Pane(self.number()?)
                } else {
                    let columns = self.take(b'{');
                    if !columns && !self.take(b'[') {
                        return Err(error("malformed"));
                    }
                    let mut children = vec![self.node(depth + 1)?];
                    for _ in 0..self.bytes.len() {
                        if !self.take(b',') {
                            break;
                        }
                        children.push(self.node(depth + 1)?);
                    }
                    if children.len() < 2 || !self.take(if columns { b'}' } else { b']' }) {
                        return Err(error("malformed"));
                    }
                    Content::Split(if columns { Axis::Columns } else { Axis::Rows }, children)
                };
                Ok(Layout {
                    width,
                    height,
                    x,
                    y,
                    content,
                })
            }
        }
        let mut parser = Parser { bytes, at: 5 };
        let node = parser.node(0)?;
        let mut panes = node.ids();
        panes.sort_unstable();
        if parser.at != bytes.len() || panes.windows(2).any(|p| p[0] == p[1]) {
            return Err(error("malformed"));
        }
        Ok(node)
    }
}
