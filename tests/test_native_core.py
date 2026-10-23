"""Compile the native launcher's pure helpers and exercise failures without opening a window."""
from pathlib import Path
import os
import subprocess
import tempfile

repo=Path(__file__).resolve().parents[1]
source=(repo/'macos/main.swift').read_text().split('final class Launcher:',1)[0]
fixture=r'''
let invalid = ["", ".", "..", "../escape", "CON", "nul.txt", " leading", "trailing.", "trailing ", "quote\"", "a\nb"]
for name in invalid { precondition(!validName(name), "accepted invalid name: " + name) }
precondition(validName("中文 ' 空格 & 百分号% [x]"))
let captured = runCommand("/bin/sh", ["-c", "printf stdout; /usr/bin/head -c 262144 /dev/zero >&2; exit 17"])
precondition(captured.status == 17 && captured.output.hasPrefix("stdout") && captured.output.utf8.count == 262150)
let directory = NSTemporaryDirectory() + UUID().uuidString
try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: directory) }
let scaffold = Scaffold(id: "test", label: "test", path: "test", protocolVersion: 2)
precondition(!validProject(directory, scaffold: scaffold))
let manifest = "{\"schemaVersion\":1,\"requiredFiles\":[\"main.c\"]}"
try manifest.write(toFile: directory + "/.envlauncher.json", atomically: true, encoding: .utf8)
precondition(!validProject(directory, scaffold: scaffold))
try "int main(void){return 0;}".write(toFile: directory + "/main.c", atomically: true, encoding: .utf8)
precondition(validProject(directory, scaffold: scaffold))
let escaped = "{\"schemaVersion\":1,\"requiredFiles\":[\"../outside.c\"]}"
try escaped.write(toFile: directory + "/.envlauncher.json", atomically: true, encoding: .utf8)
precondition(!validProject(directory, scaffold: scaffold))
print("PASS native name validation, exit codes, stderr capture and completion manifest validation")
'''
with tempfile.TemporaryDirectory(prefix='envlauncher-native-') as temp:
    folder=Path(temp)
    swift=folder/'main.swift'; swift.write_text(source+fixture)
    cache=os.environ.get('SWIFT_MODULE_CACHE_PATH',str(folder/'cache'))
    arch='arm64' if os.uname().machine=='arm64' else 'x86_64'
    subprocess.run(['swiftc','-module-cache-path',cache,'-target',arch+'-apple-macosx11.0',str(swift),'-o',str(folder/'test')],check=True)
    subprocess.run([str(folder/'test')],check=True,timeout=15)
