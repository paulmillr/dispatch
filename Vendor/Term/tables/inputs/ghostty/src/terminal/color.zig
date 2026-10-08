pub fn default(self: Name) error{NoDefaultValue}!RGB {
        return switch (self) {
            .black => RGB{ .r = 0x1D, .g = 0x1F, .b = 0x21 },
            .red => RGB{ .r = 0xCC, .g = 0x66, .b = 0x66 },
            .green => RGB{ .r = 0xB5, .g = 0xBD, .b = 0x68 },
            .yellow => RGB{ .r = 0xF0, .g = 0xC6, .b = 0x74 },
            .blue => RGB{ .r = 0x81, .g = 0xA2, .b = 0xBE },
            .magenta => RGB{ .r = 0xB2, .g = 0x94, .b = 0xBB },
            .cyan => RGB{ .r = 0x8A, .g = 0xBE, .b = 0xB7 },
            .white => RGB{ .r = 0xC5, .g = 0xC8, .b = 0xC6 },

            .bright_black => RGB{ .r = 0x66, .g = 0x66, .b = 0x66 },
            .bright_red => RGB{ .r = 0xD5, .g = 0x4E, .b = 0x53 },
            .bright_green => RGB{ .r = 0xB9, .g = 0xCA, .b = 0x4A },
            .bright_yellow => RGB{ .r = 0xE7, .g = 0xC5, .b = 0x47 },
            .bright_blue => RGB{ .r = 0x7A, .g = 0xA6, .b = 0xDA },
            .bright_magenta => RGB{ .r = 0xC3, .g = 0x97, .b = 0xD8 },
            .bright_cyan => RGB{ .r = 0x70, .g = 0xC0, .b = 0xB1 },
            .bright_white => RGB{ .r = 0xEA, .g = 0xEA, .b = 0xEA },

            else =>
