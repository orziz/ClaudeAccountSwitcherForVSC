# Claude Account Switcher

> 中文版： [README.zh-CN.md](README.zh-CN.md)

Run multiple Claude accounts on one machine — each in its own isolated VS Code
window, in parallel, without logging in and out. Handy when different projects
use different accounts (work / client / open-source / personal).

There are two complementary tools:

| Tool | What it does | When to use |
|------|--------------|-------------|
| **Environment Launcher** | Each "environment" = its own `CLAUDE_CONFIG_DIR` (own login) + its own VS Code `--user-data-dir`. Open several at once, each on a different account. | You want multiple accounts **running side by side**. |
| **Account Switcher** | Swaps the **default** login in place (Keychain on macOS / file on Windows). One window, switch which account it is. | You want **one** window and just change who's logged in. |

## How it works

Claude Code keys its login off `CLAUDE_CONFIG_DIR`. Point it at a fresh folder
and it's a clean, separate login. Give each environment its own config dir plus
its own VS Code user-data dir (which forces a separate process so the env var
actually isolates), and the accounts never step on each other.

Credential storage differs by OS — this matters a lot:

- **macOS**: the OAuth token lives in the **login Keychain** (`Claude Code-credentials`), *not* in a file.
- **Windows / Linux**: the token is a file at `~/.claude/.credentials.json`.

The tools handle both.

## Requirements

- **macOS**: VS Code installed (the `code` CLI is auto-detected). Everything else
  uses built-in `osascript` (dialogs) and `plutil` / `security` — nothing to install.
- **Windows**: PowerShell + VS Code.

## Usage — macOS

```sh
chmod +x claude-env-launcher.command claude-switch.command   # first time only
```

Then double-click:

- **`claude-env-launcher.command`** — create/open environments.
  - *New environment* → name it → pick a default project (optional) → bind an account:
    - **Live login** — open the window and run `/login` once (recommended; most secure).
    - **Use current account** — copy the currently-logged-in account in.
    - **From a saved profile** — reuse a snapshot.
  - `●` = logged in, `○` = not yet.
  - *Save current account as profile* — snapshot your current login for reuse.
- **`claude-switch.command`** — switch the default account in place.
  - Switching rewrites the Keychain; **restart Claude / open a new VS Code window** to take effect. Already-open sessions are unaffected. macOS may prompt once to allow access — click Allow.

If macOS blocks the file ("Apple cannot verify…"), it's just Gatekeeper quarantine
on a downloaded file, not malware. Clear it with:
`xattr -d com.apple.quarantine claude-env-launcher.command`

## Usage — Windows

Double-click the desktop shortcut or `launch.vbs`. `ClaudeEnvLauncher.ps1` is the
launcher; `claude-switch.ps1` is the in-place switcher. The whole folder is
portable (paths are auto-detected).

## Compliance

This tool uses **only officially supported mechanisms** (`CLAUDE_CONFIG_DIR`, the
OS keychain, the `code` CLI, standard OAuth `/login`). It does not crack, bypass,
or circumvent anything.

Whether *your use* is compliant depends on one thing: **every account must be one
you legitimately own or are authorized to use, each independently
licensed/subscribed.** Used that way (your own paid accounts, for your own work),
it's analogous to running multiple browser profiles — fine.

It is **not** acceptable to use it to multiply free-tier quota, to evade a single
subscription's usage limits with extra accounts, or to share/resell one account
across people. Always check Anthropic's current
[Usage Policy](https://www.anthropic.com/legal/aup) and Terms.

## Security — read this

Account login tokens are **sensitive**. Treat the `envs/`, `profiles/` and
`backups/` folders like passwords:

- **Encrypted profiles (recommended).** When saving a profile you can protect it
  with a passphrase. The token is then stored as `credentials.json.enc`
  (AES-256-CBC, PBKDF2-HMAC-SHA256, 200k iterations — openssl `Salted__` format,
  so a profile encrypts/decrypts interchangeably on macOS and Windows). No
  plaintext token is written; you enter the passphrase when seeding/switching.
  **A lost passphrase is unrecoverable.**
- An **active environment** (`envs/<name>/.credentials.json`) is always plaintext —
  this is unavoidable: `CLAUDE_CONFIG_DIR` reads a credentials *file*, not the
  Keychain. So a token file on disk is inherent to the running multi-account model
  (true on both Windows and macOS). Encryption protects the *saved profiles*, not
  the live env.
- The scripts set `umask 077`, so created files/dirs are **owner-only** (600/700).
- `envs/`, `profiles/`, `backups/` are **git-ignored** — never commit them.
- **Do not** sync these folders to iCloud / OneDrive / Dropbox, and **do not**
  copy the folder to other people or machines.
- To minimize copies, prefer **Live login** per environment, and encrypt any
  profile you do save.
- A leaked token = account takeover. If one leaks, run `/login` again to rotate it.

## Files

| File | Role |
|------|------|
| `claude-env-launcher.command` | macOS environment launcher |
| `claude-switch.command` | macOS in-place account switcher |
| `ClaudeEnvLauncher.ps1` | Windows environment launcher |
| `claude-switch.ps1` | Windows in-place account switcher |
| `launch.vbs` | Windows silent launcher |
| `envs/<name>/` | per-environment config + token (**sensitive**, git-ignored) |
| `profiles/<name>/` | saved account snapshots (**sensitive**, git-ignored) |
