# Inspect the prepared Ansible lab

Run `bash setup-lab.sh` on your Mac. Select the OS for each machine and finish browser login if requested. The script starts three VMs and installs Ansible plus its prerequisites. See [README.md](README.md) for the full launcher workflow.

## Enter the controller

Use the controller browser terminal, or run the exact SSH command printed by the launcher on your Mac:

```sh
labctl ssh YOUR_PLAY_ID -m controller
```

Commands below run on the controller as `laborant`.

## Display the installed version and paths

```sh
~/ansible-lab/show-details.sh
```

This prints the actual `ansible --version` output, the global executable and package locations, the configuration/hosts file locations, active settings and the inventory graph. The initial report is saved at `~/ansible-lab/setup-details.txt`.

```sh
command -v ansible
ansible --version
cat /etc/ansible/ansible.cfg
cat /etc/ansible/hosts
ansible-config dump --only-changed
ansible-inventory --graph
```

| Item | Location |
| --- | --- |
| Executable | `/usr/local/bin/ansible` |
| Python packages | `/opt/ansible/lib` |
| Configuration | `/etc/ansible/ansible.cfg` |
| Hosts/inventory | `/etc/ansible/hosts` |

The setup selects the Ansible Core 2.21 series and prints the installed patch version after installation. There is no activation step. The global commands load their packages from `/opt/ansible/lib`.

## Verify access

```sh
getent hosts node-01 node-02
ssh -o BatchMode=yes laborant@node-01 'hostname; sudo -n whoami'
ssh -o BatchMode=yes laborant@node-02 'hostname; sudo -n whoami'
ansible managed -m ansible.builtin.ping
ansible managed -b -m ansible.builtin.command -a whoami
```

Expect `pong` from both nodes and `root` from the final command. These checks do not install application software or run a demonstration playbook.

## Edit the files

```sh
sudo vim /etc/ansible/ansible.cfg
sudo vim /etc/ansible/hosts
```

A project-local `ansible.cfg`, `~/.ansible.cfg`, or `ANSIBLE_CONFIG` can take precedence over `/etc/ansible/ansible.cfg`. `ansible --version` shows the active configuration. The report helper explicitly selects the lab's standard configuration.

## Troubleshoot

| Symptom | Check |
| --- | --- |
| Ansible command missing | `ls -l /usr/local/bin/ansible`; ensure `/usr/local/bin` is on PATH and inspect the controller init task. |
| Empty or unexpected inventory | Check the active config in `ansible --version`, then read `/etc/ansible/hosts`. |
| SSH authentication fails | Confirm the user is `laborant` and the target is in the same play; use `ssh -v laborant@node-01`. |
| sudo requests a password | Run `sudo -n true` on the affected node and inspect the official image's `laborant` sudo rule. |
| Init task fails | From your Mac: `labctl playground tasks YOUR_PLAY_ID -o yaml`. |
| Package unavailable | Inspect `/etc/os-release` and the enabled repositories on the failing VM. Named platform images can change. |
| Reusing a lab created by an older script version | Default execution creates the new minimal setup; reuse does not uninstall old applications or rerun init tasks. |

The first automated SSH check accepts new host keys within this isolated lab, records them, and continues to reject changed keys. No private keys are embedded in or replaced by this script.
