//! ANSI escape sequence stripping writer.
//!
//! `zli` hardcodes ANSI styles in its help output, so when color is disabled we
//! route the CLI writer through this filter to keep redirected output plain.

const std = @import("std");
const Io = std.Io;

pub const Writer = struct {
    interface: Io.Writer,
    target: *Io.Writer,
    state: State = .text,

    const State = enum {
        text,
        escape,
        csi,
        osc,
        osc_escape,
    };

    pub fn init(target: *Io.Writer) Writer {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            .target = target,
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));

        var consumed: usize = 0;
        for (data, 0..) |chunk, index| {
            const repeat = if (index + 1 == data.len) splat else 1;
            var i: usize = 0;
            while (i < repeat) : (i += 1) {
                try self.process(chunk);
                consumed += chunk.len;
            }
        }
        return consumed;
    }

    fn process(self: *Writer, chunk: []const u8) Io.Writer.Error!void {
        var start: usize = 0;
        var i: usize = 0;

        while (i < chunk.len) : (i += 1) {
            const byte = chunk[i];
            switch (self.state) {
                .text => {
                    if (byte == 0x1b) {
                        if (i > start) try self.target.writeAll(chunk[start..i]);
                        self.state = .escape;
                        start = i + 1;
                    }
                },
                .escape => {
                    if (byte == '[') {
                        self.state = .csi;
                    } else if (byte == ']') {
                        self.state = .osc;
                    } else if (byte >= 0x20 and byte <= 0x2f) {
                        // Intermediate byte; the sequence continues.
                    } else {
                        self.state = .text;
                        start = i + 1;
                    }
                },
                .csi => {
                    if (byte >= 0x40 and byte <= 0x7e) {
                        self.state = .text;
                        start = i + 1;
                    }
                },
                .osc => {
                    if (byte == 0x07) {
                        self.state = .text;
                        start = i + 1;
                    } else if (byte == 0x1b) {
                        self.state = .osc_escape;
                    }
                },
                .osc_escape => {
                    if (byte == '\\') {
                        self.state = .text;
                        start = i + 1;
                    } else {
                        self.state = .osc;
                        start = i + 1;
                    }
                },
            }
        }

        if (self.state == .text and start < chunk.len) {
            try self.target.writeAll(chunk[start..]);
        }
    }
};

test "strips SGR and cursor sequences" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var strip = Writer.init(&out.writer);
    try strip.interface.writeAll("\x1b[1mhello\x1b[0m \x1b[32mworld\x1b[0m\n");
    try std.testing.expectEqualStrings("hello world\n", out.written());
}

test "strips escape sequences split across writes" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var strip = Writer.init(&out.writer);
    try strip.interface.writeAll("\x1b[");
    try strip.interface.writeAll("32mgreen");
    try strip.interface.writeAll("\x1b[0m\n");
    try std.testing.expectEqualStrings("green\n", out.written());
}

test "keeps plain text and strips OSC hyperlinks" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var strip = Writer.init(&out.writer);
    try strip.interface.writeAll("plain \x1b]8;;https://ziglang.org\x1b\\link\x1b]8;;\x1b\\ end\n");
    try std.testing.expectEqualStrings("plain link end\n", out.written());
}
