# <img src="assets/appicon-title.png" width="36" align="absmiddle"> EnvLauncher

选好环境，自动在 VS Code 新窗口打开 —— 目录结构、编译与调试配置一次生成，不用再手动建目录、配 `tasks.json`、敲命令。

**适配系统**　macOS（Apple Silicon）｜ Windows

**适配环境**　C ｜ C++ ｜ Python ｜ Java

**适配软件**　<img src="assets/vscode.png" width="20"> Visual Studio Code

## 安装

**下载安装包**（推荐）→ [Releases](https://github.com/Alooshy0827/EnvLauncher/releases/latest)

挑对应平台的那个：**macOS（Apple Silicon）** 或 **Windows**。

> **macOS**：首次打开需**右键 →「打开」**（应用未签名，双击会被 Gatekeeper 拦下）
>
> **Windows**：解压前先右键压缩包 → 属性 → **解除锁定**，否则 PowerShell 会拒绝执行脚本

**从源码安装**

```bash
# macOS
git clone https://github.com/Alooshy0827/EnvLauncher.git
cd EnvLauncher/macos && ./build.sh --install
mkdir -p ~/bin
cp new-* scaffold-common.sh ~/bin/  # 可选：命令行建项目
```

**Windows**：下载本仓库 → 右键 `windows/install.ps1` → 使用 PowerShell 运行

## 使用

选择环境、填写项目名和保存位置，点击 **创建并打开**。右侧可搜索和打开最近项目，界面自动跟随系统深浅色。

## 依赖

- [VS Code](https://code.visualstudio.com/)
- C / C++：Clang、MinGW-w64 或 Visual Studio C++ Build Tools
- Python：Python 3
- Java：JDK（含 `javac`）

## License

[MIT](LICENSE)
