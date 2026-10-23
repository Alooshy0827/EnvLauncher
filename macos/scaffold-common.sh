#!/bin/bash
# Shared by the bundled scaffolds. Compatible with macOS Bash 3.2.
set -euo pipefail

json_string() {
    local value="$1"
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}; value=${value//$'\b'/\\b}; value=${value//$'\f'/\\f}
    printf '"%s"' "$value"
}

valid_name() {
    local upper
    [ -n "$1" ] || return 1
    case "$1" in .|..|*[/\\:*?\"\<\>\|]*|*'.'|*' '| ' '*) return 1;; esac
    [[ "$1" =~ [[:cntrl:]] ]] && return 1
    upper=$(printf '%s' "${1%%.*}" | tr '[:lower:]' '[:upper:]')
    case "$upper" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) return 1;; esac
    return 0
}

find_tool() {
    local candidate output pid waited version_argument="--version"
    if [ "${1:-}" = -version ]; then version_argument=-version; shift; fi
    for candidate in "$@"; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        # Version probes can be broken stubs. Bound their runtime without dependencies.
        output=$(mktemp)
        "$candidate" "$version_argument" >"$output" 2>&1 & pid=$!
        waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
        if wait "$pid" 2>/dev/null && [ -s "$output" ]; then
            rm -f "$output"; command -v "$candidate"; return 0
        fi
        rm -f "$output"
    done
    return 1
}

find_java() {
    find_tool -version javac
}

