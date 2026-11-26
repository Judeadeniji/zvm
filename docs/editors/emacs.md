# Emacs + zvm

Configure `eglot` (built into Emacs 29+) or `lsp-mode` to use `~/.zvm/bin/zls`.

## 1. Install ZLS and create the shim

```bash
zvm setup
zvm zls install
```

## 2. Configure Eglot

Generate the snippet:

```bash
zvm env --editor emacs
```

Add to your Emacs init file (`init.el`):

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `(zig-mode ,(expand-file-name "~/.zvm/bin/zls"))))
```
