const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main(init: std.process.Init) !void {
    const exit_code = try cli.run(init);
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test {
    _ = cli;
}
