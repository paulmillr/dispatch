//! Swift 6.0.3's `String.count` (extended grapheme clusters as Swift implements them: Unicode
//! 15.0 tables and its own indic-conjunct rule), for producers that bound presentation like
//! c1654cc Dispatch/Chat/ChatSideConversation.swift:79-85. A port of
//! stdlib/public/core/StringGraphemeBreaking.swift (_GraphemeBreakingState.shouldBreak; a
//! fresh state per cluster like nextBoundary) and UnicodeBreakProperty.swift.
mod table;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cat {
    Any,
    Control,
    Extend,
    Pictographic,
    L,
    LV,
    LVT,
    Prepend,
    Regional,
    SpacingMark,
    T,
    V,
    ZWJ,
}
use Cat::*;

/// The sorted-range row containing `c`.
fn find<T>(table: &[T], c: u32, range: fn(&T) -> (u32, u32)) -> Option<&T> {
    table
        .binary_search_by(|row| {
            let (lo, hi) = range(row);
            if hi < c {
                std::cmp::Ordering::Less
            } else if lo > c {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .ok()
        .map(|i| &table[i])
}

/// Unicode._GraphemeBreakProperty(from:): fast paths, then the generated table.
fn category(c: u32) -> Cat {
    match c {
        0x0..=0x1F | 0xE01F0..=0xE0FFF => Control,
        0x20..=0x7E => Any,
        0x200D => ZWJ,
        0x1100..=0x115F | 0xA960..=0xA97C => L,
        0x1160..=0x11A7 | 0xD7B0..=0xD7C6 => V,
        0x11A8..=0x11FF | 0xD7CB..=0xD7FB => T,
        0xAC00..=0xD7A3 if c % 28 == 16 => LV,
        0xAC00..=0xD7A3 => LVT,
        0x1F1E6..=0x1F1FF => Regional,
        0x1FC00..=0x1FFFD => Pictographic,
        _ => find(table::CATEGORIES, c, |r| (r.0, r.1)).map_or(Any, |r| r.2),
    }
}

fn listed(table: &[(u32, u32)], c: u32) -> bool {
    find(table, c, |r| *r).is_some()
}

/// _hasGraphemeBreakBetween's ranges that always break when paired.
fn paired(c: u32) -> bool {
    matches!(c, 0x3400..=0xA4CF | 0x0..=0x2FF | 0x3041..=0x3096 | 0x30A1..=0x30FC
        | 0x400..=0x482 | 0x61D..=0x64A | 0xAC00..=0xD7AF | 0x2010..=0x2029
        | 0x3000..=0x3029 | 0xFF01..=0xFF9D)
}

/// Unicode.Scalar._isVirama (six scripts only).
fn virama(c: u32) -> bool {
    matches!(c, 0x94D | 0x9CD | 0xACD | 0xB4D | 0xC4D | 0xD4D)
}

#[derive(Default)]
struct State {
    emoji: bool,
    indic: bool,
    virama: bool,
    regional: bool,
}

impl State {
    fn split(&mut self, a: u32, b: u32) -> bool {
        if a == 0xD && b == 0xA {
            return false;
        }
        if paired(a) && paired(b) {
            return true;
        }
        let (x, y) = (category(a), category(b));
        if x == Control {
            return true;
        }
        let (mut emoji, mut indic) = (false, false);
        let split = match (x, y) {
            (Any, Any) | (_, Control) => true,
            (L, L | V | LV | LVT) | (LV | V, V | T) | (LVT | T, T) => false,
            (_, Extend | ZWJ) => {
                emoji = x == Pictographic || (self.emoji && x == Extend);
                // An Extend without a combining class ends the indic sequence.
                if (self.indic || listed(table::CONSONANTS, a))
                    && (y != Extend || listed(table::MARKS, b))
                {
                    indic = true;
                    self.virama |= virama(b);
                }
                false
            }
            (_, SpacingMark) | (Prepend, _) => false,
            (ZWJ, Pictographic) => !self.emoji,
            (Regional, Regional) => {
                self.regional = !self.regional;
                !self.regional
            }
            _ if self.indic && self.virama && listed(table::CONSONANTS, b) => {
                self.virama = false;
                false
            }
            _ => true,
        };
        self.emoji = emoji;
        self.indic = indic;
        split
    }
}

/// Number of Swift `Character`s in `text`.
pub fn count(text: &str) -> usize {
    let mut scalars = text.chars().map(u32::from);
    let Some(mut previous) = scalars.next() else {
        return 0;
    };
    let (mut clusters, mut state) = (1, State::default());
    for scalar in scalars {
        if state.split(previous, scalar) {
            clusters += 1;
            state = State::default();
        }
        previous = scalar;
    }
    clusters
}
