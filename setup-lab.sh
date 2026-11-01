#!/usr/bin/env bash
# Run on your Mac. Installs/updates labctl and completes login when needed.
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR=${ANSIBLE_LAB_STATE_DIR:-"$SCRIPT_DIR/.iximiuz-ansible-lab"}
MODE=new
CONTROLLER_OS=''
NODE1_OS=''
NODE2_OS=''

usage() {
  cat <<'HELP'
Usage: bash setup-lab.sh [--reuse | --new | --dry-run] [OS options]

Default: install/update labctl if needed, verify login, create a NEW flexbox
playground definition and start its three VMs. Existing labs are retained.
--reuse: reuse/resume the saved lab instead of creating a new playground.
--new: explicitly request the default fresh-playground behavior.
--dry-run: only generate the manifest; no downloads, login or remote calls.

On first login, complete the browser authentication opened by the script.

Select Rocky Linux or Ubuntu 24.04 independently for each of the three VMs.
OS options (skip the corresponding interactive menu):
  --controller rocky|ubuntu
  --node1 rocky|ubuntu
  --node2 rocky|ubuntu

Example without menus:
  bash setup-lab.sh --controller rocky --node1 rocky --node2 ubuntu

Existing --reuse labs retain their original OS choices and skip the menus.
The lab contains one controller and two managed nodes, machine-wide
Ansible Core 2.21 and its SSH/Python prerequisites. Setup prints the installed
version and the executable, configuration and hosts/inventory file locations.
State defaults to .iximiuz-ansible-lab/ next to this script. Override it with
ANSIBLE_LAB_STATE_DIR to use another local state directory.
HELP
}

MODE_SET=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --new|--reuse|--dry-run)
      if [ "$MODE_SET" = true ]; then
        printf 'Select only one mode: --new, --reuse or --dry-run.\n' >&2; exit 2
      fi
      MODE_SET=true
      case "$1" in --new) MODE=new ;; --reuse) MODE=reuse ;; --dry-run) MODE=dry-run ;; esac
      shift ;;
    --controller|--node1|--node2)
      option=$1
      if [ "$#" -lt 2 ]; then printf '%s requires rocky or ubuntu.\n' "$option" >&2; exit 2; fi
      case "$2" in rocky|ubuntu) ;; *) printf 'Unsupported OS: %s. Choose rocky or ubuntu.\n' "$2" >&2; exit 2 ;; esac
      case "$option" in
        --controller) CONTROLLER_OS=$2 ;;
        --node1) NODE1_OS=$2 ;;
        --node2) NODE2_OS=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

on_error() {
  local rc=$?
  printf '\nSetup failed (exit %s). Saved state: %s\n' "$rc" "$STATE_DIR" >&2
  printf 'Existing VMs are retained. No remote resources are automatically deleted.\n' >&2
  printf 'A normal rerun creates a new lab; use --reuse to retry the saved run.\n' >&2
  if [ -s "$STATE_DIR/play-id" ]; then
    printf 'Inspect tasks: "%s" playground tasks "%s" -o yaml\n' \
      "${LABCTL:-labctl}" "$(cat "$STATE_DIR/play-id")" >&2
  fi
  exit "$rc"
}
trap on_error ERR

umask 077
mkdir -p "$STATE_DIR"

choose_os() {
  local role=$1 selection
  while true; do
    printf '\nSelect %s OS:\n  1) Rocky Linux (platform image)\n  2) Ubuntu 24.04\nChoice [1 or 2]: ' "$role" >&2
    if ! IFS= read -r selection; then
      printf '\nNo selection received. Use --controller, --node1 and --node2 for unattended execution.\n' >&2
      exit 2
    fi
    case "$selection" in
      1|rocky) OS_CHOICE=rocky; return ;;
      2|ubuntu) OS_CHOICE=ubuntu; return ;;
      *) printf 'Please enter 1 or 2.\n' >&2 ;;
    esac
  done
}

GENERATE_MANIFEST=true
if [ "$MODE" = reuse ] && [ -s "$STATE_DIR/playground-name" ]; then
  GENERATE_MANIFEST=false
  if [ -n "$CONTROLLER_OS$NODE1_OS$NODE2_OS" ]; then
    printf 'OS options cannot change an existing --reuse lab. Omit --reuse to create a new topology.\n' >&2
    exit 2
  fi
  printf 'Reusing the saved playground configuration: %s\n' "$(cat "$STATE_DIR/playground-name")"
