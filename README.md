# ansible-prod-notebook

Ansible configuration for the laptop that administers the production homelab: Zorin OS 18 Core (Ubuntu 24.04 base) with Claude Code installed natively and locked down. It follows the conventions of [ansible-prod-srv](https://github.com/Gu35t09/ansible-prod-srv); the design decisions are in [homelab-prod](https://github.com/Gu35t09/homelab-prod).

The laptop is part of production: it runs the server playbook and its YubiKey is the way in as root. The priorities are the same as for the server: privacy, security, simplicity.

## Two users

| User | Groups | What runs there |
| --- | --- | --- |
| `v` | none (no sudo) | Everyday work: browser, documents, Claude Code. Working copies of the repositories; you review and push to GitHub. |
| `v-admin` | `sudo` | This playbook and the server playbook, from copies pulled from GitHub after the merge. SSH to prod-srv-01 with the YubiKey, the vault password typed at every run. |

Claude Code never shares an account with anything that can become root, on the laptop or on the server: the wrapper refuses to start for members of `sudo`, `admin`, `wheel` or `adm`.

**Elevating**: switch to `v-admin` from the login screen (system menu → *Switch User*), never with `su` or `sudo -iu` in a terminal of `v`. A password typed in the session of `v` can be caught by anything that runs there (an alias in `~/.bashrc` is enough), and the YubiKey is given by udev to the user of the active session only, so FIDO2 SSH does not work through `su` anyway. For a single system task from `v` (installing an app, updates in *Software*), GNOME's authentication window asks for the password of `v-admin`: it is drawn by the shell, not by a terminal of `v`.

Day to day: Claude writes in `v`, you review and push the branch; after the merge, *Switch User* to `v-admin`, `git pull`, run the playbook.

## Layout

```text
.
├── ansible.cfg
├── site.yml                          # the only playbook; areas are selected by tag
├── inventory/
│   ├── hosts.ini                     # the laptop itself (connection local)
│   └── group_vars/laptops/
│       ├── main.yml                  # site settings: the two users, notifications
│       ├── vault.yml                 # secrets, encrypted, never committed (from the example)
│       └── vault.yml.example
├── roles/                            # in the order site.yml runs them
│   ├── notify/                       # Telegram helper and Uptime Kuma push calls (a dependency)
│   ├── base/                         # packages, unattended-upgrades and its Telegram report, journal
│   ├── users/                        # the everyday user without sudo, private homes
│   ├── privacy/                      # census, crash reports, snapd, connectivity check
│   ├── hardening/                    # nftables inbound deny, sysctl, no sshd
│   ├── claude_code/                  # signed pinned binary, wrapper, managed settings, sandbox
│   ├── clamav/                       # daemon, daily scan, quarantine
│   ├── monitoring/                   # SMART and disk space alerts
│   ├── integrity/                    # NTP, no sshd, unpackaged libraries, Ebury, admins
│   └── yara/                         # vendored YARA rules and daily scan
├── scripts/bootstrap.sh              # Ansible in a venv on a fresh install
├── scripts/update-yara-rules.sh      # refreshes the vendored YARA rules
├── .githooks/pre-commit              # refuses an unencrypted vault.yml
├── docs/
│   ├── walkthrough.md                # every task: what it does, why, how to check it
│   └── maintenance.md                # calendar, procedures, troubleshooting, recovery
└── verify.md                         # commands to check each part
```

Still to come: `desktop` (the Zorin layout, once chosen on the test VM), `apps` (Flatpak from Flathub), `security_keys` (YubiKey, SSH to prod-srv-01).

The YARA rules are in `roles/yara/files/rules` (Elastic License 2.0 and BSD 2-Clause, see `SOURCES.md` there); the rest of the repository is under the AGPL-3.0 in `LICENSE`.

## Roles

| Role | What it does |
| --- | --- |
| `notify` | `/usr/local/sbin/notify-telegram` (the same bot and chat as the server; the token only in `/etc/homelab/notify.env`, root 0600) and `notify-push`, called by systemd when each job ends to tell its Uptime Kuma push monitor. Every message names the laptop (`💻 Laptop`). |
| `base` | Base packages; unattended-upgrades every day for Ubuntu's security and update pockets, never rebooting; needrestart restarts services; a Telegram message after every unattended-upgrades run (upgraded, nothing to install, errors, reboot needed) and when the package lists fail; journal capped at 500 MB. |
| `users` | Creates `v` with no supplementary group and checks that it has no sudo, admin, adm or lpadmin and that `sudo -l` grants it nothing; checks that `v-admin` is in `sudo`; homes in mode 0700. The password of `v` is set by hand once (`sudo passwd v`). |
| `privacy` | Purges `zorin-os-census`, apport, whoopsie, kerneloops, ubuntu-report, popularity-contest and snapd, and pins them at priority -10 so they never come back. Turns off the login news (motd-news) and NetworkManager's connectivity check (captive portals then need an `http://` page opened by hand). |
| `hardening` | nftables: inbound denied except replies, loopback and IPv6 neighbour discovery; only its own table is replaced. Kernel and network sysctl hardening. No SSH server. |
| `claude_code` | Claude Code at a pinned version in `/opt/claude-code/<version>`, owned by root: the manifest is checked against Anthropic's release key (fingerprint pinned) and the binary against the signed checksum. `/usr/local/bin/claude` is a wrapper that refuses to start for members of the admin groups, and in `/`, system directories, the home and its hidden folders. `/etc/claude-code/managed-settings.json` (see below). Disables Zorin's AppArmor profile for bwrap, which keeps the sandbox from starting. |
| `clamav` | `clamav-daemon` and `clamav-freshclam`, a daily scan at 12:30 (or at the next boot) of the homes, `/tmp`, `/var/tmp` and `/opt`, caches and Flatpak runtimes left out; quarantine in `/root`; Telegram report. |
| `monitoring` | smartd with self-tests and temperature alerts (skipped on VMs), disk space check of `/` and `/boot` every 15 minutes with one alert per threshold crossing. |
| `integrity` | Every 15 minutes: NTP on and synchronized, no SSH server, no setuid/setgid or ownerless files and no shared object outside the packages in the library directories (how Ebury hides), no `/etc/ld.so.preload`, no Ebury socket, nobody but `v-admin` in `sudo` and nothing granted by sudoers to anyone else. Telegram when the findings change, repeated daily while they last. |
| `yara` | YARA with the same vendored rules as the server (ESET, Elastic). Daily scan at 13:30 (or at the next boot) of binaries, libraries, `/opt`, `/etc`, the homes and temporary directories, plus processes running from temporary places or memory. Reports only. Ubuntu's `yara` is in universe with no security updates, so the scan runs in a systemd sandbox (no network, read-only file system, only the capabilities to read files and process memory); a separate unit sends the report. |

Every timer is `Persistent=true`: a job missed while the laptop was off runs at the next boot, at idle priority.

## Claude Code: what the managed settings enforce

The file is in `/etc/claude-code/`, owned by root: neither the user, nor a project's `.claude/settings.json`, nor Claude itself can change it.

- **Always ask.** No auto mode, no bypass mode. Only the managed rules count (`allowManagedPermissionRulesOnly`): an "always allow" answer or a cloned repository cannot add rules, hooks or MCP servers.
- **Sandbox, failing closed.** Every shell command runs in bubblewrap: it writes only in the working directory and reaches only the allowed domains (`github.com`); anything else is asked. Claude does not start if the sandbox cannot (`failIfUnavailable`) and never retries a command outside it (`allowUnsandboxedCommands: false`).
- **Reads only in the working directory** (`blockReadsOutsideWorkingDirectories`), plus deny rules for the secrets (`~/.ssh`, keyrings, browser profiles, `vault.yml`, `.env`) in case Claude is started in the wrong place.
- **No production.** `ssh`, `ansible-playbook`, `ansible-vault`, `git push`, `sudo` are denied. The prefix rules are a speed bump; the barriers are the sandbox network (no route to the servers), sudo's password and the YubiKey's PIN and touch.
- **No telemetry, error reports, feedback or self-updates.** Updates come only from this repository: change `claude_code_version` and run `--tags claude-code`.

### Why the AppArmor change

Zorin ships `bwrap-userns-restrict-patched` (package `zorin-os-default-settings`): processes started by bwrap lose their capabilities in nested user namespaces, and the Claude Code sandbox fails with `nested userns is capability-restricted`. Flatpak blocks nested namespaces with its own seccomp filter (checked on the test VM: `unshare` fails inside a Flatpak with the profile unloaded), so disabling the profile costs nothing for Flatpak apps. The profile is disabled with a link in `/etc/apparmor.d/disable/`, which package upgrades respect. Unprivileged user namespaces stay allowed, as on Fedora and as Zorin already has it.

### Why not agent-box

[agent-box](https://github.com/morrolinux/agent-box) needs podman 5; Ubuntu 24.04 has podman 4.9, and podman, passt and podman-compose come from universe (passt and podman-compose have had no update since the release). The sandbox of the agent would rest on the least maintained packages of the system.

## First setup

1. Install Zorin OS 18 Core: *Advanced features → LVM and encryption*; decline the census; the user created by the installer is **`v-admin`** (it gets sudo). Log in as `v-admin`.
2. `snap list`: whatever is listed is removed by the `privacy` role.
3. Get the repository and Ansible, as `v-admin`:
   ```bash
   git clone https://github.com/Gu35t09/ansible-prod-notebook ~/Documents/ansible-prod-notebook
   cd ~/Documents/ansible-prod-notebook
   ./scripts/bootstrap.sh
   ```
4. The vault, as `v-admin` (the values are the server's Telegram bot and chat; the Uptime Kuma tokens come in step 7, leave them out for now). Its password can be the same as the server's vault; keep a copy of the file on the emergency secrets key:
   ```bash
   cp inventory/group_vars/laptops/vault.yml.example inventory/group_vars/laptops/vault.yml
   ansible-vault encrypt inventory/group_vars/laptops/vault.yml
   ansible-vault edit inventory/group_vars/laptops/vault.yml
   ```
   `vault.yml` is in `.gitignore`: this repository is public, the file never leaves the laptop and the emergency key. In the working copy of `v`, where commits are made, enable the hook that refuses it unencrypted anyway: `git config core.hooksPath .githooks`.
5. Dry run, then the real run:
   ```bash
   ansible-playbook site.yml -K --ask-vault-pass --check --diff
   ansible-playbook site.yml -K --ask-vault-pass
   ```
   The run creates `v`; set its password: `sudo passwd v`. The first run takes a few minutes: ClamAV downloads its signatures (a few hundred MB) before the daemon can start.
6. Log out, log in as `v`. Claude Code: `cd` into a project and run `claude`; log in with the subscription (the browser opens claude.ai). On claude.ai, *Settings → Privacy*: choose whether conversations may be used to improve the models.
7. Uptime Kuma (at home, `https://health.greyroom.net`): *Add New Monitor*, type **Push**, *Retries* 0, *Heartbeat Interval* **604800** (7 days), one per job. Copy each token (the part of the *Push URL* after `/api/push/`, before `?`) into `vault_uptime_kuma_push_tokens` under the job's name, then, as `v-admin`, `--tags base` (it carries the `notify` role, which writes the calls):

   | Monitor | Job name |
   | --- | --- |
   | Laptop: unattended upgrades | `unattended_upgrades` |
   | Laptop: ClamAV scan | `clamav` |
   | Laptop: YARA scan | `yara` |
   | Laptop: integrity check | `integrity` |
   | Laptop: disk space check | `disk_space` |

   Why 7 days and not 25 hours as on the server: the laptop is often off, and away from home it cannot reach Uptime Kuma (it is on the services VLAN, with no WireGuard). A call that fails is only logged; the jobs send their own failures to Telegram from anywhere. A monitor turns red only when its job has not reported from home for a week.
8. Check everything with [verify.md](verify.md).

## Documentation

[docs/walkthrough.md](docs/walkthrough.md) explains every role task by task: what it does, why, and how to check it.

[docs/maintenance.md](docs/maintenance.md) is the maintenance guide: calendar, running the playbook, what to do for each Telegram notification, routine procedures (updating Claude Code, allowing a domain, elevating to `v-admin`, refreshing the YARA rules), troubleshooting and recovery.

[verify.md](verify.md) lists the commands to check each part.

## Tags

| Command | Use |
| --- | --- |
| `ansible-playbook site.yml -K --ask-vault-pass` | Full configuration, as `v-admin`. Safe to run again. |
| `--tags base,users,privacy,hardening,claude-code,clamav,monitoring,integrity,yara` | One or more areas. `security` = users + hardening + claude-code; `detection` = clamav + integrity + yara. |
| `--check --diff` | Show what would change. Always first, after any change. |
