import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

struct ProxyConfig: Codable {
    var host: String
    var hookPort: Int
    var envScheme: String
    var envPort: Int

    static let defaultConfig = ProxyConfig(
        host: "127.0.0.1",
        hookPort: 7890,
        envScheme: "http",
        envPort: 7890
    )

    var hookProxyURL: String {
        "socks5://\(host):\(hookPort)"
    }

    var envProxyURL: String {
        "\(envScheme)://\(host):\(envPort)"
    }
}

enum BuilderError: LocalizedError {
    case missingSourceApp(String)
    case missingResource(String)
    case invalidPort(String)
    case commandFailed(String)
    case asarFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceApp(let path):
            return "找不到原版 Antigravity：\(path)"
        case .missingResource(let name):
            return "Builder App 缺少资源：\(name)"
        case .invalidPort(let message):
            return message
        case .commandFailed(let message):
            return message
        case .asarFormat(let message):
            return "app.asar patch 失败：\(message)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: ProxyConfig = .defaultConfig
    @Published var status: String = "准备就绪"
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published var showConfig = true
    @Published var launchOnAppear = true

    private let support = AppSupport()

    func load() {
        if let loaded = try? support.loadConfig() {
            config = loaded
            showConfig = false
        } else {
            config = .defaultConfig
            showConfig = true
        }
    }

    func startIfConfigured() {
        guard launchOnAppear else { return }
        launchOnAppear = false
        load()
        if !showConfig {
            Task {
                await start()
            }
        }
    }

    func saveAndStart() {
        Task {
            await start()
        }
    }

    func start() async {
        isWorking = true
        errorMessage = nil
        status = "检查代理端口..."

        do {
            try validate(config)
            guard canConnect(host: config.host, port: config.hookPort, timeoutSeconds: 2) else {
                showConfig = true
                throw BuilderError.invalidPort("无法连接 \(config.host):\(config.hookPort)，请确认 Clash 或代理软件已经启动，并检查端口配置。")
            }

            try support.saveConfig(config)
            showConfig = false

            let builder = RuntimeBuilder(config: config, support: support) { [weak self] message in
                DispatchQueue.main.async {
                    self?.status = message
                }
            }

            try builder.rebuildAndLaunch()
            status = "已启动 Antigravity-Proxy"
            isWorking = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "需要配置"
            showConfig = true
            isWorking = false
        }
    }

