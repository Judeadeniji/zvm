//! `zvm completions` subcommand generating shell completion scripts for Bash, Zsh, Fish, and PowerShell.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");

pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn parse(raw: []const u8) zvm.errors.CliError!Shell {
        if (std.ascii.eqlIgnoreCase(raw, "bash")) return .bash;
        if (std.ascii.eqlIgnoreCase(raw, "zsh")) return .zsh;
        if (std.ascii.eqlIgnoreCase(raw, "fish")) return .fish;
        if (std.ascii.eqlIgnoreCase(raw, "powershell") or std.ascii.eqlIgnoreCase(raw, "pwsh")) return .powershell;
        return zvm.errors.CliError.UnsupportedShell;
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "completions",
        .description = "Generate shell completions (bash, zsh, fish, powershell)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "shell",
        .description = "Target shell: bash, zsh, fish, or powershell",
        .required = true,
    });
    return cmd;
}

pub fn render(writer: *std.Io.Writer, shell: Shell) !void {
    const script = switch (shell) {
        .bash => bash_script,
        .zsh => zsh_script,
        .fish => fish_script,
        .powershell => powershell_script,
    };
    try writer.writeAll(script);
}

fn handle(ctx: zli.CommandContext) (zvm.errors.CliError || std.Io.Writer.Error || report.Reported)!void {
    const app = ctx.getContextData(AppContext);
    const raw_shell = ctx.getArg("shell") orelse {
        try app.reporter.fail("A shell name is required.\n", .{});
        try app.reporter.hint("Expected bash, zsh, fish, or powershell.\n", .{});
        return error.Reported;
    };
    const shell = Shell.parse(raw_shell) catch {
        try app.reporter.fail("Unsupported shell '{s}'.\n", .{raw_shell});
        try app.reporter.hint("Expected bash, zsh, fish, or powershell.\n", .{});
        return error.Reported;
    };
    try render(ctx.writer, shell);
}

const bash_script =
    \\_zvm_completions() {
    \\    local cur prev
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\    local cmds="install use pin list list-remote current which uninstall setup shim doctor clean config env completions upgrade self-update zls"
    \\    if [[ ${COMP_CWORD} -eq 1 ]]; then
    \\        COMPREPLY=( $(compgen -W "${cmds} --help --version" -- "${cur}") )
    \\        return 0
    \\    fi
    \\    case "${COMP_WORDS[1]}" in
    \\        install) COMPREPLY=( $(compgen -W "master --force --exact --with-zls --minisig-key --no-minisig --help" -- "${cur}") ) ;;
    \\        use)
    \\            local installed=""
    \\            if command -v zvm >/dev/null 2>&1; then
    \\                installed="$(zvm list 2>/dev/null | sed 's/^[* ]*//' | awk '{print $1}')"
    \\            fi
    \\            COMPREPLY=( $(compgen -W "${installed} --with-zls --help" -- "${cur}") )
    \\            ;;
    \\        uninstall)
    \\            local installed=""
    \\            if command -v zvm >/dev/null 2>&1; then
    \\                installed="$(zvm list 2>/dev/null | sed 's/^[* ]*//' | awk '{print $1}')"
    \\            fi
    \\            COMPREPLY=( $(compgen -W "${installed} --help" -- "${cur}") )
    \\            ;;
    \\        which)
    \\            local installed=""
    \\            if command -v zvm >/dev/null 2>&1; then
    \\                installed="$(zvm list 2>/dev/null | sed 's/^[* ]*//' | awk '{print $1}')"
    \\            fi
    \\            COMPREPLY=( $(compgen -W "${installed} zls --zls --exact --help" -- "${cur}") )
    \\            ;;
    \\        current|doctor|list) COMPREPLY=( $(compgen -W "--exact --help" -- "${cur}") ) ;;
    \\        config)
    \\            if [[ ${COMP_CWORD} -eq 2 ]]; then
    \\                COMPREPLY=( $(compgen -W "auto-install exact --help" -- "${cur}") )
    \\            else
    \\                COMPREPLY=( $(compgen -W "on off toggle --help" -- "${cur}") )
    \\            fi
    \\            ;;
    \\        zls)
    \\            if [[ ${COMP_CWORD} -eq 2 ]]; then
    \\                COMPREPLY=( $(compgen -W "install update list use which uninstall --help" -- "${cur}") )
    \\            else
    \\                COMPREPLY=( $(compgen -W "--force --exact --help" -- "${cur}") )
    \\            fi
    \\            ;;
    \\        upgrade|self-update) COMPREPLY=( $(compgen -W "--check --nightly --force --help" -- "${cur}") ) ;;
    \\        env) COMPREPLY=( $(compgen -W "bash zsh fish powershell --auto-install --editor --help" -- "${cur}") ) ;;
    \\        completions) COMPREPLY=( $(compgen -W "bash zsh fish powershell --help" -- "${cur}") ) ;;
    \\        list-remote) COMPREPLY=( $(compgen -W "--all --help" -- "${cur}") ) ;;
    \\        clean) COMPREPLY=( $(compgen -W "--dry-run --help" -- "${cur}") ) ;;
    \\        setup|shim) COMPREPLY=( $(compgen -W "--force --help" -- "${cur}") ) ;;
    \\        *) COMPREPLY=( $(compgen -W "--help" -- "${cur}") ) ;;
    \\    esac
    \\}
    \\complete -F _zvm_completions zvm
    \\
