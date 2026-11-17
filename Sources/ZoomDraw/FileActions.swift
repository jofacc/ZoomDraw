import AppKit

/// 文件搜索里的操作（操作菜单 / 快捷键）
enum FileAction: CaseIterable {
    case open, openWith, reveal, copyFile, copyPath, copyName, moveTo, copyTo, rename, trash,
         terminal, info, quit, forceQuit, clearBuffer

    var title: String {
        switch self {
        case .open: return "打开"
        case .openWith: return "打开方式…"
        case .reveal: return "打开所在目录"
        case .copyFile: return "复制文件"
        case .copyPath: return "复制路径"
        case .copyName: return "复制文件名"
        case .moveTo: return "移动到…"
        case .copyTo: return "复制到…"
        case .rename: return "重命名…"
        case .trash: return "移到废纸篓"
        case .terminal: return "在终端中打开"
        case .info: return "显示简介"
        case .quit: return "退出应用"
        case .forceQuit: return "强制退出应用"
        case .clearBuffer: return "清空已选文件"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .openWith: return "square.grid.2x2"
        case .reveal: return "folder"
        case .copyFile: return "doc.on.doc"
        case .copyPath: return "link"
        case .copyName: return "textformat"
        case .moveTo: return "folder.badge.plus"
        case .copyTo: return "plus.square.on.square"
        case .rename: return "pencil"
        case .trash: return "trash"
        case .terminal: return "terminal"
        case .info: return "info.circle"
        case .quit: return "xmark.circle"
        case .forceQuit: return "exclamationmark.octagon"
        case .clearBuffer: return "xmark.bin"
        }
    }

    var shortcut: String {
        switch self {
        case .open: return "⏎"
        case .reveal: return "⌘⏎"
        case .copyPath: return "⌘C"
        case .copyFile: return "⌥⌘C"
        default: return ""
        }
    }

    /// 适用于这些目标的操作
    static func available(for urls: [URL], isBuffer: Bool) -> [FileAction] {
        guard !urls.isEmpty else { return [] }
        if isBuffer || urls.count > 1 {
            return [.open, .reveal, .copyFile, .copyPath, .moveTo, .copyTo, .trash, .clearBuffer]
        }
        let u = urls[0]
        if u.pathExtension.lowercased() == "app" {
            var list: [FileAction] = [.open, .reveal, .copyPath, .info]
            if !FileOps.runningApps(for: u).isEmpty { list += [.quit, .forceQuit] }
            return list
        }
        var list: [FileAction] = [.open, .openWith, .reveal, .copyFile, .copyPath, .copyName,
                                  .moveTo, .copyTo, .rename, .trash]
        if FileSearchSettings.isDirectory(u.path) && !NSWorkspace.shared.isFilePackage(atPath: u.path) {
            list.removeAll { $0 == .openWith }
            list.append(.terminal)
        }
        list.append(.info)
        return list
    }
}

enum FileOps {
    static func isApp(_ url: URL) -> Bool { url.pathExtension.lowercased() == "app" }

