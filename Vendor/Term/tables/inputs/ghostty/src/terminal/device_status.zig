const entries: []const Entry = &.{
    .{ .name = "operating_status", .value = 5 },
    .{ .name = "cursor_position", .value = 6 },
    .{ .name = "cursor_position_extended", .value = 6, .question = true },
    .{ .name = "color_scheme", .value = 996, .question = true },
    .{ .name = "visibility", .value = 998, .question = true },
};