;

const zsh_script =
    \\#compdef zvm
    \\_zvm() {
    \\    local -a commands
    \\    commands=(
    \\        'install:Download and install a Zig version'
    \\        'use:Switch the global default Zig version'
    \\        'pin:Pin a Zig version or constraint in .zig-version'
    \\        'list:List locally installed Zig versions'
    \\        'list-remote:List available upstream releases'
    \\        'current:Show active Zig version for current directory'
    \\        'which:Print binary path of active or specified Zig version'
    \\        'uninstall:Remove an installed Zig version'
    \\        'setup:Create or verify the zig shim symlink'
    \\        'shim:Alias for setup'
    \\        'doctor:Check directories, shim status, and PATH precedence'
    \\        'clean:Remove cached download archives'
    \\        'config:Inspect or toggle persistent zvm settings'
    \\        'env:Print shell PATH and hook setup script'
    \\        'completions:Generate shell completion script'
    \\        'upgrade:Upgrade zvm itself to the latest release'
    \\        'self-update:Alias for upgrade'
    \\        'zls:Manage ZLS versions paired to Zig'
    \\    )
    \\    _arguments -C \
    \\        '(-h --help)'{-h,--help}'[Show help]' \
    \\        '1:command:->cmds' \
    \\        '*::arg:->args'
    \\    case "$state" in
    \\        cmds) _describe -t commands 'zvm command' commands ;;
    \\        args)
    \\            case "$line[1]" in
    \\                completions) _values 'shell' bash zsh fish powershell ;;
    \\                env) _arguments '--auto-install[Enable ZVM_AUTO_INSTALL=1]' '--editor[Print editor ZLS config]:editor:(vscode nvim helix emacs zed)' '1:shell:(bash zsh fish powershell)' ;;
    \\                config) _arguments '1:key:(auto-install exact)' '2:value:(on off toggle)' ;;
    \\                upgrade|self-update) _arguments '(-c --check)'{-c,--check}'[Check for updates only]' '--nightly[Upgrade to nightly build]' '(-f --force)'{-f,--force}'[Force reinstall]' ;;
    \\                zls) _values 'zls subcommand' install update list use which uninstall ;;
    \\                install) _arguments '(-f --force)'{-f,--force}'[Force reinstall]' '--exact[Install exact minimum_zig_version]' '--with-zls[Also install compatible ZLS]' '--minisig-key[Override Minisign public key]:key:' '--no-minisig[Skip minisig check]' '1:version:(master)' ;;
    \\                use) _arguments '--with-zls[Also install/activate paired ZLS]' ;;
    \\                current|doctor|list|which) _arguments '--exact[Treat minimum_zig_version as exact]' ;;
    \\                clean) _arguments '(-n --dry-run)'{-n,--dry-run}'[Dry run]' ;;
    \\                list-remote) _arguments '(-a --all)'{-a,--all}'[Show all releases]' ;;
    \\                setup|shim) _arguments '(-f --force)'{-f,--force}'[Overwrite existing shim]' ;;
    \\            esac
    \\            ;;
    \\    esac
    \\}
    \\compdef _zvm zvm
    \\
;

