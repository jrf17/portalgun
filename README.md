# portalgun

> One installer to build the entire Kali master image — apt env, libraries, ~700 apt tools, ~220 GitHub tools, tools-docs web server, BloodHound, Firefox profile, and the portalgun CLI. Plus a runtime tool that lets you add new entries with one command and have them register everywhere.

## TL;DR

On a fresh Kali, one command does everything:

```bash
sudo ./install.sh
```

Then on the running system, add a new tool with one command:

```bash
sudo portalgun install github https://github.com/akamai/BadSuccessor /opt/tools/windows/exploit
```

That installs it, registers it in `installers/install_github_tools.sh` (so the next clean rebuild includes it), updates the web UI, and symlinks the binary to `/usr/local/bin/` (Linux targets only).

## Web UI

Once `./install.sh` finishes, the tools-docs web server is live on port **1337**:

| URL | What it shows |
|---|---|
| `http://<vm-ip>:1337` | Main tools dashboard (Kali tools docs + config manager) |
| `http://<vm-ip>:1337/portalgun_tools.html` | Live list of everything portalgun has installed (apt + github, filterable, searchable) |
| `http://<vm-ip>:1337/portalgun_wiki.html` | Full portalgun docs — commands, paths, status codes, **default service credentials** (BloodHound, postgres, neo4j) |

The main index has a purple banner at the top with one-click links to the portalgun pages. From any host on the same network: open the IP, click around.

## Quick reference

```bash
sudo portalgun install apt <package>             # apt + register
sudo portalgun install github <url> [dir]        # clone + auto-compile + register
portalgun list [apt|github|all]                  # what's installed
portalgun doctor [--fix-shadows]                 # full diagnostic
portalgun status                                  # registry totals + paths
sudo portalgun sanitize [--yes]                  # prep VM for cloning (DESTRUCTIVE)
portalgun help
```

Full HTML wiki: `http://<vm-ip>:1337/portalgun_wiki.html` (deployed automatically).

## What every `install` does

Five actions in one shot:

1. **Installs the tool** — apt-get install, or git clone + auto-detect compile
2. **Records it in the registry** at `/var/lib/portalgun/registry/<type>/<name>.json`
3. **Appends it to the v1 install scripts** (`Kali_Config/installable_packages.txt` or `install_github_tools.sh`) inside `PORTALGUN_MANAGED_START`/`END` markers, so clean rebuilds include it
4. **Updates the web manifest** at `/opt/tools-docs/portalgun_tools.json` so the dashboard shows it
5. **Symlinks the binary to `/usr/local/bin/`** so it's callable by name from any shell. Linux targets only — `/opt/tools/windows/*` skipped (PE binaries can't run on Linux). Never shadows system commands.

## Install

```bash
cd portalgun
sudo ./install.sh
```

Installs to `/opt/portalgun/`, symlinks `/usr/local/bin/portalgun`, sets up zsh completion, creates `/var/lib/portalgun/registry/` and `/var/log/portalgun/`, deploys `portalgun_tools.html` + `portalgun_wiki.html` to `/opt/tools-docs/`, and enables `portalgun-firstboot.service` for clone identity regeneration.

Also integrated into `Kali_Config/master_setup.sh` as **Phase 10** — a full master rebuild installs portalgun automatically.

## Auto-compile detection

For `install github`, after cloning, portalgun inspects the repo root for these markers (priority order):

| File present | Language | Build command |
|---|---|---|
| `Cargo.toml` | Rust | `cargo build --release` |
| `go.mod` | Go | `go build -o <name> ./...` |
| `pom.xml` | Maven | `mvn -q package -DskipTests` |
| `build.gradle*` | Gradle | `gradle -q build -x test` |
| `CMakeLists.txt` | CMake | `cmake -B build && cmake --build build` |
| `configure` (executable) | Autotools | `./configure && make` |
| `Makefile` | Make | `make` |
| `pyproject.toml` / `setup.py` | Python | `pip install --user .` |
| `*.csproj` / `*.sln` | .NET | `dotnet build -c Release` |
| `package.json` w/ `scripts.build` | Node | `npm ci && npm run build` |
| _none of the above_ | scripts only | no compile, just `chmod +x` |

Missing toolchains auto-install once (`apt install cargo`, `apt install golang`, etc).

**Override:** target dirs under `/opt/tools/windows/` never compile (those tools are for transfer to Windows targets, not local build).

### Build status codes

| status | meaning |
|---|---|
| `ok` | installed and (if compiled) built successfully |
| `source_only` | clone succeeded but no build was attempted/needed |
| `build_failed` | clone OK, build attempted, build failed (see `/var/log/portalgun/build-<tool>.log`) |
| `skipped` | clone OK, build skipped (windows target) |

Build failures never block registration — the tool is still cloned and discoverable.

