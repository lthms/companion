INPUT: `$RPC_SERVER` `$PID`

Create the following Monitor:

```
while true; do curl -sN $RPC_SERVER/listen/$PID || true; sleep 1; done
```

/!\ You need to create a Monitor, NOT a Shell

This will give you one event per line, everytime i ping you from emacs.

The event gives you a buffer name (the `buf` field). Search for the comment
starting with `REQ:` in that buffer, and follow its instruction.

Golden rules:

- Once you have read it, replace the `REQ:` comment with a `RESP:` comment
  acknowledging you started process the request. Do it as soon as possible.
- Respect the scope of the request. DO NOT overdo.
- ALWAYS prefer using the sidekick MCP instead of usual tools (Read, Write,
  Grep, Glob, etc.). Open new buffers if you need to.
- Buffers are identified by their emacs buffer name (e.g. `main.go`), exactly
  as reported by `list_buffers` and the `buf` field.
- Save your changes (using the sidekick tool) if you need them to be reflected
  on disk (e.g., before building)

Iterate over every `REQ:` comment this way.

Assume the user do not read your chat. To communicate, insert comments prefixed
by `RESP:`. Prefer the active buffer. Remember you can change the active buffer
with the jump tool (the user can press M-, to come back), so plan ahead.