const fish_script =
    \\complete -c zvm -f
    \\set -l zvm_cmds install use pin list list-remote current which uninstall setup shim doctor clean config env completions upgrade self-update zls
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a install -d "Install a Zig version"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a use -d "Switch global default Zig version"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a pin -d "Pin version in .zig-version"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a list -d "List installed Zig versions"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a list-remote -d "List upstream Zig releases"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a current -d "Show active Zig version"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a which -d "Print Zig binary path"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a uninstall -d "Remove installed Zig version"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a setup -d "Create or verify zig shim"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a doctor -d "Diagnose setup and PATH"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a clean -d "Clean download cache"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a config -d "Inspect or toggle persistent settings"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a env -d "Print shell PATH and hook script"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a completions -d "Generate shell completions"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a upgrade -d "Upgrade zvm itself"
    \\complete -c zvm -n "not __fish_seen_subcommand_from $zvm_cmds" -a zls -d "Manage ZLS versions"
    \\complete -c zvm -n "__fish_seen_subcommand_from completions env" -a "bash zsh fish powershell"
    \\complete -c zvm -n "__fish_seen_subcommand_from env" -l auto-install -d "Enable ZVM_AUTO_INSTALL=1"
    \\complete -c zvm -n "__fish_seen_subcommand_from env" -l editor -r -a "vscode nvim helix emacs zed" -d "Print editor ZLS config"
    \\complete -c zvm -n "__fish_seen_subcommand_from zls" -a "install update list use which uninstall"
    \\complete -c zvm -n "__fish_seen_subcommand_from config" -a "auto-install exact on off toggle"
    \\complete -c zvm -n "__fish_seen_subcommand_from current doctor list which" -l exact -d "Treat minimum_zig_version as exact"
    \\complete -c zvm -n "__fish_seen_subcommand_from install" -s f -l force -d "Force reinstall"
    \\complete -c zvm -n "__fish_seen_subcommand_from install" -l exact -d "Install exact minimum_zig_version"
    \\complete -c zvm -n "__fish_seen_subcommand_from upgrade self-update" -s c -l check -d "Check for updates only"
    \\complete -c zvm -n "__fish_seen_subcommand_from upgrade self-update" -l nightly -d "Upgrade to nightly build"
    \\complete -c zvm -n "__fish_seen_subcommand_from upgrade self-update" -s f -l force -d "Force reinstall"
    \\complete -c zvm -n "__fish_seen_subcommand_from install use" -l with-zls -d "Also install compatible ZLS"
    \\complete -c zvm -n "__fish_seen_subcommand_from install" -l minisig-key -r -d "Override Minisign public key"
    \\complete -c zvm -n "__fish_seen_subcommand_from install" -l no-minisig -d "Skip minisig verification"
    \\complete -c zvm -n "__fish_seen_subcommand_from clean" -s n -l dry-run -d "Preview cleanup"
    \\complete -c zvm -n "__fish_seen_subcommand_from list-remote" -s a -l all -d "Include unsupported targets"
    \\complete -c zvm -n "__fish_seen_subcommand_from setup shim" -s f -l force -d "Overwrite existing shim"
    \\
;

const powershell_script =
    \\Register-ArgumentCompleter -Native -CommandName zvm -ScriptBlock {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    $cmds = @('install', 'use', 'pin', 'list', 'list-remote', 'current', 'which', 'uninstall', 'setup', 'shim', 'doctor', 'clean', 'config', 'env', 'completions', 'upgrade', 'self-update', 'zls')
    \\    $tokens = $commandAst.CommandElements
    \\    if ($tokens.Count -le 2) {
    \\        $cmds | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -eq 'completions') {
    \\        @('bash', 'zsh', 'fish', 'powershell') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -eq 'env') {
    \\        @('bash', 'zsh', 'fish', 'powershell', '--auto-install', '--editor') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -eq 'zls') {
    \\        @('install', 'update', 'list', 'use', 'which', 'uninstall') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -eq 'config') {
    \\        $opts = if ($tokens.Count -le 3) { @('auto-install', 'exact') } else { @('on', 'off', 'toggle') }
    \\        $opts | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -in @('current', 'doctor', 'list', 'which')) {
    \\        @('--exact') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($tokens[1].Extent.Text -eq 'install') {
    \\        @('master', '--force', '--exact', '--with-zls', '--minisig-key', '--no-minisig') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    }
    \\}
    \\
;

test "Shell.parse and render completions" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(Shell.bash, try Shell.parse("bash"));
    try std.testing.expectEqual(Shell.powershell, try Shell.parse("pwsh"));
    try std.testing.expectError(zvm.errors.CliError.UnsupportedShell, Shell.parse("tcsh"));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try render(&out.writer, .zsh);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "#compdef zvm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--auto-install") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--exact") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "config:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "zls:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--with-zls") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--editor") != null);
}
