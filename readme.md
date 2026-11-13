# OpenCode Setup for Windows

[Русская версия](readme.ru.md)

A per-user Windows installer for the OpenCode CLI, RouterAI configuration, global agent instructions, and managed machine-wide security policy.

## Install

Requirements: Windows x64, Windows PowerShell 5.1 or PowerShell 7+, and an internet connection. Administrator approval is needed only when protected machine-wide policy files must be created or updated.

Review the installer before running it. For a local checkout:

```powershell
git clone https://github.com/ErrOzz/opencode_setup.git
Set-Location opencode_setup
.\install.ps1
```

Alternatively, run the installer directly from the repository:

```powershell
irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1 | iex
```

When run from a checkout, the installer uses the files beside `install.ps1`. When run remotely, it downloads them from `-BaseUrl` (which defaults to the `main` branch). For reproducible deployments, pin `-BaseUrl` to a reviewed tag or commit.

## What gets installed

| Component | Destination | Behavior |
| --- | --- | --- |
| OpenCode CLI | `%LOCALAPPDATA%\Programs\opencode\bin` | Installs or updates the latest Windows x64 CLI and adds its folder to the user `PATH`. |
| User configuration | `%USERPROFILE%\.config\opencode\opencode.jsonc` | Created from `opencode-user.jsonc` if missing. |
| Global instructions | `%USERPROFILE%\.config\opencode\AGENTS.md` | Created from this repository's `AGENTS.md` if missing. |
| Managed system policy | `%ProgramData%\opencode\opencode.json` | Deployed from `opencode-system.jsonc`; updated only when missing or changed. |
| Local policy additions | `%ProgramData%\opencode\opencode.jsonc` | Created from `opencode-system-local.jsonc` if missing and preserved on subsequent runs. The template allows access to the installing user's `%TEMP%\opencode` directory. Edit the deployed file with administrator rights for machine-specific changes. |

The installer asks for `ROUTERAI_API_KEY` only when it is not already set. The key is read from the environment and is not stored in the user configuration file.

## Updating

Run the installer again to update the CLI and managed system policy. Existing user configuration and `AGENTS.md` are preserved by default.

To replace those two files with the repository versions, first make sure your customizations are backed up, then run:

```powershell
.\install.ps1 -UpdateConfig
```

To update directly from the repository without cloning it, copy and run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1))) -UpdateConfig
```

Timestamped `.bak` copies are created before either existing file is replaced. Local policy additions in `%ProgramData%\opencode\opencode.jsonc` are never overwritten.

Options:

- `-UpdateConfig` — replace the existing user configuration and global instructions, keeping timestamped backups.
- `-SkipSystemPolicy` — skip all changes to `%ProgramData%\opencode`; CLI and per-user setup still run.
- `-BaseUrl <url>` — use a different raw repository URL as the source for configuration files.

## Security model

The system policy is protected from modification by ordinary user processes and takes priority over project-level configuration. Machine-specific exceptions belong in the separate local additions file, which is loaded after the managed policy.

This policy is not a sandbox: OpenCode runs with the permissions of your Windows account. Review policy changes and approve command execution carefully.

To inspect the effective OpenCode configuration, run:

```powershell
opencode debug config
```
