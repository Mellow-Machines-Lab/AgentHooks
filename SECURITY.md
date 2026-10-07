# Security

## Reporting a problem

Please report a vulnerability privately, not in a public issue. Use the
**Report a vulnerability** button on the repository's Security tab:
[open a private report](https://github.com/Mellow-Machines-Lab/AgentHooks/security/advisories/new).
Say what you found, how to reproduce it, and which version or commit you
used. We'll reply there.

## What's in scope

- **The hook client** (`agent-hook`): what it reads from an agent, what
  it keeps, and where it sends it.
- **The installer's edits** to the agents' settings:
  `~/.claude/settings.json`, `~/.codex/hooks.json` and
  `~/.codex/config.toml`.
- **The socket folder**, `~/.agent-hooks/sockets/`, and who can write to
  or listen on it.

## What it never does

agent-hooks only watches. It never approves, denies or blocks anything
an agent does, and it fails open: if the client can't send, or nobody is
listening, it exits cleanly and the agent carries on as if it weren't
there.