    private func validate(_ config: ProxyConfig) throws {
        guard !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuilderError.invalidPort("代理 host 不能为空。")
        }
        guard (1...65535).contains(config.hookPort) else {
            throw BuilderError.invalidPort("SOCKS5 端口必须在 1 到 65535 之间。")
        }
        guard (1...65535).contains(config.envPort) else {
            throw BuilderError.invalidPort("环境变量代理端口必须在 1 到 65535 之间。")
        }
        guard ["http", "socks5"].contains(config.envScheme) else {
            throw BuilderError.invalidPort("环境变量代理协议只能是 http 或 socks5。")
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Antigravity-Proxy")
                        .font(.title2.weight(.semibold))
                    Text("从本机原版 Antigravity 生成代理版并启动")
                        .foregroundStyle(.secondary)
                }
            }

            if model.showConfig {
                configForm
            } else {
                ProgressView()
                Text(model.status)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("重新配置") {
                    model.showConfig = true
                }
                .disabled(model.isWorking)

                Button(model.isWorking ? "处理中..." : "保存并启动") {
                    model.saveAndStart()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            model.startIfConfigured()
        }
    }

    private var configForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("代理配置")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Host")
                    TextField("127.0.0.1", text: $model.config.host)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("SOCKS5 端口")
                    TextField("7890", value: $model.config.hookPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("环境变量协议")
                    Picker("", selection: $model.config.envScheme) {
                        Text("http").tag("http")
                        Text("socks5").tag("socks5")
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("环境变量端口")
                    TextField("7890", value: $model.config.envPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Clash Verge 默认 mixed port 通常是 7890：SOCKS5 端口填 7890，环境变量协议选 http，端口填 7890。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@main
struct AntigravityProxyBuilderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct AppSupport {
    let sourceApp = URL(fileURLWithPath: "/Applications/Antigravity.app")

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antigravity Proxy", isDirectory: true)
    }

    var runtimeRoot: URL {
        root.appendingPathComponent("Runtime", isDirectory: true)
    }

    var runtimeApp: URL {
        runtimeRoot.appendingPathComponent("Antigravity-Proxy.app", isDirectory: true)
    }

    var configURL: URL {
        root.appendingPathComponent("config.json")
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func loadConfig() throws -> ProxyConfig {
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(ProxyConfig.self, from: data)
    }

    func saveConfig(_ config: ProxyConfig) throws {
        try ensureRoot()
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}

final class RuntimeBuilder {
    private let config: ProxyConfig
    private let support: AppSupport
    private let progress: (String) -> Void
    private let fileManager = FileManager.default

    init(config: ProxyConfig, support: AppSupport, progress: @escaping (String) -> Void) {
        self.config = config
        self.support = support
        self.progress = progress
    }

    func rebuildAndLaunch() throws {
        guard fileManager.fileExists(atPath: support.sourceApp.path) else {
            throw BuilderError.missingSourceApp(support.sourceApp.path)
        }

        let resources = try builderResources()
        let app = support.runtimeApp
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let appResources = contents.appendingPathComponent("Resources", isDirectory: true)
        let innerApp = appResources.appendingPathComponent("Antigravity.app", isDirectory: true)

        progress("清理旧 runtime...")
        try? fileManager.removeItem(at: app)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appResources, withIntermediateDirectories: true)

        progress("复制原版 Antigravity...")
        try run("/usr/bin/ditto", [support.sourceApp.path, innerApp.path])

        progress("写入代理组件...")
        try fileManager.copyItem(at: resources.launcher, to: macOS.appendingPathComponent("AntigravityProxyLauncher"))
        try fileManager.copyItem(at: resources.dylib, to: appResources.appendingPathComponent("libantigravity_proxy.dylib"))
        try writeProxyEnv(to: appResources.appendingPathComponent("proxy.env"))
        try run("/bin/chmod", ["+x", macOS.appendingPathComponent("AntigravityProxyLauncher").path])

        progress("生成图标...")
        let icon = try prepareIcon(resources: resources, appResources: appResources)

        progress("修改 bundle 信息...")
        try configureInnerApp(innerApp: innerApp, iconName: icon.name, iconURL: icon.icns)
        try writeOuterInfoPlist(contents: contents, iconName: icon.name)
        try "APPL????".write(to: contents.appendingPathComponent("PkgInfo"), atomically: true, encoding: .utf8)

        progress("Patch Electron 图标...")
        let asar = innerApp.appendingPathComponent("Contents/Resources/app.asar")
        if fileManager.fileExists(atPath: asar.path) {
            try AsarIconPatcher.patch(asarURL: asar, iconURL: resources.iconPNG)
        }

        progress("重签名 runtime...")
        let entitlements = try writeEntitlements()
        try sign(app: app, innerApp: innerApp, entitlements: entitlements)

        progress("启动代理版 Antigravity...")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private func builderResources() throws -> BuilderResources {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw BuilderError.missingResource("Resources")
        }
        let base = URL(fileURLWithPath: resourcePath, isDirectory: true)
        let resources = BuilderResources(
            dylib: base.appendingPathComponent("libantigravity_proxy.dylib"),
            launcher: base.appendingPathComponent("AntigravityProxyLauncher"),
            iconPNG: base.appendingPathComponent("icon.png")
        )
        for url in [resources.dylib, resources.launcher, resources.iconPNG] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw BuilderError.missingResource(url.lastPathComponent)
            }
        }
        return resources
    }

    private func writeProxyEnv(to url: URL) throws {
        let contents = """
        AG_PROXY=\(config.hookProxyURL)
        AG_PROXY_LOG=1
        AG_PROXY_TIMEOUT_MS=15000
        HTTP_PROXY=\(config.envProxyURL)
        HTTPS_PROXY=\(config.envProxyURL)
        ALL_PROXY=\(config.envProxyURL)
        http_proxy=\(config.envProxyURL)
        https_proxy=\(config.envProxyURL)
        all_proxy=\(config.envProxyURL)
        NO_PROXY=localhost,127.0.0.1,::1,*.local
        no_proxy=localhost,127.0.0.1,::1,*.local

        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func prepareIcon(resources: BuilderResources, appResources: URL) throws -> RuntimeIcon {
        let iconName = "antigravity-proxy.icns"
        let iconURL = appResources.appendingPathComponent(iconName)
        try generateICNS(from: resources.iconPNG, to: iconURL)
        return RuntimeIcon(name: iconName, icns: iconURL)
    }

    private func generateICNS(from png: URL, to icns: URL) throws {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("antigravity-proxy-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = temp.appendingPathComponent("icon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")
        ]

        for (size, name) in sizes {
            try run("/usr/bin/sips", [
                "-z", "\(size)", "\(size)",
                png.path,
                "--out",
                iconset.appendingPathComponent(name).path
            ])
        }
        try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    }

    private func configureInnerApp(innerApp: URL, iconName: String, iconURL: URL) throws {
        let info = innerApp.appendingPathComponent("Contents/Info.plist")
        try plistSet(info, "CFBundleIdentifier", "com.google.antigravity.proxy.inner")
        try plistSetOrAdd(info, "CFBundleIconFile", iconName)

        let innerResources = innerApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.copyItem(at: iconURL, to: innerResources.appendingPathComponent(iconName))

        try setHelper(innerApp, "Antigravity Helper.app", "com.google.antigravity.proxy.inner.helper", iconName, iconURL)
        try setHelper(innerApp, "Antigravity Helper (GPU).app", "com.google.antigravity.proxy.inner.helper.GPU", iconName, iconURL)
        try setHelper(innerApp, "Antigravity Helper (Plugin).app", "com.google.antigravity.proxy.inner.helper.Plugin", iconName, iconURL)
        try setHelper(innerApp, "Antigravity Helper (Renderer).app", "com.google.antigravity.proxy.inner.helper.Renderer", iconName, iconURL)
    }

    private func setHelper(_ innerApp: URL, _ helperName: String, _ helperID: String, _ iconName: String, _ iconURL: URL) throws {
        let helper = innerApp.appendingPathComponent("Contents/Frameworks/\(helperName)", isDirectory: true)
        let plist = helper.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: plist.path) else { return }

        let resources = helper.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: resources.appendingPathComponent(iconName))
        try fileManager.copyItem(at: iconURL, to: resources.appendingPathComponent(iconName))
        try plistSet(plist, "CFBundleIdentifier", helperID)
        try plistSetOrAdd(plist, "CFBundleIconFile", iconName)
    }

    private func writeOuterInfoPlist(contents: URL, iconName: String) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDevelopmentRegion</key>
          <string>en</string>
          <key>CFBundleDisplayName</key>
          <string>Antigravity-Proxy</string>
          <key>CFBundleExecutable</key>
          <string>AntigravityProxyLauncher</string>
          <key>CFBundleIdentifier</key>
          <string>com.google.antigravity.proxy.runtime</string>
          <key>CFBundleInfoDictionaryVersion</key>
          <string>6.0</string>
          <key>CFBundleName</key>
          <string>Antigravity-Proxy</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>1.0</string>
          <key>CFBundleVersion</key>
          <string>1</string>
          <key>CFBundleIconFile</key>
          <string>\(iconName)</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    private func writeEntitlements() throws -> URL {
        try support.ensureRoot()
        let url = support.root.appendingPathComponent("antigravity-proxy.entitlements.plist")
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>com.apple.security.automation.apple-events</key>
          <true/>
          <key>com.apple.security.cs.allow-dyld-environment-variables</key>
          <true/>
          <key>com.apple.security.cs.allow-jit</key>
          <true/>
          <key>com.apple.security.cs.disable-library-validation</key>
          <true/>
          <key>com.apple.security.device.audio-input</key>
          <true/>
          <key>com.apple.security.device.camera</key>
          <true/>
        </dict>
        </plist>
        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sign(app: URL, innerApp: URL, entitlements: URL) throws {
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], allowFailure: true)

        let script = """
        set -euo pipefail
        app="$1"
        inner="$2"
        entitlements="$3"
        while IFS= read -r -d '' item; do
          if /usr/bin/file "$item" | /usr/bin/grep -q 'Mach-O'; then
            /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$item" >/dev/null 2>&1 || true
          fi
        done < <(/usr/bin/find "$app/Contents" -type f -perm -111 -print0)
        /usr/bin/codesign --force --deep --sign - --options runtime --entitlements "$entitlements" "$inner"
        /usr/bin/codesign --force --deep --sign - --options runtime --entitlements "$entitlements" "$app"
        /usr/bin/codesign --verify --deep --strict "$app"
        """

        try run("/bin/bash", ["-c", script, "sign-runtime", app.path, innerApp.path, entitlements.path])
    }

    private func plistSet(_ plist: URL, _ key: String, _ value: String) throws {
        try run("/usr/libexec/PlistBuddy", ["-c", "Set :\(key) \(value)", plist.path])
    }

    private func plistSetOrAdd(_ plist: URL, _ key: String, _ value: String) throws {
        do {
            try plistSet(plist, key, value)
        } catch {
            try run("/usr/libexec/PlistBuddy", ["-c", "Add :\(key) string \(value)", plist.path])
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            if allowFailure { return error.localizedDescription }
            throw BuilderError.commandFailed("\(executable) \(arguments.joined(separator: " "))\n\(error.localizedDescription)")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && !allowFailure {
            throw BuilderError.commandFailed("\(executable) \(arguments.joined(separator: " "))\n\(output)")
        }

        return output
    }
}

struct BuilderResources {
    let dylib: URL
    let launcher: URL
    let iconPNG: URL
}

struct RuntimeIcon {
    let name: String
    let icns: URL
}

enum AsarIconPatcher {
    static func patch(asarURL: URL, iconURL: URL) throws {
        let original = try Data(contentsOf: asarURL)
        guard original.count >= 16 else {
            throw BuilderError.asarFormat("文件过小")
        }

        let jsonSize = Int(readUInt32(original, offset: 12))
        let headerStart = 16
        let headerEnd = headerStart + jsonSize
        guard headerEnd <= original.count else {
            throw BuilderError.asarFormat("header size 越界")
        }

        let headerData = original.subdata(in: headerStart..<headerEnd)
        guard var header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              var files = header["files"] as? [String: Any] else {
            throw BuilderError.asarFormat("无法解析 header")
        }

        let iconData = try Data(contentsOf: iconURL)
        var blobs: [Data] = []
        var offset = 0
        var foundIcon = false

        try processFiles(
            files: &files,
            prefix: "",
            original: original,
            dataStart: headerEnd,
            iconData: iconData,
            blobs: &blobs,
            offset: &offset,
            foundIcon: &foundIcon
        )

        guard foundIcon else {
            throw BuilderError.asarFormat("icon.png not found")
        }

        header["files"] = files
        var newHeader = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
        let padding = (4 - (newHeader.count % 4)) % 4
        if padding > 0 {
            newHeader.append(Data(repeating: 0x20, count: padding))
        }

        var output = Data()
        output.append(writeUInt32(4))
        output.append(writeUInt32(UInt32(newHeader.count + 8)))
        output.append(writeUInt32(UInt32(newHeader.count + 4)))
        output.append(writeUInt32(UInt32(newHeader.count)))
        output.append(newHeader)
        for blob in blobs {
            output.append(blob)
        }
        try output.write(to: asarURL, options: .atomic)
    }

    private static func processFiles(
        files: inout [String: Any],
        prefix: String,
        original: Data,
        dataStart: Int,
        iconData: Data,
        blobs: inout [Data],
        offset: inout Int,
        foundIcon: inout Bool
    ) throws {
        for name in Array(files.keys).sorted() {
            guard var entry = files[name] as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"

            if var nested = entry["files"] as? [String: Any] {
                try processFiles(
                    files: &nested,
                    prefix: path,
                    original: original,
                    dataStart: dataStart,
                    iconData: iconData,
                    blobs: &blobs,
                    offset: &offset,
                    foundIcon: &foundIcon
                )
                entry["files"] = nested
                files[name] = entry
                continue
            }

            if (entry["unpacked"] as? Bool) == true {
                files[name] = entry
                continue
            }

            let blob: Data
            if path == "icon.png" {
                blob = iconData
                foundIcon = true
                entry["size"] = blob.count
                let blockSize = ((entry["integrity"] as? [String: Any])?["blockSize"] as? Int) ?? 4 * 1024 * 1024
                entry["integrity"] = integrity(for: blob, blockSize: blockSize)
            } else {
                guard let size = intValue(entry["size"]),
                      let oldOffset = intValue(entry["offset"]) else {
                    throw BuilderError.asarFormat("缺少 size 或 offset：\(path)")
                }
                let start = dataStart + oldOffset
                let end = start + size
                guard start >= 0, end <= original.count else {
                    throw BuilderError.asarFormat("文件数据越界：\(path)")
                }
                blob = original.subdata(in: start..<end)
            }

            entry["offset"] = String(offset)
            blobs.append(blob)
            offset += blob.count
            files[name] = entry
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func integrity(for data: Data, blockSize: Int) -> [String: Any] {
        var blocks: [String] = []
        var index = 0
        while index < data.count {
            let end = min(index + blockSize, data.count)
            blocks.append(sha256Hex(data.subdata(in: index..<end)))
            index = end
        }
        if blocks.isEmpty {
            blocks = [sha256Hex(Data())]
        }
        return [
            "algorithm": "SHA256",
            "hash": sha256Hex(data),
            "blockSize": blockSize,
            "blocks": blocks
        ]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return bytes.enumerated().reduce(UInt32(0)) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    private static func writeUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}

func canConnect(host: String, port: Int, timeoutSeconds: Int) -> Bool {
    var hints = addrinfo(
        ai_flags: AI_NUMERICHOST,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )

    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "\(port)", &hints, &result) == 0, let first = result else {
        return false
    }
    defer { freeaddrinfo(result) }

    var current: UnsafeMutablePointer<addrinfo>? = first
    while let info = current {
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd >= 0 {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let ok = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
            close(fd)
            if ok { return true }
        }
        current = info.pointee.ai_next
    }
    return false
}
