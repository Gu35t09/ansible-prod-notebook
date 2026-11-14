# Verification

Commands to check each part on the laptop, after `ansible-playbook site.yml -K` (run as `v-admin`). Sections 1–5 as `v-admin`, section 6 as `v`.

## 1. Playbook

```bash
ansible-playbook site.yml -K          # a second run must report changed=0
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

## 4. Privacy

```bash
dpkg -l zorin-os-census apport whoopsie kerneloops ubuntu-report popularity-contest snapd 2>&1 | grep -E '^ii' || echo "none installed"
apt-cache policy snapd | grep -E 'Candidate|-10'
systemctl is-enabled motd-news.timer           # masked
nmcli general permissions >/dev/null; busctl get-property org.freedesktop.NetworkManager \
  /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled   # b false
```

What the laptop still sends by itself (half an hour, desktop idle):

```bash
sudo timeout 1800 tcpdump -i any -n -l port 53 2>/dev/null | grep -oE '(A|AAAA)\? [^ ]+' | sort | uniq -c | sort -rn
```

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

In `mkdir -p ~/progetti/prova && cd ~/progetti/prova && claude`, ask Claude to run each of these. Every one must fail or ask you, never succeed silently:

| Request | Expected |
| --- | --- |
| `curl -sI https://example.com` | A prompt for `example.com` (answer no: it fails) |
| `curl -sI https://github.com` | Works (allowed domain) |
| `touch ~/fuori.txt` | Fails (read-only outside the project), no retry outside the sandbox |
| `cat ~/.ssh/config` | Refused (outside the working directory and denied) |
| `ssh v@10.123.11.11` | Refused (denied rule) |
| `sudo true` | Refused |

`/status` in Claude shows the managed settings among the sources; `/permissions` shows the deny rules; Shift+Tab must not offer auto or bypass mode.
