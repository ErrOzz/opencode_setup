---
name: routerai-models
description: Add, update, remove and look up RouterAI (routerai.ru) models in the OpenCode config, and guide API key setup. Use this skill whenever the user mentions RouterAI models, wants to add or drop a model, refresh model prices, context sizes or capabilities, compare models by price, or asks how to set or change the RouterAI API key, even if they do not name this skill.
---

# RouterAI models

Keep the RouterAI model entries in the user's OpenCode config correct and up to date. The model list comes from the public RouterAI API (no key needed). A helper script reads it and prints ready-made entries; you edit the config yourself with small, exact edits, because the OpenCode desktop app and CLI also write to the same file.

## Ground rules

- Write all text and comments that go into files in English. Talk to the user in the language they use.
- Never ask the user to paste the API key into the chat. Never print, read, or search for the key: do not open `auth.json`, do not dump environment variables, do not echo config values that may hold it.
- Edit only what the task needs. Leave everything else in the file as it is, including comments, other providers, MCP servers and agents.
- The script never writes files. All config changes are yours, so show the user what you changed.

## The helper script

`scripts/routerai.py` lives in this skill's directory. Run it with `python` (on Windows use `py -3` if `python` is not found). Standard library only.

```
python scripts/routerai.py search <words>        # compact table; add several words to narrow down
python scripts/routerai.py show <id>             # full details incl. cache prices and description
python scripts/routerai.py snippet <id> [<id>]   # ready-to-paste config entries
```

Options for `snippet`: `--output N` (output limit for a new model, default 32000) and `--no-pro`.

Warnings go to stderr. Read them and pass the important ones on to the user (price differences, pro sibling).

Use `search` first when the user gives only a rough name. Pick the exact `id` from the table; do not guess ids.

## Finding the config

1. Look in the user-level OpenCode config directory (`~/.config/opencode/`, on Windows `%USERPROFILE%\.config\opencode\`).
2. Edit the file that already holds the settings, whichever extension it has (`opencode.json` or `opencode.jsonc`). If both exist, use the one that contains the RouterAI provider. Never create a second config file.
3. Find the RouterAI provider block by its base URL (`routerai.ru`), not by its key name, and work inside its `models` object.
4. If no config or no RouterAI provider exists, tell the user and ask how to proceed instead of creating one.

## Add a model

1. `search` to find the id, then `snippet <id>`.
2. If the id is already in the config, treat the request as an update.
3. Insert the entry into the provider's `models` object next to the other entries, matching their indentation and fixing commas.
4. Tell the user the final name, context and whether a `pro` variant was added.

## Update models

1. Read the `models` object and list the ids. Update the ones the user named, or all if they asked for all.
2. Run `snippet` for those ids and compare with the current entries field by field.
3. Update only these fields: `name` (short name and price), `capabilities.tools`, `capabilities.input`, `capabilities.output`, `capabilities.reasoning.supported`, `limit.context`, `compatibility.cacheFormat`. A missing `reasoning` block in the snippet means the same as `"supported": false` in an entry.
4. Never change `limit.output`, `variants`, `capabilities.reasoning.effort` or any key the script does not produce. These are the user's choices: the API reports neither output limits nor effort levels.
5. If a field differs and the entry has a comment that explains the difference (for example audio left out on purpose), keep the entry as is and mention it.
6. If the snippet has a `pro` variant and the entry does not, do not add it silently. Ask first: it changes how the model behaves and what it costs.
7. If an id is not found by the script, the model has left the API. Report it and do not delete it on your own.
8. Finish with a short before/after list: id, what changed.

## Remove a model

1. Delete the whole entry, including the comment lines directly above it, and fix commas.
2. Search the config for the removed id: it may still be used as a default `model`, `small_model` or in an agent. Report such references to the user and do not change them without asking.

## Check the result

Re-read the edited region and confirm the JSON still has balanced braces and correct commas. Run `opencode debug config` for a merge check only if the config holds no key (no `env` list, `apiKey`, `{env:...}`, `{file:...}`); otherwise it may print resolved secrets, so ask the user to run it instead.

## API key

OpenCode stores the key itself as a saved account (it is not in the config and not in an environment variable). Never handle the key yourself: do not read OpenCode's database, do not ask for the key in the chat, do not print it. If the user wants to set or replace it, tell them to run this in their own terminal (the prompt is interactive and hides the input):

```
opencode auth login routerai --method key
```

Use the provider id from the config if it is not `routerai`. To check that a key is saved, ask the user to run `opencode auth list`. If the provider block has an `env` list, a plain-text key or an `{env:...}` reference, say so without printing the value and suggest moving it to the command above.

## What the script cannot know

- The output limit defaults to 32000; the user adjusts it per model.
- Reasoning effort levels are assumed to be low, medium and high when the API lists `reasoning_effort`.
- The `pro` variant is added only when the API list has a model with the same id plus `-pro`. The variant body is fixed in the script (`reasoning.mode = "pro"`). Use `show <id>-pro` to confirm that its description says it is the same model with reasoning pro.
- `file` is added to the input types of every model on purpose, even when the API does not list it. Older entries may still say `pdf`: the first update turns it into `file`, which is intended.
- Models of the `anthropic` vendor get `compatibility.cacheFormat = "anthropic"` (request caching through the gateway). If Claude requests start failing with a cache_control error, remove that line from the entry.
