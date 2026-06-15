# p3ta-tricks offline knowledge service

Portalgun installs [`p3ta00/p3ta-tricks-offline`](https://github.com/p3ta00/p3ta-tricks-offline) as a first-class local knowledge service. The upstream application aggregates searchable offensive-security references and is designed to function without an internet connection after installation.

## Default deployment

| Setting | Default |
|---|---|
| Application root | `/opt/portalgun/p3ta-tricks-offline/source` |
| Python environment | `/opt/portalgun/p3ta-tricks-offline/venv` |
| Service | `portalgun-p3ta-tricks.service` |
| Service account | `portalgun-p3ta` |
| Bind address | `0.0.0.0` |
| Port | `1339` |
| Tool inventory | `/opt/tools` |
| Registry record | `/var/lib/portalgun/registry/knowledge/p3ta-tricks-offline.json` |
| Launcher | `/usr/local/bin/p3ta-tricks` |

Open `http://<portalgun-host>:1339/` from the local network. Portalgun uses `http://127.0.0.1:1339/` for local health checks.

## Installation and updates

The full Portalgun installer provisions the service by default. For development or intentionally minimal images, disable it with:

```bash
PORTALGUN_SKIP_P3TA_TRICKS=1 ./install.sh --profile <profile>
```

Install or repair it independently:

```bash
sudo portalgun install p3ta-tricks
```

Fetch the configured upstream ref again and atomically replace the current deployment:

```bash
sudo portalgun update p3ta-tricks
```

The requested upstream ref defaults to `main` and can be overridden:

```bash
sudo env PORTALGUN_P3TA_TRICKS_REF=<tag-or-commit> \
  portalgun install p3ta-tricks
```

Every successful deployment records the exact resolved Git commit and processed-page count. Pinning a reviewed commit through `PORTALGUN_P3TA_TRICKS_REF` provides fully reproducible source selection.

## Service controls

```bash
p3ta-tricks status
p3ta-tricks url
p3ta-tricks restart
```

The `start`, `stop`, and `restart` actions use `sudo systemctl`. Direct systemd controls also work:

```bash
sudo systemctl restart portalgun-p3ta-tricks.service
journalctl -u portalgun-p3ta-tricks.service
```

## Verification

```bash
sudo portalgun verify
```

The offline-knowledge verification checks:

- Required upstream files and content directories
- Minimum processed-page count
- Symbolic-link containment
- Isolated Gunicorn environment
- Enabled and active systemd service
- HTTP response content
- Registry provenance and offline-mode state

A direct component-level verifier is also available to sourced maintenance scripts:

```bash
sudo bash -c 'source /opt/portalgun/lib/install_p3ta_tricks.sh; verify_p3ta_tricks'
```

## Deployment safety

Portalgun does not run the upstream `install.sh`. Instead it:

1. Clones the requested ref into a temporary staging directory.
2. Validates required content and rejects escaping symbolic links or unsupported filesystem entries.
3. Creates a dedicated Python virtual environment.
4. Records the exact resolved commit, dependency inventory, and page count.
5. Stops the existing service only after staging succeeds.
6. Atomically activates the staged tree.
7. Restarts the hardened systemd service and performs an HTTP health check.
8. Restores the previous tree, unit, and launcher if activation fails.

The systemd unit runs without Linux capabilities and uses `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, private temporary/device namespaces, and kernel/control-group protections.

## Air-gapped operation

The repository includes its processed content and local static assets. The Python dependencies still have to be available during initial provisioning. If the upstream checkout contains a populated `vendor/` wheel directory, Portalgun automatically installs from that directory with `--no-index`. This supports a completely disconnected build when the repository and its dependency wheelhouse are preseeded.
