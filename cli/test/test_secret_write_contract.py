#!/usr/bin/env python3
"""Exercise write/no-op/refusal through the real CLI; Kubernetes must never activate."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def require(value, message):
    if not value:
        raise AssertionError(message)


def main():
    sol = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        workspace = root / 'workspace'
        (workspace / 'sol').mkdir(parents=True)
        units = [('payments', 'api_svc', 'http'), ('comms', 'notify_worker', 'worker'),
                 ('payments', 'cleanup_fn', 'fn'), ('payments', 'canary_svc', 'http')]
        manifest = 'project: secret_contract\nservices:\n'
        authorities = ''
        for domain, name, kind in units:
            unit = workspace / 'app' / domain / name
            unit.mkdir(parents=True)
            (unit / 'Dockerfile').write_text('FROM scratch\n')
            toml = '[infra.env]\nsecrets = ["API_KEY"]\n'
            if name == 'canary_svc':
                toml += '\n[infra.rollout]\nstrategy = "canary"\nsteps = [100]\n'
            if name == 'cleanup_fn':
                toml += '\n[service]\nschedule = "*/5 * * * *"\n'
            (unit / 'sol.toml').write_text(toml)
            manifest += f'  {name}:\n    type: {kind}\n    path: app/{domain}/{name}\n    language: ocaml\n'
            authorities += f'        {domain}/{name}:\n          API_KEY:\n            authority: sol\n'
        (workspace / 'sol.yml').write_text(manifest)
        (workspace / 'sol/environments.yml').write_text(
            'prod:\n  targets:\n    aws/us-east-1:\n      shape: local\n      cluster_name: planned\n      kube_context: planned\n      state_bucket: test-state\n      secrets:\n' + authorities)
        binary = root / 'bin'
        binary.mkdir()
        stub = binary / 'kubectl'
        stub.write_text('''#!/usr/bin/env python3
import json,os,sys,pathlib
root=pathlib.Path(os.environ['SECRET_TEST_ROOT'])
a=sys.argv[1:]
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\\n')
state=json.loads((root/'state.json').read_text())
if 'rollout' in a or 'wait' in a:
 print('unexpected workload activation/readiness',file=sys.stderr);sys.exit(91)
if 'get' in a and 'secret' in a:
 i=a.index('secret'); name=a[i+1]; ns=a[a.index('-n')+1]
 key=ns+'/'+name
 if key not in state: print('NotFound',file=sys.stderr);sys.exit(1)
 print(json.dumps(state[key]));sys.exit(0)
if 'get' in a and 'externalsecrets' in a: sys.exit(0)
if 'patch' in a:
 i=a.index('patch'); assert a[i+1]=='secret'
 ns=a[a.index('-n')+1];key=ns+'/'+a[i+2]
 if os.environ.get('FAIL_NAMESPACE')==ns:
  print('Error from server (Forbidden): scoped write denied',file=sys.stderr);sys.exit(1)
 operations=json.load(open(a[a.index('--patch-file')+1]))
 for op in operations:
  if op['op']=='test': assert state[key]['metadata']['labels']['app.kubernetes.io/managed-by']==op['value']
  else:
   assert op['op']=='add' and op['path'].startswith('/data/')
   state[key]['data'][op['path'][6:]]=op['value']
 (root/'state.json').write_text(json.dumps(state))
 print('secret patched');sys.exit(0)
if 'apply' in a or 'create' in a:
 assert 'kind: Namespace' in pathlib.Path(a[a.index('-f')+1]).read_text()
 sys.exit(0)
print('unsupported Kubernetes operation: '+repr(a),file=sys.stderr);sys.exit(90)
''')
        stub.chmod(0o700)
        encode = lambda value: base64.b64encode(value.encode()).decode()
        def secret(value, key='API_KEY'):
            return {'metadata': {'labels': {'app.kubernetes.io/managed-by': 'sol'}, 'resourceVersion': '1'},
                    'data': {key: encode(value), 'OTHER_KEY': encode('preserve-me')}}
        state = {f'workspace-{domain}/{name.replace("_", "-")}-secrets': secret('old') for domain, name, _ in units}
        (root / 'state.json').write_text(json.dumps(state))
        environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'], SECRET_TEST_ROOT=str(root))
        canary = 'secret-canary-no-output'
        def execute(address, *, fail_ns=None, value=canary, from_file=None):
            env = dict(environment)
            if fail_ns:
                env['FAIL_NAMESPACE'] = fail_ns
            args = [sol, 'secret', 'set', 'prod/aws/us-east-1', address]
            args += ['--from-file', from_file] if from_file else ['--from-stdin']
            result = subprocess.run(args, cwd=workspace, env=env, input=value+'\n', text=True, capture_output=True, timeout=10)
            require(canary not in result.stdout+result.stderr, 'secret value disclosed')
            require('restart' not in result.stdout.lower() and 'activated' not in result.stdout.lower(), 'write claimed activation')
            return result
        for domain, name, _ in units:
            key = f'workspace-{domain}/{name.replace("_", "-")}-secrets'
            address = f'{domain}/{name}/API_KEY'
            before = json.loads((root / 'state.json').read_text())
            changed = execute(address)
            require(changed.returncode == 0 and 'Secret updated' in changed.stdout, address+': write failed: '+changed.stderr)
            after = json.loads((root / 'state.json').read_text())
            expected = json.loads(json.dumps(before))
            expected[key]['data']['API_KEY'] = encode(canary)
            require(after == expected, address+': wrong Secret/key changed')
            calls = (root / 'calls.jsonl').read_text().splitlines()
            unchanged = execute(address)
            require(unchanged.returncode == 0 and 'already had' in unchanged.stdout, address+': no-op misreported')
            extra = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()[len(calls):]]
            require(not any('patch' in call for call in extra), address+': no-op mutated the cluster')
            failed = execute(address, value='replacement', fail_ns=f'workspace-{domain}')
            require(failed.returncode != 0 and 'Forbidden' in failed.stderr, 'failed write lost provider error')
            require(json.loads((root / 'state.json').read_text()) == after, 'failed write changed state')
            print('ok: '+address+' changed/no-op/error writes preserve scope without activation')
        config = workspace / 'sol/environments.yml'
        config.write_text(config.read_text().replace('shape: local', 'shape: durable'))
        state = json.loads((root / 'state.json').read_text())
        for namespace in ('workspace-comms', 'workspace-payments'):
            state[namespace+'/sol-secrets'] = secret('old', 'KAFKA_SASL_PASSWORD')
        (root / 'state.json').write_text(json.dumps(state))
        before_platform = json.loads(json.dumps(state))
        calls_before = len((root / 'calls.jsonl').read_text().splitlines())
        platform = execute('@platform/KAFKA_SASL_PASSWORD', fail_ns='workspace-payments')
        require(platform.returncode != 0 and 'resource-owned' in platform.stderr,
                'Kafka platform key was not refused as resource-owned')
        require(json.loads((root / 'state.json').read_text()) == before_platform,
                'refused Kafka platform key wrote a destination')
        extra = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()[calls_before:]]
        require(not any('patch' in call for call in extra),
                'refused Kafka platform key reached a write')
        print('ok: resource-owned Kafka keys are refused before any platform write')
        # Resolution and ownership refusals precede opening the requested secret file.
        refused = execute('payments/api_svc/UNDECLARED', from_file=str(root/'must-not-open'))
        require(refused.returncode != 0 and 'could not read' not in refused.stderr, 'invalid key reached input')
        calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
        require(not any('rollout' in call or 'wait' in call for call in calls), 'write path restarted or waited on workloads')
        print('ok: all workload shapes preserve writes-only behavior and reject invalid input before reading')


if __name__ == '__main__':
    main()