else
  if [ -z "$CONTROLLER_OS" ]; then choose_os controller; CONTROLLER_OS=$OS_CHOICE; fi
  if [ -z "$NODE1_OS" ]; then choose_os 'managed node 1'; NODE1_OS=$OS_CHOICE; fi
  if [ -z "$NODE2_OS" ]; then choose_os 'managed node 2'; NODE2_OS=$OS_CHOICE; fi

  case "$CONTROLLER_OS" in rocky) CONTROLLER_SOURCE=rockylinux; CONTROLLER_LABEL='Rocky Linux' ;; ubuntu) CONTROLLER_SOURCE=ubuntu-24-04; CONTROLLER_LABEL='Ubuntu 24.04' ;; esac
  case "$NODE1_OS" in rocky) NODE1_SOURCE=rockylinux; NODE1_LABEL='Rocky Linux' ;; ubuntu) NODE1_SOURCE=ubuntu-24-04; NODE1_LABEL='Ubuntu 24.04' ;; esac
  case "$NODE2_OS" in rocky) NODE2_SOURCE=rockylinux; NODE2_LABEL='Rocky Linux' ;; ubuntu) NODE2_SOURCE=ubuntu-24-04; NODE2_LABEL='Ubuntu 24.04' ;; esac
  NODE1_NAME="${NODE1_OS}-01"
  NODE2_NAME="${NODE2_OS}-02"
  # Keep generated hostnames and tab labels comfortably inside the API's
  # 20-character tab-label limit; choices come from the fixed OS allowlist.
  for hostname in controller "$NODE1_NAME" "$NODE2_NAME"; do
    if [ "${#hostname}" -gt 20 ] || ! [[ "$hostname" =~ ^[a-z][a-z0-9-]*$ ]]; then
      printf 'Invalid generated machine name: %s\n' "$hostname" >&2; exit 2
    fi
  done
  printf '\nSelected topology:\n  %-12s 172.16.0.2  %s\n  %-12s 172.16.0.3  %s\n  %-12s 172.16.0.4  %s\n\n' \
    controller "$CONTROLLER_LABEL" "$NODE1_NAME" "$NODE1_LABEL" "$NODE2_NAME" "$NODE2_LABEL"
fi

if [ "$GENERATE_MANIFEST" = true ]; then
cat > "$STATE_DIR/manifest.template.yaml" <<'YAML'
kind: playground
name: ansible-training-auto
title: Ansible Lab - __CONTROLLER_LABEL__ Controller
description: Three-machine Ansible training environment with SSH access and installation details.
categories:
  - linux
