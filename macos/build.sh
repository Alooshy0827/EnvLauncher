#!/bin/bash
# ============================================================
#  build.sh —— 构建 macOS 版 EnvLauncher（环境启动器.app）
#
#  用法:  ./build.sh              构建到 ./dist/
#         ./build.sh --install    构建并安装到 ~/Applications/
#
#  依赖: Xcode Command Line Tools 里的 swiftc（系统自带）
# ============================================================

set -euo pipefail

# ── 可配置项 ──
APP_NAME="环境启动器"              # 应用显示名
BUNDLE_ID="local.envlauncher"      # 保持与原版一致，重装时替换而不是并存
VERSION="1.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/main.swift"
ICON="$SCRIPT_DIR/assets/AppIcon.icns"
EDITOR_ICON="$SCRIPT_DIR/../assets/vscode.png"
DIST="$SCRIPT_DIR/dist"
APP="$DIST/$APP_NAME.app"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}  ✓${RESET} $*"; }
fail() { echo "${RED}  ✗${RESET} $*" >&2; exit 1; }

echo
echo "${BOLD}构建 $APP_NAME.app${RESET}"
echo "${DIM}  源码: $SRC${RESET}"

# ── 前置检查 ──
[ -f "$SRC" ] || fail "找不到源码: $SRC"
[ -f "$EDITOR_ICON" ] || fail "找不到 VS Code 图标: $EDITOR_ICON"
command -v swiftc >/dev/null 2>&1 || fail "找不到 swiftc，请先安装 Xcode Command Line Tools：xcode-select --install"

# ── 清理 ──
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ── 编译 ──
echo "  编译中..."
ERRLOG="$(mktemp)"
ARCH="$(uname -m)"
[ "$ARCH" = x86_64 ] || ARCH=arm64
if ! swiftc -target "$ARCH-apple-macosx11.0" -O -o "$APP/Contents/MacOS/launcher" "$SRC" 2>"$ERRLOG"; then
    cat "$ERRLOG" >&2
    rm -f "$ERRLOG"
    fail "编译失败"
fi
if grep -q "error:" "$ERRLOG"; then
    cat "$ERRLOG" >&2
    rm -f "$ERRLOG"
    fail "编译出现错误"
fi
# 保留编译警告，便于跟进 SDK 的兼容性变化。
if [ -s "$ERRLOG" ]; then cat "$ERRLOG" >&2; fi
WARNCOUNT=$(grep -c "warning:" "$ERRLOG" 2>/dev/null || true)
rm -f "$ERRLOG"
[ -n "${WARNCOUNT:-}" ] || WARNCOUNT=0
[ -f "$APP/Contents/MacOS/launcher" ] || fail "编译失败"
ok "编译完成 ($(stat -f%z "$APP/Contents/MacOS/launcher") bytes，$WARNCOUNT 条编译警告)"

# ── 图标 ──
cp "$EDITOR_ICON" "$APP/Contents/Resources/vscode.png"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
    ok "图标已装入"
else
    echo "  ${DIM}(未找到图标，跳过)${RESET}"
fi

# ── 脚手架（打包进 App 作兜底副本）──
# 启动器会扫描 new-* 脚本；用户自己的在 ~/bin 或 PATH 里优先，
# 这份是 App 自带的兜底，保证不装任何东西也能用。
mkdir -p "$APP/Contents/Resources/scripts"
BUNDLED=0
cp "$SCRIPT_DIR/scaffold-common.sh" "$APP/Contents/Resources/scripts/"
for s in "$SCRIPT_DIR"/new-*; do
    [ -f "$s" ] || continue
    cp "$s" "$APP/Contents/Resources/scripts/"
    chmod +x "$APP/Contents/Resources/scripts/$(basename "$s")"
    BUNDLED=$((BUNDLED + 1))
done
ok "已打包 $BUNDLED 个脚手架: $(ls "$APP/Contents/Resources/scripts" | tr '\n' ' ')"

# ── Info.plist ──
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>         <string>launcher</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>     <string>11.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST
ok "Info.plist 已生成"

# 去掉隔离属性，避免首次打开被 Gatekeeper 拦
xattr -cr "$APP" 2>/dev/null || true

echo
ok "构建完成: $APP"

# ── 可选安装 ──
if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    # 刷新 LaunchServices，让访达立刻认到新图标
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST/$APP_NAME.app" 2>/dev/null || true
    ok "已安装到: $DEST/$APP_NAME.app"
    echo
    echo "  在访达里打开「应用程序」即可看到，双击运行。"
fi
echo
