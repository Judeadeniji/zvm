# Visual Studio Code + zvm

Use the `zvm` ZLS shim so VS Code automatically uses the ZLS build matching each project's active Zig version.

## 1. Install ZLS and create the shim

```bash
zvm setup
zvm zls install
```

## 2. Configure the Zig Language extension

Generate the snippet:

```bash
zvm env --editor vscode
```

Add it to `.vscode/settings.json` (or your global VS Code `settings.json`):

```json
{
  "zig.zls.path": "~/.zvm/bin/zls"
}
```

> On Windows, use `%LOCALAPPDATA%\zvm\bin\zls.exe` (printed automatically by `zvm env --editor vscode`).
