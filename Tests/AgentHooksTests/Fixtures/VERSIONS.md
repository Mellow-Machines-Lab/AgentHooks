# Hook fixtures

Raw hook payloads, one directory per agent:

- `claude-code/2026-09-08/` and `codex/2026-09-08/`: recorded from Claude
  Code 2.1.263 and Codex CLI 0.153.4 on that day.
- `<agent>/synthetic/`: hand-written sessions in the recorded payloads'
  shape, for cases the recordings don't cover: a Claude permission request
  with its matching `Notification`, approved for a two-minute build, a
  denied Claude subagent that ends with only `SubagentStop` (its payload
  in the shape Claude's hook reference gives, not yet recorded), and
  Codex requests its automatic reviewer handles (resolved inside the 2 s
  grace period) or that wait for a person; and `states.jsonl` for each
  agent, a session through everything that agent's hooks report, with
  `permission_mode`, `SubagentStart` and a resumed `SessionStart`'s
  `source` in the shape Claude's hook reference gives, not yet recorded.

A line `{"wait_ms": N}` moves a replay's clock. `WireTests` walks every
file and checks that only your prompt and the agent's last message reach
the hook line, and only with `--keep-text` (the `PRIVATE_…` markers).

To record a new agent release, point its hooks at a script that appends
each payload (stdin) to a `.jsonl` file, run one short session, and put
the file in a new dated directory before claiming support for it.
