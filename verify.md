# Verification

Commands to check each part on the laptop, after `ansible-playbook site.yml -K --ask-vault-pass` (run as `v-admin`). Sections 1–5 and 7–12 as `v-admin`, section 6 as `v`.

## 1. Playbook

```bash
ansible-playbook site.yml -K --ask-vault-pass          # a second run must report changed=0
```

## 2. Users

```bash
id v                                           # groups: v only
id v-admin                                     # includes sudo
sudo -l -U v                                   # "is not allowed to run sudo"
ls -ld /home/v /home/v-admin                   # drwx------
```

As `v`: `sudo true` must fail with "v is not in the sudoers file".

## 3. Updates (base)

```bash
cat /etc/apt/apt.conf.d/52unattended-upgrades-local
sudo unattended-upgrade --dry-run -d 2>&1 | grep -E 'Allowed origins|Checking|pkgs that look like'
```

`Allowed origins` must list `origin=Ubuntu,archive=noble-security` and `noble-updates`.

Interrupting the dry run (Ctrl+C) while it downloads leaves an `ERROR fetch.run() ... Method http has died unexpectedly` line in `/var/log/unattended-upgrades/unattended-upgrades.log`. It is not a failed job, and no Telegram message follows: the report runs only after `apt-daily-upgrade.service`.

The first run after a fresh install catches up on everything published since the ISO: on the test VM about 400 packages, 20 minutes of CPU, longer in real time. While it runs, `systemctl` commands may end with "Warning! D-Bus connection terminated" when systemd is upgraded and re-executes itself: the command's job keeps running, wait for it with `systemctl is-active <unit>`.

## 4. Privacy

```bash
dpkg -l zorin-os-census apport whoopsie kerneloops ubuntu-report popularity-contest snapd 2>&1 | grep -E '^ii' || echo "none installed"
apt-cache policy snapd | grep -E 'Candidate|-10'
systemctl is-enabled motd-news.timer           # masked
nmcli general permissions >/dev/null; busctl get-property org.freedesktop.NetworkManager \
  /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled   # b false
```

What the laptop sends by itself: record half an hour with the desktop of `v` idle (start it as `v-admin`, then *Switch User* to `v` and touch nothing). Only DNS, UDP and the first packet of each new TCP connection are kept: no content.

```bash
sudo timeout 1800 tcpdump -i any -n -w /var/tmp/idle.pcap \
  'port 53 or udp or (tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0)'
```

Then read it. With `-i any` each line carries the interface and the direction (`In`, `Out`, `M` for multicast received), so the destination is the field after `>`:

```bash
echo "== DNS names =="
sudo tcpdump -n -r /var/tmp/idle.pcap port 53 2>/dev/null | grep -oE '(A|AAAA)\? [^ ]+' | sort | uniq -c | sort -rn
echo "== New TCP connections =="
sudo tcpdump -n -r /var/tmp/idle.pcap 'tcp[tcpflags] & tcp-syn != 0' 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i==">") print $3, $(i-1), "->", $(i+1)}' | sed 's/:$//' | sort | uniq -c
echo "== UDP, not DNS =="
sudo tcpdump -n -r /var/tmp/idle.pcap 'udp and not port 53' 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i==">") print $3, $(i-1), "->", $(i+1)}' | sed -E 's/\.[0-9]+ ->/ ->/; s/:$//' | sort | uniq -c | sort -rn | head -15
sudo rm /var/tmp/idle.pcap
```

On the test VM (15 November 2026) the only outgoing traffic in 30 minutes was:
- **no DNS query at all**;
- four TCP connections to `10.123.12.11:443`: the push calls of the integrity and disk space checks, which connect by address;
- NTP to `185.125.190.56` (`ntp.ubuntu.com`);
- one DHCP renewal.

Everything else was multicast **received** from the host (mDNS 5353, SSDP 1900, WS-Discovery 3702), dropped by the firewall. A new name or address in the `Out` lines means a new package or app is calling home.

Daily jobs (apt, freshclam, GNOME Software, fwupd) are not always inside a 30-minute window. For them, record DNS only for a day: `sudo timeout 86400 tcpdump -i any -n -w /var/tmp/day.pcap port 53`. The expected names are the Ubuntu archives, `database.clamav.net`, Flathub, `fwupd.org`, `api.telegram.org`.

## 5. Firewall and sysctl (hardening)

```bash
sudo nft list table inet laptop_filter
dpkg -l openssh-server 2>&1 | grep -E '^ii' || echo "no sshd"
sysctl kernel.kptr_restrict kernel.unprivileged_bpf_disabled net.ipv4.conf.all.accept_redirects
```

From another machine on the same network, `nmap -Pn <laptop IP>` must show every port filtered.

## 6. Claude Code

```bash
command -v claude                              # /usr/local/bin/claude
claude --version                               # the pinned version
ls -l /opt/claude-code/                        # root-owned, one version only
cat /etc/claude-code/managed-settings.json        # readable by all, writable by root only
cd ~ && claude                                 # as v: refused, it is your home
                                               # as v-admin, anywhere: refused, member of sudo
```

