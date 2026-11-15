# Maintenance guide

How to keep the laptop healthy: what runs by itself, what to do by hand and when, how to react to each Telegram notification, routine procedures, troubleshooting and recovery.

For what each task does, see [walkthrough.md](walkthrough.md). For check commands, see [../verify.md](../verify.md). The laptop is part of production: the server's own guide ([ansible-prod-srv, maintenance](https://github.com/Gu35t09/ansible-prod-srv/blob/main/docs/maintenance.md)) covers the YubiKey, the emergency secrets key and the lost laptop procedure from the server's side.

Who does what:

- **`v`**: everyday work, Claude Code, working copies of the repositories. No sudo.
- **`v-admin`**: the playbooks (this one and the server's), SSH to production, every command with `sudo` in this guide. Reached through *Switch User* (system menu, top right), never with `su` or `sudo -iu` in a terminal of `v` (see [walkthrough, Role: users](walkthrough.md#6-role-users)).

The laptop's Telegram messages go to the same chat as the server's and start with `💻 Laptop: <hostname>`.

Contents:

1. [What runs by itself](#1-what-runs-by-itself)
2. [Maintenance calendar](#2-maintenance-calendar)
3. [Running the playbook](#3-running-the-playbook)
4. [Responding to notifications](#4-responding-to-notifications)
5. [Routine procedures](#5-routine-procedures)
6. [Troubleshooting](#6-troubleshooting)
7. [Recovery](#7-recovery)
8. [Where to look](#8-where-to-look)

---

## 1. What runs by itself

| What | When | Where to see it |
| --- | --- | --- |
| Package list update (`apt-daily`) | 06:00 and 18:00 with random delays, or at the next boot | Telegram only if it fails |
| Ubuntu security and update packages, Brave, Zorin's packages (unattended-upgrades) | Daily from 06:00, or at the next boot | Telegram at every run: upgraded, nothing to install, errors, and whether a reboot is needed |
| Service restarts after an upgrade (needrestart) | After each upgrade | journal |
| Removal of old kernels and leftover dependencies | With the upgrades | the same log |
| Firmware, Flatpak apps | Offered by GNOME Software, installed when you accept (admin password) | GNOME Software, *Updates* |
| ClamAV signature updates (freshclam) | Several times a day | `journalctl -u clamav-freshclam` |
| ClamAV scan | Daily at 12:30, or at the next boot | Telegram at every run |
| YARA scan (files and suspicious processes) | Daily at 13:30, or at the next boot | Telegram on matches or errors only |
| Integrity check (NTP, no sshd, libraries, Ebury, admins) | Every 15 minutes | Telegram when the findings change, then daily while they last |
| Disk space check (`/`, `/boot`) | Every 15 minutes | Telegram when a threshold is crossed |
| SMART self-tests | Short daily at 12:00, long on Saturdays at 13:00, if the laptop is on | Telegram on problems only |
| Uptime Kuma push calls | When each job above ends | The monitors "Laptop: …" in Uptime Kuma, at home only (7-day heartbeat) |

Nothing reboots the laptop by itself, and nothing updates Claude Code: its version changes only through this repository. Every timer is `Persistent=true`: a job missed while the laptop was off runs at the next boot, at idle priority.

## 2. Maintenance calendar

### Every day you use the laptop

- Read the laptop's Telegram messages. Two arrive on a normal day: "✅ UNATTENDED-UPGRADES" and "✅ CLAMAV: SCAN CLEAN". A "🔁 REBOOT REQUIRED" means a newer kernel waits: reboot the same day. If the laptop was on and one of them did not arrive, something is wrong even without an error message: see [Responding to notifications](#4-responding-to-notifications).

### Every week

- When GNOME asks for a reboot after an update (a new kernel), reboot the same day: until then the old kernel runs.
- Open GNOME Software, *Updates*: install any firmware it offers, and Flatpak apps if you added some. Brave and Zorin's packages update by themselves every day (unattended-upgrades): check in the Telegram report that `brave-browser` shows up when Brave announces a release. A browser left out of date is the largest risk on a desktop.

### Every month

- As `v-admin`, from an up-to-date clone, check that the laptop still matches the repository:
  ```bash
  cd ~/Documents/ansible-prod-notebook && git pull
  ansible-playbook site.yml -K --ask-vault-pass --check --diff
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
- Run the EICAR tests of `verify.md` sections 9 (ClamAV) and 12 (YARA), and `sudo notify-telegram "Quarterly test from $(hostname)"`.
- Look at the ClamAV quarantine (`sudo ls -l /root/clamav-quarantine`) and empty it once each file has been examined ([Malware detected](#malware-detected)).
- [Refresh the YARA rules](#refresh-the-yara-rules), together with ansible-prod-srv.
- In Uptime Kuma (at home), the five "Laptop: …" monitors are green.

### Every year

- Check Zorin's release calendar (zorin.com): Zorin OS 18 follows Ubuntu 24.04 LTS. Plan the move to the next major release well before the end of its support; a major upgrade means a new branch of this repository, tested on a VM ([Reinstall the laptop](#reinstall-the-laptop) is often simpler than an in-place upgrade).
- Review the GitHub sessions and tokens of the account used in `v` (*Settings → Sessions*, *Applications*) and remove the ones you do not recognize.
- Make sure the [emergency secrets key](#emergency-secrets-key) has the laptop's entries and that they are current.
- The Telegram token is rotated with the server's ([Rotate the Telegram token](#rotate-the-telegram-token)): the same bot.

## 3. Running the playbook

Always as `v-admin`, in its own session, from a clone pulled from GitHub. `v-admin` needs no GitHub credentials: the repositories are public, and it only reads them.

| What | Command | When |
| --- | --- | --- |
| Configure the laptop | `ansible-playbook site.yml -K --ask-vault-pass` | After merging a change |
| Notifications only | `ansible-playbook site.yml -K --ask-vault-pass --tags base` | After editing the vault (Telegram, push tokens) |
| Drift check | `ansible-playbook site.yml -K --ask-vault-pass --check --diff` | Monthly, and before every real run |
| One area | `ansible-playbook site.yml -K --ask-vault-pass --tags claude-code` | After a change to that role only |

`-K` asks for the sudo password of `v-admin`, `--ask-vault-pass` the vault password (never stored). The play stops at once if it is not run as `v-admin`. `vault.yml` is only in the clone of `v-admin` (and on the emergency key): `git pull` never touches it, since it is not in the repository.

How a change gets there:

1. As `v`, in the working copy: a branch, the change (by hand or with Claude), the review of the diff.
2. As `v`: `git push` (by you: it is denied to Claude) and a pull request on GitHub.
3. Merge on github.com.
4. *Switch User* to `v-admin`: `git pull`, `--check --diff`, then the real run.

## 4. Responding to notifications

### A laptop push monitor is down

A "Laptop: …" monitor in Uptime Kuma turned red: its job has not reported, from home, for 7 days, or it reported a failure.

1. Was the laptop away or off for a week? Then it is expected: it turns green at the next run at home.
2. Otherwise, as `v-admin`: `systemctl list-timers` (the job's timer is listed with its next run) and `journalctl -u <unit> -n 30`, where the unit is in [walkthrough, Role: notify](walkthrough.md#4-role-notify).
3. A failed job has also sent its own Telegram message: start from that.

### Malware detected

"⚠️ CLAMAV: MALWARE DETECTED". With `quarantine` (the default) the files are already in `/root/clamav-quarantine`.

1. Read the file names and the signature. Typical harmless cases: the EICAR test file, an archive of security tools you downloaded on purpose.
2. Where did it come from? A download (the Downloads folder, `~/Scaricati` or `~/Downloads` depending on the language), an email attachment, a repository cloned by you or by Claude. As `v`, `ls -la` around the original path; for a repository, `git log` of the file.
3. If you did not expect it, treat `v` as compromised: [Suspected compromise of v](#suspected-compromise-of-v).
4. If it is a false positive and you need the file back: `sudo mv /root/clamav-quarantine/<file> <original path>` and `sudo chown v:v <original path>`. ClamAV will find it again at the next scan: keep it outside the scanned paths, or accept the daily message.
5. Once examined, delete it: `sudo rm /root/clamav-quarantine/<file>`.

### ClamAV scan error

"❌ CLAMAV: SCAN ERROR". As `v-admin`:

```bash
sudo sh -c 'tail -n 30 "$(ls -t /var/log/clamav/scan_*.log | head -n 1)"'
systemctl status clamav-daemon clamav-freshclam
```

Usual causes: clamd not running after a freshclam failure (no network at the first start: `sudo systemctl restart clamav-freshclam`, wait, `sudo systemctl start clamav-daemon`), a full disk.

### No daily ClamAV message

The laptop was on but "SCAN CLEAN" did not arrive. Either the scan did not run (`systemctl list-timers clamav-scan.timer`, `journalctl -u clamav-scan.service`), or Telegram did not accept the message: test with `sudo notify-telegram "test"`, which prints the reason.

### Integrity check alert

"🚨 INTEGRITY CHECK". Read each finding:

- **NTP off or not synchronized**: after a long time offline it resolves by itself once online. If NTP was turned off (`timedatectl` NTP=no) and you did not do it, it is suspicious: `sudo timedatectl set-ntp true`, then look for who changed it (`journalctl -u systemd-timedated`).
- **An SSH server is installed / listens on port 22**: the laptop has none by design. If you did not install it, treat the laptop as compromised. If you did, for a reason, remove it: `--tags hardening` purges `openssh-server`.
- **A shared object or setuid file not installed by any package**: look at it (`ls -l`, `file`, `sha256sum`, the date). A library you installed by hand (a driver) goes into `integrity_lib_allowlist` after you are sure; anything else, treat as compromise.
- **`/etc/ld.so.preload` or `LD_PRELOAD`**: never legitimate here. Compromise.
- **Ebury socket**: compromise.
- **A user in sudo other than `v-admin`, or sudo granting commands to someone else**: if you did not do it, compromise (someone who had root left a way back). Otherwise `--tags users` removes `v` from the admin groups.

For compromise: [Suspected compromise of the laptop](#suspected-compromise-of-the-laptop).

### YARA match

"🚨 YARA: N MATCH(ES)": the rule, then the file or process. Nothing has been moved.

1. Read the rule name. `Multi_EICAR_*` is the test file. A match inside documentation, a security repository you cloned, or a Claude transcript (`~/.claude/projects`) that quotes malware strings is a false positive by nature: the file contains the string, it is not malware.
2. A match on a system binary or library (`/usr/bin`, `/usr/lib`), or on a process: compare the file with the package (`dpkg -S <file>`, then `dpkg --verify <package>`). A packaged file that does not verify, or a process running from `/tmp` or memory: [Suspected compromise of the laptop](#suspected-compromise-of-the-laptop).
3. A match in the home of `v` (a download, a project): as for [Malware detected](#malware-detected).
4. A false positive that repeats every day: add the path to `yara_exclude_paths`, in a PR, and say why in the commit.

### YARA scan error

"❌ YARA: SCAN ERROR": usually the rules do not compile after an update (`sudo yara-scan --compile-only` shows the error), or the disk is full. Fix the rules in the repository and run `--tags yara`.

If the message says the unit ended with `signal` or `exit-code` and no reason of its own, the sandbox may have stopped something: `journalctl -u yara-scan.service -n 50` and, as `v-admin`, `sudo journalctl -k -g 'audit.*yara'` for a blocked system call. After a YARA or systemd update, a sandbox option can need adjusting (`roles/yara/templates/yara-scan.service.j2`); do not remove `PrivateNetwork` or the capability limit, which are the point of it.

### SMART warning

"💽 SMART WARNING": read the type and the message. As `v-admin`: `sudo smartctl -a /dev/nvme0n1 | grep -iE 'critical warning|percentage used|media and data integrity|available spare'`. A critical warning, media errors or the spare below its threshold mean the disk is failing: make sure the data of `v` is backed up (OpenCloud, GitHub) and plan the replacement ([Reinstall the laptop](#reinstall-the-laptop)). A temperature warning alone: the laptop was working hard on a warm surface.

### Disk space low

"⚠️ DISK SPACE LOW": as `v-admin`, `sudo du -xh --max-depth=2 / | sort -h | tail -20`. Usual causes on a laptop: the Downloads folder, VM images, Flatpak runtimes (`flatpak uninstall --unused`), the journal (capped at 500 MB), old kernels in `/boot` (`sudo apt autoremove --purge`).

### Unattended-upgrades errors or a package list failure

- "❌ UNATTENDED-UPGRADES: ERRORS" or "JOB FAILED": the message has the error lines. As `v-admin`, `sudo unattended-upgrade -d` shows the whole run; often a held package or a dpkg question: `sudo apt full-upgrade` resolves it by hand.
- "❌ APT: PACKAGE LISTS NOT UPDATED": usually the laptop had no network at that moment (a train, a captive portal). Look into it only if it repeats.

## 5. Routine procedures

### Elevate to v-admin

- **For a playbook or production**: system menu → *Switch User* → `v-admin`. `v`'s session stays open and locked; switch back the same way.
- **For a single system task while working as `v`** (installing an app in Software, an update, a setting): GNOME's authentication window asks for the password of `v-admin`. It is drawn by the shell, not by a terminal of `v`.
- **Never** `su - v-admin` or `sudo -iu v-admin` in a terminal of `v`: the password would be typed in the session you are protecting, and the YubiKey would not be reachable anyway.

### SSH to production

As `v-admin`, with the YubiKey plugged in: `ssh prod-srv-01` asks for the FIDO2 PIN, then a touch. The playbook of ansible-prod-srv asks for the PIN in a window (ssh-askpass) and for the touch, once per run.

**First time on this laptop** (after `--tags security-keys`, which reminds it):

```bash
cd ~/.ssh && ssh-keygen -K          # PIN and touch: writes id_ed25519_sk_rk_prod-srv-01 and .pub
mv id_ed25519_sk_rk_prod-srv-01 id_ed25519_sk
mv id_ed25519_sk_rk_prod-srv-01.pub id_ed25519_sk.pub
ssh prod-srv-01 hostname             # PIN, touch, "prod-srv-01"
```

**The pinned host key.** `security_keys_ssh_hosts[].host_key` in `group_vars` is the server's `/etc/ssh/ssh_host_ed25519_key.pub` (its first two fields). To set or change it, read it from the server's console or from a computer that already trusts it, and compare the fingerprint with the console's `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` before committing. After a reinstall of the server ssh refuses with "REMOTE HOST IDENTIFICATION HAS CHANGED": expected; update the key the same way, never with `ssh-keygen -R`.

**Without the YubiKey**: the file key on the emergency secrets key, as in ansible-prod-srv's guide ("SSH with the YubiKey", "Without the YubiKey"): `ssh -i ~/.ssh/emergency_key prod-srv-01` (`IdentitiesOnly` takes the `-i` key).

Each failed attempt makes the server hold back the next connection for a few seconds: wait half a minute between tries.

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
   ansible-playbook site.yml -K --ask-vault-pass --tags claude-code
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

### Refresh the YARA rules

Every three months, together with ansible-prod-srv (same script, same pins). As `v`, in the working copy:

```bash
scripts/update-yara-rules.sh <new ESET commit> <new Elastic commit>
git diff --stat roles/yara/files/rules
```

Update the two pins at the top of the script, open a PR, merge, then as `v-admin` run `--tags yara` (it fails if a rule does not compile).

### Rotate the Telegram token

The laptop uses the server's bot: one token for both, and Uptime Kuma's notifications too. In @BotFather, `/revoke` for the bot, then put the new token in **both** vaults (ansible-prod-srv and this one) and in Uptime Kuma (*Settings → Notifications*) and in the GitHub secret `TELEGRAM_BOT_TOKEN` of ansible-prod-srv. Run the server's playbook with `--tags base` and this one with `--tags base`. Test with `sudo notify-telegram "test"` on both.

### Edit the vault

As `v-admin`: `ansible-vault edit inventory/group_vars/laptops/vault.yml`, then `--tags base` (the `notify` role rewrites the credentials and the push calls), then copy the file to the emergency secrets key.

### Change the vault password

`ansible-vault rekey inventory/group_vars/laptops/vault.yml`, then replace the copy on the emergency key and, if it is written there, the password in `RECOVERY.txt`.

### Update the cursor theme

The theme rarely changes (v2.0.1 is from May 2024). For a new release of ful1e5/apple_cursor, as `v`:

```bash
d=$(mktemp -d) && cd "$d"
curl -fsSLO https://github.com/ful1e5/apple_cursor/releases/download/<version>/macOS.tar.xz
sha256sum macOS.tar.xz
tar -tvJf macOS.tar.xz | awk '{print $1}' | cut -c1 | sort | uniq -c       # only - d l: files, dirs, links
tar -tvJf macOS.tar.xz | awk '$1 ~ /^l/ {print $NF}' | grep -cE '^/|\.\.'    # 0: no link points outside
tar -xJf macOS.tar.xz && find . -type f -perm /111 ! -name '*.tar.xz'      # nothing executable
```

If the content is still only cursors, put the version and the new SHA-256 in `roles/desktop/defaults/main.yml`, PR, merge, then as `v-admin` `--tags desktop`. To switch to the white variant or another size: `desktop_cursor_theme: macOS-White`, `desktop_cursor_size: 32`.

If after an update the cursor is Adwaita again for everyone, Zorin probably added a desktop-specific section: `grep -B6 cursor-theme /usr/share/glib-2.0/schemas/*.override` shows the `[org.gnome.desktop.interface:NAME]` headers; add `NAME` to `desktop_cursor_sections` and run `--tags desktop`.

### Set or change the password of v

As `v-admin`: `sudo passwd v`. The password is not in the repository nor on the emergency key: `v-admin` can always reset it.

### Log in to a captive portal

With the connectivity check off, a hotel or train Wi-Fi does not open its login page by itself. Open any plain `http://` address in the browser (for example `http://neverssl.com`): the network redirects it to its login page.

### Install an application

From Flathub, through Software or `flatpak install --system flathub <app id>` (as `v-admin`, or with the admin password): Flatpak apps run sandboxed. An application removed by the `apps` role comes back only if you take it off `apps_remove_packages` in a PR; otherwise the next run removes it again.

### A blocked package is needed

`apt install` refuses a package listed in `/etc/apt/preferences.d/90-privacy-blocked` ("has no installation candidate"). If you really need it (for example a Snap-only app), remove it from `privacy_purge_packages` or set `privacy_remove_snapd: false`, in a PR, and run `--tags privacy`. Prefer the Flatpak of the same app.

### Open an inbound port

Only for a service you run on purpose (a development server for another device on the LAN, for example): add it to `hardening_inbound_tcp_ports` or `hardening_inbound_udp_ports`, PR, `--tags hardening`. Remove it when you are done.

## 6. Troubleshooting

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

### /status shows warnings

Expected, and harmless: "~/.local/bin is not in your PATH", "install method is 'not set'", "claude command at ~/.local/bin/claude missing or broken" (Claude Code is installed by root in `/opt`, not by its own installer), and "Glob patterns in sandbox permission rules are not fully supported on Linux". **Not** expected: "Found invalid entries in /etc/claude-code/managed-settings.json": a value failed the schema and was dropped. The role's `validate` should prevent it; if it appears after a Claude Code update, the schema changed: read `claude doctor`, fix the value in `roles/claude_code/defaults/main.yml`, run `--tags claude-code`.

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

### "D-Bus connection terminated" from systemctl

`Warning! D-Bus connection terminated. Failed to wait for response: Connection reset by peer`, while an upgrade is running: systemd was upgraded and re-executed itself, and every `systemctl` waiting for an answer lost its connection. The unit it started keeps running. Wait for it with `systemctl is-active <unit>`, then read its journal. Seen on the test VM during the first big unattended upgrade.

### No Telegram messages

As `v-admin`: `sudo notify-telegram "test"; echo $?`. 0 and no message: the chat ID is wrong. 1: Telegram refused it (the token was revoked: [Rotate the Telegram token](#rotate-the-telegram-token)) or no network. 2: `/etc/homelab/notify.env` is missing: `--tags base`.

### No network after a change

`sudo nft list ruleset` shows what is loaded. To rule the firewall out: `sudo nft delete table inet laptop_filter` (until the next reload or boot), then `--tags hardening` once the cause is fixed.

## 7. Recovery

### Emergency secrets key

The laptop adds two entries to `RECOVERY.txt` on the emergency secrets key (the list itself is in the server's maintenance guide):

| Secret | Why |
| --- | --- |
| LUKS passphrase of the laptop's disk | Boot the laptop |
| Password of `v-admin` | Log in as admin, reset the password of `v` |
| A copy of `inventory/group_vars/laptops/vault.yml` (encrypted), and its vault password if it differs from the server's | The Telegram credentials and the Uptime Kuma push tokens. The file is never committed: this copy and the clone of `v-admin` are the only ones |

The password of `v` is not on it: `v-admin` resets it.

### Reinstall the laptop

Everything is in this repository; the data of `v` comes from its own backup (documents in OpenCloud, repositories on GitHub).

1. Install Zorin OS 18 Core: *Advanced features → LVM and encryption*, decline the census, first user **`v-admin`**.
2. As `v-admin`: `snap list` (what is listed will be removed), then
   ```bash
   git clone https://github.com/Gu35t09/ansible-prod-notebook.git ~/Documents/ansible-prod-notebook
   cd ~/Documents/ansible-prod-notebook && ./scripts/bootstrap.sh
   install -m 600 <emergency key>/laptop-vault.yml inventory/group_vars/laptops/vault.yml
   ansible-playbook site.yml -K --ask-vault-pass --check --diff
   ansible-playbook site.yml -K --ask-vault-pass
   sudo passwd v
   ```
3. Log in as `v`: log in to Claude Code, GitHub and the other services again.
4. `verify.md`, every section.
5. For production, as `v-admin`: [SSH to production](#ssh-to-production) ("First time on this laptop"), and a clone of ansible-prod-srv with its `vault.yml` from the emergency key.

### Lost or stolen laptop

Follow the server guide's "Lost or stolen laptop" from another computer. With two users the exposure is split:

- **`v`** holds the GitHub session used for branches and pull requests, the Claude Code login, the browser sessions and documents. Close them: GitHub (*Settings → Sessions*, *Applications*, tokens), claude.ai (*Settings*, log out of other devices), Vaultwarden, OpenCloud.
- **root** holds the Telegram bot token, shared with the server: [rotate it](#rotate-the-telegram-token). The Uptime Kuma push tokens only let someone mark the laptop's monitors green or red: delete the five monitors and create new ones.
- **`v-admin`** holds the SSH configuration for production, this repository's `vault.yml` and, while you work, a copy of the server's `vault.yml`. Its access to the server needs the YubiKey, which is on your keyring; the vault password is never stored.
- The disk is encrypted with LUKS: safe if the laptop was **off**, not if it was on, suspended or unlocked.

### Suspected compromise of the laptop

A finding of the integrity check or YARA on system files means someone had root. Nothing on the laptop can be trusted any more, the alerts included.

1. Disconnect the network.
2. From another device: [rotate the Telegram token](#rotate-the-telegram-token); close the sessions of `v` (below); on the server, read the SSH log for logins you did not make (`journalctl -u ssh`), and if there are any follow the server guide's "Suspected compromise".
3. Copy for analysis, if you want, `/var/log/{clamav,yara}/`, the journal and `~/.claude/projects/` of `v` to a USB stick.
4. [Reinstall the laptop](#reinstall-the-laptop) from the installer, not from a backup of the system.

### Suspected compromise of v

Signs: Claude or a command did something you did not ask for, unknown files in the projects, prompts for domains you do not recognize, GitHub activity you did not do.

What an attacker in `v` can reach: what `v` can read and its sessions (GitHub, Claude, browser). Not root (no sudo), not production (no SSH configuration, YubiKey), not the files of `v-admin` (home 0700).

1. Disconnect the network.
2. As `v`, before closing anything: copy `~/.claude/projects/` (the transcripts show what Claude was asked and what it ran) to a USB stick for analysis.
3. From another device: close the sessions of `v` (GitHub, claude.ai, the others above) and revoke its tokens.
4. Check the repositories on GitHub for commits and branches you did not make.
5. [Reinstall the laptop](#reinstall-the-laptop): a compromised user session cannot be cleaned with certainty.

## 8. Where to look

| What | Where |
| --- | --- |
| Unattended upgrades | `/var/log/unattended-upgrades/`, `journalctl -u apt-daily-upgrade` |
| Firewall | `sudo nft list ruleset` |
| AppArmor denials | `sudo journalctl -k \| grep 'apparmor="DENIED"'` |
| Claude Code settings in force | `/etc/claude-code/managed-settings.json`; `/status` and `/permissions` inside Claude |
| Claude Code transcripts | `~/.claude/projects/` (of `v`), deleted after 30 days |
| Unattended-upgrades report | `journalctl -u apt-daily-upgrade.service -u apt-daily.service` |
| ClamAV scans | `/var/log/clamav/scan_*.log` (30 days), `journalctl -u clamav-scan.service` |
| YARA scans | `/var/log/yara/scan_*.log` (30 days), `/var/log/yara/last-report`, `journalctl -u yara-scan.service -u yara-report.service` |
| Integrity check | `journalctl -u integrity-check.service` |
| Disk space, SMART | `journalctl -u disk-space-check.service`, `journalctl -u smartmontools` |
| Push calls | `journalctl -g notify-push` |
| Timers | `systemctl list-timers` |
| Installed Claude Code | `/opt/claude-code/<version>/`, `/usr/local/bin/claude` (wrapper) |
| What the playbook writes | [walkthrough, section 18](walkthrough.md#18-files-the-playbook-creates-on-the-laptop) |
