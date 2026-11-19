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
- Per request it tries at most 6 reconnects, each looking for up to 8 fresh addresses.
  Addresses that were refused are skipped for the next 24 hours.
- If every address is exhausted, the request stops with the usual quota message: wait for
  the daily reset, or switch provider.

## Install

The binary is self-contained: one file, no installer and no package manager. Download it
from the **Releases** page of this repository, pick the asset that matches your OS, then put
it on your `PATH` so it runs from any directory.

Available assets:

| Asset | Machine |
|---|---|
| `opencode-hop-darwin-arm64` | macOS on Apple Silicon |
| `opencode-hop-darwin-x64` | macOS on Intel |
| `opencode-hop-linux-x64` | Linux x86_64 |
| `opencode-hop-linux-arm64` | Linux ARM64 |
| `opencode-hop-windows-x64.exe` | Windows x86_64 |
| `opencode-hop-windows-arm64.exe` | Windows ARM64 |

Each release also ships `SHA256SUMS`. Check the downloaded file before running it:

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
```

### macOS / Linux

```bash
mkdir -p ~/.local/bin
mv ~/Downloads/opencode-hop-darwin-arm64 ~/.local/bin/opencode-hop
chmod +x ~/.local/bin/opencode-hop
```

If macOS refuses to open it because it came from the internet, clear the quarantine flag
once:

```bash
xattr -d com.apple.quarantine ~/.local/bin/opencode-hop
```

Add that folder to `PATH`. No `sudo`, and it survives reboots once it is in your shell
config:

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

Verify:

```bash
which opencode-hop        # -> /home/<you>/.local/bin/opencode-hop
opencode-hop --version    # -> opencode v2.3.2
cd / && opencode-hop run "say ok"
```

`which` printing the path inside your home folder is the proof it is global for your shell.

For every user on the machine, skip the `PATH` edit and link it where the system already
looks:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -sf "$HOME/.local/bin/opencode-hop" /usr/local/bin/opencode-hop
```

A symlink stays valid after an upgrade because it points at the path, not at the old file.

Linux extras: on a musl distro (Alpine) use a `-musl` build; if `/usr/local/bin` is not on
`PATH` for your shell, add it the same way as above instead of using `sudo`.

### Windows

PowerShell, current user only — no administrator rights:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\bin" | Out-Null
Move-Item "$env:USERPROFILE\Downloads\opencode-hop-windows-x64.exe" `
          "$env:USERPROFILE\bin\opencode-hop.exe"

# persist for future sessions
setx PATH "$env:USERPROFILE\bin;$env:Path"

# this session
$env:Path = "$env:USERPROFILE\bin;$env:Path"

where.exe opencode-hop
opencode-hop --version
```

Windows may warn about an unsigned download from the internet. Choose **More info → Run
anyway**, or clear the mark of the web first:

```powershell
Unblock-File "$env:USERPROFILE\bin\opencode-hop.exe"
```

Notes for Windows:

- The ARM64 build uses the x64 companion binary, since that is the only build published
  upstream. Windows emulates it transparently.
- No `chmod` step; it is not needed there.
- A running `.exe` cannot be overwritten, so stop the service before replacing the binary:
  `opencode-hop service stop`, replace the file, then `opencode-hop service start`.

From here the examples just say `opencode-hop`.

### Keeping it global after an upgrade

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

The first rotation needs internet access once to fetch the companion binary; it is cached
after that. If downloads are blocked on your machine, put one in place yourself and point
`OPENCODE_WARP_PROXY` at it.

## License

MIT, inherited from the [upstream project](https://github.com/anomalyco/opencode).
`LICENSE` must travel with any binary taken from here, and `NOTICE` lists third-party
components and the non-affiliation statement. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Folder contents

```
README.md   this file
LICENSE     MIT license of the upstream project plus this distribution
NOTICE      non-affiliation and third-party notices
.gitignore  ignores everything else; releases carry the binaries
```

The binary is not stored in this repository. GitHub rejects files over 100 MB and this one
is close to 200 MB, so each build is attached to a release instead — that is why the install
section starts at the Releases page.