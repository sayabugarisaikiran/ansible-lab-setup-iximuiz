# Ansible Lab Setup on iximiuz Labs

Create a three-machine Ansible lab from your Mac with one command. Select Rocky Linux or Ubuntu independently for the controller and each managed node.

## Run

```sh
git clone https://github.com/sayabugarisaikiran/ansible-lab-setup-iximuiz.git
cd ansible-lab-setup-iximuiz
bash setup-lab.sh
```

The script installs or updates `labctl` when necessary, checks authentication, and opens `labctl auth login` if needed. Complete the browser sign-in when prompted. It verifies authentication before creating a new owner-only flexbox playground and starting its three machines.

## Select the machines

Each menu offers:

```text
1) Rocky Linux (platform image)
2) Ubuntu 24.04
```

Choose separately for the controller, managed node 1, and managed node 2. The selected topology is printed before provisioning.

| Machine | Private IP | Resources |
| --- | --- | --- |
| controller | 172.16.0.2 | 1 CPU, 2 GiB RAM |
| `<os>-01` | 172.16.0.3 | 1 CPU, 1 GiB RAM |
| `<os>-02` | 172.16.0.4 | 1 CPU, 1 GiB RAM |

Rocky uses the platform's `rockylinux` image; its major release is controlled by iximiuz. Ubuntu uses `ubuntu-24-04`. These named images are not immutable image digests. Both supplied distributions use the existing `laborant` user with platform-provided cross-machine SSH and passwordless sudo.

You can supply the choices without menus:

```sh
bash setup-lab.sh --controller rocky --node1 rocky --node2 ubuntu
```

## What is prepared

- The three Linux VMs, shared network, and one regular browser terminal tab per machine.
- Python 3.12 and Ansible Core 2.21 on the controller, with global command launchers.
- Python and package-manager prerequisites on the two managed nodes.
- A system-wide Ansible configuration and hosts/inventory file.
- SSH, passwordless sudo, and Ansible ping checks.
- A report containing the actual installed version and file locations.
- tmux and a three-pane recording helper on the controller.

No application/demo playbooks are run and no web server is installed by this script. The provided base images may already contain their own standard tools.

Ansible is installed machine-wide under `/opt/ansible/lib`, with commands under `/usr/local/bin`. There is no virtual environment or activation step. The explicit package destination avoids replacing the distributions' OS-managed Python libraries. Ansible is installed only on the controller.

## Output and locations

After provisioning, the script runs `ansible --version` on the real controller and displays its output. The exact patch version is obtained from the installation; it is not hard-coded in the summary.

| Item | Controller path |
| --- | --- |
| Ansible executable | `/usr/local/bin/ansible` |
| Ansible packages | `/opt/ansible/lib` |
| Python interpreter | `/usr/bin/python3.12` |
| Configuration file | `/etc/ansible/ansible.cfg` |
| Hosts/inventory file | `/etc/ansible/hosts` |
| Saved setup report | `/home/laborant/ansible-lab/setup-details.txt` |
| Report command | `/home/laborant/ansible-lab/show-details.sh` |

Managed machines are named from their OS and position: `ubuntu-01` / `ubuntu-02` or `rocky-01` / `rocky-02`. A mixed selection can produce `rocky-01` and `ubuntu-02`. These names are used consistently in the VM hostname, terminal tab, inventory, and SSH checks. Tab labels stay within the platform's 20-character limit. The controller remains `controller`, with the tab label `Controller`.

The configuration explicitly uses `/etc/ansible/hosts`. Both managed hostnames are listed in the `managed` group. The report also shows active settings and the inventory graph.

From the controller terminal:

```sh
~/ansible-lab/show-details.sh
ansible --version
ansible-inventory --graph
ansible managed -m ansible.builtin.ping
```

To inspect or edit the standard files:

```sh
cat /etc/ansible/ansible.cfg
cat /etc/ansible/hosts
sudo vim /etc/ansible/ansible.cfg
sudo vim /etc/ansible/hosts
```

Other project-local configuration files or the `ANSIBLE_CONFIG` environment variable can override the standard config for ordinary commands. The report helper explicitly selects `/etc/ansible/ansible.cfg`; use `ansible --version` in your working directory to see the active configuration.

## Ready-to-copy management commands

