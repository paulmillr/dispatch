fn ctrlSeq(
    logical_key: key.Key,
    utf8: []const u8,
    unshifted_codepoint: u21,
    mods: key.Mods,
) ?u8 {
    const ctrl_only = comptime (key.Mods{ .ctrl = true }).int();

    // If ctrl is not pressed then we never do anything.
    if (!mods.ctrl) return null;

    const char, const unset_mods = unset_mods: {
        // We need to only get binding modifiers so we strip lock
        // keys, sides, etc.
        var unset_mods = mods.binding();

        // Remove alt from our modifiers because it does not impact whether
        // we are generating a ctrl sequence and we handle the ESC-prefix
        // logic separately.
        unset_mods.alt = false;

        var char: u8 = char: {
            // If we have exactly one UTF8 byte, we assume that is the
            // character we want to convert to a C0 byte.
            if (utf8.len == 1) break :char utf8[0];

            // If we have a logical key that maps to a single byte
            // printable character, we use that. History to explain this:
            // this was added to support cyrillic keyboard layouts such
            // as Russian and Mongolian. These layouts have a `c` key that
            // maps to U+0441 (cyrillic small letter "c") but every
            // terminal I've tested encodes this as ctrl+c.
            if (logical_key.codepoint()) |cp| {
                if (std.math.cast(u8, cp)) |byte| {
                    // For this specific case, we only map to the key if
                    // we have exactly ctrl pressed. This is because shift
                    // would modify the key and we don't know how to do that
                    // properly here (don't have the layout). And we want
                    // to encode shift as CSIu.
                    if (unset_mods.int() != ctrl_only) return null;
                    break :char byte;
                }
            }

            // Otherwise we don't have a character to convert that
            // we can reliably map to a C0 byte.
            return null;
        };

        // Remove shift if we have something outside of the US letter
        // range. This is so that characters such as `ctrl+shift+-`
        // generate the correct ctrl-seq (used by emacs).
        if (unset_mods.shift and (char < 'A' or char > 'Z')) shift: {
            // Special case for fixterms awkward case as specified.
            if (char == '@') break :shift;
            unset_mods.shift = false;
        }

        // If the character is uppercase, we convert it to lowercase. We
        // rely on the unshifted codepoint to do this. This handles
        // the scenario where we have caps lock pressed. Note that
        // shifted characters are handled above, if we are just pressing
        // shift then the ctrl-only check will fail later and we won't
        // ctrl-seq encode.
        if (char >= 'A' and char <= 'Z' and unshifted_codepoint > 0) {
            if (std.math.cast(u8, unshifted_codepoint)) |byte| {
                char = byte;
            }
        }

        // An additional note on caps lock and shift interaction.
        // If we have caps lock set and an ASCII letter is pressed,
        // we lowercase it (above). If we have only control pressed,
        // we process it as a ctrl seq. For example ctrl+M with caps
        // lock but no shift will encode as 0x0D.
        //
        // But, if you press ctrl+shift+m, this will not encode as a
        // ctrl-seq and falls through to CSIu encoding. This lets programs
        // detect the difference between ctrl+M and ctrl+shift+M. This
        // diverges from the fixterms "spec" and most terminals. This
        // only matches Kitty in behavior. But I believe this is a
        // justified divergence because it's a useful distinction.

        break :unset_mods .{ char, unset_mods };
    };

    // After unsetting, we only continue if we have ONLY control set.
    if (unset_mods.int() != ctrl_only) return null;

    // From Kitty's key encoding logic. I tried to discern the exact
    // behavior across different terminals but it's not clear, so I'm
    // just going to repeat what Kitty does.
    return switch (char) {
        ' ' => 0,
        '/' => 31,
        '0' => 48,
        '1' => 49,
        '2' => 0,
        '3' => 27,
        '4' => 28,
        '5' => 29,
        '6' => 30,
        '7' => 31,
        '8' => 127,
        '9' => 57,
        '?' => 127,
        '@' => 0,
        '\\' => 28,
        ']' => 29,
        '^' => 30,
        '_' => 31,
        'a' => 1,
        'b' => 2,
        'c' => 3,
        'd' => 4,
        'e' => 5,
        'f' => 6,
        'g' => 7,
        'h' => 8,
        'j' => 10,
        'k' => 11,
        'l' => 12,
        'n' => 14,
        'o' => 15,
        'p' => 16,
        'q' => 17,
        'r' => 18,
        's' => 19,
        't' => 20,
        'u' => 21,
        'v' => 22,
        'w' => 23,
        'x' => 24,
        'y' => 25,
        'z' => 26,
        '~' => 30,

        // These are purposely NOT handled here because of the fixterms
        // specification: https://www.leonerd.org.uk/hacks/fixterms/
        // These are processed as CSI u.
        // 'i' => 0x09,
        // 'm' => 0x0D,
        // '[' => 0x1B,

        else => null