## doctor

```bash
portalgun doctor                  # diagnose
sudo portalgun doctor --fix-shadows  # remove symlinks that shadow system commands
```

Reports:
- Registry totals (apt + github counts, build_failed list)
- `/opt/tools/` audit: complete / source-only / empty
- PATH symlinks (total, broken, dangerous shadows)
- Services: `tools-server`, `portalgun-firstboot`, `bloodhound`
- Web manifest drift vs registry

## sanitize + clone workflow

> **DESTRUCTIVE.** Confirms with `y` unless `--yes` is passed.

Run on the master VM right before shutdown:

```bash
sudo portalgun sanitize
sudo shutdown -h now
```

Sanitize does:
1. Stop BloodHound containers cleanly
2. Clear bash/zsh history (root + all `/home/*` users)
3. Truncate `/var/log/*` + rotate journal
4. `apt-get clean`
5. Remove `/etc/sudoers.d/temp_install`
6. Clear DHCP leases + NetworkManager state
7. Clear `/tmp` and `/var/tmp`
8. `fstrim -av` + zero free space (qcow2 compresses small)

Then on the hypervisor host:

```bash
sudo qemu-img convert -O qcow2 -c master.qcow2 ~/share/kali-$(date +%F).qcow2
```

When a clone first boots, `portalgun-firstboot.service` regenerates `/etc/machine-id` + `/etc/ssh/ssh_host_*` (so two clones on the same network don't collide), then disables itself.

### What sanitize does NOT remove

These persist into the clone because they're usually what you want shipped:

- BloodHound admin password (in the postgres volume)
- Firefox saved passwords + bookmarks (in the profile)
- portalgun registry
- `/opt/tools/`

⚠️ **Security:** Seed tarballs in `Kali_Config/firefox_seed/` and `bloodhound_seed/` contain real credentials. Do not redistribute the master VM externally without first scrubbing or replacing these.

## Paths

| Path | Purpose |
|---|---|
| `/opt/portalgun/` | the tool itself (bin, lib, web, completion) |
| `/usr/local/bin/portalgun` | symlink for `$PATH` |
| `/var/lib/portalgun/registry/{apt,github}/*.json` | per-tool manifests |
| `/var/log/portalgun/` | apt.log, git.log, build-`<tool>`.log |
| `/opt/tools-docs/portalgun_tools.html` | live tools dashboard |
| `/opt/tools-docs/portalgun_tools.json` | manifest the dashboard reads |
| `/opt/tools-docs/portalgun_wiki.html` | full wiki |
| `/etc/systemd/system/portalgun-firstboot.service` | first-boot hygiene |
| `/var/lib/portalgun/firstboot-done` | sentinel (firstboot already ran) |
| `~/Kali_Config/installable_packages.txt` | v1 apt list (auto-modified) |
| `~/Kali_Config/install_github_tools.sh` | v1 github script (auto-modified) |

Overridable via env: `PORTALGUN_ROOT`, `PORTALGUN_REGISTRY`, `PORTALGUN_LOG_DIR`, `PORTALGUN_TOOLS_BASE`, `PORTALGUN_WEB_DIR`, `PORTALGUN_V1_DIR`.

## Architecture

```
                         ┌─────────────────┐
                         │   portalgun     │
                         │   install ...   │
                         └────────┬────────┘
            ┌────────┬────────────┼────────────┬──────────┐
            │        │            │            │          │
            ▼        ▼            ▼            ▼          ▼
       apt-get   git clone   write JSON   append to    symlink to
       install    + build     to registry  v1 scripts  /usr/local/bin/
                                  │
                                  └────► sync_web.py ───► portalgun_tools.json
                                                              │
                                                              ▼
                                                       browser dashboard
```

## End-to-end workflow

```
┌─────────────────────────────────────────────────────────────┐
│  ONLINE MASTER VM                                            │
│    sudo Kali_Config/master_setup.sh                          │
│      → installs apt env + tools + bloodhound + firefox + portalgun
│    sudo portalgun install github <url> <dir>                 │
│      → installs + registers + appends to scripts + symlinks  │
│    portalgun doctor                                          │
│      → verify everything healthy                             │
│    sudo portalgun sanitize                                   │
│      → strip identity / history / tmp                        │
│    sudo shutdown -h now                                      │
└───────────────────────┬─────────────────────────────────────┘
                        │ qemu-img convert -O qcow2 -c
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  OFFLINE CLONE VMs                                           │
│    First boot → portalgun-firstboot regenerates machine-id   │
│                + ssh host keys, disables itself              │
│    Fully configured environment, no internet needed.         │
└─────────────────────────────────────────────────────────────┘
```

## Repo layout

```
portalgun/
├── README.md                       ← this file
├── install.sh                      ← ONE script — full master image (sudo ./install.sh)
├── installers/                     ← individual phase installers (called by install.sh)
│   ├── install_libraries.sh
│   ├── install_tools.sh            ← reads data/installable_packages.txt
│   ├── install_github_tools.sh     ← ~220 GitHub tools, auto-symlink to /usr/local/bin
│   ├── install_bloodhound_ce.sh    ← Docker, port 1338, seed-restored
│   ├── install_firefox_profile.sh  ← profile from seeds/firefox_seed
│   ├── setup_tools_server.sh       ← Flask web UI on port 1337
│   ├── portalgun_install.sh        ← installs the CLI to /opt/portalgun (called by install.sh as Phase 10)
│   └── update_tools.sh, add_dotfile.sh, ...
├── bin/                            ← portalgun runtime CLI
│   ├── portalgun
│   └── portalgun-firstboot.sh      ← runs once on first boot of each clone
├── lib/                            ← runtime code (sourced by `portalgun` CLI)
│   ├── common.sh, registry.sh, detect.sh
│   ├── install_apt.sh, install_github.sh
│   ├── sync_scripts.sh, sync_github.py, sync_web.sh, sync_web.py
│   └── doctor.sh, sanitize.sh
├── completion/_portalgun           ← zsh completion
├── web/
│   ├── portalgun_tools.html        ← live tool dashboard
│   ├── portalgun_wiki.html         ← full HTML wiki
│   └── portalgun-firstboot.service ← systemd oneshot
├── configs/                        ← zshrc, kitty.conf, tmux.conf, starship.toml, zellij/
├── tmux/                           ← tmux theme presets
├── zellij/                         ← zellij presets
├── dotfiles/                       ← dotfile manifest
├── data/
│   ├── installable_packages.txt    ← ~700 apt packages
│   ├── tools_readme.html           ← web UI homepage
│   └── tools_server.py             ← Flask server
└── seeds/
    ├── bloodhound_seed/            ← postgres + neo4j volume tarballs (~8MB)
    └── firefox_seed/               ← firefox profile tarball (~73MB)
```

### Adding a new install type (e.g. pip, cargo, gem)

1. Create `lib/install_<type>.sh` with a function `install_<type>()` that:
   - Installs the package
   - Calls `registry_write <type> <name> <json>`
   - Calls `sync_apt_to_script` or equivalent (or a new sync function)
   - Calls `sync_web_manifest`
2. Add the dispatch case in `bin/portalgun`:
   ```bash
   <type>) shift; source "$PORTALGUN_LIB/install_<type>.sh"; install_<type> "$@" ;;
   ```
3. Add to zsh completion in `completion/_portalgun`
4. Add a section in this README + `web/portalgun_wiki.html`
5. Test, then `sudo ./install.sh` to redeploy

### Testing locally

```bash
# Build a clean state
sudo ./install.sh
portalgun doctor

# Smoke tests
sudo portalgun install apt nmap
sudo portalgun install github https://github.com/tomnomnom/anew /opt/tools/linux/recon
portalgun list
```

### Useful overrides during dev

```bash
PORTALGUN_REGISTRY=/tmp/pgreg \
PORTALGUN_WEB_DIR=/tmp/pgweb \
PORTALGUN_V1_DIR=/tmp/pgv1 \
portalgun status
```

## Troubleshooting

**Tool not on PATH after install** —
1. Windows target? `/opt/tools/windows/*` is intentionally skipped (PE binaries can't run on Linux).
2. Name collision with system command? portalgun never shadows `/usr/bin/`, `/bin/`, `/usr/sbin/`, `/sbin/`.
3. `portalgun doctor` reports broken + shadow symlinks.

**Build failed for a github tool** — check `/var/log/portalgun/build-<toolname>.log`. Common causes: missing deps (try `apt install build-essential`), Rust crates needing newer rustc (drop `--locked`), old Gopkg projects (need `go mod init`).

**Dangerous shadow detected by doctor** — `sudo portalgun doctor --fix-shadows`.

**GitHub API rate limit during install** — portalgun's three-tier fetch (hardcoded URL → API → release-page scrape) means tier-3 doesn't hit the API, so installs succeed even when rate-limited.

**Registry/manifest drift** — re-run any `portalgun install` to refresh, or manually: `sudo python3 /opt/portalgun/lib/sync_web.py /var/lib/portalgun/registry /opt/tools-docs/portalgun_tools.json`.

## Not implemented (yet)

- `portalgun uninstall <name>` — for now: `rm` the registry JSON + the tool dir + the symlink
- `portalgun update [name]` — re-run `install` to refresh
- `portalgun apply` — replay the entire registry on a fresh Kali
- `pip` / `cargo` / `gem` / `npm` install types — extend `lib/install_<type>.sh`
- Tool removal automation
