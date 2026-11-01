import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
script = root / 'setup-lab.sh'

CLI = r'''
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as f:
    f.write(json.dumps(args)+'\n')
mode=os.environ.get('MOCK_MODE','normal')
authed=Path(os.environ['HOME'], 'authenticated').exists()
installed=Path(os.environ['HOME'], 'installed').exists()
if args == ['playground','--help']:
    print('Available Commands:')
    if mode != 'upgrade_bad' and (mode != 'old' or installed):
        print('  tasks     Inspect tasks')
elif args == ['auth','whoami']:
    if mode in ['loggedout','login_cancel','login_no_session'] and not authed:
        print('Not logged in')
    elif mode == 'whoami_error' and not authed:
        sys.exit(1)
    else:
        print('User: Test Trainer')
elif args == ['auth','login']:
    if mode == 'login_cancel': sys.exit(1)
    if mode != 'login_no_session':
        Path(os.environ['HOME'], 'authenticated').touch()
elif args == ['playground','list','--quiet']:
    if mode == 'private_denied': sys.exit(1)
elif args[:2] == ['playground','create']:
    if mode == 'create_failure': sys.exit(1)
    counter=Path(os.environ['HOME'],'counter')
    count=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(count))
    if mode == 'invalid_name': print('not a valid name')
    else: print('ansible-rocky-ubuntu-auto-test'+str(count))
elif args[:2] == ['playground','start']:
    if mode == 'invalid_id': print('unexpected output')
    else: print('testplay'+Path(os.environ['HOME'],'counter').read_text())
elif args[:2] == ['playground','restart']:
    if mode == 'expired': sys.exit(1)
elif args[:2] == ['playground','tasks']:
    if mode == 'task_failure': sys.exit(1)
elif args[:1] == ['ssh']:
    if args[-1] == 'true' and mode in ['stopped','expired']: sys.exit(1)
    if mode == 'verification_failure' and args[-1] != 'true': sys.exit(1)
    if args[-1] != 'true':
        assert 'show-details.sh' in args[-1]
        print('ansible [core 2.21.9]')
        print('  config file = /etc/ansible/ansible.cfg')
else:
    sys.stderr.write('Unexpected CLI invocation: '+repr(args))
    sys.exit(9)
'''

CURL = r'''
import json, os, sys
from pathlib import Path
with open(os.environ['MOCK_LOG'],'a') as f: f.write(json.dumps(['download'])+'\n')
if os.environ.get('MOCK_MODE')=='download_failure': sys.exit(22)
args=sys.argv[1:]
target=args[args.index('-o')+1]
Path(target).write_text(''' + repr('''#!/bin/sh
set -eu
printf '["installer"]\\n' >> "$MOCK_LOG"
if [ "${MOCK_MODE:-}" = installer_failure ]; then exit 1; fi
mkdir -p "$HOME/.iximiuz/labctl/bin"
cp "$MOCK_TEMPLATE" "$HOME/.iximiuz/labctl/bin/labctl"
chmod +x "$HOME/.iximiuz/labctl/bin/labctl"
touch "$HOME/installed"
''') + ''')
'''

