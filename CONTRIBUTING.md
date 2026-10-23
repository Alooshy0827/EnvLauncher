# 开发注意

## ⚠️ `windows/*.ps1` 必须保留 UTF-8 BOM

Windows PowerShell 5.1（系统自带那个）读取**没有 BOM** 的 `.ps1` 时，会按系统 ANSI 码页（中文系统是 GBK）解析，脚本里所有中文都会变成乱码 —— 界面文字全废。

这个坑尤其隐蔽：BOM 被抹掉后，**本地和远程是一致地坏**，`git status`、`git diff`、和远程对比都看不出来。

所以 `windows/*.ps1` **必须**以 `EF BB BF` 开头。很多编辑器（包括各种 AI 编程工具）保存时会悄悄抹掉 BOM，改完记得确认：

```bash
head -c 3 windows/new-c.ps1 | xxd -p    # 应输出 efbbbf
```

批量补 BOM：

```bash
python3 -c "
import glob
BOM = b'\xef\xbb\xbf'
for f in glob.glob('windows/*.ps1'):
    raw = open(f,'rb').read()
    if not raw.startswith(BOM):
        open(f,'wb').write(BOM + raw); print('fixed', f)
"
```

## 改完 PowerShell 脚本建议校验语法

不用真的跑到 Windows 上，用 PowerShell 自带的 AST 解析器就能查出语法错误：

```bash
pwsh -Command "
\$e=\$null
[System.Management.Automation.Language.Parser]::ParseFile('windows/new-c.ps1',[ref]\$null,[ref]\$e)
if(\$e.Count){ \$e | %{ \$_.Message } } else { 'OK' }
"
```

## 构建 macOS 版

```bash
cd macos
./build.sh            # 构建到 ./dist/
./build.sh --install  # 构建并安装到 ~/Applications/
```

源码只有 `main.swift` 一个文件，用系统自带的 `swiftc` 编译，无第三方依赖。

## 目录约定

- 默认项目根目录是用户目录下的 `VS Code`，界面支持选择任意保存位置并记忆上次设置。
- 命令行支持 macOS `--root DIRECTORY` / Windows `-Root DIRECTORY`，也支持 `ENVLAUNCHER_ROOT`。
- 设置、最近项目和日志与源码分开保存：macOS 为 `~/Library/Application Support/EnvLauncher/`，Windows 为 `%LOCALAPPDATA%\EnvLauncher\`。可用 `ENVLAUNCHER_STATE_DIR` 隔离测试数据。
- 内置脚手架分别使用 `macos/scaffold-common.sh` 和 `windows/scaffold-common.ps1`；分发时需与 `new-*` 一起复制。

## README 标题图标的对齐方式

`assets/` 下有两个图标，用途不同：

| 文件 | 用途 |
|---|---|
| `appicon.png` | 干净的方形图标原图（256×256） |
| `appicon-title.png` | README 标题专用（256×316，底部多 60px 透明边距） |

标题用的是后者，配合 `align="absmiddle"`：

```html
# <img src="assets/appicon-title.png" width="36" align="absmiddle"> EnvLauncher
```

**为什么要留白**：GitHub 会把 `style` 和 `class` 属性清洗掉，只剩 `align` 可用来控制垂直对齐。而 `align="absmiddle"` 是把整张图（含透明区）在行内居中 —— 底部那 60px 透明区会把可见图标往上顶约 3px，正好抵消掉默认的偏低。实测偏差从 +3.5px 收敛到 −0.5px。

改图标时记得**重新导出这两个文件**：先出方形原图，再在底部补 60px 透明边距。

> 别用 `align="middle"` —— 实测偏低 11.5px，比默认的偏高 6.5px 还糟。

## 怎么加一个新环境

启动器扫描目录里所有 `new-*` 脚本，从开头的 `# @label XXX` 读取显示名。
`~/bin` / PATH / 应用内置脚本中，同名脚本优先选择协议版本较高的副本；相同版本保留先发现者。
这样以前安装到 bin 的旧副本不会遮住升级后的模板。自定义脚本不必修改启动器。

**1. 写脚手架脚本**

- macOS：`macos/new-xxx`（bash，记得 `chmod +x`）
- Windows：`windows/new-xxx.ps1`（PowerShell，**必须带 UTF-8 BOM**）

脚本第一行注释声明显示名：

```bash
#!/bin/bash
# @label Rust
```

```powershell
#Requires -Version 5.1
# @label Rust
```

没有 `@label` 也能用，会回退成文件名首字母大写（`new-rust` → `Rust`）。

