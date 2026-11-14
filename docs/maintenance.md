# Maintenance guide

How to keep the laptop healthy: what runs by itself, what to do by hand and when, routine procedures, troubleshooting and recovery.

For what each task does, see [walkthrough.md](walkthrough.md). For check commands, see [../verify.md](../verify.md). The laptop is part of production: the server's own guide ([ansible-prod-srv, maintenance](https://github.com/Gu35t09/ansible-prod-srv/blob/main/docs/maintenance.md)) covers the YubiKey, the emergency secrets key and the lost laptop procedure from the server's side.

Who does what:

- **`v`**: everyday work, Claude Code, working copies of the repositories. No sudo.
- **`v-admin`**: the playbooks (this one and the server's), SSH to production. Reached through *Switch User* (system menu, top right), never with `su` or `sudo -iu` in a terminal of `v` (see [walkthrough, Role: users](walkthrough.md#5-role-users)).

Contents:

1. [What runs by itself](#1-what-runs-by-itself)
2. [Maintenance calendar](#2-maintenance-calendar)
3. [Running the playbook](#3-running-the-playbook)
4. [Routine procedures](#4-routine-procedures)
5. [Troubleshooting](#5-troubleshooting)
6. [Recovery](#6-recovery)
7. [Where to look](#7-where-to-look)

---

## 1. What runs by itself

| What | When | Where to see it |
| --- | --- | --- |
| Package list update (`apt-daily`) | Daily, at a random time | `journalctl -u apt-daily` |
| Ubuntu security and update packages (unattended-upgrades) | Daily, after the list update | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| Service restarts after an upgrade (needrestart) | After each upgrade | journal |
| Removal of old kernels and leftover dependencies | With the upgrades | the same log |
| Firmware, Zorin packages, Flatpak apps | Offered by GNOME Software, installed when you accept (admin password) | GNOME Software, *Updates* |

Nothing reboots the laptop by itself, and nothing updates Claude Code: its version changes only through this repository.

## 2. Maintenance calendar

### Every week

- When GNOME asks for a reboot after an update (a new kernel), reboot the same day: until then the old kernel runs.
- Open GNOME Software, *Updates*: install the Flatpak apps, Zorin's packages and any firmware it offers. The browser is a Flatpak: a browser left out of date is the largest risk on a desktop.

### Every month

- As `v-admin`, from an up-to-date clone, check that the laptop still matches the repository:
  ```bash
  cd ~/Documents/ansible-prod-notebook && git pull
  ansible-playbook site.yml -K --check --diff
  ```
  On an unchanged laptop it reports `changed=0`. Anything else means something changed by hand or by a package: read the diff before running the playbook for real.
- Check that unattended-upgrades does its job:
  ```bash
  grep -E 'Packages that will be upgraded|No packages found|ERROR' /var/log/unattended-upgrades/unattended-upgrades.log | tail -5
  apt list --upgradable 2>/dev/null | grep -i security || echo "no security update waiting"
  ```

### Every three months

- [Update Claude Code](#update-claude-code) to the current version of the "stable" channel.
- Run the sandbox checks of `verify.md` section 6 as `v`. Each Claude Code update can change how the sandbox and the settings behave: the six requests in the table must still fail or ask.
- Look at what the laptop sends by itself (`verify.md` section 4, the `tcpdump` command): a new name in the list means a new package or app is calling home.
- On claude.ai, *Settings → Privacy*: the choice on using conversations to improve the models is still the one you made.

### Every year

- Check Zorin's release calendar (zorin.com): Zorin OS 18 follows Ubuntu 24.04 LTS. Plan the move to the next major release well before the end of its support; a major upgrade means a new branch of this repository, tested on a VM ([Reinstall the laptop](#reinstall-the-laptop) is often simpler than an in-place upgrade).
- Review the GitHub sessions and tokens of the account used in `v` (*Settings → Sessions*, *Applications*) and remove the ones you do not recognize.
- Make sure the [emergency secrets key](#emergency-secrets-key) has the laptop's entries and that they are current.

## 3. Running the playbook

Always as `v-admin`, in its own session, from a clone pulled from GitHub. `v-admin` needs no GitHub credentials: the repositories are public, and it only reads them.

| What | Command | When |
| --- | --- | --- |
| Configure the laptop | `ansible-playbook site.yml -K` | After merging a change |
| Drift check | `ansible-playbook site.yml -K --check --diff` | Monthly, and before every real run |
| One area | `ansible-playbook site.yml -K --tags claude-code` | After a change to that role only |

`-K` asks for the sudo password of `v-admin`. The play stops at once if it is not run as `v-admin`.

How a change gets there:

1. As `v`, in the working copy: a branch, the change (by hand or with Claude), the review of the diff.
2. As `v`: `git push` (by you: it is denied to Claude) and a pull request on GitHub.
3. Merge on github.com.
4. *Switch User* to `v-admin`: `git pull`, `--check --diff`, then the real run.

## 4. Routine procedures

### Elevate to v-admin

- **For a playbook or production**: system menu → *Switch User* → `v-admin`. `v`'s session stays open and locked; switch back the same way.
- **For a single system task while working as `v`** (installing an app in Software, an update, a setting): GNOME's authentication window asks for the password of `v-admin`. It is drawn by the shell, not by a terminal of `v`.
- **Never** `su - v-admin` or `sudo -iu v-admin` in a terminal of `v`: the password would be typed in the session you are protecting, and the YubiKey would not be reachable anyway.

### Work on a repository with Claude

As `v`:

```bash
mkdir -p ~/progetti && cd ~/progetti
git clone https://github.com/<owner>/<repo>.git && cd <repo>
claude
```

- Claude starts only inside a project folder: never from the home, `/` or a hidden folder.
- Sandboxed commands run without asking; anything that reaches a new domain, edits outside the folder or uses a web tool asks you. Read the question: it says the command and the domain.
- Claude cannot push. When the work is done: `git diff`, then `git push` yourself.
- When Claude reads a cloned repository from someone else, it reads their instructions too (`CLAUDE.md`, comments, issues). With the managed settings their hooks, MCP servers and permission rules do not apply, but treat what Claude proposes after reading untrusted content with extra care.

### Update Claude Code

1. Find the current version of the "stable" channel and read what changed:
   ```bash
   curl -fsS https://downloads.claude.ai/claude-code-releases/stable; echo
   ```
   The release notes are in the Claude Code changelog (code.claude.com). Look for changes to the sandbox, the permissions and the managed settings.
2. As `v`, in a branch: change `claude_code_version` in `roles/claude_code/defaults/main.yml`, push, open a PR, merge.
3. As `v-admin`: `git pull`, then
   ```bash
   ansible-playbook site.yml -K --tags claude-code
   ```
   The role verifies the new manifest's signature and the binary's checksum, installs it, switches the wrapper and removes the old version.
4. As `v`: `claude --version`, then `verify.md` section 6.

If the signing key ever changes, the role stops at "Check the fingerprint of the signing key". Do not just replace the file: check the new fingerprint in Claude Code's setup documentation, then update both `files/claude-code.asc` and `claude_code_key_fingerprint` in the same PR.

### Allow a domain to sandboxed commands

A domain you approve in a prompt is valid for that session only (`allowManagedPermissionRulesOnly`). For one you use all the time (a package registry, a documentation site), add it to `claude_code_sandbox_allowed_domains` in `roles/claude_code/defaults/main.yml`, PR, merge, `--tags claude-code`. Keep the list short: each domain is a place where a manipulated command can send data without asking.

### Change a permission rule

The rules are in `claude_code_managed_settings` (`roles/claude_code/defaults/main.yml`). Rule syntax, from Claude Code's permission documentation:

- `Read(~/path/**)`: relative to the home; `Read(//abs/path/**)`: absolute (two slashes); `Read(**/name)`: anywhere.
- `Bash(command *)`: a command and its arguments.

After the run, `/permissions` in Claude shows the rules it applies, and `/status` lists the managed settings among its sources.

### Set or change the password of v

As `v-admin`: `sudo passwd v`. The password is not in the repository nor on the emergency key: `v-admin` can always reset it.

### Log in to a captive portal

With the connectivity check off, a hotel or train Wi-Fi does not open its login page by itself. Open any plain `http://` address in the browser (for example `http://neverssl.com`): the network redirects it to its login page.

### A blocked package is needed

`apt install` refuses a package listed in `/etc/apt/preferences.d/90-privacy-blocked` ("has no installation candidate"). If you really need it (for example a Snap-only app), remove it from `privacy_purge_packages` or set `privacy_remove_snapd: false`, in a PR, and run `--tags privacy`. Prefer the Flatpak of the same app.

### Open an inbound port

Only for a service you run on purpose (a development server for another device on the LAN, for example): add it to `hardening_inbound_tcp_ports` or `hardening_inbound_udp_ports`, PR, `--tags hardening`. Remove it when you are done.

## 5. Troubleshooting

### The playbook stops at "Check that the playbook runs as the admin user"

You are running it as `v` (or another user). *Switch User* to `v-admin` and run it there.

### The playbook stops at "Check that the admin user is in sudo"

`v-admin` lost the `sudo` group. With nobody in sudo, only the recovery boot can fix it: reboot, choose *Advanced options → recovery mode → root*, then `usermod -aG sudo v-admin` and reboot.

### The playbook stops at "Refuse a user-level install"

The official installer was run as `v` at some point. As `v`: `rm -f ~/.local/bin/claude && rm -rf ~/.local/share/claude`, then run the playbook again.

### Claude refuses to start

The wrapper says why:

- "a member of sudo" (or admin, wheel, adm): you are in `v-admin`. Claude runs only as `v`.
- "it is your home", "system directory", "hidden folder": `cd` into a project folder first.
- "it is not owned by you": the folder belongs to another user; clone it again as `v`.

### Claude says the sandbox is not available

With `failIfUnavailable` it does not start at all. As `v`:

```bash
bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-net -- unshare -U -r true && echo "nested OK"
ls -l /etc/apparmor.d/disable/
```

If `nested OK` does not appear, as `v-admin`:

```bash
sudo aa-status | grep -E 'bwrap|unpriv'
sudo journalctl -k --since "-1 hour" | grep -i 'apparmor="DENIED"' | tail
sysctl kernel.apparmor_restrict_unprivileged_userns
```

- Denials for `unpriv_bwrap`: Zorin's profile is loaded again, perhaps under a new file name after an upgrade. Look in `/etc/apparmor.d/` for the file that defines `unpriv_bwrap` (`grep -l unpriv_bwrap /etc/apparmor.d/*`), set `claude_code_bwrap_profile` to it, and run `--tags claude-code`.
- The sysctl at 1: something changed it; `--tags claude-code` sets it back.

### A command fails in the sandbox

Expected cases: it writes outside the project folder (read-only file system), it reaches a domain you refused, it opens a Unix socket (D-Bus, an agent). Claude does not retry it outside the sandbox. Run it yourself in a terminal if it is legitimate, or [allow the domain](#allow-a-domain-to-sandboxed-commands).

### No security updates are installed

```bash
sudo unattended-upgrade --dry-run -d 2>&1 | grep -iE 'allowed origins|pkgs that look like they should be upgraded'
apt-cache policy | grep -E 'o=Ubuntu.*noble-security' | head -2
```

The allowed origins must include `origin=Ubuntu,archive=noble-security`, and `apt-cache policy` must show a security source with `o=Ubuntu`. If Zorin changes how its archive is labelled, fix `base_unattended_origins`.

### No network after a change

`sudo nft list ruleset` shows what is loaded. To rule the firewall out: `sudo nft delete table inet laptop_filter` (until the next reload or boot), then `--tags hardening` once the cause is fixed.

## 6. Recovery

### Emergency secrets key

The laptop adds two entries to `RECOVERY.txt` on the emergency secrets key (the list itself is in the server's maintenance guide):

| Secret | Why |
| --- | --- |
| LUKS passphrase of the laptop's disk | Boot the laptop |
| Password of `v-admin` | Log in as admin, reset the password of `v` |

The password of `v` is not on it: `v-admin` resets it.

### Reinstall the laptop

Everything is in this repository; the data of `v` comes from its own backup (documents in OpenCloud, repositories on GitHub).

1. Install Zorin OS 18 Core: *Advanced features → LVM and encryption*, decline the census, first user **`v-admin`**.
2. As `v-admin`: `snap list` (what is listed will be removed), then
   ```bash
   git clone https://github.com/Gu35t09/ansible-prod-notebook.git ~/Documents/ansible-prod-notebook
   cd ~/Documents/ansible-prod-notebook && ./scripts/bootstrap.sh
   ansible-playbook site.yml -K --check --diff
   ansible-playbook site.yml -K
   sudo passwd v
   ```
3. Log in as `v`: log in to Claude Code, GitHub and the other services again.
4. `verify.md`, every section.
5. For production, as `v-admin`: the server guide's "SSH with the YubiKey" ("New computer": `ssh-keygen -K`), and a clone of ansible-prod-srv with its `vault.yml` from the emergency key.

### Lost or stolen laptop

Follow the server guide's "Lost or stolen laptop" from another computer. With two users the exposure is split:

- **`v`** holds the GitHub session used for branches and pull requests, the Claude Code login, the browser sessions and documents. Close them: GitHub (*Settings → Sessions*, *Applications*, tokens), claude.ai (*Settings*, log out of other devices), Vaultwarden, OpenCloud.
- **`v-admin`** holds the SSH configuration for production and, while you work, a copy of `vault.yml`. Its access to the server needs the YubiKey, which is on your keyring; the vault password is never stored.
- The disk is encrypted with LUKS: safe if the laptop was **off**, not if it was on, suspended or unlocked.

### Suspected compromise of v

Signs: Claude or a command did something you did not ask for, unknown files in the projects, prompts for domains you do not recognize, GitHub activity you did not do.

What an attacker in `v` can reach: what `v` can read and its sessions (GitHub, Claude, browser). Not root (no sudo), not production (no SSH configuration, YubiKey), not the files of `v-admin` (home 0700).

1. Disconnect the network.
2. As `v`, before closing anything: copy `~/.claude/projects/` (the transcripts show what Claude was asked and what it ran) to a USB stick for analysis.
3. From another device: close the sessions of `v` (GitHub, claude.ai, the others above) and revoke its tokens.
4. Check the repositories on GitHub for commits and branches you did not make.
5. [Reinstall the laptop](#reinstall-the-laptop): a compromised user session cannot be cleaned with certainty.

## 7. Where to look

| What | Where |
| --- | --- |
| Unattended upgrades | `/var/log/unattended-upgrades/`, `journalctl -u apt-daily-upgrade` |
| Firewall | `sudo nft list ruleset` |
| AppArmor denials | `sudo journalctl -k \| grep 'apparmor="DENIED"'` |
| Claude Code settings in force | `/etc/claude-code/managed-settings.json`; `/status` and `/permissions` inside Claude |
| Claude Code transcripts | `~/.claude/projects/` (of `v`), deleted after 30 days |
| Installed Claude Code | `/opt/claude-code/<version>/`, `/usr/local/bin/claude` (wrapper) |
| What the playbook writes | [walkthrough, section 10](walkthrough.md#10-files-the-playbook-creates-on-the-laptop) |
