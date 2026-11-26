//! `zvm env` subcommand outputting shell `PATH` setup and directory-change hook scripts.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");
const Shell = @import("completions.zig").Shell;

pub const Editor = enum {
    vscode,
    nvim,
    helix,
    emacs,
    zed,

    pub fn parse(raw: []const u8) ?Editor {
        if (std.ascii.eqlIgnoreCase(raw, "vscode") or std.ascii.eqlIgnoreCase(raw, "code")) return .vscode;
        if (std.ascii.eqlIgnoreCase(raw, "nvim") or std.ascii.eqlIgnoreCase(raw, "neovim")) return .nvim;
        if (std.ascii.eqlIgnoreCase(raw, "helix") or std.ascii.eqlIgnoreCase(raw, "hx")) return .helix;
        if (std.ascii.eqlIgnoreCase(raw, "emacs")) return .emacs;
        if (std.ascii.eqlIgnoreCase(raw, "zed")) return .zed;
        return null;
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "env",
        .description = "Print shell integration snippet (PATH + hook) or editor ZLS config",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "shell",
        .description = "Target shell: bash, zsh, fish, or powershell (omit when using --editor)",
        .required = false,
    });
    try cmd.addFlag(.{
        .name = "auto-install",
        .description = "Enable ZVM_AUTO_INSTALL=1 in the generated environment",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "editor",
        .description = "Print ZLS config snippet for an editor (vscode, nvim, helix, emacs, zed)",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    return cmd;
}

pub fn renderEditorConfig(writer: *std.Io.Writer, editor: Editor, zls_shim_path: []const u8) !void {
    switch (editor) {
        .vscode => try writer.print(
            \\// .vscode/settings.json (or User settings.json)
            \\{{
            \\  "zig.zls.path": "{s}"
            \\}}
            \\
        , .{zls_shim_path}),
        .nvim => try writer.print(
            \\-- Neovim (nvim-lspconfig)
            \\require("lspconfig").zls.setup({{
            \\  cmd = {{ "{s}" }},
            \\}})
            \\
        , .{zls_shim_path}),
        .helix => try writer.print(
            \\# ~/.config/helix/languages.toml
            \\[language-server.zls]
            \\command = "{s}"
            \\
        , .{zls_shim_path}),
        .emacs => try writer.print(
            \\;; Emacs (eglot)
            \\(with-eval-after-load 'eglot
            \\  (add-to-list 'eglot-server-programs '(zig-mode "{s}")))
            \\
        , .{zls_shim_path}),
        .zed => try writer.print(
            \\// ~/.config/zed/settings.json
            \\{{
            \\  "lsp": {{
            \\    "zls": {{
            \\      "binary": {{
            \\        "path": "{s}"
            \\      }}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{zls_shim_path}),
    }
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

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_editor = ctx.flag("editor", []const u8);
    if (raw_editor.len > 0) {
        const editor = Editor.parse(raw_editor) orelse {
            try app.reporter.fail("Unsupported editor '{s}'.\n", .{raw_editor});
            try app.reporter.hint("Expected vscode, nvim, helix, emacs, or zed.\n", .{});
            return error.Reported;
        };
        const zls_shim = try app.paths.zlsShimPath(ctx.allocator);
        defer ctx.allocator.free(zls_shim);
        try renderEditorConfig(ctx.writer, editor, zls_shim);
        return;
    }

    const raw_shell = ctx.getArg("shell") orelse {
        try app.reporter.fail("A shell name is required (or pass --editor <name>).\n", .{});
        try app.reporter.hint("Expected bash, zsh, fish, or powershell.\n", .{});
        return error.Reported;
    };
    const auto_install = ctx.flag("auto-install", bool);

    const shell = Shell.parse(raw_shell) catch {
        try app.reporter.fail("Unsupported shell '{s}'.\n", .{raw_shell});
        try app.reporter.hint("Expected bash, zsh, fish, or powershell.\n", .{});
        return error.Reported;
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

test "renderEditorConfig outputs valid snippets for supported editors" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try renderEditorConfig(&out.writer, .vscode, "/home/alice/.zvm/bin/zls");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"zig.zls.path\": \"/home/alice/.zvm/bin/zls\"") != null);

    out.clearRetainingCapacity();
    try renderEditorConfig(&out.writer, .helix, "/home/alice/.zvm/bin/zls");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[language-server.zls]") != null);
}