    static func open(_ urls: [URL]) {
        for u in urls {
            if isApp(u) {
                NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    if let err = err {
                        DispatchQueue.main.async { ScreenshotToast.show("无法打开：\(err.localizedDescription)", duration: 2.4) }
                    }
                }
            } else if !NSWorkspace.shared.open(u) {
                ScreenshotToast.show("无法打开「\(u.lastPathComponent)」", duration: 2)
            }
        }
    }

    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err = err {
                DispatchQueue.main.async { ScreenshotToast.show("无法打开：\(err.localizedDescription)", duration: 2.4) }
            }
        }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// 能打开这个文件的应用（默认应用排第一）
    static func openWithApps(for url: URL) -> [URL] {
        let ws = NSWorkspace.shared
        var list = ws.urlsForApplications(toOpen: url)
        if let def = ws.urlForApplication(toOpen: url) {
            list.removeAll { $0.standardizedFileURL == def.standardizedFileURL }
            list.insert(def, at: 0)
        }
        var seen = Set<String>()
        return list.filter { seen.insert(Bundle(url: $0)?.bundleIdentifier ?? $0.path).inserted }
    }

    static func uniqueDestination(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var dst = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dst.path) else { return dst }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2...999 {
            let n = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            dst = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: dst.path) { break }
        }
        return dst
    }

    /// 移动 / 复制；目标已有同名文件时自动改名（xxx 2.txt）
    static func transfer(_ urls: [URL], to dir: URL, move: Bool) -> (done: [URL], errors: [String]) {
        let fm = FileManager.default
        var done: [URL] = [], errors: [String] = []
        for u in urls {
            if move && u.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { continue }
            if dir.path == u.path || dir.path.hasPrefix(u.path + "/") {
                errors.append("不能把「\(u.lastPathComponent)」放进它自己里面"); continue
            }
            let dst = uniqueDestination(u.lastPathComponent, in: dir)
            do {
                if move { try fm.moveItem(at: u, to: dst) } else { try fm.copyItem(at: u, to: dst) }
                done.append(dst)
            } catch {
                errors.append("\(u.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (done, errors)
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw NSError(domain: "ZoomDraw", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件名无效"])
        }
        let dst = url.deletingLastPathComponent().appendingPathComponent(name)
        if dst.path == url.path { return url }
        // 只改大小写时 fileExists 也会返回 true，这种情况允许
        if FileManager.default.fileExists(atPath: dst.path), dst.path.lowercased() != url.path.lowercased() {
            throw NSError(domain: "ZoomDraw", code: 2, userInfo: [NSLocalizedDescriptionKey: "已存在同名的文件"])
        }
        try FileManager.default.moveItem(at: url, to: dst)
        return dst
    }

    /// 移到废纸篓；completion 给出 原位置 → 废纸篓里的位置（用于撤销）
    static func trash(_ urls: [URL], completion: @escaping ([URL: URL], Error?) -> Void) {
        NSWorkspace.shared.recycle(urls) { map, err in
            DispatchQueue.main.async { completion(map, err) }
        }
    }

    /// 撤销移到废纸篓：放回原处，返回成功的数量
    static func restore(_ map: [URL: URL]) -> Int {
        var n = 0
        for (orig, trashed) in map {
            guard !FileManager.default.fileExists(atPath: orig.path) else { continue }
            if (try? FileManager.default.moveItem(at: trashed, to: orig)) != nil { n += 1 }
        }
        return n
    }

    static func openInTerminal(_ url: URL) {
        let dir = FileSearchSettings.isDirectory(url.path) ? url : url.deletingLastPathComponent()
        guard let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 访达的「显示简介」窗口（首次使用时系统会询问是否允许 ZoomDraw 控制访达）
    static func showInfo(_ urls: [URL]) {
        let items = urls.prefix(10).map { u -> String in
            let p = u.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "open information window of (POSIX file \"\(p)\" as alias)"
        }.joined(separator: "\n")
        let src = "tell application \"Finder\"\nactivate\n\(items)\nend tell"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err = err {
                let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                DispatchQueue.main.async {
                    if code == -1743 {
                        ScreenshotToast.show("请在「系统设置 → 隐私与安全性 → 自动化」中允许 ZoomDraw 控制访达", duration: 3)
                    } else {
                        reveal(urls)
                    }
                }
            }
        }
    }

    static func runningApps(for url: URL) -> [NSRunningApplication] {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let bid = Bundle(url: url)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            if let b = $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path, b == path { return true }
            return bid != nil && $0.bundleIdentifier == bid
        }
    }

    static func quit(_ url: URL, force: Bool) -> Bool {
        let apps = runningApps(for: url)
        guard !apps.isEmpty else { return false }
        for a in apps { _ = force ? a.forceTerminate() : a.terminate() }
        return true
    }
}
