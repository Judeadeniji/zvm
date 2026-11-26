# Zed + zvm

Point Zed's `zls` binary path at `~/.zvm/bin/zls`.

## 1. Install ZLS and create the shim

```bash
zvm setup
zvm zls install
```

## 2. Configure `~/.config/zed/settings.json`

Generate the snippet:

```bash
zvm env --editor zed
```

Add to `~/.config/zed/settings.json`:

```json
{
  "lsp": {
    "zls": {
      "binary": {
        "path": "~/.zvm/bin/zls"
      }
    }
  }
}
```

*(Use the exact expanded path printed by `zvm env --editor zed`.)*