playground:
  networks:
    - name: local
      subnet: 172.16.0.0/24
  machines:
    - name: controller
      users:
        - name: laborant
          default: true
      drives:
        - source: __CONTROLLER_SOURCE__
          mount: /
          size: 10GiB
      network:
        interfaces:
          - network: local
            address: 172.16.0.2
      resources:
        cpuCount: 1
        ramSize: 2GiB
    - name: __NODE1_NAME__
      users:
        - name: laborant
          default: true
      drives:
        - source: __NODE1_SOURCE__
          mount: /
          size: 10GiB
      network:
        interfaces:
          - network: local
            address: 172.16.0.3
      resources:
        cpuCount: 1
        ramSize: 1GiB
    - name: __NODE2_NAME__
      users:
        - name: laborant
          default: true
      drives:
        - source: __NODE2_SOURCE__
          mount: /
          size: 10GiB
      network:
        interfaces:
          - network: local
            address: 172.16.0.4
      resources:
        cpuCount: 1
        ramSize: 1GiB
  tabs:
    - kind: terminal
      machine: controller
      name: Controller
    - kind: terminal
      machine: __NODE1_NAME__
      name: __NODE1_NAME__
    - kind: terminal
      machine: __NODE2_NAME__
      name: __NODE2_NAME__
  accessControl:
    canList: [owner]
    canRead: [owner]
    canStart: [owner]
  startupFiles:
    - path: /etc/ansible/hosts
      machines: [controller]
      owner: root
      mode: "644"
      content: |
        [managed]
        __NODE1_NAME__
        __NODE2_NAME__

        [managed:vars]
        ansible_user=laborant
        ansible_python_interpreter=/usr/bin/python3
    - path: /etc/ansible/ansible.cfg
      machines: [controller]
      owner: root
      mode: "644"
      content: |
        [defaults]
        inventory = /etc/ansible/hosts
        remote_user = laborant
        host_key_checking = True
    - path: /home/laborant/ansible-lab/show-details.sh
      machines: [controller]
      owner: laborant
      mode: "755"
      content: |
        #!/usr/bin/env bash
        set -Eeuo pipefail
        export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
        export ANSIBLE_CONFIG=/etc/ansible/ansible.cfg
        test -f /etc/ansible/ansible.cfg
        test -f /etc/ansible/hosts
        printf '\nAnsible installation details\n'
        printf 'Executable:     %s\n' "$(command -v ansible)"
        printf 'Package root:   /opt/ansible/lib\n'
        printf 'Configuration:  /etc/ansible/ansible.cfg\n'
        printf 'Hosts/inventory: /etc/ansible/hosts\n'
        printf '\nInstalled version and active configuration:\n'
        ansible --version
        printf '\nActive settings:\n'
        ansible-config dump --only-changed
        printf '\nInventory:\n'
        ansible-inventory --graph
  initTasks:
    init_controller_packages:
      init: true
      machine: controller
      user: root
      timeout_seconds: 900
      run: |
        set -euo pipefail
        chown -R laborant:laborant /home/laborant/ansible-lab
        . /etc/os-release
        case "$ID" in
          rocky) dnf install -y python3.12 python3.12-pip ;;
          ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y python3.12 python3-pip ;;
          *) echo "Unsupported controller OS: $ID" >&2; exit 1 ;;
        esac
        # Machine-wide installation, without venv or changes to distro-managed
        # Python packages. Global launchers supply the package search path.
        install -d -m 755 /opt/ansible/lib /usr/local/bin
        python3.12 -m pip install --upgrade --target /opt/ansible/lib 'ansible-core>=2.21,<2.22'
        for tool in ansible ansible-config ansible-console ansible-doc ansible-galaxy ansible-inventory ansible-playbook ansible-pull ansible-vault; do
          cat > "/usr/local/bin/$tool" <<EOF
        #!/bin/sh
        export PYTHONPATH=/opt/ansible/lib\${PYTHONPATH:+:\$PYTHONPATH}
        exec /usr/bin/python3.12 "/opt/ansible/lib/bin/$tool" "\$@"
        EOF
          chmod 755 "/usr/local/bin/$tool"
        done
        chmod -R a+rX /opt/ansible
        /usr/local/bin/ansible --version
    init_node_01_packages:
      init: true
      machine: __NODE1_NAME__
      user: root
      timeout_seconds: 600
      run: |
        set -euo pipefail
        . /etc/os-release
        case "$ID" in
          rocky) dnf install -y python3 python3-dnf ;;
          ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y python3 python3-apt ;;
          *) echo "Unsupported managed OS: $ID" >&2; exit 1 ;;
        esac
    init_node_02_packages:
      init: true
      machine: __NODE2_NAME__
      user: root
      timeout_seconds: 600
      run: |
        set -euo pipefail
        . /etc/os-release
        case "$ID" in
          rocky) dnf install -y python3 python3-dnf ;;
          ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y python3 python3-apt ;;
          *) echo "Unsupported managed OS: $ID" >&2; exit 1 ;;
        esac
    init_verify_setup:
      init: true
      machine: controller
      user: laborant
      needs:
        - init_controller_packages
        - init_node_01_packages
        - init_node_02_packages
      timeout_seconds: 900
      run: |
        set -euo pipefail
        export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
        export ANSIBLE_CONFIG=/etc/ansible/ansible.cfg
        cd /home/laborant/ansible-lab
        for node in __NODE1_NAME__ __NODE2_NAME__; do
          ready=false
          for attempt in $(seq 1 30); do
            if ssh -o BatchMode=yes -o ConnectTimeout=5 \
              -o StrictHostKeyChecking=accept-new \
              "laborant@$node" 'sudo -n true && /usr/bin/python3 --version'; then
              ready=true
              break
            fi
            sleep 2
          done
          if [ "$ready" != true ]; then
            echo "SSH/sudo/Python check failed for $node" >&2
            exit 1
          fi
        done
        ansible-inventory --graph
        ansible managed -m ansible.builtin.ping
        ansible managed -b -m ansible.builtin.command -a whoami
        /home/laborant/ansible-lab/show-details.sh | tee setup-details.txt
        python3.12 -m pip freeze --path /opt/ansible/lib > requirements-controller.txt
        ansible --version > ansible-version.txt
        cat /etc/os-release > controller-os-release.txt
