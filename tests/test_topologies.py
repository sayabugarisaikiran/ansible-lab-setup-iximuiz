import itertools
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parents[1]
launcher=root/'setup-lab.sh'

def parse_yaml(path=None, text=None):
    expression='require "yaml"; require "json"; print JSON.generate(YAML.safe_load('+('File.read(ARGV[0])' if path else 'STDIN.read')+'))'
    result=subprocess.run(['ruby','-e',expression,*([str(path)] if path else [])],input=text,capture_output=True,text=True,check=True)
    return json.loads(result.stdout)

with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as tmp:
    base=Path(tmp)
    manifests=[]
    for controller,node1,node2 in itertools.product(['rocky','ubuntu'],repeat=3):
        state=base/f'{controller}-{node1}-{node2}'
        result=subprocess.run(['bash',str(launcher),'--dry-run','--controller',controller,'--node1',node1,'--node2',node2],env=dict(os.environ,ANSIBLE_LAB_STATE_DIR=str(state)),capture_output=True,text=True,check=True)
        assert 'No remote calls made' in result.stdout
        raw=(state/'manifest.yaml').read_text()
        assert '__CONTROLLER_' not in raw and '__NODE1_' not in raw and '__NODE2_' not in raw
        m=parse_yaml(state/'manifest.yaml'); p=m['playground']; manifests.append(p)
        machines=p['machines']
        names=['controller',f'{node1}-01',f'{node2}-02']
        assert [x['name'] for x in machines]==names
        assert len(set(names))==3
        assert all(re.fullmatch(r'[a-z][a-z0-9-]*',name) and len(name)<=20 for name in names)
        assert [x['drives'][0]['source'] for x in machines]==[{'rocky':'rockylinux','ubuntu':'ubuntu-24-04'}[x] for x in [controller,node1,node2]]
        assert [x['network']['interfaces'][0]['address'] for x in machines]==['172.16.0.2','172.16.0.3','172.16.0.4']
        # The API can accept a template but reject its run if a tab label
        # exceeds 20 characters. Check every supported OS combination.
        assert p['tabs'][0]['name']=='Controller'
        assert all(1 <= len(tab['name']) <= 20 for tab in p['tabs'])
        assert [tab['machine'] for tab in p['tabs']]==names
        assert [tab['name'] for tab in p['tabs'][1:]]==names[1:]
        tasks=p['initTasks']
        for name,t in tasks.items():
            assert t['machine'] in names
            assert all(dep in tasks for dep in t.get('needs',[]))
            subprocess.run(['bash','-n'],input=t['run'],text=True,check=True)
        files={f['path'].rsplit('/',1)[-1]:f['content'] for f in p['startupFiles']}
        assert f'{names[1]}\n{names[2]}' in files['hosts']
        assert f'for node in {names[1]} {names[2]}; do' in tasks['init_verify_setup']['run']
        assert 'node-01' not in raw and 'node-02' not in raw
        assert 'inventory = /etc/ansible/hosts' in files['ansible.cfg']
        assert {f['path'] for f in p['startupFiles']} == {
            '/etc/ansible/hosts', '/etc/ansible/ansible.cfg',
            '/home/laborant/ansible-lab/show-details.sh'}
        assert 'nginx' not in raw.lower()
        assert 'tmux' not in raw.lower()
        assert 'ansible-playbook ' not in tasks['init_verify_setup']['run']
        report=files['show-details.sh']
        subprocess.run(['bash','-n'],input=report,text=True,check=True)
        assert 'ansible --version' in report
        assert 'ansible-config dump --only-changed' in report
        assert '/etc/ansible/ansible.cfg' in report
        assert '/etc/ansible/hosts' in report
        assert 'setup-details.txt' in tasks['init_verify_setup']['run']
        assert ' -m venv ' not in tasks['init_controller_packages']['run']
        assert '--target /opt/ansible/lib' in tasks['init_controller_packages']['run']
    # Interactive invalid input is reprompted, then all choices are honored.
    state=base/'interactive'
    r=subprocess.run(['bash',str(launcher),'--dry-run'],input='wrong\n2\n1\n2\n',text=True,capture_output=True,env=dict(os.environ,ANSIBLE_LAB_STATE_DIR=str(state)),check=True)
    assert 'Please enter 1 or 2' in r.stderr
    assert [x['drives'][0]['source'] for x in parse_yaml(state/'manifest.yaml')['playground']['machines']]==['ubuntu-24-04','rockylinux','ubuntu-24-04']
    assert [x['name'] for x in parse_yaml(state/'manifest.yaml')['playground']['machines']]==['controller','rocky-01','ubuntu-02']
    # Exercise the actual package-manager dispatch blocks with fake managers.
    bindir=base/'bin'; bindir.mkdir(); log=base/'packages.log'
    for tool in ['dnf','apt-get']:
        f=bindir/tool
        f.write_text('#!/bin/sh\nprintf "%s\\n" "'+tool+' $*" >> "$PACKAGE_LOG"\n')
        f.chmod(0o755)
    env=dict(os.environ,PATH=f'{bindir}:/usr/bin:/bin',PACKAGE_LOG=str(log))
    controller_script=manifests[0]['initTasks']['init_controller_packages']['run']
    for task in ['init_controller_packages','init_node_01_packages','init_node_02_packages']:
        source=manifests[0]['initTasks'][task]['run']
        if task=='init_controller_packages':
            source=source[source.index('. /etc/os-release'):source.index('# Machine-wide')]
        for distro in ['rocky','ubuntu','unsupported']:
            release=base/'os-release'; release.write_text('ID='+distro+'\n')
            branch=source.replace('/etc/os-release',str(release))
            log.write_text('')
            r=subprocess.run(['bash','-euo','pipefail'],input=branch,text=True,env=env,capture_output=True)
            if distro=='unsupported':
                assert r.returncode!=0 and not log.read_text()
            else:
                assert r.returncode==0,r.stderr
                calls=log.read_text().splitlines()
                expected='dnf' if distro=='rocky' else 'apt-get'
                assert calls and all(x.startswith(expected+' ') for x in calls),calls
    # Run the generated global-launcher creation loop in a staging directory.
    library=base/'opt/ansible/lib'; (library/'bin').mkdir(parents=True)
    globalbin=base/'usr/local/bin'; globalbin.mkdir(parents=True)
    (library/'demo_dependency.py').write_text('value="target-library-loaded"\n')
    tools=['ansible','ansible-config','ansible-console','ansible-doc','ansible-galaxy','ansible-inventory','ansible-playbook','ansible-pull','ansible-vault']
    for tool in tools:
        (library/'bin'/tool).write_text('import demo_dependency,sys,os\nif sys.argv[1:]==["--version"]:\n print("ansible [core 2.21.9]\\n  config file = "+os.environ.get("ANSIBLE_CONFIG","none"))\nelse:\n print(demo_dependency.value+" "+" ".join(sys.argv[1:]))\n')
    loop=controller_script[controller_script.index('for tool in ansible '):controller_script.index('chmod -R a+rX')]
    loop=loop.replace('/opt/ansible/lib',str(library)).replace('/usr/local/bin',str(globalbin)).replace('/usr/bin/python3.12',sys.executable)
    subprocess.run(['bash','-euo','pipefail'],input=loop,text=True,check=True)
    for tool in tools:
        r=subprocess.run([str(globalbin/tool),'argument with spaces'],capture_output=True,text=True,check=True)
        assert r.stdout.strip()=='target-library-loaded argument with spaces',r.stdout
    # Execute the actual report helper against the staged command wrappers.
    configdir=base/'etc/ansible'; configdir.mkdir(parents=True)
    (configdir/'ansible.cfg').write_text('[defaults]\ninventory = '+str(configdir/'hosts')+'\n')
    (configdir/'hosts').write_text('[managed]\nubuntu-01\nubuntu-02\n')
    report=report.replace('/usr/local/bin',str(globalbin)).replace('/opt/ansible/lib',str(library)).replace('/etc/ansible',str(configdir))
    result=subprocess.run(['bash'],input=report,text=True,capture_output=True,check=True)
    assert 'ansible [core 2.21.9]' in result.stdout
    assert 'config file = '+str(configdir/'ansible.cfg') in result.stdout
    assert str(configdir/'hosts') in result.stdout
    assert 'Executable:     '+str(globalbin/'ansible') in result.stdout
    print('PASS: all 8 OS combinations, no application provisioning, standard config/hosts paths, dynamic version report, menu validation, apt/dnf dispatch and all 9 global launchers. No packages or VMs installed.')