The sandbox must start and fail closed:

```bash
ls -l /etc/apparmor.d/disable/ | grep bwrap    # the link that disables Zorin's profile
# as v-admin: sudo aa-status | grep -E 'bwrap|unpriv' || echo "bwrap profile not loaded"
bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-net -- unshare -U -r true && echo "nested OK"
```

Flatpak must still block nested namespaces by itself (any installed app):

```bash
flatpak run --command=sh org.gnome.Calculator -c 'unshare -U -r true && echo "flatpak NESTED OK"'   # must FAIL
```

At the first start Claude Code must show **no "Settings Warning"** for `/etc/claude-code/managed-settings.json`. A warning means a value failed the schema and was dropped: fix the role, do not just continue.

In `mkdir -p ~/progetti/prova && cd ~/progetti/prova && claude`, ask Claude to run each of these. Every one must fail or ask you, never succeed silently:

| Request | Expected (as seen on the test VM) |
| --- | --- |
| `curl -sI https://example.com` | A prompt for `example.com`. Answer no: it fails. Answer yes: it works for this session only |
| `curl -sI https://github.com` | Works with no prompt (allowed domain) |
| `touch ~/fuori.txt` | Looks successful inside the sandbox, but the home is a private, throwaway view there: then, as `v` in a terminal, `ls ~/fuori.txt` must say "No such file". No retry outside the sandbox |
| `cat ~/.ssh/config` | "No such file or directory": the sandbox hides the home, so an existing file and a missing one look the same |

`/mcp` must list no server: the claude.ai connectors are disabled.

Then `/permissions`: the deny rules include `Bash(ssh *)`, `Bash(sudo *)`, `Bash(git push *)` and the `Read(~/.ssh/**)` family; `/status` lists the managed settings among the sources; Shift+Tab must not offer auto or bypass mode.

A secret inside the project folder: as `v`, `echo 'SECRET=fake' > ~/progetti/prova/.env`, then ask Claude to read `.env` with its read tool (refused by the permissions), and to run `cat .env` (in the sandbox the file is replaced by an empty device: "Permission denied"). Remove it yourself afterwards: `rm ~/progetti/prova/.env` (Claude cannot: in the sandbox it is not the real file). Checked on the VM.