YAML

sed -e "s/__CONTROLLER_SOURCE__/$CONTROLLER_SOURCE/g" \
    -e "s/__NODE1_SOURCE__/$NODE1_SOURCE/g" \
    -e "s/__NODE1_NAME__/$NODE1_NAME/g" \
    -e "s/__NODE2_SOURCE__/$NODE2_SOURCE/g" \
    -e "s/__NODE2_NAME__/$NODE2_NAME/g" \
    -e "s/__CONTROLLER_LABEL__/$CONTROLLER_LABEL/g" \
    -e "s/__NODE1_LABEL__/$NODE1_LABEL/g" \
    -e "s/__NODE2_LABEL__/$NODE2_LABEL/g" \
    "$STATE_DIR/manifest.template.yaml" > "$STATE_DIR/manifest.yaml"
printf 'controller=%s\n%s=%s\n%s=%s\n' "$CONTROLLER_OS" "$NODE1_NAME" "$NODE1_OS" "$NODE2_NAME" "$NODE2_OS" \
  > "$STATE_DIR/selected-topology"
fi

if [ "$MODE" = dry-run ]; then
  printf 'Manifest generated: %s/manifest.yaml\nNo remote calls made.\n' "$STATE_DIR"
  exit 0
fi

# Resolve the official installer location directly, so the current shell does
# not depend on startup-file changes or a pre-existing PATH entry.
LABCTL=''
find_labctl() {
  if [ -x "$HOME/.iximiuz/labctl/bin/labctl" ]; then
    LABCTL="$HOME/.iximiuz/labctl/bin/labctl"
  elif command -v labctl >/dev/null 2>&1; then
    LABCTL=$(command -v labctl)
  else
    return 1
  fi
}

compatible_cli() {
  local help
  help=$("$LABCTL" playground --help) || return 1
  # Old versions can print parent help and return 0 for unknown subcommands.
  printf '%s\n' "$help" | grep -Eq '^[[:space:]]+tasks[[:space:]]'
}

if ! find_labctl || ! compatible_cli; then
  printf 'Installing/updating labctl using the official iximiuz installer...\n'
  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required to download labctl.\n' >&2
    exit 1
  }
  INSTALL_DIR=$(mktemp -d "$STATE_DIR/installer.XXXXXX")
  # Download completely before executing: a failed download is never piped to sh.
  curl --fail --silent --show-error --location \
    https://labs.iximiuz.com/cli/install.sh -o "$INSTALL_DIR/install.sh"
  sh "$INSTALL_DIR/install.sh"
  rm -rf "$INSTALL_DIR"
  hash -r
  if ! find_labctl || ! compatible_cli; then
    printf 'The installed labctl lacks required task support; no lab was created.\n' >&2
    exit 1
  fi
else
  printf 'A compatible labctl is already installed.\n'
fi

authenticated() {
  local identity
  identity=$("$LABCTL" auth whoami 2>&1) || return 1
  [ -n "$identity" ] || return 1
  # Some releases report "Not logged in" with a successful exit status.
  if printf '%s\n' "$identity" | grep -Eiq \
    'not[[:space:]]+logged[[:space:]]+in|not[[:space:]]+authenticated|unauthori[sz]ed|session[[:space:]]+expired'; then
    return 1
  fi
  # Confirm a protected read succeeds as well; do not trust display text alone.
  "$LABCTL" playground list --quiet >/dev/null 2>&1
}

if ! authenticated; then
  printf 'Login is required. Complete the iximiuz sign-in in your browser.\n'
  "$LABCTL" auth login
  if ! authenticated; then
    printf 'Could not verify login after authentication; no lab was created.\n' >&2
    exit 1
  fi
fi
printf 'Authentication verified.\n'

NAME_FILE="$STATE_DIR/playground-name"
ID_FILE="$STATE_DIR/play-id"

if [ "$MODE" = new ]; then
  # Keep previous identifiers before replacing local pointers. No remote
  # stop/remove/destroy operation is performed by this script.
  if [ -s "$NAME_FILE" ]; then cat "$NAME_FILE" >> "$STATE_DIR/previous-playground-names"; fi
  if [ -s "$ID_FILE" ]; then cat "$ID_FILE" >> "$STATE_DIR/previous-play-ids"; fi
  rm -f "$NAME_FILE" "$ID_FILE"
