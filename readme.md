### SYNOPSIS
Installs or updates the OpenCode CLI on Windows and deploys its configuration.

### DESCRIPTION
- Binary + PATH: per-user, no admin rights needed
  (%LOCALAPPDATA%\Programs\opencode\bin, User PATH).
- User config: %USERPROFILE%\.config\opencode\opencode.jsonc
  Created if missing. With -UpdateConfig it is overwritten (a timestamped
  .bak copy is kept).
- System policy: %ProgramData%\opencode\opencode.jsonc
  The only step that needs admin rights. A UAC prompt appears ONLY when
  the file is missing or differs from the repository version. The folder
  is locked down so ordinary users (and agents running as them) can read
  the policy but not change it.
- API key: ROUTERAI_API_KEY is requested only if it is not set yet
  (checked in Process, User and Machine scopes).

Works on Windows PowerShell 5.1 and PowerShell 7+.
Config files are taken from the folder next to this script if it is run
from a file; otherwise they are downloaded from $BaseUrl.

### PARAMETER BaseUrl
Raw URL prefix of the repository folder that holds install.ps1,
opencode-system.jsonc and opencode-user.jsonc. Pin it to a tag or commit.

### PARAMETER UpdateConfig
Overwrite the existing user config (with a backup).

### PARAMETER SkipSystemPolicy
Do not touch %ProgramData%\opencode (no UAC prompt).

### EXAMPLE
    irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1 | iex

### EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1))) -UpdateConfig