**2. 完事**

`build.sh` 和 `install.ps1` 都是按 `new-*` 通配收录的，不用改。
把脚本放进 `~/bin`（macOS）或 `%USERPROFILE%\bin`（Windows）即可生效。

### 脚手架约定

- 新脚本标记 `# @protocol 2`，并支持 `--root` / `-Root` 和只读的 `--check` / `-Check`。
- GUI 也会传入 `ENVLAUNCHER_ROOT`；旧脚本可继续使用，但需自行读取该变量才能支持自选位置。
- 项目名必须作为单个目录名处理；调用公共校验，禁止路径穿越、控制字符、保留名称和末尾空格/句点。
- 创建前原子地取得目录所有权，不覆盖已有目录；失败只清理本次新建的目录。
- 全部文件写完后最后生成 `.envlauncher.json`，包含 `schemaVersion: 1`、`language` 和 `requiredFiles` 相对文件列表。GUI 同时检查退出码和这些文件。
- 生成 JSON 时不要拼接未经转义的名称/路径。Windows 使用 `ConvertTo-Json`，macOS 路径使用 `json_string`。
- VS Code 任务优先使用 `type: process`，避免用户路径被 shell 再次解释。
- macOS C/C++ 不指定带版本号的扩展路径；由扩展定位调试适配器。
- **检测工具链时要真的执行一次**，不能只看 `command -v` / `Get-Command`。
  macOS 没装 JDK 时 `/usr/bin/javac` 也存在，但那只是个占位存根；
  Windows 上 Oracle 的 `javapath` 在 JDK 卸载后也会留坏存根。
- 工具链缺失时**照常建项目**，但在项目根目录写一个 `!缺少工具链.md`，
  里面写清楚缺什么、怎么装。启动器会检测该文件并在状态栏提示，具体原因保留在项目内。

### 排查「我的环境没出现在菜单里」

```bash
ENVLAUNCHER_LIST=1 ~/Applications/环境启动器.app/Contents/MacOS/launcher
```

会直接列出发现到的环境、标签和来源路径，不开面板。

## 发布流程

### Release notes 格式

**先放一遍完整的 README，再写本次更新。** 这样访问 release 页面的人
不用跳回仓库首页就知道这是什么、怎么装。

结构：

```markdown
<该 tag 的完整 README>

---

## 本次更新

<这次改了什么>
```

取某个 tag 的 README：

```bash
git show v1.2.0:README.md
```

### ⚠️ 相对链接要改成绝对路径

release 页面在 `/releases/tag/xxx` 下，README 里的相对路径会失效：

| README 里 | release 页面会解析成 | 结果 |
|---|---|---|
| `assets/appicon-title.png` | `.../releases/tag/assets/appicon-title.png` | ❌ 404 |
| `LICENSE` | `.../releases/tag/LICENSE` | ❌ 404 |

所以拼接前先替换成绝对链接：

```bash
python3 - <<'PY'
repo = 'https://github.com/Alooshy0827/EnvLauncher'
readme = readme.replace('src="assets/', f'src="{repo}/raw/main/assets/')
readme = readme.replace('](LICENSE)', f']({repo}/blob/main/LICENSE)')
PY
```

### 发布命令

```bash
git push origin main
gh release create v1.x.0 --title "..." --notes-file notes.md --target main \
  EnvLauncher-macOS-arm64.zip EnvLauncher-Windows.zip
```

更新已有 release 的内容：`gh release edit v1.x.0 --notes-file notes.md`

### 打包注意事项

- macOS 包**用 Python 的 `zipfile`**（保留 Unix 可执行权限），不要用 `ditto` —— 后者不会设置
  UTF-8 文件名标志（0x800），换成别的解压工具中文名会乱码
- Windows 包用 `zip -r` 即可，但**打完后要解压验证 BOM 还在**


## 验证要求

- macOS：`python3 tests/test_macos.py`；`macos/build.sh`；检查原生窗口。
- Windows：`powershell -NoProfile -File tests/test_windows.ps1`，另用 PowerShell 7 跑一次。
- Windows PowerShell 测试本身也必须带 UTF-8 BOM。
- CI 的 Windows 窗口冒烟测试只能确认进程/窗口存活；高 DPI 和不同系统主题仍需人工检查。
- 测试可用 `ENVLAUNCHER_SCRIPTS` 指定脚手架发现目录，`ENVLAUNCHER_STATE_DIR` 隔离设置和日志。
- 不要把测试项目、便携工具运行时或构建缓存提交到仓库。
