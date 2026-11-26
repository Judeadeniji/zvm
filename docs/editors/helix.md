# Helix + zvm

Point Helix's `zls` language server configuration at `~/.zvm/bin/zls`.

## 1. Install ZLS and create the shim

```bash
zvm setup
zvm zls install
```

## 2. Configure `~/.config/helix/languages.toml`

Generate the snippet:

```bash
zvm env --editor helix
```

Add to `~/.config/helix/languages.toml`:

```toml
[language-server.zls]
command = "~/.zvm/bin/zls"
```

*(Or use the exact expanded path printed by `zvm env --editor helix`.)*