`/status` lists these diagnostics, all expected: "Native installation exists but ~/.local/bin is not in your PATH", "config install method is 'not set'", "claude command at ~/.local/bin/claude missing or broken" (Claude Code expects its own installer's layout; here it is installed by root in `/opt`, with updates off), and "Glob patterns in sandbox permission rules are not fully supported on Linux" (see the walkthrough, "Known limits"). It must **not** list "Found invalid entries in /etc/claude-code/managed-settings.json".

Asking Claude to run `ssh` to another account or `sudo` is not a useful test: Claude declines by itself before the rules are reached, and the request can trip the model's safety classifier ("safeguards flagged this session"). Check those rules with `/permissions` instead.

## 7. Notifications

As `v-admin`:

```bash
sudo notify-telegram "Test from $(hostname)"; echo "exit code $?"
```

Exit code 0 and a message on Telegram. Code 1 means Telegram refused the request (check token and chat ID in the vault), 2 that the credentials are missing.

The unattended-upgrades report, without waiting for the morning run:

```bash
sudo systemctl start apt-daily-upgrade.service
journalctl -u apt-daily-upgrade.service -n 20 -o cat
```

A "✅ UNATTENDED-UPGRADES" message on Telegram (or none, if unattended-upgrades already ran today: it runs once a day).

## 8. Uptime Kuma push calls

At home, after step 7 of the README's first setup:

```bash
ls /etc/systemd/system/*.service.d/90-push.conf
sudo systemctl start disk-space-check.service
journalctl -u disk-space-check.service -n 5 -o cat | grep notify-push || echo "no error from notify-push"
```

The "Laptop: disk space check" monitor shows a new green beat. Away from home, the same command logs "Uptime Kuma not reachable ... normal away from home" and the job still succeeds.

## 9. ClamAV

```bash
apt-cache policy clamav clamav-daemon | grep -E '^[a-z]|500'   # main or universe? (note it in the walkthrough)
systemctl is-active clamav-daemon clamav-freshclam
systemctl list-timers clamav-scan.timer
```

Test with the EICAR file, harmless and detected by every antivirus. The string is split in two here, so this file does not match the scanners in the clones of the repository. As `v`, then as `v-admin`:

```bash
# as v
printf '%s%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$(xdg-user-dir DOWNLOAD)/eicar.com"     # ~/Scaricati or ~/Downloads, by language
# as v-admin
sudo systemctl start clamav-scan.service
sudo sh -c 'cat "$(ls -t /var/log/clamav/scan_*.log | head -n 1)"' | grep -E 'FOUND|Files to scan|Infected'
```

Expected: `eicar.com: Eicar-Signature FOUND`, the file moved to `/root/clamav-quarantine` and a "MALWARE DETECTED" message on Telegram. Clean up: `sudo rm -f /root/clamav-quarantine/eicar.com`.

## 10. SMART and disk space

On a virtual machine smartmontools is not installed (there is no physical disk to read): skip `smartctl` and test only the disk space check.

```bash
sudo smartctl -H /dev/nvme0n1
sudo systemctl start disk-space-check.service
systemctl list-timers disk-space-check.timer
```

To test the alert path, lower `disk_space_warn_percent` below the current usage with `-e disk_space_warn_percent=1 --tags monitoring`, start the check (a "DISK SPACE LOW" message), then run `--tags monitoring` again without `-e` and start it once more ("BACK TO NORMAL").

## 11. Time and integrity check

```bash
timedatectl show --property=NTP --property=NTPSynchronized   # NTP=yes, NTPSynchronized=yes
systemctl list-timers integrity-check.timer
sudo integrity-check; echo "exit code $?"                    # 0 and "nothing found"
```

On a fresh install a few findings may need an allowlist entry (a library Zorin installs outside the packages): read them before adding anything to `integrity_lib_allowlist`.

To test the alert path, plant a fake unpackaged library, run the check, then remove it:

```bash
sudo cp /usr/lib/x86_64-linux-gnu/libkeyutils.so.1.* /usr/lib/x86_64-linux-gnu/libtest-integrity.so.1
sudo integrity-check     # exit code 1, "shared object not installed by any package", Telegram message
sudo rm /usr/lib/x86_64-linux-gnu/libtest-integrity.so.1
sudo integrity-check     # "nothing found" and "✅ INTEGRITY CHECK: ALL CLEAR" on Telegram
```

And the admin check: `sudo gpasswd -a v sudo && sudo integrity-check` reports "user v is in the sudo group"; then `sudo gpasswd -d v sudo` (or `--tags users`, which removes it as well).

## 12. YARA

```bash
apt-cache policy yara | grep -E '^[a-z]|500'                 # universe, hence the sandbox
sudo yara-scan --compile-only && echo "rules OK"
systemctl list-timers yara-scan.timer
systemd-analyze security yara-scan.service | tail -1          # the sandbox's exposure score
ls /etc/systemd/system/yara-scan.service.d/90-push.conf 2>/dev/null || echo "no push call on the sandboxed scan"
ls /etc/systemd/system/yara-report.service.d/90-push.conf     # the push call is on the report
```

The sandbox has no network. This must fail, with "Network is unreachable" or a resolution error:

```bash
sudo systemd-run --wait --pipe -p PrivateNetwork=yes -p RestrictAddressFamilies=AF_UNIX curl -sS --max-time 5 https://api.telegram.org
```

Test with the EICAR file (the Elastic rules include it):

```bash
printf '%s%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.com
sudo systemctl start yara-scan.service
sudo sh -c 'cat "$(ls -t /var/log/yara/scan_*.log | head -n 1)"' | grep -v '^error scanning'
rm -f /tmp/eicar.com
```

Expected: `Multi_EICAR_ac8f42d6 /tmp/eicar.com` and a "YARA: 1 MATCH(ES)" message on Telegram, sent by `yara-report.service` (`journalctl -u yara-report.service -n 20 -o cat` shows it; it starts a moment after the scan ends, so wait a few seconds).

The journal of the scan also shows `yara-report.service: multiple trigger source candidates for exit status propagation`: harmless. The report is linked to the scan twice (`OnSuccess=` and `OnFailure=`), so systemd does not pass it the `MONITOR_*` variables with the scan's result; the report does not use them, it reads the result with `systemctl show`. Checked on the VM: report sent, `Result=success`. If ClamAV's scan runs first, it moves the file to the quarantine, which YARA never scans.

## 13. After a reboot

What the playbook sets up at run time must also hold after a reboot. As `v-admin`, after rebooting:

```bash
sudo aa-status | grep -E 'bwrap|unpriv_bwrap' || echo "bwrap profile not loaded"
sudo nft list table inet laptop_filter | head -3
sysctl kernel.kptr_restrict kernel.apparmor_restrict_unprivileged_userns   # 2 and 0
systemctl is-active clamav-daemon nftables
ansible-playbook site.yml -K --ask-vault-pass                               # changed=0
```

As `v`: `bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-net -- unshare -U -r true && echo "nested OK"` prints `nested OK`: the Claude Code sandbox starts on a fresh boot too.

All checked on the test VM on 14 November 2026.

## 14. Cursor (desktop)

As `v-admin`:

```bash
ls /usr/share/icons/ | grep -i macos                          # macOS only
find /usr/share/icons/macOS ! -user root | head -3            # nothing: all owned by root
cat /usr/share/glib-2.0/schemas/90_ansible-desktop.gschema.override
```

As `v`, after logging out and in again:

```bash
gsettings get org.gnome.desktop.interface cursor-theme        # 'macOS'
gsettings get org.gnome.desktop.interface cursor-size         # 24
```

The pointer is the macOS arrow, and the hand on links is the macOS hand, in the terminal, in the browser and on the login screen of a new session. GTK4 Flatpak apps (the Calculator) keep the Adwaita cursor: expected (walkthrough, Role: desktop).
