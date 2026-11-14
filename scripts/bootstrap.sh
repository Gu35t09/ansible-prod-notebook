#!/bin/bash
# First step on a fresh Zorin install: Ansible in a virtual environment of the
# user, at a pinned version (Ubuntu's ansible-core is older than the one the
# server playbook is written for). Run as the user, not with sudo.
set -euo pipefail

ANSIBLE_CORE_VERSION="2.20.7"
VENV="$HOME/.local/share/ansible-venv"

[[ $EUID -ne 0 ]] || { echo "Run this as your user, not as root." >&2; exit 1; }

sudo apt-get update
sudo apt-get install -y git python3-venv

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install "ansible-core==${ANSIBLE_CORE_VERSION}"

mkdir -p "$HOME/.local/bin"
for tool in ansible ansible-playbook ansible-galaxy ansible-vault ansible-config ansible-doc; do
  ln -sf "$VENV/bin/$tool" "$HOME/.local/bin/$tool"
done

echo
echo "Ansible ${ANSIBLE_CORE_VERSION} is in $VENV, linked in ~/.local/bin."
echo "Open a new terminal (or log in again) if ~/.local/bin was not on the PATH yet, then:"
echo "  ansible-playbook site.yml -K --ask-vault-pass --check --diff"