scaffold_main() {
    local language="$1" name="" root="${ENVLAUNCHER_ROOT:-$HOME/VS Code}" check=0
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --) shift; [ "$#" -eq 1 ] || { echo '需要且只能提供一个项目名' >&2; return 2; }; name="$1"; break;;
            --check) check=1; shift;;
            --root) [ "$#" -ge 2 ] || { echo '--root 需要一个目录' >&2; return 2; }; root="$2"; shift 2;;
            *) [ -z "$name" ] || { echo '参数过多' >&2; return 2; }; name="$1"; shift;;
        esac
    done
    local tool="" extension="" source="" standard="" command="" warning="" architecture
    case "$language" in
        c) tool=$(find_tool cc clang gcc || true); extension=ms-vscode.cpptools; source=src/main.c; standard=c17;;
        cpp) tool=$(find_tool c++ clang++ g++ || true); extension=ms-vscode.cpptools; source=src/main.cpp; standard=c++17;;
        py) tool=$(find_tool python3 || true); extension=ms-python.python; source=main.py;;
        java) tool=$(find_java || true); extension=vscjava.vscode-java-pack; source=src/Main.java;;
    esac
    if [ "$check" -eq 1 ]; then
        if [ -n "$tool" ]; then printf '工具链已找到：%s\n' "$tool"; else printf '缺少工具链；仍可创建项目，安装后再运行。\n'; fi
        printf 'VS Code 扩展：%s\n' "$extension"
        return 0
    fi
    valid_name "$name" || { echo '项目名不能为空，不能包含控制字符、路径分隔符、Windows 保留字符/名称，或以空格开头、空格/句点结尾。' >&2; return 2; }
    [ -n "$root" ] && ! [[ "$root" =~ [[:cntrl:]] ]] || { echo '保存位置不能为空或包含控制字符。' >&2; return 2; }
    mkdir -p "$root"
    root=$(cd "$root" && pwd -P)
    DIR="$root/$name"
    # mkdir claims ownership atomically; never clean up or overwrite an existing project.
    mkdir "$DIR" || { echo "项目已存在或无法创建：$DIR" >&2; return 1; }
    trap 'result=$?; if [ "$result" -ne 0 ]; then rm -rf -- "$DIR"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$DIR/.vscode"
    printf '{"recommendations":["%s"%s]}\n' "$extension" "$([ "$language" = py ] && printf ',"ms-python.debugpy"' || true)" > "$DIR/.vscode/extensions.json"
    printf '.venv/\n__pycache__/\n*.py[cod]\nbuild/\nbin/\n.DS_Store\n' > "$DIR/.gitignore"
    case "$language" in
        c|cpp)
            mkdir "$DIR/src" "$DIR/build"
            if [ "$language" = c ]; then
                printf '#include <stdio.h>\n\nint main(void)\n{\n    puts("Hello, C!");\n    return 0;\n}\n' > "$DIR/$source"
                command="${tool:-clang}"
            else
                printf '#include <iostream>\n\nint main()\n{\n    std::cout << "Hello, C++!" << std::endl;\n    return 0;\n}\n' > "$DIR/$source"
                command="${tool:-clang++}"
            fi
            architecture=$(uname -m); [ "$architecture" = x86_64 ] && architecture=x64
            cat > "$DIR/.vscode/c_cpp_properties.json" <<EOF
{"version":4,"configurations":[{"name":"macOS","includePath":["\${workspaceFolder}/src/**"],"compilerPath":$(json_string "$command"),"cStandard":"c17","cppStandard":"c++17","intelliSenseMode":"macos-clang-$architecture"}]}
EOF
            cat > "$DIR/.vscode/tasks.json" <<EOF
{"version":"2.0.0","tasks":[{"label":"编译","type":"process","command":$(json_string "$command"),"args":["-std=$standard","-Wall","-Wextra","-g","-O0","-o","\${workspaceFolder}/build/main","\${workspaceFolder}/$source"],"options":{"cwd":"\${workspaceFolder}"},"problemMatcher":["\$gcc"],"group":{"kind":"build","isDefault":true}},{"label":"运行","type":"process","command":"\${workspaceFolder}/build/main","dependsOn":"编译","problemMatcher":[]}]}
EOF
            # Omit miDebuggerPath: the extension resolves its own bundled LLDB adapter.
            cat > "$DIR/.vscode/launch.json" <<'EOF'
{"version":"0.2.0","configurations":[{"name":"调试 (F5)","type":"cppdbg","request":"launch","program":"${workspaceFolder}/build/main","cwd":"${workspaceFolder}","MIMode":"lldb","externalConsole":false,"preLaunchTask":"编译"}]}
EOF
            [ -n "$tool" ] || warning='缺少 C/C++ 编译器。运行 xcode-select --install 安装命令行工具，然后重启 VS Code。'
            ;;
        py)
            printf 'def main():\n    print("你好，Python！")\n\n\nif __name__ == "__main__":\n    main()\n' > "$DIR/main.py"
            cat > "$DIR/.vscode/settings.json" <<'EOF'
{"python.defaultInterpreterPath":"${workspaceFolder}/.venv/bin/python","python.terminal.activateEnvironment":true}
EOF
            cat > "$DIR/.vscode/launch.json" <<'EOF'
{"version":"0.2.0","configurations":[{"name":"调试 (F5)","type":"debugpy","request":"launch","program":"${workspaceFolder}/main.py","console":"integratedTerminal"}]}
EOF
            if [ -z "$tool" ]; then
                warning='没有找到可用的 Python 3。请安装 Python 3，随后在项目目录运行 python3 -m venv .venv。'
            else
                echo '正在创建 Python 虚拟环境…'
                if "$tool" -m venv "$DIR/.venv" > "$DIR/.venv-create.log" 2>&1 && [ -x "$DIR/.venv/bin/python" ]; then
                    rm -f "$DIR/.venv-create.log"
                else
                    warning='Python 已找到，但虚拟环境创建失败。具体错误见 .venv-create.log。修复后在本目录重新运行 python3 -m venv .venv。'
                fi
            fi
            ;;
        java)
            mkdir "$DIR/src" "$DIR/bin"
            printf 'public class Main {\n    public static void main(String[] args) {\n        System.out.println("Hello, Java!");\n    }\n}\n' > "$DIR/src/Main.java"
            cat > "$DIR/.vscode/settings.json" <<'EOF'
{"java.project.sourcePaths":["src"],"java.project.outputPath":"bin","java.configuration.updateBuildConfiguration":"automatic"}
EOF
            cat > "$DIR/.vscode/tasks.json" <<EOF
{"version":"2.0.0","tasks":[{"label":"编译","type":"process","command":$(json_string "${tool:-javac}"),"args":["-encoding","UTF-8","-d","\${workspaceFolder}/bin","\${workspaceFolder}/src/Main.java"],"problemMatcher":["\$javac"],"group":{"kind":"build","isDefault":true}},{"label":"运行","type":"process","command":"java","args":["-cp","\${workspaceFolder}/bin","Main"],"dependsOn":"编译","problemMatcher":[]}]}
EOF
            # Java's unmanaged project name is supplied by the extension, not the folder name.
            cat > "$DIR/.vscode/launch.json" <<'EOF'
{"version":"0.2.0","configurations":[{"name":"调试 (F5)","type":"java","request":"launch","mainClass":"Main","cwd":"${workspaceFolder}"}]}
EOF
            [ -n "$tool" ] || warning='没有找到可用的 JDK（javac）。请从 https://adoptium.net/ 安装 JDK，重启 VS Code 后再编译。'
            ;;
    esac
    if [ -n "$warning" ]; then
        printf '# 工具链需要处理\n\n%s\n\n修复后即可使用现有项目，无需重建。确认可以运行后可删除本提示。\n' "$warning" > "$DIR/!缺少工具链.md"
    fi
    printf '# %s\n\n在 `%s` 中编写代码。\n\n安装 VS Code 推荐的扩展后按 F5 调试。C/C++ 和 Java 可用“编译”任务编译当前入口文件；多文件项目请按需扩展 tasks.json。\n\nPython 项目使用 .venv；若缺少工具链，请先阅读 !缺少工具链.md。\n' "$name" "$source" > "$DIR/README.md"
    # Written last. Launchers validate this manifest as well as the process exit status.
    printf '{"schemaVersion":1,"language":"%s","requiredFiles":["%s",".vscode/launch.json",".vscode/extensions.json","README.md"]}\n' "$language" "$source" > "$DIR/.envlauncher.json"
    trap - EXIT INT TERM
    printf '项目已创建：%s\n' "$DIR"
    [ -z "$warning" ] || printf '%s\n' "$warning"
}
