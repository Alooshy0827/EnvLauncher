"""Integration checks for generated projects. No third-party test dependencies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.uname().sysname == 'Darwin', 'macOS scaffolds require macOS')
class Scaffolds(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='envlauncher-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "中文 ' 引号 & 百分号% [目录]"

    def run_scaffold(self, language, name=None, root=None, env=None, check=False):
        args = ['/bin/bash', str(REPO/'macos'/('new-'+language))]
        if check:
            args += ['--check']
        elif name is not None:
            args += [name]
        args += ['--root', str(root or self.root)]
        return subprocess.run(args, capture_output=True, text=True, env=env, timeout=45)

    def minimal_path(self):
        tools = self.base/'tools'
        tools.mkdir(exist_ok=True)
        for tool in ['dirname', 'tr', 'mkdir', 'cat', 'uname', 'rm', 'mktemp', 'sleep']:
            (tools/tool).symlink_to(shutil.which(tool))
        return tools

    def test_reject_names_before_writing(self):
        for name in ['', '.', '..', '../escape', '/absolute', 'back\\slash', 'has"quote', 'CON', 'nul.txt', 'COM1', 'LPT9.c', 'trailing.', 'leading ', ' leading', 'line\nbreak', 'a\tb', 'a\x7fb']:
            with self.subTest(name=name):
                result = self.run_scaffold('c', name)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.root.exists(), result.stdout+result.stderr)

    def test_templates_and_executable_output(self):
        for language in ['c', 'cpp', 'py', 'java']:
            with self.subTest(language=language):
                name=language+' 中文 空格 & 百分号% [x]'
                result=self.run_scaffold(language, name)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                project=self.root/name
                manifest=json.loads((project/'.envlauncher.json').read_text())
                for relative in manifest['requiredFiles']:
                    self.assertTrue((project/relative).is_file(), relative)
                for file in (project/'.vscode').glob('*.json'):
                    value=json.loads(file.read_text())
                    self.assertNotIn('cpptools-1.',file.read_text())
                if language in ['c','cpp']:
                    task=json.loads((project/'.vscode/tasks.json').read_text())['tasks'][0]
                    self.assertEqual(task['type'], 'process')
                    args=[arg.replace('${workspaceFolder}',str(project)) for arg in task['args']]
                    compiled=subprocess.run([task['command'],*args],capture_output=True,text=True,timeout=30)
                    self.assertEqual(compiled.returncode,0,compiled.stderr)
                    subprocess.run([str(project/'build/main')],check=True,capture_output=True,timeout=5)
                    launch=json.loads((project/'.vscode/launch.json').read_text())['configurations'][0]
                    self.assertNotIn('miDebuggerPath',launch)
                if language=='py':
                    python=project/'.venv/bin/python'
                    self.assertTrue(python.is_file())
                    run=subprocess.run([str(python),str(project/'main.py')],capture_output=True,text=True,timeout=5)
                    self.assertEqual(run.stdout.strip(),'你好，Python！')
                if language=='java':
                    launch=json.loads((project/'.vscode/launch.json').read_text())['configurations'][0]
                    self.assertNotIn('projectName',launch)
                    javac=subprocess.run(['javac','-version'],capture_output=True,text=True)
                    if javac.returncode==0:
                        task=json.loads((project/'.vscode/tasks.json').read_text())['tasks'][0]
                        args=[arg.replace('${workspaceFolder}',str(project)) for arg in task['args']]
                        subprocess.run([task['command'],*args],check=True,capture_output=True,timeout=30)
                        subprocess.run(['java','-cp',str(project/'bin'),'Main'],check=True,capture_output=True,timeout=5)
                    else:
                        self.assertTrue((project/'!缺少工具链.md').is_file())

    def test_missing_tools_and_readonly_preflight(self):
        env=dict(os.environ,PATH=str(self.minimal_path()))
        for language in ['c','cpp','py','java']:
            with self.subTest(language=language):
                check_root=self.base/("preflight-"+language)
                result=self.run_scaffold(language,root=check_root,env=env,check=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertFalse(check_root.exists())
                self.assertIn('缺少工具链',result.stdout)
                result=self.run_scaffold(language,language,env=env)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertTrue((self.root/language/'!缺少工具链.md').is_file())

    def test_existing_project_is_untouched(self):
        project=self.root/'existing'
        project.mkdir(parents=True)
        (project/'sentinel').write_text('keep')
        result=self.run_scaffold('c','existing')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual([p.name for p in project.iterdir()],['sentinel'])

    def test_write_failure_removes_only_new_project(self):
        tools=self.minimal_path()
        (tools/'cat').unlink()
        (tools/'cat').write_text('#!/bin/bash\necho simulated-write-failure >&2\nexit 17\n')
        (tools/'cat').chmod(0o755)
        result=self.run_scaffold('c','partial',env=dict(os.environ,PATH=str(tools)))
        self.assertEqual(result.returncode,17,result.stdout+result.stderr)
        self.assertFalse((self.root/'partial').exists())

    def test_python_venv_failure_keeps_reason(self):
        tools=self.minimal_path()
        (tools/'python3').write_text('#!/bin/bash\nif [ "$1" = --version ]; then echo "Python 3.12.0"; exit 0; fi\necho "simulated ensurepip failure" >&2\nexit 9\n')
        (tools/'python3').chmod(0o755)
        result=self.run_scaffold('py','venv-failure',env=dict(os.environ,PATH=str(tools)))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Python 已找到',(self.root/'venv-failure/!缺少工具链.md').read_text())
        self.assertIn('ensurepip',(self.root/'venv-failure/.venv-create.log').read_text())

    def test_name_that_looks_like_option(self):
        args=['/bin/bash',str(REPO/'macos/new-c'),'--root',str(self.root),'--','--check']
        result=subprocess.run(args,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.root/'--check/.envlauncher.json').is_file())

    def test_concurrent_creation_has_one_owner(self):
        args=['/bin/bash',str(REPO/'macos/new-c'),'same','--root',str(self.root)]
        processes=[subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
        results=[process.communicate(timeout=30) for process in processes]
        self.assertEqual(sorted(process.returncode==0 for process in processes),[False,True],results)
        self.assertTrue((self.root/'same/.envlauncher.json').exists())

if __name__=='__main__':
    unittest.main(verbosity=2)