After setup completes, the terminal prints commands with the actual play ID and playground name already filled in. They cover controller SSH, task inspection, listing runs for the template, stopping, restarting, destroying the run, and removing its template. The resolved `labctl` executable path is included so the commands also work immediately after a fresh CLI installation.

Destroy permanently deletes that run's VMs/data. Remove the template only after all its active or stopped runs have been destroyed; the filtered listing command helps identify them. Setup prints these commands and does not execute the stop, destroy or remove actions automatically.

The same command reference is saved on your Mac in:

```text
.iximiuz-ansible-lab/commands-<actual-play-id>.txt
.iximiuz-ansible-lab/commands.txt
```

The first file belongs to that specific run; `commands.txt` contains the latest successful run's reference. To display it later from the repo directory:

```sh
cat .iximiuz-ansible-lab/commands.txt
```

## Three-pane recording view

tmux is installed on either controller OS through its package manager. On the controller, run:

```sh
~/ansible-lab/recording-view.sh
```

The controller occupies the left pane; the two managed-node SSH sessions are stacked on the right. The helper uses the actual selected hostnames, such as `ubuntu-01` and `rocky-02`. Mouse selection and divider resizing are enabled. Running the helper again reconnects to the same session. It works in a browser terminal or a Mac terminal connected to the controller.

To detach, press Control+B, release, then D. Reconnect using the helper command. Existing labs created without tmux/helper files require a fresh run to receive the new provisioning; `--reuse` does not rerun init tasks.

## Reuse, fresh runs and previews

Every normal execution creates a fresh playground definition and run. Previous labs are retained. The latest name and play ID are stored in `.iximiuz-ansible-lab/` next to the script; earlier identifiers are archived there. This directory is excluded from Git.

Reuse/resume the last saved lab without changing its OS choices:

```sh
bash setup-lab.sh --reuse
```

Reuse preserves existing machine state; it does not re-provision the machines or uninstall software from older labs. If your saved lab was created by an earlier version of this script, run the default command to create the current minimal setup. A destroyed/expired instance also requires a fresh run. `--new` explicitly requests the default fresh-run behavior.

Preview without downloading software, authenticating, or creating remote resources:

```sh
bash setup-lab.sh --dry-run
```

Add all three OS options for a preview without prompts. To maintain independent local state, set `ANSIBLE_LAB_STATE_DIR` to another directory. Stop old runs when no longer needed using the command printed by the script. Persistence/expiry remains subject to your iximiuz account settings; this script does not mark runs as kept or extend their lifetime.

## Repository files

| File | Purpose |
| --- | --- |
| `setup-lab.sh` | Self-contained interactive launcher and provisioning manifest generator |
| `SETUP.md` | Controller inspection and troubleshooting instructions |
| `manifest.yaml` | Optional topology-only example: Rocky controller and two Ubuntu nodes |
| `ansible.cfg`, `hosts` | Examples of the standard files created on the controller |
| `tests/` | Local tests with fake external commands; no cloud resources created |

The automated script generates all required files itself; the example files are not runtime dependencies. The topology-only example does not install Ansible or create the standard configuration files by itself.

## Local verification

Requires Bash, Python 3, and Ruby with its standard YAML/JSON libraries:

```sh
bash -n setup-lab.sh
python3 tests/test_launcher.py
python3 tests/test_topologies.py
```

Tests cover all eight OS combinations, standard config/hosts paths, actual-version reporting, menu validation, apt/dnf dispatch, global command launchers, CLI installation/login behavior, fresh/reused runs, and failure handling. They do not download packages, authenticate to an account, or create VMs. Real provisioning and connectivity still require live validation.

## References

- [iximiuz multi-machine playgrounds](https://labs.iximiuz.com/docs/custom-playgrounds/multi-machine-playgrounds)
- [iximiuz init tasks](https://labs.iximiuz.com/docs/custom-playgrounds/init-tasks)
- [iximiuz CLI workflows](https://labs.iximiuz.com/docs/playgrounds/how-to-use-playgrounds)
- [Ansible configuration and inventory defaults](https://docs.ansible.com/projects/ansible/latest/reference_appendices/config.html)
- [Ansible/Python support matrix](https://docs.ansible.com/projects/ansible/latest/reference_appendices/release_and_maintenance.html)
- [pip target-directory installation](https://pip.pypa.io/en/stable/cli/pip_install/)