fi

if [ -s "$NAME_FILE" ]; then
  LAB_NAME=$(cat "$NAME_FILE")
else
  printf 'Creating the reusable three-machine playground...\n'
  LAB_NAME=$("$LABCTL" playground create ansible-training-auto \
    --base flexbox -f "$STATE_DIR/manifest.yaml" --quiet)
  if ! [[ "$LAB_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    printf 'Unexpected playground name output; inspect it before retrying:\n%s\n' "$LAB_NAME" >&2
    exit 1
  fi
  printf '%s\n' "$LAB_NAME" > "$NAME_FILE"
  cp "$STATE_DIR/selected-topology" "$STATE_DIR/topology"
fi

if [ -s "$ID_FILE" ]; then
  PLAY_ID=$(cat "$ID_FILE")
  printf 'Checking saved run %s...\n' "$PLAY_ID"
  if "$LABCTL" ssh "$PLAY_ID" -m controller -- true; then
    printf 'Reusing the running lab.\n'
  else
    printf 'Saved run is not accessible; attempting to resume it...\n'
    printf 'If it was destroyed or expired, use --new to start a fresh run.\n'
    "$LABCTL" playground restart "$PLAY_ID"
  fi
else
  printf 'Starting three VMs; package installation may take several minutes...\n'
  PLAY_ID=$("$LABCTL" playground start "$LAB_NAME" --quiet --open --skip-wait-init)
  if ! [[ "$PLAY_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    printf 'Unexpected play ID output; inspect labctl playground list:\n%s\n' "$PLAY_ID" >&2
    exit 1
  fi
  printf '%s\n' "$PLAY_ID" > "$ID_FILE"
fi

printf 'Waiting for provisioning and verification tasks...\n'
"$LABCTL" playground tasks "$PLAY_ID" --wait --fail-fast

# Inspect actual guest state as well as task status. SSH below is noninteractive
# command execution; it does not install or configure applications.
"$LABCTL" ssh "$PLAY_ID" -m controller -- \
  'set -e; export PATH=/usr/local/bin:/usr/bin:/bin:$PATH; export ANSIBLE_CONFIG=/etc/ansible/ansible.cfg; /usr/local/bin/ansible managed -m ansible.builtin.ping; /usr/local/bin/ansible managed -b -m ansible.builtin.command -a whoami; /home/laborant/ansible-lab/show-details.sh'

COMMANDS_FILE="$STATE_DIR/commands-$PLAY_ID.txt"
cat <<INFO | tee "$COMMANDS_FILE"

Lab ready.
Playground: $LAB_NAME
Play ID:    $PLAY_ID

Open the controller from your Mac:
  "$LABCTL" ssh "$PLAY_ID" -m controller

Inspect provisioning tasks from your Mac:
  "$LABCTL" playground tasks "$PLAY_ID" -o yaml

List all active/stopped runs belonging to this template:
  "$LABCTL" playground list --all --filter "playground=$LAB_NAME"

Controller locations:
  Ansible executable: /usr/local/bin/ansible
  Ansible packages:   /opt/ansible/lib
  Configuration:     /etc/ansible/ansible.cfg
  Hosts/inventory:   /etc/ansible/hosts
  Saved report:      /home/laborant/ansible-lab/setup-details.txt

Show the actual installed version and locations again on the controller:
  ~/ansible-lab/show-details.sh

Test the two managed nodes:
  ansible managed -m ansible.builtin.ping

Stop and preserve this run:
  "$LABCTL" playground stop "$PLAY_ID"

Restart this run after stopping it:
  "$LABCTL" playground restart "$PLAY_ID"

Permanently delete this run and its VM data:
  "$LABCTL" playground destroy "$PLAY_ID"

Then remove its template, after ALL associated active/stopped runs are destroyed:
  "$LABCTL" playground remove "$LAB_NAME"

These management commands are printed for you to copy; setup does not execute them.

A normal rerun creates another new flexbox playground and run.
To reuse/resume this saved lab instead: bash "$SCRIPT_DIR/setup-lab.sh" --reuse
Previous labs are retained; stop them when you no longer need them.
State directory: $STATE_DIR
Command reference saved on your Mac: $COMMANDS_FILE
INFO
cp "$COMMANDS_FILE" "$STATE_DIR/commands.txt"