with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temporary:
    directory = Path(temporary)

    class Fixture:
        def __init__(self, name, missing=False):
            self.dir=directory/name
            self.bin=self.dir/'bin'
            self.home=self.dir/'home'
            self.bin.mkdir(parents=True)
            self.home.mkdir()
            self.state=self.dir/'state'
            self.log=self.dir/'calls.jsonl'
            self.template=self.dir/'labctl-template'
            self.template.write_text('#!'+sys.executable+'\n'+CLI)
            self.template.chmod(0o755)
            if not missing:
                (self.bin/'labctl').write_bytes(self.template.read_bytes())
                (self.bin/'labctl').chmod(0o755)
            (self.bin/'curl').write_text('#!'+sys.executable+'\n'+CURL)
            (self.bin/'curl').chmod(0o755)
            self.env=dict(os.environ, HOME=str(self.home),
                PATH=f'{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                MOCK_LOG=str(self.log), MOCK_TEMPLATE=str(self.template),
                ANSIBLE_LAB_STATE_DIR=str(self.state))
        def run(self, mode='normal', arguments=(), success=True, choices='1\n2\n2\n'):
            self.log.write_text('')
            r=subprocess.run(['/bin/bash',str(script),*arguments],
                env=dict(self.env,MOCK_MODE=mode),input=choices,capture_output=True,text=True)
            assert (r.returncode==0)==success, (mode,r.stdout,r.stderr)
            calls=[json.loads(line) for line in self.log.read_text().splitlines()]
            if success and '--dry-run' not in arguments:
                assert 'Lab ready.' in r.stdout
                assert 'ansible [core 2.21.9]' in r.stdout
                assert '/etc/ansible/ansible.cfg' in r.stdout
                assert '/etc/ansible/hosts' in r.stdout
                assert '/opt/ansible/lib' in r.stdout
                assert '~/ansible-lab/recording-view.sh' in r.stdout
                play_id=(self.state/'play-id').read_text().strip()
                name=(self.state/'playground-name').read_text().strip()
                for action in ['stop','restart','destroy']:
                    assert f'playground {action} "{play_id}"' in r.stdout
                assert f'playground remove "{name}"' in r.stdout
                assert f'--filter "playground={name}"' in r.stdout
                assert r.stdout.index(f'playground destroy "{play_id}"') < r.stdout.index(f'playground remove "{name}"')
                commands=(self.state/f'commands-{play_id}.txt').read_text()
                assert commands==(self.state/'commands.txt').read_text()
                assert f'playground destroy "{play_id}"' in commands
                assert 'PLAY_ID' not in commands and 'PLAYGROUND_NAME' not in commands
                assert not any(c[:2] in [['playground','destroy'],['playground','remove'],['playground','stop']] for c in calls)
                creation=[i for i,c in enumerate(calls) if c[:2]==['playground','create']]
                if creation:
                    assert calls.index(['playground','list','--quiet']) < creation[0]
            if not success: assert 'Lab ready.' not in r.stdout
            return calls

    def has(calls, prefix): return any(c[:len(prefix)]==prefix for c in calls)
    def no_creation(calls):
        assert not has(calls,['playground','create'])
        assert not has(calls,['playground','start'])

    f=Fixture('dry',missing=True)
    assert not f.run(arguments=['--dry-run'])
    assert not (f.home/'.iximiuz').exists()
    f=Fixture('normal')
    calls=f.run()
    assert has(calls,['playground','create']) and has(calls,['playground','start'])
    assert not has(calls,['auth','login']) and not has(calls,['download'])
    calls=f.run()
    assert has(calls,['playground','create']) and has(calls,['playground','start'])
    assert (f.state/'play-id').read_text().strip()=='testplay2'
    assert (f.state/'previous-play-ids').read_text().strip()=='testplay1'
    calls=f.run(arguments=['--reuse'])
    no_creation(calls)
    assert not has(calls,['playground','restart'])
    no_creation(f.run(arguments=['--reuse','--controller','ubuntu'],success=False))
    calls=f.run('stopped',arguments=['--reuse'])
    no_creation(calls)
    assert has(calls,['playground','restart'])
    no_creation(f.run('expired',arguments=['--reuse'],success=False))
    calls=f.run(arguments=['--new'])
    assert has(calls,['playground','create'])
    for name,missing,mode in [('missing',True,'normal'),('outdated',False,'old')]:
        f=Fixture(name,missing=missing)
        calls=f.run(mode)
        assert has(calls,['download']) and has(calls,['installer'])
        assert (f.home/'.iximiuz/labctl/bin/labctl').exists()
    for mode in ['download_failure','installer_failure','upgrade_bad']:
        f=Fixture(mode,missing=True)
        no_creation(f.run(mode,success=False))
    for mode in ['loggedout','whoami_error']:
        calls=Fixture(mode).run(mode)
        assert has(calls,['auth','login'])
        assert calls.index(['auth','login']) < next(i for i,c in enumerate(calls) if c[:2]==['playground','create'])
    for mode in ['login_cancel','login_no_session','private_denied']:
        calls=Fixture(mode).run(mode,success=False)
        assert has(calls,['auth','login'])
        no_creation(calls)
    for mode in ['create_failure','invalid_name','invalid_id','task_failure','verification_failure']:
        Fixture(mode).run(mode,success=False)
    Fixture('invalid_option').run(arguments=['--unknown'],success=False)
    Fixture('invalid_os').run(arguments=['--node1','fedora'],success=False)
    Fixture('missing_os').run(arguments=['--node2'],success=False)
    Fixture('conflicting_modes').run(arguments=['--reuse','--new'],success=False)
    no_creation(Fixture('menu_eof').run(choices='',success=False))
    f=Fixture('preserve_on_auth_failure')
    f.run()
    old_id=(f.state/'play-id').read_text()
    no_creation(f.run('private_denied',success=False))
    assert (f.state/'play-id').read_text()==old_id
    print('PASS: automatic install/upgrade, PATH refresh, cached login, exit-zero logged-out detection, login/verification failures, fresh runs by default, explicit reuse/resume, state history, dry-run, provisioning failures and invalid output.')
