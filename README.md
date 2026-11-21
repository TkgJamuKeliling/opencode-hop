# opencode-hop

An [opencode](https://github.com/anomalyco/opencode) build that swaps the outbound connection
automatically whenever the free tier rejects a request. No account juggling, no model
switching, no VPN of your own.

Single binary: `opencode-hop`.

Unofficial build. Not made by, endorsed by, or affiliated with the
[OpenCode](https://github.com/anomalyco/opencode) team; see [NOTICE](NOTICE).

## What to expect

You keep using the same account, the same TUI, and the same free models. When a request is
refused because the free-tier quota is used up, the binary transparently reconnects over a
different outbound address and continues the request. Nothing else on the machine changes
its connection.

- The screen shows `Rotating network, please wait...` while it reconnects, then the line
  disappears on its own once the request is on its way again.
- While quota is still available nothing happens at all — this only triggers after a real
  refusal, and there is no setting to turn it on or off.
- Per request it tries at most 6 reconnects, each looking for up to 4 fresh addresses.
  Addresses that were refused are skipped for the next 24 hours.
- If no fresh address could be found, a single warning line says so before the retry
  continues, so a run that keeps hitting the limit says why instead of looking stuck.
- Extra egress sources can be added with `OPENCODE_WARP_PROXIES` (HTTP proxies) and
  `OPENCODE_WARP_SOCKS` (SOCKS5, typically a local Tor). They are used only after every
  WARP reconnect failed, and a source that just failed is benched for ten minutes.
- If every address is exhausted, the request stops with the usual quota message: wait for
  the daily reset, or switch provider.

## Install

Two ways: run the installer script, or do the five steps by hand. The script is the
recommended path because it also handles the 9router marker and a running service.

### Automatic install (recommended)

macOS and Linux:

```bash
curl -fsSL https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh
```

If `curl` is not installed, use `wget`:

```bash
wget -qO- https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh
```

Windows (PowerShell):

```powershell
$p = "$env:TEMP\opencode-hop-install.cmd"
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.cmd" -OutFile $p
Unblock-File $p
& $p
```

The installer:

- picks the asset for this machine (macOS and Linux on arm64 or x64, Windows on x64 or
  ARM64), and refuses a mismatched or musl build with a specific message;
- downloads the asset and `SHA256SUMS`, verifies the checksum, and checks the binary
  header before installing;
- installs to `~/.local/bin/opencode-hop` or `%USERPROFILE%\bin\opencode-hop.exe`;
- adds that folder to your `PATH` when needed;
- stops a running service before replacing the binary, then starts it again;
- creates `~/.config/opencode/opencode.json` (two bytes, `{}`) when no stock `opencode`
  is visible, so 9router can find this install; an existing file is never touched;
- prints the installed version.

Options:

```bash
# pin a release
curl -fsSL https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh -s -- --tag v2.3.4

# report what would happen, without changing anything
curl -fsSL https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh -s -- --check

# print the plan, without changing anything
curl -fsSL https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh -s -- --dry-run
```

Windows:

```powershell
& $p --tag v2.3.4
& $p --check
& $p --dry-run
```

The installer needs `curl` or `wget` on macOS and Linux, and PowerShell 5.1 on Windows.
It never installs stock `opencode`.

### Manual install

Five steps: download the right file, verify it, install it, put it on your `PATH`, and run it.

#### Step 1 — Download

Open the [latest release](https://github.com/TkgJamuKeliling/opencode-hop/releases/latest)
and download the file that matches your machine, plus `SHA256SUMS`.

| Asset | Machine | Check yours with |
|---|---|---|
| `opencode-hop-darwin-arm64` | macOS, Apple Silicon (M1/M2/M3/M4) | `uname -sm` → `Darwin arm64` |
| `opencode-hop-darwin-x64` | macOS, Intel | `uname -sm` → `Darwin x86_64` |
| `opencode-hop-linux-x64` | Linux, x86_64 | `uname -sm` → `Linux x86_64` |
| `opencode-hop-linux-arm64` | Linux, ARM64 | `uname -sm` → `Linux aarch64` |
| `opencode-hop-windows-x64.exe` | Windows, x86_64 | `$env:PROCESSOR_ARCHITECTURE` → `AMD64` |
| `opencode-hop-windows-arm64.exe` | Windows, ARM64 | `$env:PROCESSOR_ARCHITECTURE` → `ARM64` |

Still unsure on macOS? `uname -m` prints `arm64` on Apple Silicon and `x86_64` on Intel.

#### Step 2 — Verify the download

Put `SHA256SUMS` next to the file you downloaded, then run the check from that folder:

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS --ignore-missing      # Linux: sha256sum -c SHA256SUMS
```

Expected output is one line, `opencode-hop-darwin-arm64: OK`. Anything else means the
download is incomplete — get it again. `--ignore-missing` only skips the other platforms'
entries, it does not skip yours.

#### Step 3 — Install the file

Pick your platform. The same commands work for every asset name; only the file name
changes.

macOS and Linux:

```bash
mkdir -p ~/.local/bin
mv ~/Downloads/opencode-hop-darwin-arm64 ~/.local/bin/opencode-hop
chmod +x ~/.local/bin/opencode-hop
```

macOS only: the first run may be blocked by Gatekeeper, because this binary is not signed
with a paid Apple certificate. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine ~/.local/bin/opencode-hop
```

Prefer the mouse? Try to open it once, then go to **System Settings → Privacy &
Security**, scroll down, and click **Open Anyway** next to the blocked-item notice. The
same applies to any file you downloaded again later: the flag travels with the file.

Windows (PowerShell, current user only, no administrator rights):

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\bin" | Out-Null
Move-Item "$env:USERPROFILE\Downloads\opencode-hop-windows-x64.exe" `
          "$env:USERPROFILE\bin\opencode-hop.exe"
Unblock-File "$env:USERPROFILE\bin\opencode-hop.exe"
```

#### Step 4 — Make it callable from anywhere

Add the folder to `PATH` once, in your shell config. No `sudo`, and it survives reboots:

```bash
# zsh (default on macOS)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# bash on Linux
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# fish (either OS)
fish_add_path ~/.local/bin
```

For every user on the machine, link it where the system already looks instead:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -sf "$HOME/.local/bin/opencode-hop" /usr/local/bin/opencode-hop
```

A symlink keeps working after an upgrade, because it points at the path, not at the old file.

Windows:

```powershell
setx PATH "$env:USERPROFILE\bin;$env:Path"     # future sessions
$env:Path = "$env:USERPROFILE\bin;$env:Path"   # this session
```

#### Step 5 — Check it works

```bash
which opencode-hop        # -> /home/<you>/.local/bin/opencode-hop
opencode-hop --version    # -> opencode v2.3.2
cd / && opencode-hop run "say ok"
```

`which` printing a path inside your home folder is the proof it is global for your shell.
Command not found means the shell config from step 4 has not been reloaded, or the wrong
file was added there.

Windows:

```powershell
where.exe opencode-hop
opencode-hop --version
```

Notes for Windows:

- The ARM64 build uses the x64 companion binary, since that is the only build published
  upstream. Windows emulates it transparently.
- There is no `chmod` step on Windows.
- A running `.exe` cannot be overwritten, so stop the service before replacing the binary:
  `opencode-hop service stop`, replace the file, then `opencode-hop service start`.

#### If something goes wrong

| What you see | Why | Fix |
|---|---|---|
| "cannot be opened because Apple cannot check it for malicious software" | macOS quarantine on a downloaded, unsigned file | step 3: `xattr -dr com.apple.quarantine <file>`, or **Open Anyway** in Privacy & Security |
| `killed: 9`, or `rc=137` with no output | binary replaced while a process was still using it, or the wrong architecture | `rm` the file first, then copy; check `uname -m` against step 1 |
| `command not found: opencode-hop` | folder not on `PATH`, or shell not reloaded | step 4, then open a new terminal |
| checksum mismatch | incomplete download | download the file again |
| `Free usage limit reached` and the line about reconnecting loops | a system-wide VPN is already active, so reconnects keep landing on the same network | disconnect that VPN while using this build |
| a leftover helper process from a crashed reconnect | nothing frees it while the service holds it | `opencode-hop service restart` |

From here the examples just say `opencode-hop`.

#### Keeping it global after an upgrade

The automatic installer is also the upgrade path: run the same command again. It stops the
service, replaces the binary, and starts it again. The manual steps below do the same by
hand.

Replace the target file in place, so every shell and any symlink keeps resolving to it.

macOS / Linux:

```bash
rm -f ~/.local/bin/opencode-hop
cp <new-binary> ~/.local/bin/opencode-hop
chmod +x ~/.local/bin/opencode-hop
opencode-hop service restart
```

Windows:

```powershell
opencode-hop service stop
Remove-Item "$env:USERPROFILE\bin\opencode-hop.exe"
Copy-Item .\opencode-hop.exe "$env:USERPROFILE\bin\opencode-hop.exe"
opencode-hop service start
```

Remove first on macOS and Linux too: `cp -f` over a file a live process is using makes
macOS kill the new binary with `rc=137`, and every command then exits without printing
anything.

## Usage

Start the TUI:

```bash
opencode-hop
```

One-shot, no TUI:

```bash
opencode-hop run "explain what this repository does"
opencode-hop run --model opencode/deepseek-v4.1-flash-free "say ok"
```

Background service (the TUI uses it; without it the TUI starts one itself):

```bash
opencode-hop service status
opencode-hop service start
opencode-hop service stop
opencode-hop service restart
```

After replacing the binary with a newer build, run `service restart` once — the running
process keeps the code it already loaded in memory.

## Running next to a stock install

This build keeps its own slots, so it can run alongside an installed
[opencode](https://github.com/anomalyco/opencode):

| | owned by this binary |
|---|---|
| service registration | `~/.local/state/opencode/service-hop.json` |
| port | `127.0.0.1:20672` |
| session database | `~/.local/share/opencode/opencode-hop.db` |
| config, plugins, models | `~/.config/opencode` (shared) |

Session history stays separate; config and API keys are the same for both.

## 9router

[9router](https://github.com/decolua/9router) serves an OpenAI-compatible endpoint and writes the
opencode provider block into `~/.config/opencode/opencode.json`. Both builds read that file, so
there is nothing to connect twice:

| your machine | what to do |
|---|---|
| a stock opencode is already connected to 9router | nothing — this build sees the `9router/*` models on its next start |
| no opencode installed at all | the automatic installer does step 1 for you; manual steps below |

9router looks for the `opencode` name on the PATH of its own process, and falls back to the
existence of `~/.config/opencode/opencode.json`. With only this build installed neither is true,
so the CLI Tools page reports **not installed** even though the connection itself is fine. Give it
the config file:

1. If `~/.config/opencode/opencode.json` does not exist, create it with the two bytes `{}`.
2. Refresh the 9router dashboard, then CLI Tools → OpenCode. The status becomes **Not Configured**.
3. Pick the models and press Apply. The status becomes **Connected**, and the provider block is
   written into the file from step 1.
4. Restart this build. The models are listed as `9router/<model>`.

Notes:

- The automatic installer creates this marker when it cannot find a stock `opencode`. If the
  file already exists, it leaves it alone.
- Step 1 is a marker only: at that point 9router checks that the file exists and does not read it.
  The real content arrives with Apply.
- Use real model IDs. The `provider/model-id` in 9router's manual snippet is a placeholder, and a
  `model` pointing at it does not resolve.
- Apply also sets the top-level `model` and `agent.explorer` to the 9router model. Back the file up
  first if it already holds a config you want to keep.
- `options.baseURL` is whatever the dashboard reports. On the same machine
  `http://127.0.0.1:20128/v1` answers faster than the tunnel URL and survives a tunnel restart.
- Installing stock opencode later changes nothing: it reads the same file, and 9router's check then
  resolves to the stock binary. The two keep their own service, port and session database.
- Prefer a real binary over the empty file? Put an `opencode` symlink where 9router looks, for
  example `/usr/local/bin/opencode` → this binary, and skip step 1. Both names then run the same
  program; the channel baked into the build does not change.

## Logs and settings

Every rotation trace lives in `~/.local/share/opencode/tjk-warp/`:

```
warp.log          rotated / hop failed / cooldown entries
warp-device.json  saved device
warp-burned.json  refused addresses (expire after 24 hours)
wireproxy         companion binary, fetched on the first rotation
```

Watch it live:

```bash
tail -f ~/.local/share/opencode/tjk-warp/warp.log
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OPENCODE_WARP_HOME` | `~/.local/share/opencode/tjk-warp` | where logs, device and companion binary live |
| `OPENCODE_WARP_HOSTS` | `opencode.ai` | hosts routed through the tunnel, comma separated |
| `OPENCODE_WARP_PROXY` | `$OPENCODE_WARP_HOME/wireproxy` | reuse a companion binary already on the machine |
| `OPENCODE_WARP_PROXIES` | none | HTTP proxies tried after every WARP reconnect fails, comma separated |
| `OPENCODE_WARP_SOCKS` | none | SOCKS5 endpoints (`host:port`) for the same role; a local Tor works directly |

The first rotation needs internet access once to fetch the companion binary; it is cached
after that. If downloads are blocked on your machine, put one in place yourself and point
`OPENCODE_WARP_PROXY` at it.

## License

MIT, inherited from the [upstream project](https://github.com/anomalyco/opencode).
`LICENSE` must travel with any binary taken from here, and `NOTICE` lists third-party
components and the non-affiliation statement. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Folder contents

```
README.md    this file
LICENSE      MIT license of the upstream project plus this distribution
NOTICE       non-affiliation and third-party notices
install.sh   automatic installer for macOS and Linux
install.cmd  Windows entry point
install.ps1  Windows installer used by install.cmd
.gitignore   ignores everything else; releases carry the binaries
```

The binary is not stored in this repository. GitHub rejects files over 100 MB and this one
is close to 200 MB, so each build is attached to a release instead. The automatic installer
fetches the asset for you; the manual section starts at the Releases page.
