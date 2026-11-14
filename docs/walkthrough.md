# Playbook walkthrough

For day-to-day operations see [maintenance.md](maintenance.md). For check commands see [../verify.md](../verify.md).

This document explains every part of the playbook: what each task does, why it is there, and how to check it. Read it side by side with the code. Task names here match the `name:` fields in the roles, so you can search for them.

Contents:

1. [How a run works](#1-how-a-run-works)
2. [ansible.cfg](#2-ansiblecfg)
3. [Inventory and variables](#3-inventory-and-variables)
4. [Role: base](#4-role-base)
5. [Role: users](#5-role-users)
6. [Role: privacy](#6-role-privacy)
7. [Role: hardening](#7-role-hardening)
8. [Role: claude_code](#8-role-claude_code)
9. [scripts/bootstrap.sh](#9-scriptsbootstrapsh)
10. [Files the playbook creates on the laptop](#10-files-the-playbook-creates-on-the-laptop)
11. [Known limits and points to review](#11-known-limits-and-points-to-review)
12. [How it was tested](#12-how-it-was-tested)

---

## 1. How a run works

### site.yml

There is a single playbook, `site.yml`, with a single play that targets the `laptops` group: the laptop itself, reached with `ansible_connection=local` (no SSH).

1. **Fact gathering** (`gather_facts: true`). Ansible collects the distribution, the release and the rest into `ansible_facts`.
2. **Pre-task "Check that the target runs Zorin OS 18 (Ubuntu 24.04 base)"**. The play stops on anything else: the package names, the AppArmor profile and the APT origins are Zorin's and Ubuntu 24.04's. Ansible reports Zorin as a distribution whose name contains "Zorin" and whose release is `noble`.
3. **Pre-task "Check that the playbook runs as the admin user"**. It compares `$USER` with `laptop_admin_user`. The playbook needs sudo, and only `v-admin` has it; the check gives a clear message instead of a sudo error, and reminds that the admin works in its own session. It is a guard against mistakes, not a security boundary (sudo is the boundary).
4. **Roles**, in order: `base`, `users`, `privacy`, `hardening`, `claude_code`.

The order matters:

- `base` comes first: it refreshes the package lists that the other roles use.
- `users` comes before `claude_code`, which looks for the home of the everyday user.
- `hardening` and `claude_code` both write to `/etc/sysctl.d`; their files have different numbers (90 and 60) and do not overlap.

Both pre-tasks carry the `always` tag, so they also run when you select other tags.

### Tags

| Tag | Roles |
| --- | --- |
| `base` | base |
| `users`, `security` | users |
| `privacy` | privacy |
| `hardening`, `security` | hardening |
| `claude-code`, `security` | claude_code |

There are no `never` tags yet: every role is part of a full run.

### Where variables come from

From lowest to highest priority, as Ansible applies them:

1. `roles/<role>/defaults/main.yml`: every variable a role reads, with a comment on what it does.
2. `inventory/group_vars/laptops/main.yml`: the site settings, today only the two user names.
3. `-e` on the command line, for a one-off test.

There is no `vault.yml` yet: no role needs a secret. The password of `v` is set by hand, Claude Code's login is interactive, and the GitHub credentials stay in the browser and in `v`. When a role needs a secret, it gets a vault and the pre-commit hook of ansible-prod-srv.

### Check mode

`--check --diff` shows what would change without changing it. Three places behave differently in check mode, on purpose:

- the tasks that only **read** (the groups of a user, the fingerprint of the key, `sudo -l`) run anyway (`check_mode: false`), so the checks still check;
- the Claude Code download and verification block is skipped: nothing is downloaded in check mode, so there is nothing to verify;
- on a first run, before `v` exists, the tasks on its home are skipped.

## 2. ansible.cfg

| Setting | Why |
| --- | --- |
| `inventory`, `roles_path` | So that `ansible-playbook site.yml` works from the repository root without options |
| `retry_files_enabled = False` | No `.retry` files in the repository |
| `callback_result_format = yaml` | Readable output |
| `force_handlers = True` | Handlers (reload nftables, restart journald) run even if a later task fails; otherwise a failed run leaves new configuration on disk that the services never load, and the next run sees no change to notify |
| `become = True`, `become_method = sudo` | Every task runs as root through sudo. Run with `-K`: `v-admin` keeps a sudo password |

## 3. Inventory and variables

### inventory/hosts.ini

One host, `notebook`, with `ansible_connection=local`: the playbook runs on the laptop it configures. `ansible_python_interpreter=/usr/bin/python3` makes the modules run with the system Python, which has `python3-apt` (needed by the `apt` module), and not with the Python of the virtual environment where Ansible itself is installed.

### inventory/group_vars/laptops/main.yml

| Variable | Value | Notes |
| --- | --- | --- |
| `laptop_admin_user` | `v-admin` | Created by the installer, in sudo. Runs the playbooks, holds SSH to production |
| `laptop_user` | `v` | Everyday user, no supplementary group. Claude Code runs only here |

## 4. Role: base

Purpose: the common foundation, meaning packages, automatic updates and logs.

**Install the base packages**
Installs `base_packages`:

- `git`, `python3-venv`: the repositories and the Ansible virtual environment (`scripts/bootstrap.sh`);
- `unattended-upgrades`: the daily updates below;
- `needrestart`: finds services still running old libraries after an upgrade;
- `fwupd`: firmware updates from LVFS, offered in GNOME Software and applied by hand.

`cache_valid_time: 3600` skips `apt update` if it ran in the last hour.

**Turn on the daily package list update and unattended upgrades**
Writes `/etc/apt/apt.conf.d/21auto-upgrades-local`. APT reads that directory in alphabetical order, so `21` comes after the stock `20auto-upgrades`: the daily list update and the daily unattended upgrade are on whatever Zorin ships there. `AutocleanInterval "7"` removes downloaded packages once a week.

**Configure what unattended-upgrades installs**
Writes `/etc/apt/apt.conf.d/52unattended-upgrades-local`, read after the stock `50unattended-upgrades`.

- **Origins.** The stock file allows `${distro_id}:${distro_codename}-security`, where `distro_id` comes from `lsb_release -i`. On Zorin that is "Zorin", while the Ubuntu archive's packages have origin "Ubuntu": the stock pattern may match nothing, and no security update would be installed by itself. The role adds the origins by name (`base_unattended_origins`): `origin=Ubuntu,archive=noble-security` and `noble-updates`. The lists add up: whatever the stock file allows still applies.
- **Not included**: Zorin's own repository and the Flatpak apps. Zorin's packages arrive through GNOME Software (with the admin password); Flatpak apps update from GNOME Software too.
- `Automatic-Reboot "false"`: the laptop never reboots by itself. GNOME shows when a reboot is needed.
- `Remove-Unused-Kernel-Packages`, `Remove-New-Unused-Dependencies`: old kernels and the dependencies an upgrade left behind are removed, so `/boot` does not fill up.

Check: `sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'`.

**Let needrestart restart services after upgrades**
`$nrconf{restart} = 'a'` in `/etc/needrestart/conf.d/50-auto.conf`. The interactive default does nothing in an unattended upgrade, so services would keep running old, vulnerable libraries until a reboot. needrestart never restarts the display manager (its default override list), so the desktop session stays up; the kernel is updated only by a reboot.

**Create the journald drop-in directory** / **Cap the persistent journal**
`Storage=persistent` keeps the logs across reboots (useful after a crash or a freeze), `SystemMaxUse=500M` keeps them from filling the disk. The `copy` module does not create parent directories, hence the first task.
Check: `journalctl --disk-usage`.

Handler: **Restart journald** when its drop-in changes.

## 5. Role: users

Purpose: two users with separate roles, so that nothing used every day, Claude Code above all, shares an account with a way to root.

| User | Groups | Role |
| --- | --- | --- |
| `v-admin` | `sudo` (from the installer) | Runs this playbook and the server playbook, holds SSH to prod-srv-01 (YubiKey) and types the vault password |
| `v` | none | Browser, documents, Claude Code, working copies of the repositories |

**Check that the admin user is in sudo**
`id -nG v-admin` must list `sudo`. If someone removed it, the next run could not use sudo at all: stop before touching anything.

**Create the everyday user, without sudo**
`ansible.builtin.user` with `groups: []` and `append: false`: the list of supplementary groups is exclusive, so a group added by hand (`sudo` included) is removed at the next run. The desktop does not need groups for devices: logind gives sound, camera and USB devices (the YubiKey too) to the user of the active session.

The user is created with a locked password; see the last task.

**Read the groups of the everyday user** / **Check that the everyday user has no admin group**
Reads the groups back rather than trusting the previous task, and fails if any of `users_forbidden_groups` is there: `sudo`, `admin` (older Ubuntu name), `adm` (reads the system logs), `lpadmin` (administers printers).

**Check that sudo grants nothing to the everyday user**
`sudo -l -U v` must answer "is not allowed to run sudo". A rule in `/etc/sudoers.d` naming the user directly would not show in its groups: this asks sudo itself.

**Make the homes readable only by their owner**
Mode `0700` on both homes. Ubuntu creates them `0750`: anyone in the user's group could read them. With `0700`, `v` cannot read the SSH configuration and the repositories of `v-admin`, and the reverse.

**Read the password status of the everyday user** / **Remind to set the password of the everyday user**
`passwd --status v` prints `L` (locked) or `NP` (no password) until a password is set. The password never goes in the repository: set it once with `sudo passwd v`, as `v-admin`.

### Why switching users, and not su

A password typed in a terminal of `v` can be caught by anything that runs as `v`: an alias or a function in `~/.bashrc` that wraps `su` or `sudo` is enough, and `v` controls that file. *Switch User* (GDM) opens a separate session, drawn by the display manager. GNOME's authentication window (polkit), used by Software and Settings, is drawn by the shell and asks for the password of an admin, `v-admin`.

The YubiKey adds a practical reason: udev gives the FIDO2 device to the user of the **active session**. Through `su` in a terminal of `v`, `v-admin` would not see it, and SSH with the security key would fail.

## 6. Role: privacy

Purpose: nothing on the laptop reports to Zorin or Canonical by itself.

**Build the list of packages to remove**
`privacy_purge_packages` plus `snapd` when `privacy_remove_snapd` is true.

| Package | What it sends |
| --- | --- |
| `zorin-os-census` | A periodic ping with an installation ID and the OS version |
| `apport`, `apport-gtk`, `whoopsie` | Crash reports to Canonical (`apport-gtk` is the window that offers to send them) |
| `kerneloops` | Kernel oops reports |
| `ubuntu-report` | Hardware and install report at first login |
| `popularity-contest` | Statistics of installed packages |
| `snapd` | The Snap store daemon, which phones home for updates. Apps come from Flathub |

**Purge the reporting packages**
`state: absent` with `purge: true` removes them and their configuration. A package that is not installed is skipped. **Run `--check --diff` first**: if a Zorin metapackage depends on one of them, apt removes it too, and the check shows it.

**Keep them from coming back**
`/etc/apt/preferences.d/90-privacy-blocked` with `Pin-Priority: -10` for every package in the list: APT never installs them, not as a dependency, not as a recommendation, not when Zorin's metapackages are upgraded. To see it: `apt-cache policy snapd` shows the candidate as `(none)`.

**Look for the login news** / **Turn off the news fetched for the login message** / **Mask the news timer**
`motd-news` downloads a message from Canonical twice a day for the terminal login banner (and sends the OS version and some system information in the request). Only some Ubuntu derivatives have it: the role looks for its timer first, then sets `ENABLED=0` and masks the timer.

**Turn off the NetworkManager connectivity check**
NetworkManager fetches a page from Zorin (`connectivity.zorin-os.com`) at every connection and every few minutes, to detect captive portals: it tells Zorin when, and from which address, the laptop is online. `/etc/NetworkManager/conf.d/90-privacy.conf` with `[connectivity] enabled=false` overrides Zorin's own setting. The cost: on a hotel or train Wi-Fi the login page no longer opens by itself; open any `http://` address in the browser (see the maintenance guide).

Handler: **Reload NetworkManager**, which re-reads `conf.d` without dropping the connections.

Not covered yet: the GNOME privacy settings (location services, problem reporting, usage statistics, file history). They are per-user dconf settings and belong to the `desktop` role, to come.

## 7. Role: hardening

Purpose: nothing listens for the network, and the kernel exposes as little as possible.

**Make sure no SSH server is installed**
The laptop is a client: nobody logs in to it over the network. Ubuntu's desktop does not install `openssh-server`; the task makes sure it never appears. The SSH **client** (for prod-srv-01) is a different package and stays.

**Install nftables** / **Write the host firewall** / **Load the firewall at boot**
`/etc/nftables.conf`, validated with `nft -c -f` before it replaces the old file (a syntax error never leaves the laptop without a firewall), loaded at boot by `nftables.service`.

### The ruleset

One table, `inet laptop_filter` (IPv4 and IPv6 together). The file starts with `table inet laptop_filter` and `delete table inet laptop_filter`: it replaces **only this table**, so the tables of other tools (ufw, libvirt, a VPN client) survive a reload. The stock Ubuntu `nftables.conf` starts with `flush ruleset` instead, which would wipe them.

| Chain | Policy | Rules |
| --- | --- | --- |
| `input` | drop | loopback; drop invalid packets; replies to connections the laptop opened (`established,related`, which also covers the ICMP errors of those connections); IPv6 neighbour solicitations and advertisements with hop limit 255 (they can come from global addresses, but a hop limit of 255 proves they come from the local link); router advertisements and multicast listener queries from link-local addresses; DHCPv6 replies to port 546 from link-local addresses |
| `forward` | drop | The laptop does not route |
| `output` | accept | Outbound is free: the privacy role removes what calls home, and Claude Code's sandbox filters its own traffic |

Not allowed in: ping (`echo-request`), mDNS (printer and device discovery on the LAN), KDE/Zorin Connect. Discovery of network printers may need a printer added by address. Open a port only for a service you run on purpose: `hardening_inbound_tcp_ports`, `hardening_inbound_udp_ports`.

DHCPv4 needs no rule: the client uses a raw socket for the first exchange, and the renewals are replies to a connection the laptop opened.

Handler: **Reload nftables**. A reload, never a restart: stopping `nftables.service` runs `nft flush ruleset`, which would drop every table.
Check: `sudo nft list table inet laptop_filter`.

**Write the kernel and network settings**
`/etc/sysctl.d/90-hardening.conf`, applied with `sysctl --system` (handler **Apply sysctl**).

| Setting | Value | Why |
| --- | --- | --- |
| `kernel.kptr_restrict` | 2 | Kernel addresses hidden from everyone: they help exploits |
| `kernel.dmesg_restrict` | 1 | Kernel log only for root |
| `kernel.kexec_load_disabled` | 1 | No loading another kernel at run time (a way to bypass Secure Boot) |
| `kernel.unprivileged_bpf_disabled` | 1 | No eBPF for unprivileged users, permanently until reboot (Ubuntu's default 2 can be changed back by root) |
| `net.core.bpf_jit_harden` | 2 | Hardened BPF JIT for everyone |
| `kernel.yama.ptrace_scope` | 1 | A process can debug only its own children: malware in `v` cannot read the memory of another program of `v` (the browser) |
| `fs.suid_dumpable` | 0 | No core dumps of setuid programs |
| `dev.tty.ldisc_autoload` | 0 | No line discipline modules loaded on demand (an old source of kernel bugs) |
| `fs.protected_symlinks`, `fs.protected_hardlinks` | 1 | Classic `/tmp` link attacks blocked |
| `fs.protected_fifos`, `fs.protected_regular` | 2 | The same for FIFOs and files in world-writable directories |
| `net.ipv4/6...accept_redirects`, `secure_redirects`, `send_redirects` | 0 | ICMP redirects ignored and never sent: on a public Wi-Fi they can reroute traffic |
| `...accept_source_route` | 0 | Source-routed packets ignored |
| `net.ipv4.conf.*.rp_filter` | 1 | Packets with a source address that could not come from that interface are dropped |
| `net.ipv4.tcp_syncookies` | 1 | SYN flood protection |
| `net.ipv4.icmp_echo_ignore_broadcasts` | 1 | No answering broadcast pings |

`kernel.apparmor_restrict_unprivileged_userns` is not here: the `claude_code` role sets it, because it is tied to the bwrap profile it disables.

Check: `sysctl kernel.kptr_restrict kernel.unprivileged_bpf_disabled net.ipv4.conf.all.accept_redirects`.

## 8. Role: claude_code

Purpose: Claude Code runs only as `v`, from a project folder, at a version chosen in this repository, inside a sandbox that fails closed, with rules that nothing in user space can change.

### Sandbox prerequisites

**Install the sandbox tools and gpgv**
`bubblewrap` (the sandbox), `socat` (carries the sandbox's network traffic to Claude Code's filtering proxy), `gpg` and `gpgv` (the release signature). All four are in Ubuntu's `main`, with security support from Canonical.

**Look for Zorin's AppArmor profile for bwrap** / **Disable Zorin's bwrap profile** / **Unload Zorin's bwrap profile now**

The problem, found on the test VM: Claude Code's sandbox starts bubblewrap, and inside it creates a second, nested user namespace to apply a seccomp filter (which blocks Unix sockets: D-Bus, the GNOME keyring, an SSH agent). Zorin ships `/etc/apparmor.d/bwrap-userns-restrict-patched` (package `zorin-os-default-settings`), which moves everything started by `bwrap` into the profile `unpriv_bwrap` and denies it every capability. The nested namespace then cannot be set up, and every command fails with `apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted ...)`; the kernel logs `apparmor="DENIED" operation="capable" profile="unpriv_bwrap" capname="sys_admin"`.

What the profile protects: with `kernel.apparmor_restrict_unprivileged_userns = 0` (Zorin's setting), an ordinary process can create user namespaces anyway. The profile only limits what runs **inside** bwrap: Flatpak apps and the Claude Code sandbox. Flatpak, though, already blocks the creation of user namespaces with its own seccomp filter: on the VM, with the profile unloaded, `unshare -U` inside a Flatpak still fails with "Operation not permitted". Disabling the profile therefore costs nothing for Flatpak apps.

How: a link in `/etc/apparmor.d/disable/` is AppArmor's own mechanism. The package's file stays untouched, and an upgrade of `zorin-os-default-settings` that changes the profile does not turn it back on. The link acts at boot, so the role also unloads the profile now with `apparmor_parser -R` (a profile that is not loaded is not an error). If Zorin renames the file, change `claude_code_bwrap_profile`.

Alternatives considered: a dedicated AppArmor profile for Claude's bwrap (precise, but a policy to write and maintain, fragile across updates); `enableWeakerNestedSandbox` (mounts the host's `/proc` into the sandbox; the documentation says it "considerably weakens security"); `allowNestedUserNamespaces` (lets sandboxed code create namespaces, which the documentation calls a security boundary turned off).

**Keep unprivileged user namespaces allowed**
`/etc/sysctl.d/60-claude-code-sandbox.conf` sets `kernel.apparmor_restrict_unprivileged_userns = 0`. Ubuntu's default is 1, Zorin's 0. With Zorin's profile off, bwrap is unconfined, and at 1 it could not create a namespace at all: neither Flatpak nor the sandbox would work. The file makes the dependency explicit, so a change of Zorin's default does not break them silently. This is the same as on Fedora.

### Signed, pinned binary

The official installer (`curl https://claude.ai/install.sh | bash`) puts the binary in `~/.local/bin` and `~/.local/share/claude`, writable by the user, and updates it by itself. Here instead:

**Create the install directories**
`/opt/claude-code/<version>/` and `/usr/local/share/claude-code/`, owned by root: neither `v` nor Claude can replace the binary.

**Install the release signing key** / **Read the fingerprint of the signing key** / **Check the fingerprint of the signing key**
The key is vendored in the repository (`files/claude-code.asc`, downloaded from `https://downloads.claude.ai/keys/claude-code.asc`), and the role refuses it unless its fingerprint is `claude_code_key_fingerprint`, `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`, the one published in Claude Code's setup documentation. gpg needs a home directory even to show a key: a temporary one, removed at the end.

**Look for the gpgv keyring** / **Convert the key to a keyring for gpgv**
`gpgv` reads a binary keyring, not an armored key: `gpg --dearmor` writes `claude-code.gpg`, again whenever the key file changes.

**Download, verify and install the pinned version** (skipped in check mode)

1. **Download the release manifest and its signature**: `manifest.json` and `manifest.json.sig` from `https://downloads.claude.ai/claude-code-releases/<version>/`.
2. **Verify the manifest signature**: `gpgv` exits with an error on a bad or missing signature, and the play stops.
3. **Read the manifest** / **Parse the manifest** / **Check the manifest version and checksum**: the signed manifest must describe `claude_code_version` (a valid signature on another version's manifest does not pass) and give a SHA-256 for `linux-x64`.
4. **Download the binary and check it against the signed checksum**: from `<version>/linux-x64/claude`, the same URL the official installer uses. `get_url` checks the SHA-256 after the download, and keeps an existing file that already matches, so a second run downloads nothing.

The chain of trust is the vendored key (fingerprint pinned), its signature on the manifest, the manifest's checksum of the binary.

**Install the wrapper as the only claude on the PATH**
`/usr/local/bin/claude` (from `templates/claude-wrapper.sh.j2`), owned by root. Before running the binary it:

- lets `claude --version` (and `-v`) through anywhere: it reads nothing;
- refuses to run for members of `claude_code_refused_groups` (`sudo`, `admin`, `wheel`, `adm`): Claude never runs in an account that can become root or read the system logs;
- refuses to start in `/`, the system directories, the home, a directory that contains the home, a hidden folder of the home, or a directory not owned by the user. Claude reads the whole working directory, and the "read only in the working directory" rule below is only as good as that directory. The same rule as agent-box.

**Find older versions** / **Remove older versions**
After an update only the pinned version stays in `/opt/claude-code`.

### Managed settings

**Create the managed settings directory** / **Write the managed settings**
`/etc/claude-code/managed-settings.json`, root-owned, mode 0644. Claude Code reads it on Linux and gives it precedence over the user's, the project's and the command line's settings. The content is `claude_code_managed_settings` in `defaults/main.yml`; key by key:

| Key | Value | Effect |
| --- | --- | --- |
| `permissions.defaultMode` | `default` | Claude asks before anything not already allowed |
| `permissions.disableAutoMode` | `disable` | No auto mode: a classifier never decides in your place. On the VM, auto mode let Claude retry a failed sandboxed command outside the sandbox and create a file in the home |
| `permissions.disableBypassPermissionsMode` | `disable` | No "skip all permissions" mode |
| `permissions.blockReadsOutsideWorkingDirectories` | `true` | The file tools refuse reads outside the working directory, and sandboxed commands lose read access to the home and the user directories, apart from what Claude Code itself needs |
| `permissions.deny` | list | Secrets (`~/.ssh`, `~/.gnupg`, the GNOME keyring, Flatpak app data with the browser profiles, `~/.mozilla`, the `gh` login, `vault.yml`, vault password files, `.env`); files that run later (`~/.bashrc`, `~/.profile`, autostart, user systemd units, `~/.local/bin`, desktop launchers, `~/.ssh`, Claude's own settings); and commands for production and privileges (`ssh`, `scp`, `sftp`, `ansible`, `ansible-playbook`, `ansible-vault`, `git push`, `sudo`, `su`, `pkexec`). Deny rules for `Read` also apply to the sandbox's file system |
| `allowManagedPermissionRulesOnly` | `true` | Only the rules in this file count: a repository's `.claude/settings.json`, the user's settings and the "always allow" answers cannot add rules. Every prompt is asked again in each session |
| `allowManagedHooksOnly` | `true` | No hooks from a project or the user: a cloned repository cannot run commands at Claude's events |
| `allowManagedMcpServersOnly` | `true` | No MCP servers, since none is defined here |
| `cleanupPeriodDays` | 30 | Transcripts in `~/.claude` are deleted after 30 days |
| `sandbox.enabled` | `true` | Every shell command runs in bubblewrap |
| `sandbox.failIfUnavailable` | `true` | Claude does not start if the sandbox cannot |
| `sandbox.allowUnsandboxedCommands` | `false` | No retry outside the sandbox: a command that fails in it, fails |
| `sandbox.allowNestedUserNamespaces` | `false` | Sandboxed code cannot create namespaces of its own |
| `sandbox.autoAllowBashIfSandboxed` | `true` | Sandboxed commands run without asking: they write only in the working directory and reach only the allowed domains |
| `sandbox.network.allowedDomains` | `github.com` | Reached without asking. Any other domain is asked; with `defaultMode` and no auto mode, the question comes to you |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | No telemetry, error reports, `/feedback`, release notes or feature flags |
| `env.DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` | `1` | The same, explicitly |
| `env.DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` | `1` | No background or manual updates: the version changes only through this role |
| `env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | `1` | No surveys |

Claude's memory (`~/.claude/projects/*/memory`) stays writable: only Claude's settings files are denied for edits.

Where the barriers really are. The `Bash(...)` deny rules match command prefixes, and a determined command can get around a prefix (`bash -c "ssh ..."`). They are a speed bump. The barriers are:

- the sandbox network: a sandboxed command reaches the Internet only through Claude Code's proxy, by domain, so it has no route to the servers' addresses;
- sudo: `v` is not in sudoers, and the sandbox sets `no_new_privs`;
- the YubiKey: SSH to prod-srv-01 asks for its PIN and a touch, and `v` has no SSH configuration for it;
- the file system: the sandbox writes only in the working directory.

### No user-level install

**Find the home of the everyday user** / **Look for a user-level install** / **Refuse a user-level install**
`~/.local/bin` comes before `/usr/local/bin` on the PATH. A `~/.local/bin/claude` left by the official installer would run instead of the wrapper: unpinned, updating itself, with no checks. The play fails with the commands to remove it. `fail_key: false` because, in a first `--check` run, `v` does not exist yet.

## 9. scripts/bootstrap.sh

Run once by `v-admin` on a fresh install, before the first playbook run:

1. refuses to run as root;
2. `apt-get install git python3-venv`;
3. creates `~/.local/share/ansible-venv` and installs `ansible-core==2.20.7` from PyPI;
4. links `ansible`, `ansible-playbook`, `ansible-galaxy`, `ansible-vault`, `ansible-config`, `ansible-doc` into `~/.local/bin`.

Why not Ubuntu's `ansible`: it is in universe and older (2.16) than the version ansible-prod-srv is written and tested with. PyPI is the Ansible project's own channel; the version is pinned. The same virtual environment runs both playbooks.

## 10. Files the playbook creates on the laptop

| File | Role | Purpose |
| --- | --- | --- |
| `/etc/apt/apt.conf.d/21auto-upgrades-local` | base | Daily list update and unattended upgrade |
| `/etc/apt/apt.conf.d/52unattended-upgrades-local` | base | Allowed origins, no automatic reboot |
| `/etc/needrestart/conf.d/50-auto.conf` | base | Restart services after upgrades |
| `/etc/systemd/journald.conf.d/90-size.conf` | base | Persistent journal, 500 MB |
| `/etc/apt/preferences.d/90-privacy-blocked` | privacy | Never install the reporting packages and snapd |
| `/etc/default/motd-news` | privacy | `ENABLED=0` |
| `/etc/NetworkManager/conf.d/90-privacy.conf` | privacy | No connectivity check |
| `/etc/nftables.conf` | hardening | The firewall |
| `/etc/sysctl.d/90-hardening.conf` | hardening | Kernel and network settings |
| `/etc/sysctl.d/60-claude-code-sandbox.conf` | claude_code | Unprivileged user namespaces allowed |
| `/etc/apparmor.d/disable/bwrap-userns-restrict-patched` | claude_code | Link that disables Zorin's bwrap profile |
| `/usr/local/share/claude-code/claude-code.{asc,gpg}` | claude_code | Release signing key and keyring |
| `/opt/claude-code/<version>/{manifest.json,manifest.json.sig,claude}` | claude_code | Signed manifest and the binary |
| `/usr/local/bin/claude` | claude_code | The wrapper |
| `/etc/claude-code/managed-settings.json` | claude_code | Managed settings |

Also changed: the account `v` (created), the modes of `/home/v` and `/home/v-admin` (0700), the packages removed by `privacy` and `hardening`, `motd-news.timer` (masked), `nftables.service` (enabled).

## 11. Known limits and points to review

- **Native, not isolated.** Claude Code runs as `v`, on the host kernel. The sandbox, the managed rules and the separate admin user limit what it can do; they do not make it a virtual machine. A kernel exploit from a sandboxed command would reach `v`'s session, not root's files, and not production (YubiKey).
- **Built-in tools outside the sandbox.** WebFetch and web search run in Claude Code's own process, not in bubblewrap: the domain allowlist does not limit them. They are governed by the permission prompts, which come to you.
- **Universe and Zorin's repository.** Ubuntu's `main` has security support from Canonical, universe does not. Zorin's own repository is trusted as a whole. The roles avoid universe for anything security-relevant.
- **Captive portals** need an `http://` page opened by hand (connectivity check off).
- **Not configured yet**: the GNOME privacy settings and screen lock (`desktop`), Flatpak apps and remotes (`apps`; the `zorinos` Flatpak remote is still there), the YubiKey and SSH to production for `v-admin` (`security_keys`).
- **Claude Code updates** are manual: no Renovate for `claude_code_version` yet.
- **To confirm on the VM** (written, not yet run): how Ansible names Zorin in its facts; whether purging the reporting packages removes a Zorin metapackage; that the explicit origins match in `unattended-upgrade --dry-run`; that the binary works from `/opt` with updates disabled; every check in `verify.md` section 6.

## 12. How it was tested

On the development laptop (Fedora 44, ansible-core 2.20.7):

- `ansible-playbook --syntax-check site.yml`;
- the managed settings rendered from the defaults and parsed as JSON (`cleanupPeriodDays` an integer);
- the wrapper rendered and run: it refuses `/` and the home;
- the nftables ruleset loaded twice in a row in a throwaway network namespace (`unshare -rn`), to check the replace-only-this-table pattern;
- the release key's fingerprint, and `gpgv` on the 2.1.311 manifest.

On the Zorin 18 test VM, before the roles were written: podman, passt and podman-compose versions and origins (why agent-box was dropped); bubblewrap's origin; the nested-namespace failure, its AppArmor cause, and the fix by unloading the profile; Flatpak still blocking nested namespaces without it; the sandbox working once the profile was gone; auto mode retrying outside the sandbox (why it is disabled).

The full run on the VM is the next step: the checklist is in the pull request and in [verify.md](../verify.md).
