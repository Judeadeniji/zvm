# Neovim + zvm

Point `nvim-lspconfig` at `~/.zvm/bin/zls` so Neovim automatically launches the ZLS build paired to your project's Zig version.

## 1. Install ZLS and create the shim

```bash
zvm setup
zvm zls install
```

## 2. Configure `nvim-lspconfig`

Generate the snippet:

```bash
zvm env --editor nvim
```

Add to your Neovim config (`init.lua`):

```lua
require("lspconfig").zls.setup({
  cmd = { vim.fn.expand("~/.zvm/bin/zls") },
})
```

*(If `~/.zvm/bin` is already first in your `PATH`, `require("lspconfig").zls.setup({})` also picks it up automatically.)*
