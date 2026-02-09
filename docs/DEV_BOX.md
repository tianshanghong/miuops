# Remote Dev Box Module

The `dev_box` role turns any Ubuntu/Debian host into a ready-to-code remote workstation. It installs terminal-first tooling (zsh, tmux, mosh), configures NVM + Node.js, and adds the Codex CLI so you can drop into a tmux session from an iPad or laptop and start shipping.

## Features

- Keeps the host fully updated via the main playbook, then layers on:
  - zsh (default shell) with sane defaults and automatic tmux attach
  - tmux configuration tuned for long-lived remote sessions
  - mosh server for low-latency roaming connections (opens UDP 60000-61000 when enabled)
  - nvm + Node `lts` release pre-installed
  - Codex CLI installed globally via npm (user completes `codex auth` later)
- Runs entirely under the Ansible SSH user (`ansible_user`) so it works for root or non-root accounts.
- Optional by default—only runs when `dev_box_enabled: true`.

## Enabling the Dev Box

1. In `group_vars/all.yml` (or per-host vars) set:
   ```yaml
   dev_box_enabled: true
   dev_box_node_version: "lts"        # or a specific version like 20.11.1
   dev_box_install_codex_cli: true     # set false if you want to skip npm install
   dev_box_auto_tmux: true             # disable if you prefer manual tmux attachment
   ```
2. The firewall role automatically opens the mosh UDP range (`dev_box_mosh_port_start/end`, default 60000-61000) whenever the dev box is enabled. Adjust those vars if you need a different range.
3. Run the playbook as usual (optionally limit to your workstation host):
   ```bash
   ansible-playbook playbook.yml --limit workstation-host
   ```

## After Provisioning

- SSH/mosh into the host; you should land in zsh and auto-attach to the `default` tmux session.
- If Codex CLI was installed, run `codex auth` to link your OpenAI account.
- Customize `~/.zshrc` or `~/.tmux.conf` further if desired—they’re generated once but can be edited safely; re-running the role will update them.

## Customizing

- Override `dev_box_packages` in host/group vars to add more system packages.
- Set `dev_box_shell` if you prefer a different shell path.
- Change `dev_box_nvm_version` or `dev_box_node_version` to pin a specific NVM/Node release.
- Set `dev_box_install_codex_cli: false` if you don’t want the CLI installed automatically.

This keeps the VPS lean yet productive: you log in, attach to tmux, and the same box can host your services once you’re ready to deploy.
