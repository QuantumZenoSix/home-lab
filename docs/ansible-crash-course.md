# Ansible Crash Course

This guide teaches Ansible using this repository's own [`ansible/`](../ansible/) directory. Every concept points at a real file, and every file in `ansible/` has comments explaining what each part does. Read the two side by side.

**Status: work in progress.** The playbook covers most of what [`provisioning.sh`](../provisioning/provisioning.sh) does (packages, Docker, Tailscale, Phockup, but not yet the directories it creates) plus the Restic backups (environment and secret files, scripts, systemd units, and timers). The remaining steps in [`provisioning/README.md`](../provisioning/README.md) are still manual. See [What's automated so far](#whats-automated-so-far) for which steps are done.

## Contents

1. [What Ansible is](#what-ansible-is)
2. [Set up a control node](#set-up-a-control-node)
3. [Vocabulary](#vocabulary)
4. [A tour of `ansible/`](#a-tour-of-ansible)
5. [What happens during a run](#what-happens-during-a-run)
6. [Variables](#variables)
7. [Jinja2 templating](#jinja2-templating)
8. [How idempotence is achieved](#how-idempotence-is-achieved)
9. [Secrets with Ansible Vault](#secrets-with-ansible-vault)
10. [Running it against the live Pi](#running-it-against-the-live-pi)
11. [Gotchas](#gotchas)
12. [What's automated so far](#whats-automated-so-far)
13. [Exercises](#exercises)
14. [Further reading](#further-reading)

## What Ansible is

Ansible configures machines over SSH. You describe the **state** a machine should be in (these packages installed, this file with this content and these permissions, this service enabled), and Ansible makes the machine match.

Compare a line from `provisioning.sh` with its Ansible version:

```shell
mkdir -p /var/log/journal
```

```yaml
- name: Keep the systemd journal across reboots
  ansible.builtin.file:
    path: /var/log/journal
    state: directory
    owner: root
    group: systemd-journal
    mode: "2755"
```

The shell line is an *action*: it runs every time and doesn't tell you whether anything changed. The Ansible task is a *description*. The `file` module checks the directory, fixes only what differs (missing directory, wrong owner, wrong mode), and reports either `ok` (already correct) or `changed` (it had to fix something).

This makes playbooks **idempotent**: running one twice leaves the machine the same as running it once, and the second run reports `changed=0`. So you can re-run the whole playbook against a Pi that's already set up. It only touches what has drifted, which `provisioning.sh` can't promise. A dry run with `--check --diff` shows what a real run would change, without changing it.

Other properties worth knowing:

- **Agentless.** Nothing is installed on the Pi except Python, which Raspberry Pi OS already has. Ansible connects over SSH, sends a small Python program (a *module*) for each task, runs it, and reads back the result.
- **Push-based.** You run Ansible from your own machine (the *control node*) against the Pi (a *managed node*). The control node can be any Linux machine, such as WSL or a CachyOS desktop, and you can use more than one.
- **Declarative but ordered.** Tasks run top to bottom, so order still matters, for example adding a repository before installing from it.

## Set up a control node

The control node can be any Linux machine: WSL, a desktop distribution such as CachyOS (Arch-based), Debian or Ubuntu, Fedora, and so on. Nothing is installed on the Pi; all of the steps below happen on the control node.

You can use more than one control node, for example WSL on one computer and CachyOS on another. Everything Ansible needs is in Git, except two things that you carry over by hand: your SSH key's access to the Pi, and the vault. Steps 5 and 7 cover those.

Follow the steps in order. Each one fixes a specific failure you would otherwise hit later, and the [troubleshooting table](#troubleshooting-the-first-connection) at the end maps each error message back to its step.

### 1. Get the repository and the `ansible` branch

**Why:** the playbook, roles, and inventory are all files in this repository. Until the work is merged into `main`, it lives on the `ansible` branch.

```shell
git clone https://github.com/QuantumZenoSix/home-lab.git
cd home-lab
git switch ansible
```

Git only shares changes that are committed **and** pushed. Staged or uncommitted changes exist only in the clone where you made them. So before switching computers, commit on the old one and run `git push -u origin ansible`. On the new one, `git switch ansible` (or `git pull` if the branch is already there) picks the changes up. Pushing is safe because `vault.yml` is gitignored. Before every commit, check that `git status` doesn't list it.

Keep the clone in your Linux home directory, not on a Windows drive mounted under `/mnt`. Ansible ignores an `ansible.cfg` in a world-writable directory, and Windows mounts often are.

### 2. Install Ansible and ansible-lint

**Why:** `ansible-core` provides the commands: `ansible`, `ansible-playbook`, `ansible-vault`, `ansible-doc`, `ansible-inventory`, and `ansible-galaxy`. `ansible-lint` catches mistakes and bad practices before they reach the Pi. Both are needed only on the control node.

Choose **one** way to install them. Two installs (for example, one from the distribution and one from uv) leave two different versions on your `PATH`, and it isn't obvious which one runs.

**With uv (works on every distribution):** uv installs each tool into its own isolated Python environment, so it can't conflict with system packages, and the version is the same on every machine you use.

```shell
# Install uv itself:
sudo pacman -S uv                                   # Arch / CachyOS
curl -LsSf https://astral.sh/uv/install.sh | sh     # anywhere else (Debian, Ubuntu, WSL, ...)

uv tool install ansible-core
uv tool install ansible-lint
uv tool update-shell     # adds ~/.local/bin, where uv puts the commands, to PATH; open a new terminal afterwards
```

Upgrade later with `uv tool upgrade --all`.

**With the distribution's packages (Arch / CachyOS):** Arch is a rolling release, so its packages are current, and they update with the rest of the system (`sudo pacman -Syu`).

```shell
sudo pacman -S ansible-core ansible-lint
```

On Debian and Ubuntu, the packaged `ansible-core` is often several releases behind, so use uv there.

**Check the result:**

```shell
which -a ansible-playbook    # should print exactly one path
ansible --version            # ansible-core version, its Python, and "config file = ..."
```

This playbook was written against ansible-core 2.22. It needs at least 2.15 (for the `deb822_repository` module), so any current version works.

The separate `ansible` package (on PyPI and in most distributions) is `ansible-core` plus a large bundle of community collections. Everything here so far uses only `ansible.builtin`, which ships with `ansible-core`, so the smaller package is enough. Later roles will add a `requirements.yml` listing the collections they need; see [What's automated so far](#whats-automated-so-far).

### 3. Make sure the locale works

**Why:** Ansible refuses to start unless Python can load the locale your session names (in `LANG` or `LC_ALL`). It needs a working UTF-8 locale to encode and decode command output reliably. Desktop installs such as CachyOS normally generate the locale during installation. WSL, containers, and minimal installs often don't, which is why this WSL setup failed with `could not initialize the preferred locale: unsupported locale setting`.

Ansible checks two things when it starts: that the locale loads, and that its encoding is UTF-8. This makes the same calls:

```shell
python3 -c 'import locale; locale.setlocale(locale.LC_ALL, ""); print(locale.getlocale()[1])'
```

It should print `UTF-8`. If it prints an error (`unsupported locale setting`, so the locale isn't available) or another encoding (for example with `LANG=C`), either generate the locale your session names:

```shell
# Arch / CachyOS, Debian, WSL: uncomment the locale in /etc/locale.gen, then generate it
sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && sudo locale-gen
# Ubuntu
sudo locale-gen en_US.UTF-8
```

or use `C.UTF-8`, which is built into glibc 2.35 and later and needs nothing generated. Set it in your shell's startup file:

```shell
export LC_ALL=C.UTF-8          # bash: ~/.bashrc     zsh: ~/.zshrc
set -gx LC_ALL C.UTF-8         # fish (CachyOS's default shell): ~/.config/fish/config.fish
```

### 4. Join the tailnet

**Why:** the inventory reaches the Pi as `ada-pi-server`, a name that only Tailscale's MagicDNS resolves. The Pi's firewall also accepts SSH only on its Tailscale interface ([networking-and-security.md](networking-and-security.md)). A machine that isn't on the tailnet can't connect at all, even from the same LAN.

```shell
sudo pacman -S tailscale                            # Arch / CachyOS
curl -fsSL https://tailscale.com/install.sh | sh    # anywhere else

sudo systemctl enable --now tailscaled              # the Arch package doesn't start it for you
sudo tailscale up                                   # prints a login URL
tailscale status                                    # ada-pi-server should be listed
```

On WSL, if Windows already runs Tailscale, WSL usually reaches the tailnet through Windows' network connection, so you can skip this. To check, run `ssh ada@ada-pi-server` from WSL.

### 5. Give this machine an SSH key the Pi accepts

**Why:** Ansible connects with plain SSH, using your keys, SSH agent, and `~/.ssh/config`. The Pi has password logins disabled, so `ssh-copy-id` (which logs in with a password to install the key) can't work. The new key has to be added from a machine that already has access.

Give each control node its own key, rather than copying a private key between machines. If one machine is lost, you remove just its line from the Pi's `~/.ssh/authorized_keys`.

On the new machine, create a key and print the public half:

```shell
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname) -> ada-pi-server"
cat ~/.ssh/id_ed25519.pub
```

The public key is safe to copy anywhere. On a machine that can already log in to the Pi, append it to the Pi's authorized keys:

```shell
ssh ada@ada-pi-server "echo 'ssh-ed25519 AAAA...rest of the line...' >> ~/.ssh/authorized_keys"
```

### 6. Log in once by hand

**Why:** the first SSH connection to a new host asks you to confirm its host key fingerprint. Ansible can't answer that prompt, so it fails with `Host key verification failed`. Connecting once by hand saves the key in `~/.ssh/known_hosts`. The same command also checks sudo: the playbook runs most tasks with `sudo`, and Ansible needs either passwordless sudo or the sudo password.

```shell
ssh ada@ada-pi-server 'sudo -n true && echo "passwordless sudo OK"'
```

Answer `yes` to the fingerprint prompt. If the second part fails instead of printing `passwordless sudo OK`, sudo needs a password on this Pi. Add `--ask-become-pass` (short form `-K`) to every `ansible-playbook` command and Ansible will ask for it. (Raspberry Pi OS normally gives the user created in the Imager passwordless sudo.)

### 7. Bring over the vault, or create it

**Why:** the vault holds the real secrets, and because the repository is public it's gitignored, so cloning doesn't bring it.

- **If you've already created `vault.yml` on another machine,** copy that file into `ansible/inventory/host_vars/ada-pi-server/` on this one. Use any method (scp, a USB stick, an attachment in your password manager). It's encrypted, so the file is useless without the vault password, which belongs in your password manager.
- **If it doesn't exist yet,** create it from `vault.yml.example` as described in [Secrets with Ansible Vault](#secrets-with-ansible-vault).

Once `vault.yml` exists, Ansible decrypts it whenever it loads the inventory. So every command from here on needs `--ask-vault-pass`, or a vault password file ([see below](#day-to-day)).

### 8. Test the connection

**Why:** this one command checks everything above at once: the config is picked up, the inventory resolves, Tailscale DNS works, the SSH key and host key are in place, Python runs on the Pi, and the vault decrypts. Run it from `ansible/`, because that's where `ansible.cfg` is:

```shell
cd ansible
ansible homelab -m ansible.builtin.ping --ask-vault-pass
```

A reply of `"ping": "pong"` means you're ready. This is an **ad-hoc command**: a single module run against hosts from the command line, without a playbook. It's handy for quick checks.

### 9. Run the linter

**Why:** `ansible-lint` is the safety net for every edit you make. It catches syntax errors, deprecated modules, and practices known to cause trouble, all without touching the Pi. Make it a habit before every run against the Pi:

```shell
ansible-lint --profile production
```

The playbook currently passes on this strictest profile, so any finding comes from your latest change.

**Next:** your first dry run. See [Running it against the live Pi](#running-it-against-the-live-pi).

### Troubleshooting the first connection

| Error | Cause | Fix |
|---|---|---|
| The shell can't find `ansible` ("command not found", or "Unknown command" in fish) | `~/.local/bin` isn't on `PATH` | Step 2 (`uv tool update-shell`, then open a new terminal) |
| `could not initialize the preferred locale` | The session's locale isn't available | Step 3 |
| `ansible --version` shows `config file = None` | You aren't in the `ansible/` directory, or it's world-writable | `cd ansible` (step 8); keep the clone under your home directory (step 1) |
| `Could not resolve hostname ada-pi-server` | Not on the tailnet | Step 4 |
| `Permission denied (publickey)` | The Pi doesn't know this machine's key | Step 5 |
| `Host key verification failed` | The Pi's host key isn't in `known_hosts` | Step 6 |
| `Missing sudo password` | Sudo needs a password on the Pi | Add `-K` (step 6) |
| `Attempting to decrypt but no vault secrets found` | `vault.yml` exists but no vault password was given | Add `--ask-vault-pass` (step 7) |
| The restic role's first task fails: "needs the real secrets" | `vault.yml` is missing or still has placeholders | Step 7 |

## Vocabulary

| Term | Meaning | Example here |
|---|---|---|
| **Control node** | The machine you run Ansible from | WSL, or your CachyOS machine |
| **Managed node** | A machine Ansible configures | `ada-pi-server` |
| **Inventory** | The list of managed nodes, organized into groups, with how to reach them | [`inventory/hosts.yml`](../ansible/inventory/hosts.yml) |
| **Module** | A unit of work with options, e.g. `apt`, `file`, `template`, `systemd_service` | `ansible.builtin.apt` |
| **Task** | One call to a module, with a `name` | "Install core packages" |
| **Play** | A set of hosts paired with the tasks or roles to run on them | The one play in `site.yml` |
| **Playbook** | A YAML file containing one or more plays | [`site.yml`](../ansible/site.yml) |
| **Role** | A reusable bundle of tasks, defaults, handlers, and templates in a standard folder layout | `roles/restic/` |
| **Handler** | A task that runs only when notified by a task that changed something, once, at the end of the play | "Restart Docker" |
| **Facts** | Information Ansible gathers about each host at the start of a play | `ansible_facts['mounts']` |
| **Template** | A file containing Jinja2 placeholders, rendered with variables and copied to the host | `restic-env.j2` |
| **Vault** | Ansible's tool for encrypting secret files | `vault.yml` |
| **Become** | Privilege escalation, normally sudo | `become: true` in `site.yml` |
| **Tag** | A label on tasks or roles so you can run just those | `--tags restic` |
| **Collection** | A package of modules and plugins. `ansible.builtin` comes with ansible-core; others are installed with `ansible-galaxy` | `community.docker` (needed later) |
| **FQCN** | Fully qualified collection name: a module's full name, including its collection | `ansible.builtin.template` instead of `template` |

## A tour of `ansible/`

```text
ansible/
├── ansible.cfg                  Settings for commands run from this directory
├── site.yml                     The main playbook: one play, five roles, and a cleanup task
├── .gitignore                   Keeps the real vault.yml out of Git
├── inventory/
│   ├── hosts.yml                Hosts and groups, and how to reach them
│   └── host_vars/
│       └── ada-pi-server/       Everything in here is loaded for ada-pi-server
│           ├── vars.yml         Plain settings: user, mount points, Kuma URL
│           └── vault.yml.example  Placeholder secrets. Copy to vault.yml and encrypt it.
└── roles/
    ├── base/                    OS checks, packages, journald, SSH
    │   ├── defaults/main.yml    Package lists (overridable)
    │   ├── tasks/main.yml       The tasks
    │   └── handlers/main.yml    Restart journald
    ├── docker/                  Docker apt repo, Engine and Compose, daemon.json, docker group
    │   └── templates/daemon.json.j2
    ├── tailscale/               Tailscale apt repo, package, and service (tailnet join is still manual)
    ├── phockup/                 uv, the Phockup clone in /opt/phockup, and its venv
    └── restic/                  Everything for the backups
        ├── defaults/main.yml    Settings: schedules, retention, host tags, paths
        ├── vars/main.yml        Internal structure: the two repositories and their files
        ├── tasks/main.yml       Secrets, scripts, units, timers
        ├── tasks/init.yml       Optional: create repositories that don't exist yet
        ├── handlers/main.yml    systemctl daemon-reload
        └── templates/           The scripts, env files, and units, as Jinja2 templates
```

### Role layout

Ansible finds a role's files by folder name, so the names matter:

| Folder | Holds | Loaded |
|---|---|---|
| `tasks/main.yml` | The role's tasks | Always; it's the entry point |
| `handlers/main.yml` | Handlers that tasks can `notify` | Always |
| `defaults/main.yml` | Variables with the lowest precedence, meant to be overridden | Always |
| `vars/main.yml` | Variables with high precedence, internal to the role | Always |
| `templates/` | Jinja2 files for the `template` module, referred to by bare filename | When a task uses them |
| `files/` | Static files for the `copy` module (none here yet) | When a task uses them |
| `meta/main.yml` | Role metadata and dependencies (none here yet) | Always |

`ansible-galaxy role init --init-path roles <name>` creates this skeleton for a new role (delete the folders you don't use).

### How `ansible/` relates to `filesystem/` and `provisioning/`

- The restic templates were generated from the copies in [`filesystem/`](../filesystem/), with hardcoded values (paths, host tags, retention, the Kuma URL) replaced by variables. With `ada-pi-server`'s variables, the scripts render byte-for-byte the same as `filesystem/`, apart from a "Managed by Ansible" header.
- From now on, **the templates are the source of truth** for any file that Ansible manages. A hand edit on the Pi gets reverted on the next run. Make the change in the template (and, for now, in the `filesystem/` copy too, until we decide whether to retire those copies).
- `provisioning.sh` stays until the playbook covers everything. Running both on the same Pi is safe: the docker and tailscale roles remove the old-style apt repository files that the script writes before adding their own.

## What happens during a run

When you run `ansible-playbook site.yml`:

1. **Config.** `ansible.cfg` is read from the current directory. It sets the inventory path, the roles path, and output format.
2. **Inventory.** `hosts.yml` is parsed, then `host_vars/ada-pi-server/*.yml` is loaded (decrypting `vault.yml` with your vault password).
3. **Play start.** The play in `site.yml` targets `hosts: homelab`, which resolves to `ada-pi-server`. With `become: true`, tasks run as root through sudo.
4. **Fact gathering.** The implicit "Gathering Facts" task runs the `setup` module: OS, architecture, mounts, network, and so on, stored in `ansible_facts`.
5. **Roles, in order.** For each role, its `defaults/` and `vars/` are loaded, then `tasks/main.yml` runs from top to bottom. Tasks that change something queue their notified handlers.
6. **post_tasks.** The cleanup task in `site.yml` runs.
7. **Handlers.** Any queued handlers run once each. The restic role flushes them earlier with `meta: flush_handlers`, because it needs `daemon-reload` before it enables the timers.
8. **Recap.** A summary per host: `ok`, `changed`, `failed`, `skipped`, and so on.

If a task fails, Ansible stops running tasks **on that host**. Handlers that were already queued don't run, unless you pass `--force-handlers`.

## Variables

### Where variables come from

The variables used here, from lowest to highest precedence. The higher one wins when two sources set the same name:

| Precedence | Source | Example here |
|---|---|---|
| Lowest | Role defaults, `roles/*/defaults/main.yml` | `restic_system_backup_schedule` |
| | Inventory `group_vars/` | None yet |
| | Inventory `host_vars/` | `homelab_user`, the `vault_*` secrets |
| | Gathered facts | `ansible_facts` |
| | Role vars, `roles/*/vars/main.yml` | `restic_repos` |
| | Task `vars:` | `restic_vault_values` in the restic assert |
| | `set_fact` and `register` | `restic_backup_drive_mounted`, `docker_repo` |
| Highest | Extra vars on the command line, `-e name=value` | `-e restic_init_repos=true` |

The full list has 22 levels (see [Further reading](#further-reading)). In practice: put **overridable settings in role defaults**, put **per-lab values in inventory**, and use **`-e` for one-off overrides**.

To see exactly what a host ends up with:

```shell
ansible-inventory --host ada-pi-server                                  # every inventory variable
ansible ada-pi-server -m ansible.builtin.debug -a "var=homelab_backup_mount"   # one variable, fully evaluated
```

Both commands see only inventory variables. Role defaults exist only while a play runs that role, so `-a "var=restic_system_host_tag"` shows as undefined here.

### Naming conventions used here

- **`homelab_*`**: lab-wide values used by several roles, set in `host_vars/`.
- **`<role>_*`**: a role's own variables (`restic_*`, `docker_*`, ...). ansible-lint enforces this, so two roles can't accidentally clash.
- **`vault_*`**: secrets, defined only in `vault.yml`. Roles refer to them indirectly (see `restic_secrets` in `roles/restic/vars/main.yml`), so `grep vault_` finds every place a secret is used even while `vault.yml` is encrypted.

### Lazy evaluation

Variable values containing `{{ }}` are evaluated when a task uses them, not when the file is loaded. That is why `roles/restic/defaults/main.yml` can define `restic_tmp_dir: "{{ homelab_backup_mount }}/restic-tmp"` even though `homelab_backup_mount` comes from the inventory.

## Jinja2 templating

Ansible uses [Jinja2](https://jinja.palletsprojects.com/) everywhere: in task arguments, `when:` conditions, and template files.

| Syntax | Purpose | Example here |
|---|---|---|
| `{{ expr }}` | Insert a value | `dest: "{{ item.env_file }}"` |
| `expr \| filter` | Transform a value | `base_optional_packages \| join(' ')`, `docker_dns \| to_json` |
| `expr is test` | Yes/no question about a value | `docker_repo is changed`, `vault_restic_b2_bucket is defined` |
| `{% if %}`, `{% for %}`, `{% set %}` | Logic, in template files | The `{% if %}` around the AWS keys in `restic-env.j2` |
| `{# comment #}` | Template comment, not rendered | None here (and see [Gotchas](#gotchas)) |

A longer example from `roles/restic/tasks/main.yml`:

```yaml
restic_backup_drive_mounted: "{{ homelab_backup_mount in (ansible_facts['mounts'] | map(attribute='mount')) }}"
```

Read it inside out: `ansible_facts['mounts']` is a list of dictionaries, one per mount. `map(attribute='mount')` turns that into a list of mount-point paths, and `in` checks whether the backup drive's path is among them. The result is `true` or `false`.

`when:` conditions are already Jinja expressions, so they don't take `{{ }}`: write `when: restic_enable_timers | bool`, not `when: "{{ restic_enable_timers }}"`.

Useful filters to know: `default('x')` (fall back when undefined), `bool`, `int`, `length`, `join`, `map`, `select`/`selectattr`, `to_json`/`to_nice_yaml`, `basename`/`dirname`, `quote` (shell-escape a value).

## How idempotence is achieved

Most modules are idempotent by themselves. Where they aren't, these tools make a task report the truth:

| Tool | What it does | Example here |
|---|---|---|
| A module's `state:` | Describe the end state; the module works out what to do | `state: present`, `state: directory`, `state: absent` |
| `creates:` | Skip a `command`/`shell` task if a path exists | The uv install and the Phockup venv |
| `changed_when:` | Decide when a `command`/`shell` task counts as "changed" | `changed_when: false` on read-only checks |
| `failed_when:` | Decide when a task counts as failed | `failed_when: false` on `restic cat config` |
| `check_mode: false` | Run a read-only task even during `--check`, so later tasks can use its result | The optional-package lookup |
| `register` + `when` | Act only based on an earlier result | Install the optional packages that exist |
| `notify` + handlers | Restart or reload only when a config file actually changed | `Restart Docker`, `Reload systemd` |
| `validate:` | Check a rendered file before it replaces the live one | `bash -n %s` on the backup scripts |

Prefer a real module over `command`/`shell` when one exists. Use `ansible-doc -l | grep <word>` to search, and `ansible-doc ansible.builtin.<module>` to read a module's options and examples offline.

## Secrets with Ansible Vault

`ansible-vault` encrypts a YAML file with AES-256 using a password you choose. Ansible decrypts it in memory during a run.

### First-time setup

```shell
cd ansible/inventory/host_vars/ada-pi-server
cp vault.yml.example vault.yml
$EDITOR vault.yml                 # replace every placeholder with the real value
ansible-vault encrypt vault.yml   # choose a strong vault password
```

### Day to day

```shell
ansible-vault view vault.yml       # read it
ansible-vault edit vault.yml       # decrypts into $EDITOR, re-encrypts when you save
ansible-vault rekey vault.yml      # change the vault password
ansible-playbook site.yml --ask-vault-pass
```

Ansible decrypts an encrypted file in `host_vars/` as soon as it loads the inventory. So once `vault.yml` exists, **every** command needs the vault password: `ansible-playbook`, ad-hoc `ansible` commands, and `ansible-inventory`. To avoid typing it each time, set `vault_password_file` in `ansible.cfg` (or pass `--vault-password-file`). It can point at a file such as `ansible/.vault_pass` (chmod 600, already gitignored), or at an executable script that prints the password, for example by fetching it from Bitwarden or 1Password with their CLIs.

### Choices made here

- **`vault.yml` isn't committed.** The repository is public. An encrypted vault is safe to publish with a strong password, but leaving it out removes the risk entirely. The trade-off is that you must back it up yourself, along with its password, in your password manager. The README's "Before you start" table already lists the secrets as stored off the Pi, so `vault.yml` becomes that list in one file.
- **A good next step** for running several labs: move `inventory/` into a separate private Git repository, commit the encrypted `vault.yml` there, and point at it with `ansible-playbook -i ../home-lab-private/inventory site.yml`. The roles stay public and generic.
- **The restic role refuses to run with placeholders.** Its first task is an `assert` that fails if any secret is missing or still looks like `****` or `XXXX`.

### Keeping secrets out of the output

Ansible prints task arguments and results, and `--diff` prints file contents. The tasks that write secrets set:

- `no_log: true`, which hides arguments and results (including error messages, so to debug, comment it out temporarily and don't commit that).
- `diff: false`, which never shows that file's diff.

The loops also set `loop_control.label`, so only a file path is printed for each item, not the whole item. For the same reason, `restic_repos` (looped over and printed) contains no secrets; the secrets are kept in `restic_secrets`.

## Running it against the live Pi

The Pi was set up by hand and with `provisioning.sh`, so the first run is mostly about confirming that the playbook agrees with reality. Run it from `ansible/`.

**1. Dry run with diffs.** Nothing on the Pi changes:

```shell
ansible-playbook site.yml --ask-vault-pass --check --diff
```

What to expect on the first run:

| Role | Expected changes | Why |
|---|---|---|
| docker, tailscale | `docker.list`/`tailscale.list` and their keyrings removed; `docker.sources`/`tailscale.sources` added | Moving to apt's deb822 format |
| restic | Every script, unit, and env file shows as changed | The new "Managed by Ansible" header, and the timer descriptions now include the schedule |
| restic | `/etc/kuma-env*` mode `0644` → `0600` | Fixes the permissions noted in `provisioning/README.md` step 7 |
| restic | Password files, only if their content differs | The diff is hidden. A missing trailing newline in the live file is enough to count as a change, and harmless. |
| restic | "Reload systemd" handler runs | Because the unit files changed |
| base | Possibly `/var/log/journal` ownership, and any optional packages that are missing | Ansible enforces what the script only created |
| phockup | Nothing, if uv, the clone, and the venv already exist | `creates:` and `update: false` |

Anything else in the diff is real drift between the Pi and this repository. Look into it before applying.

**Check mode limits:** a task that depends on an earlier task's change can fail in check mode, because the earlier change was only simulated. On a *fresh* Pi, for example, "Install Docker Engine" fails with "No package matching 'docker-ce'", because the repository wasn't really added. On the live Pi, where everything already exists, this doesn't happen.

**2. Apply one role at a time,** starting with the lowest-risk ones:

```shell
ansible-playbook site.yml --ask-vault-pass --tags base
ansible-playbook site.yml --ask-vault-pass --tags docker,tailscale
ansible-playbook site.yml --ask-vault-pass --tags phockup
ansible-playbook site.yml --ask-vault-pass --tags restic
```

Other ways to narrow a run: `--step` asks for confirmation before each task, `--start-at-task "Install the backup scripts"` skips everything before that task, and `--limit ada-pi-server` restricts a run to one host once there's more than one.

**3. Check the result on the Pi:**

```shell
systemctl list-timers 'restic-*'
sudo ls -l /etc/restic-* /etc/kuma-env*        # all -rw------- root root
sudo bash -n /usr/local/sbin/restic_backup_system.sh
```

**4. Run the full playbook again.** The recap should show `changed=0`. If a task changes on every run, it isn't idempotent; that's a bug to fix.

## Gotchas

- **`user: groups:` without `append: true`** replaces all of the user's supplementary groups, which can take away sudo. The docker role uses `append: true`.
- **Quote values that start with `{{`.** In YAML, `dest: {{ path }}` is read as a dictionary. Write `dest: "{{ path }}"`.
- **Quote file modes.** `mode: 0644` without quotes is read as an octal number and can end up wrong. Always write `mode: "0644"`.
- **Jinja in non-Ansible files.** A template is parsed as Jinja before anything else, so `{#`, `{{`, and `{%` in a shell script break it. Bash's `${#array[@]}` contains `{#`, which starts a Jinja comment. Wrap such sections in `{% raw %}...{% endraw %}`. The current backup scripts contain none of these.
- **`command` vs `shell`.** `command` runs a program directly: no pipes, redirects, `source`, `~`, or `$VARS`. Use `shell` only when you need those, and then add `set -o pipefail` with `executable: /bin/bash`.
- **`creates:` doesn't expand `~`.** Use full paths, like `phockup_uv`.
- **Handlers run at the end of the play.** If a later task depends on a restart or reload, use `meta: flush_handlers` first, as the restic role does before enabling timers.
- **`become_user` to a different non-root user** needs the `acl` package on the host for Ansible's temporary files when the SSH user differs. The base role installs it. Here the SSH user and the become user are both `ada`, so it isn't needed yet.
- **Ansible ignores `ansible.cfg` in a world-writable directory,** such as Windows drives mounted under `/mnt` in WSL, or some network and USB mounts. Keep the repository in your Linux home folder.
- **Hand edits on the Pi get reverted.** Once Ansible manages a file, change the template, not the file.

## What's automated so far

| `provisioning.sh` / README step | Ansible | Status |
|---|---|---|
| Script: OS checks, packages, optional packages, journald, SSH | `base` role | Done |
| Script: Docker repo, packages, `daemon.json`, docker group | `docker` role | Done |
| Script: Tailscale repo and package | `tailscale` role | Done |
| Script: uv, Phockup, venv, symlink | `phockup` role | Done |
| Script: drive mount points | Future `storage` role | Not yet |
| Script: `~/scripts` | Future `automation` role | Not yet |
| Script: Compose directories, `~/containers/<project>` | Future `stacks` role | Not yet |
| Step 3: `tailscale up` | `tailscale` role, with an auth key from the vault | Not yet |
| Step 4: SSH hardening | Future `hardening` role: an sshd drop-in template, checked with `sshd -t` before it's applied | Not yet |
| Step 5: UFW | Future `hardening` role: `community.general.ufw` | Not yet |
| Step 6: fstab | Future `storage` role: `ansible.posix.mount`, drive UUIDs in `host_vars` | Not yet |
| Step 7: Restic and Kuma files | `restic` role | Done |
| Step 7: photo and Obsidian scripts, their `.env_*` files, units | Future `automation` role (same pattern as `restic`) | Not yet |
| Step 7: Compose files with secrets | Future `stacks` role: templates plus `community.docker.docker_compose_v2` | Not yet |
| Step 8: `restic init` | `restic` role, opt-in with `-e restic_init_repos=true` | Done |
| Step 9: start containers; signal-api | Future `stacks` role. signal-api needs a Compose file first (see the step 9 TODO). | Not yet |
| Step 10: Uptime Kuma monitors | Stays manual for now, or restored from backup | Manual |
| Step 11: systemd timers | `restic` role (backup timers); `automation` role later | Partly done |

The `community.*` and `ansible.posix` collections aren't part of ansible-core. When the first role needs one, add an `ansible/requirements.yml` listing them, and install with `ansible-galaxy collection install -r requirements.yml`.

## Exercises

Run these from `ansible/`. None of them change the Pi. Once `vault.yml` exists, add `--ask-vault-pass` to each command (or set up a vault password file).

1. **Inventory.** Run `ansible-inventory --graph` and `ansible-inventory --host ada-pi-server`. Find where each value is defined.
2. **Facts.** Run `ansible ada-pi-server -m ansible.builtin.setup -a "filter=ansible_mounts"`. Find the two USB drives. This is the data the restic role uses to decide whether the backup drive is mounted.
3. **Ad-hoc commands.** Run `ansible homelab -m ansible.builtin.command -a "systemctl list-timers --no-pager"`. Then try `-m ansible.builtin.apt -a "name=restic state=present" --become --check`. Why does it report `ok`?
4. **Overrides.** Add `restic_system_backup_schedule: "*-*-* 02:00:00"` to `host_vars/ada-pi-server/vars.yml`, then run `ansible-playbook site.yml --ask-vault-pass --tags restic --check --diff`. Which files change, and which handler is notified? Then remove the line. Try the same override with `-e` instead of editing the file.
5. **Module docs.** Run `ansible-doc ansible.builtin.template` and find what `backup: true` does. Would it be useful for the backup scripts?
6. **Lint.** Run `ansible-lint`. Then remove `append: true` from the docker role's user task and run it again. (ansible-lint doesn't catch that one, which is why it's in [Gotchas](#gotchas).) Put the line back.
7. **Write a task.** Add a task to the `base` role that sets the timezone with `community.general.timezone`. It's a collection module, so you'll need to install the collection first. Run it in check mode.

## Further reading

- [Ansible getting started](https://docs.ansible.com/ansible/latest/getting_started/index.html)
- [Variable precedence](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html#understanding-variable-precedence): all 22 levels
- [Playbook keywords](https://docs.ansible.com/ansible/latest/reference_appendices/playbooks_keywords.html): everything you can put on a play, role, block, or task
- [Roles](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html)
- [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
- [ansible-lint rules](https://docs.ansible.com/projects/lint/rules/)
- *Ansible for DevOps* by Jeff Geerling: a practical book that builds real server setups step by step
