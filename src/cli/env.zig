//! `zvm env` subcommand outputting shell `PATH` setup and directory-change hook scripts.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const Shell = @import("completions.zig").Shell;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "env",
        .description = "Print shell integration snippet (PATH + directory hook)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "shell",
        .description = "Target shell: bash, zsh, fish, or powershell",
        .required = true,
    });
    try cmd.addFlag(.{
        .name = "auto-install",
        .description = "Enable ZVM_AUTO_INSTALL=1 in the generated environment",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

pub fn render(writer: *std.Io.Writer, shell: Shell, bin_dir: []const u8, auto_install: bool) !void {
    switch (shell) {
        .bash => {
            try writer.print("export PATH=\"{s}:$PATH\"\n", .{bin_dir});
            if (auto_install) try writer.writeAll("export ZVM_AUTO_INSTALL=1\n");
            try writer.writeAll(
                \\_zvm_hook() {
                \\    if [[ -f ".zig-version" || -f "build.zig.zon" ]]; then
                \\        zvm current >/dev/null 2>&1 || true
                \\    fi
                \\}
                \\if [[ ";${PROMPT_COMMAND:-};" != *";_zvm_hook;"* ]]; then
                \\    PROMPT_COMMAND="_zvm_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
                \\fi
                \\
            );
        },
        .zsh => {
            try writer.print("export PATH=\"{s}:$PATH\"\n", .{bin_dir});
            if (auto_install) try writer.writeAll("export ZVM_AUTO_INSTALL=1\n");
            try writer.writeAll(
                \\_zvm_hook() {
                \\    if [[ -f ".zig-version" || -f "build.zig.zon" ]]; then
                \\        zvm current >/dev/null 2>&1 || true
                \\    fi
                \\}
                \\autoload -Uz add-zsh-hook
                \\add-zsh-hook chpwd _zvm_hook
                \\
            );
        },
        .fish => {
            try writer.print("fish_add_path -p \"{s}\"\n", .{bin_dir});
            if (auto_install) try writer.writeAll("set -gx ZVM_AUTO_INSTALL 1\n");
            try writer.writeAll(
                \\function _zvm_hook --on-variable PWD
                \\    if test -f .zig-version -o -f build.zig.zon
                \\        zvm current >/dev/null 2>&1; or true
                \\    end
                \\end
                \\
            );
        },
        .powershell => {
            try writer.print("$env:PATH = \"{s};\" + $env:PATH\n", .{bin_dir});
            if (auto_install) try writer.writeAll("$env:ZVM_AUTO_INSTALL = \"1\"\n");
        },
    }
}

fn handle(ctx: zli.CommandContext) (zvm.errors.CliError || std.Io.Writer.Error)!void {
    const app = ctx.getContextData(AppContext);
    const raw_shell = ctx.getArg("shell") orelse return zvm.errors.CliError.MissingShell;
    const auto_install = ctx.flag("auto-install", bool);

    const shell = Shell.parse(raw_shell) catch {
        try ctx.writer.print("error: Unsupported shell '{s}'. Expected bash, zsh, fish, or powershell.\n", .{raw_shell});
        return zvm.errors.CliError.UnsupportedShell;
    };

    try render(ctx.writer, shell, app.paths.bin_dir, auto_install);
}

test "render env script includes bin_dir and optional ZVM_AUTO_INSTALL" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try render(&out.writer, .bash, "/home/alice/.zvm/bin", true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "export PATH=\"/home/alice/.zvm/bin:$PATH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "export ZVM_AUTO_INSTALL=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "PROMPT_COMMAND") != null);
}
