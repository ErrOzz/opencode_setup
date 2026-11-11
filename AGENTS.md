# Global rules

## Inspecting files
- Use built-in tools first: `grep` to locate lines, `read` with `offset` and `limit` for just the block you need. Use MCP tools when the project provides them. Do not read whole large files.
- Do not write inline Python or PowerShell to inspect files. If the logic needs more than one short command, write a script file to `.scratch/` in the project and run it with a short command (for example `python .scratch/check.py`).

## Shell commands
- Before any shell command, and before running a Python script in `.scratch/`, give one short explanation in this format: `<operation icon> <path> — <scope icon> <scope> — <purpose>`.
- Operation icon: 🟢 read, 🟡 create or modify, 🔴 delete. Scope icon: 🟩 inside the project, 🟨 OpenCode temporary/config/data folders outside the project, 🟥 any other path outside the project. Classify every touched path; if a command has different operations or scopes, mention each briefly.
- Keep commands short, one purpose each. Do not chain unrelated steps or hide logic in long one-liners.
- Never access paths outside the project without saying so first.