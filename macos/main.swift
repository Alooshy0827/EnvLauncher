import Cocoa

struct Scaffold {
    let id: String
    let label: String
    let path: String
    let protocolVersion: Int
}
struct Settings: Codable {
    var root: String
    var lastScaffold: String
    var recent: [String]
}
struct CommandResult {
    let status: Int32
    let output: String
}
let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let stateDirectory = ProcessInfo.processInfo.environment["ENVLAUNCHER_STATE_DIR"]
    ?? (home + "/Library/Application Support/EnvLauncher")

func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func loginShell() -> String {
    let value = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    return fm.isExecutableFile(atPath: value) ? value : "/bin/zsh"
}
// Both streams go to a file, so a full stderr pipe can never block the child.
// Called only on a worker queue. The process exit status is always preserved.
func runCommand(_ executable: String, _ arguments: [String], log: String? = nil) -> CommandResult {
    let path = log ?? (NSTemporaryDirectory() + UUID().uuidString + ".log")
    defer { if log == nil { try? fm.removeItem(atPath: path) } }
    do {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard fm.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path) else {
            return CommandResult(status: 1, output: "无法写入执行日志：\(path)")
        }
        defer { handle.closeFile() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let output = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "无法读取日志。"
        return CommandResult(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        let message = error.localizedDescription
        if log != nil { try? message.write(toFile: path, atomically: true, encoding: .utf8) }
        return CommandResult(status: 1, output: message)
    }
}
func runShell(_ command: String, log: String? = nil) -> CommandResult {
    return runCommand(loginShell(), ["-lc", command], log: log)
}
func validName(_ name: String) -> Bool {
    if name.isEmpty || name != name.trimmingCharacters(in: .whitespacesAndNewlines) || name.hasSuffix(".") { return false }
    if name.rangeOfCharacter(from: .controlCharacters) != nil { return false }
    if name.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/:*?\"<>|")) != nil { return false }
    return name.range(of: "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\\.|$)", options: [.regularExpression, .caseInsensitive]) == nil
}
func discoverScaffolds() -> [Scaffold] {
    var directories = [home + "/bin"]
    directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    if let resource = Bundle.main.resourcePath { directories.append(resource + "/scripts") }
    if let override = ProcessInfo.processInfo.environment["ENVLAUNCHER_SCRIPTS"] { directories.insert(override, at: 0) }
    var result: [String: Scaffold] = [:]
    for directory in directories {
        for name in ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).sorted() where name.hasPrefix("new-") {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: path) else { continue }
            var label = String(name.dropFirst(4)).capitalized
            var version = 1
            if let handle = FileHandle(forReadingAtPath: path) {
                let text = String(data: handle.readData(ofLength: 8192), encoding: .utf8) ?? ""
                handle.closeFile()
                for raw in text.components(separatedBy: .newlines).prefix(20) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("# @label ") { label = String(line.dropFirst(9)) }
                    if line == "# @protocol 2" { version = 2 }
                }
            }
            // Older copies installed in ~/bin must not silently shadow upgraded bundled templates.
            if let previous = result[name], previous.protocolVersion >= version { continue }
            result[name] = Scaffold(id: name, label: label, path: path, protocolVersion: version)
        }
    }
    return result.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
}
func findVSCode() -> String? {
    for candidate in ["/Applications/Visual Studio Code.app", home + "/Applications/Visual Studio Code.app"] {
        let path = candidate + "/Contents/Resources/app/bin/code"
        if fm.isExecutableFile(atPath: path) { return path }
    }
    let result = runShell("command -v code")
    return result.status == 0 && fm.isExecutableFile(atPath: result.output) ? result.output : nil
}
func validProject(_ path: String, scaffold: Scaffold) -> Bool {
    var directory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return false }
    if scaffold.protocolVersion < 2 { return true }
    guard let data = fm.contents(atPath: path + "/.envlauncher.json"),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          object["schemaVersion"] as? Int == 1,
          let files = object["requiredFiles"] as? [String], !files.isEmpty else { return false }
    let root = URL(fileURLWithPath: path).standardizedFileURL.path + "/"
    return files.allSatisfy { relative in
        let file = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        return file.hasPrefix(root) && fm.fileExists(atPath: file, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var settings = Settings(root: home + "/VS Code", lastScaffold: "", recent: [])
    let scaffolds = discoverScaffolds()
    let environment = NSPopUpButton()
    let name = NSTextField()
    let location = NSTextField()
    let preview = NSTextField(labelWithString: "")
    let toolchain = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let search = NSSearchField()
    let table = NSTableView()
    let recentEmpty = NSTextField(wrappingLabelWithString: "最近打开的项目将显示在这里。")
    let progress = NSProgressIndicator()
    var create: NSButton!
    var browse: NSButton!
    var existing: NSButton!
    var openRecent: NSButton!
    var busy = false
    var checkGeneration = 0
    var recentPaths: [String] = []
    let settingsPath = stateDirectory + "/settings.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = fm.contents(atPath: settingsPath), let value = try? JSONDecoder().decode(Settings.self, from: data) { settings = value }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "环境启动器"
        window.delegate = self
        window.center()
        let view = window.contentView!
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, bold: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: x, y: y, width: w, height: h)
            field.font = bold ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 13)
            view.addSubview(field)
            return field
        }
        let editorIcon = NSImageView(frame: NSRect(x: 20, y: 496, width: 64, height: 64))
        editorIcon.image = Bundle.main.url(forResource: "vscode", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        editorIcon.imageScaling = .scaleProportionallyUpOrDown
        editorIcon.setAccessibilityLabel("Visual Studio Code")
        view.addSubview(editorIcon)
        _ = label("新建项目", 96, 525, 292, 30, bold: true)
        _ = label("选好环境，直接开始写代码。", 96, 502, 292, 22)
        _ = label("环境", 28, 455, 360, 22)
        environment.frame = NSRect(x: 26, y: 420, width: 362, height: 30)
        environment.addItems(withTitles: scaffolds.map { $0.label })
        if let index = scaffolds.firstIndex(where: { $0.id == settings.lastScaffold }) { environment.selectItem(at: index) }
        environment.target = self; environment.action = #selector(environmentChanged)
        view.addSubview(environment)
        _ = label("项目名称", 28, 382, 360, 22)
        name.frame = NSRect(x: 28, y: 348, width: 360, height: 27)
        name.placeholderString = "例如：我的练习"; name.delegate = self
        view.addSubview(name)
        _ = label("保存到", 28, 310, 360, 22)
        location.frame = NSRect(x: 28, y: 275, width: 280, height: 27)
        location.stringValue = settings.root; location.delegate = self
        view.addSubview(location)
        browse = NSButton(title: "选择…", target: self, action: #selector(selectLocation))
        browse.frame = NSRect(x: 312, y: 273, width: 80, height: 30); browse.bezelStyle = .rounded; view.addSubview(browse)
        preview.frame = NSRect(x: 28, y: 237, width: 360, height: 28)
        preview.font = .systemFont(ofSize: 11); preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingMiddle; view.addSubview(preview)
        toolchain.frame = NSRect(x: 28, y: 135, width: 360, height: 88)
        toolchain.font = .systemFont(ofSize: 12); toolchain.textColor = .secondaryLabelColor; view.addSubview(toolchain)
        create = NSButton(title: "创建并打开", target: self, action: #selector(createProject))
        create.bezelStyle = .rounded; create.keyEquivalent = "\r"
        create.frame = NSRect(x: 255, y: 91, width: 139, height: 34); view.addSubview(create)
        let divider = NSBox(frame: NSRect(x: 410, y: 90, width: 1, height: 459)); divider.boxType = .separator; view.addSubview(divider)
        _ = label("最近项目", 438, 525, 354, 30, bold: true)
        search.frame = NSRect(x: 438, y: 490, width: 354, height: 28)
        search.placeholderString = "搜索名称或路径"; search.delegate = self; view.addSubview(search)
        let scroll = NSScrollView(frame: NSRect(x: 438, y: 148, width: 354, height: 326))
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project")); column.width = 333
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 57
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelectedRecent)
        scroll.documentView = table; view.addSubview(scroll)
        recentEmpty.frame = NSRect(x: 452, y: 361, width: 326, height: 65)
        recentEmpty.textColor = .secondaryLabelColor; recentEmpty.font = .systemFont(ofSize: 13)
        view.addSubview(recentEmpty)
        existing = NSButton(title: "打开其他项目 / 工作区…", target: self, action: #selector(openExisting))
        existing.bezelStyle = .rounded; existing.frame = NSRect(x: 433, y: 94, width: 230, height: 30); view.addSubview(existing)
        openRecent = NSButton(title: "打开", target: self, action: #selector(openSelectedRecent))
        openRecent.bezelStyle = .rounded; openRecent.frame = NSRect(x: 704, y: 94, width: 93, height: 30); view.addSubview(openRecent)
        let footer = NSBox(frame: NSRect(x: 28, y: 74, width: 764, height: 1)); footer.boxType = .separator; view.addSubview(footer)
        progress.frame = NSRect(x: 29, y: 29, width: 20, height: 20); progress.style = .spinning; progress.isDisplayedWhenStopped = false; view.addSubview(progress)
        status.frame = NSRect(x: 58, y: 17, width: 734, height: 44); status.font = .systemFont(ofSize: 14); status.textColor = .secondaryLabelColor; view.addSubview(status)
        refreshRecent(); updatePreview(); refreshToolchain()
        window.makeFirstResponder(name)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if busy { NSSound.beep() }; return !busy }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { return busy ? .terminateCancel : .terminateNow }
    func saveSettings() {
        do {
            try fm.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        } catch { status.stringValue = "项目可用，但无法保存最近记录：\(error.localizedDescription)" }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { refreshRecent() } else { updatePreview() }
    }
    func updatePreview() {
        let root = (location.stringValue as NSString).expandingTildeInPath
        preview.stringValue = root + "/" + (name.stringValue.isEmpty ? "项目名称" : name.stringValue)
        create.isEnabled = !busy && validName(name.stringValue) && !root.isEmpty && !scaffolds.isEmpty
        if !name.stringValue.isEmpty && !validName(name.stringValue) {
            status.stringValue = "请使用有效名称，避开路径分隔符、保留名称，以及开头的空格和结尾的空格/句点。"
        } else if !busy { status.stringValue = "文件准备完成后会在 VS Code 新窗口打开。" }
    }
    @objc func environmentChanged() { refreshToolchain() }
    func refreshToolchain() {
        checkGeneration += 1
        let generation = checkGeneration
        guard environment.indexOfSelectedItem >= 0, environment.indexOfSelectedItem < scaffolds.count else { toolchain.stringValue = "未发现脚手架，请重新安装应用。"; return }
        let scaffold = scaffolds[environment.indexOfSelectedItem]
        guard scaffold.protocolVersion >= 2 else { toolchain.stringValue = "自定义脚手架：\(scaffold.path)\n保存位置通过 ENVLAUNCHER_ROOT 传入。"; return }
        toolchain.stringValue = "正在检测工具链…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runShell("exec " + shellQuote(scaffold.path) + " --check")
            DispatchQueue.main.async {
                if self.checkGeneration == generation { self.toolchain.stringValue = result.output.isEmpty ? "检测失败，创建时将显示详细日志。" : result.output }
            }
        }
    }
    @objc func selectLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (location.stringValue as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { location.stringValue = url.path; updatePreview() }
    }
    func setBusy(_ value: Bool) {
        busy = value
        for control: NSControl in [environment, name, location, browse, existing, openRecent, search] { control.isEnabled = !value }
        table.isEnabled = !value
        if value { progress.startAnimation(nil); create.isEnabled = false } else { progress.stopAnimation(nil); updatePreview() }
    }
    func showError(_ text: String, log: String? = nil) {
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = text; alert.alertStyle = .warning
        alert.addButton(withTitle: "返回")
        if log != nil { alert.addButton(withTitle: "查看日志") }
        if alert.runModal() == .alertSecondButtonReturn, let path = log { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
    @objc func createProject() {
        guard !busy, validName(name.stringValue), environment.indexOfSelectedItem >= 0 else { return }
        let projectName = name.stringValue
        let rawRoot = (location.stringValue as NSString).expandingTildeInPath
        guard rawRoot.hasPrefix("/"), rawRoot.rangeOfCharacter(from: .controlCharacters) == nil else { showError("请选择有效的绝对保存路径。"); return }
        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL.path
        let target = root + "/" + projectName
        if fm.fileExists(atPath: target) { showError("项目已存在：\(target)\n请换一个名称，或从右侧打开已有项目。"); return }
        let scaffold = scaffolds[environment.indexOfSelectedItem]
        settings.root = root; settings.lastScaffold = scaffold.id
        setBusy(true); status.stringValue = "正在创建 \(projectName)…窗口会保持打开。"
        let log = stateDirectory + "/Logs/" + UUID().uuidString + ".log"
        DispatchQueue.global(qos: .userInitiated).async {
            guard let code = findVSCode() else {
                DispatchQueue.main.async { self.setBusy(false); self.showError("没有找到 VS Code。请先安装 VS Code，或把 code 命令加入 PATH。"); }; return
            }
            var command = "export ENVLAUNCHER_ROOT=" + shellQuote(root) + "; exec " + shellQuote(scaffold.path)
            if scaffold.protocolVersion >= 2 { command += " --root " + shellQuote(root) + " -- " + shellQuote(projectName) }
            else { command += " " + shellQuote(projectName) }
            let result = runShell(command, log: log)
            let complete = result.status == 0 && validProject(target, scaffold: scaffold)
            DispatchQueue.main.async {
                self.setBusy(false)
                guard complete else {
                    self.status.stringValue = "创建失败；可修改后重试。日志：\(log)"
                    self.showError("脚手架退出码：\(result.status)\n" + (result.output.isEmpty ? "未找到完整的项目文件。" : String(result.output.suffix(1600))), log: log)
                    return
                }
                self.recordRecent(target)
                self.openPath(target, code: code)
                self.status.stringValue = fm.fileExists(atPath: target + "/!缺少工具链.md") ? "项目已创建。工具链需要处理，请查看项目内的 !缺少工具链.md。" : "项目已创建并打开：\(projectName)"
            }
        }
    }
    func recordRecent(_ path: String) {
        settings.recent.removeAll { $0 == path }; settings.recent.insert(path, at: 0)
        settings.recent = Array(settings.recent.prefix(30)); saveSettings(); refreshRecent()
    }
    func refreshRecent() {
        let query = search.stringValue
        recentPaths = settings.recent.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        recentEmpty.isHidden = !recentPaths.isEmpty
        recentEmpty.stringValue = query.isEmpty ? "最近打开的项目将显示在这里。\n可打开任意文件夹或工作区。" : "没有匹配的最近项目。"
        if settings.recent.isEmpty { status.stringValue = "还没有最近项目。可以新建项目，或打开已有文件夹 / .code-workspace。" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { return recentPaths.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 333, height: 57))
        let path = recentPaths[row]
        let title = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        title.frame = NSRect(x: 7, y: 30, width: 320, height: 19); title.font = .boldSystemFont(ofSize: 13)
        let subtitle = NSTextField(labelWithString: path)
        subtitle.frame = NSRect(x: 7, y: 7, width: 320, height: 18); subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(title); cell.addSubview(subtitle); cell.toolTip = path
        return cell
    }
    func openPath(_ path: String, code: String) {
        // The launcher waits for CLI startup on a worker queue to report startup errors.
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runCommand(code, ["-n", "--", path])
            DispatchQueue.main.async {
                self.setBusy(false)
                if result.status != 0 { self.status.stringValue = "项目已保留，但 VS Code 打开失败。"; self.showError("项目已保留，但无法打开 VS Code：\n" + String(result.output.suffix(1200))) }
                else { self.status.stringValue = fm.fileExists(atPath: path + "/!缺少工具链.md") ? "项目已打开。工具链需要处理，请查看项目内的 !缺少工具链.md。" : "已打开：\((path as NSString).lastPathComponent)" }
            }
        }
    }
    @objc func openSelectedRecent() {
        guard !busy, table.selectedRow >= 0, table.selectedRow < recentPaths.count else { return }
        openExistingPath(recentPaths[table.selectedRow])
    }
    @objc func openExisting() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowedFileTypes = ["code-workspace"]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openExistingPath(url.path) }
    }
    func openExistingPath(_ path: String) {
        guard fm.fileExists(atPath: path) else { showError("项目路径已移动或删除：\(path)"); return }
        setBusy(true); status.stringValue = "正在打开项目…"
        DispatchQueue.global(qos: .userInitiated).async {
            let code = findVSCode()
            DispatchQueue.main.async {
                self.setBusy(false)
                if let command = code { self.recordRecent(path); self.openPath(path, code: command) }
                else { self.showError("没有找到 VS Code，请先安装 VS Code 或配置 code 命令。"); }
            }
        }
    }
}

if ProcessInfo.processInfo.environment["ENVLAUNCHER_LIST"] == "1" {
    for scaffold in discoverScaffolds() { print("\(scaffold.id)\t\(scaffold.label)\t\(scaffold.path)") }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenu = NSMenuItem(); menu.addItem(appMenu)
let appCommands = NSMenu(); appMenu.submenu = appCommands
appCommands.addItem(withTitle: "退出环境启动器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
let edit = NSMenu(title: "编辑"); editItem.submenu = edit
for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
    edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
}
app.mainMenu = menu
let delegate = Launcher()
app.delegate = delegate
app.run()
