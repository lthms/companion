---
model: claude-haiku-4-5-20251001
---
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
- Do NOT process the request inline. You (the dispatcher) read the `REQ:`,
  write the `RESP:` ack, then delegate the actual work to a background `worker`
  subagent (Agent tool, `run_in_background: true`). Give the worker the context
  it needs — the buffer name, the request text, and where it lives — since it
  will NOT re-read the REQ or write the ack. This keeps the dispatcher free to
  answer the next ping immediately.
- Choose the worker's model yourself, per task: pass a cheap model (e.g. Haiku)
  via the Agent `model` override for trivial edits, and a heavier one (Sonnet/Opus)
  for complex work.

Iterate over every `REQ:` comment this way.

Assume the user do not read your chat. To communicate, insert comments prefixed
by `RESP:`. Prefer the active buffer. Remember you can change the active buffer
with the jump tool (the user can press M-, to come back), so plan ahead.
