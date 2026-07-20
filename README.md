# Sidekick

<p align="center"><img src="sophie.png" alt="Turn Claude into your own sidekick" width="300px"></p>

Drive Claude Code from your editor. Sidekick is a small daemon that bridges
your editor and a `claude` session: you keep writing code, leave a request as a
comment, and Claude answers in place.

## Getting Started

```sh
go build -o sidekick .
./sidekick --port 8000   # or SIDEKICK_PORT
```

### Neovim

Install the Neovim plugin provided in this repository. For instance, with
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "lthms/sidekick",
    lazy = false,
    opts = {},
}
```

After leaving a comment starting with `REQ:`, you can use `:SidekickNotify` to
nudge the background Claude session to read it. Sidekick exposes a MCP server
allowing it to interact with your editor (opening, reading, writing buffers,
etc.).

### Emacs

Load the Emacs plugin (see `emacs/sidekick.el`) and run `M-x sidekick-setup`.

After leaving a comment starting with `REQ:`, you can use `M-x sidekick-notify`
to nudge the background Claude session to read it. Sidekick exposes the same
MCP server, plus a few Emacs-native tools (`xref`-based definition/reference
lookup and buffer diagnostics).
