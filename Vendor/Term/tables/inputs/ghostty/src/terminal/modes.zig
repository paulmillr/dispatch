const entries: []const ModeEntry = &.{
    // ANSI
    .{ .name = "disable_keyboard", .value = 2, .ansi = true }, // KAM
    .{ .name = "insert", .value = 4, .ansi = true },
    .{ .name = "send_receive_mode", .value = 12, .ansi = true, .default = true }, // SRM
    .{ .name = "linefeed", .value = 20, .ansi = true },

    // DEC
    .{ .name = "cursor_keys", .value = 1 }, // DECCKM
    .{ .name = "132_column", .value = 3, .default_configurable = false },
    .{ .name = "slow_scroll", .value = 4 },
    .{ .name = "reverse_colors", .value = 5 },
    .{ .name = "origin", .value = 6, .default_configurable = false },
    .{ .name = "wraparound", .value = 7, .default = true },
    .{ .name = "autorepeat", .value = 8 },
    .{ .name = "mouse_event_x10", .value = 9, .default_configurable = false },
    .{ .name = "cursor_blinking", .value = 12, .default_configurable = false },
    .{ .name = "cursor_visible", .value = 25, .default = true },
    .{ .name = "enable_mode_3", .value = 40 },
    .{ .name = "reverse_wrap", .value = 45 },
    .{ .name = "alt_screen_legacy", .value = 47, .default_configurable = false },
    .{ .name = "keypad_keys", .value = 66 },
    // DEC Backarrow Key Mode (DECBKM)
    // See https://vt100.net/dec/ek-vt3xx-tp-002.pdf page 170
    // If `false` (the default), `backspace` emits 0x7f
    // If `true`, `backspace` emits 0x08
    .{ .name = "backarrow_key_mode", .value = 67 },
    .{ .name = "enable_left_and_right_margin", .value = 69, .default_configurable = false },
    .{ .name = "mouse_event_normal", .value = 1000, .default_configurable = false },
    .{ .name = "mouse_event_button", .value = 1002, .default_configurable = false },
    .{ .name = "mouse_event_any", .value = 1003, .default_configurable = false },
    .{ .name = "focus_event", .value = 1004 },
    .{ .name = "mouse_format_utf8", .value = 1005, .default_configurable = false },
    .{ .name = "mouse_format_sgr", .value = 1006, .default_configurable = false },
    .{ .name = "mouse_alternate_scroll", .value = 1007, .default = true },
    .{ .name = "mouse_format_urxvt", .value = 1015, .default_configurable = false },
    .{ .name = "mouse_format_sgr_pixels", .value = 1016, .default_configurable = false },
    .{ .name = "ignore_keypad_with_numlock", .value = 1035, .default = true },
    .{ .name = "alt_esc_prefix", .value = 1036, .default = true },
    .{ .name = "alt_sends_escape", .value = 1039 },
    .{ .name = "reverse_wrap_extended", .value = 1045 },
    .{ .name = "alt_screen", .value = 1047, .default_configurable = false },
    .{ .name = "save_cursor", .value = 1048, .default_configurable = false },
    .{ .name = "alt_screen_save_cursor_clear_enter", .value = 1049, .default_configurable = false },
    .{ .name = "bracketed_paste", .value = 2004 },
    .{ .name = "synchronized_output", .value = 2026, .default_configurable = false },
    .{ .name = "grapheme_cluster", .value = 2027 },
    .{ .name = "report_color_scheme", .value = 2031 },
    .{ .name = "report_visibility", .value = 2033, .default_configurable = false },
    .{ .name = "in_band_size_reports", .value = 2048 },
    // Kitty clipboard protocol paste events. When set, a user-initiated
    // paste sends an unsolicited OSC 5522 targets listing with a
    // one-time password instead of pasting the text.
    // See https://sw.kovidgoyal.net/kitty/clipboard/
    .{
        .name = "kitty_paste_events",
        .value = 5522,
        // The macOS app and libghostty-vt can both serve the follow-up
        // Kitty clipboard read that a paste event grants.
        .disabled = build_options.artifact != .lib and builtin.os.tag != .macos,
    },
};
