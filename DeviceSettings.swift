import AppKit
import CryptoKit
import Security
import SwiftUI

struct DivoomSession: Codable {
    let userID: Int
    let token: String
    let email: String
    var nickname: String
    var fields: [String: Any] { ["UserId": userID, "Token": Int(token).map { $0 as Any } ?? token] }
}

struct FrameClock: Identifiable {
    let id: Int
    let name: String
    let type: Int
}

enum DivoomCloud {
    static func request(_ path: String, fields: [String: Any], method: String = "POST") async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://appin.divoom-gz.com/" + path)!)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Account responses must not enter the shared on-disk URL cache.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameError.message("Divoom 云端响应无效，请稍后重试。")
        }
        guard (result["ReturnCode"] as? NSNumber)?.intValue == 0 else {
            throw FrameError.message("Divoom 云端：\(result["ReturnMessage"] as? String ?? "请求失败，请重新登录。")")
        }
        return result
    }

    static func login(email: String, password: String) async throws -> DivoomSession {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw FrameError.message("请输入 Divoom 邮箱和密码。") }
        // The service requires MD5; the digest is sent only to Divoom over HTTPS.
        let digest = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        let result = try await request("UserLogin", fields: ["Email": email, "Password": digest])
        guard let id = (result["UserId"] as? NSNumber)?.intValue, id > 0,
              let token = (result["Token"] as? NSNumber)?.stringValue ?? result["Token"] as? String,
              !token.isEmpty else { throw FrameError.message("登录响应中缺少用户 ID 或会话凭据。") }
        return DivoomSession(userID: id, token: token, email: email, nickname: result["Nickname"] as? String ?? email)
    }

    static func clocks(deviceID: Int, session: DivoomSession?) async throws -> [FrameClock] {
        var clocks: [FrameClock] = []
        var seen = Set<Int>()
        for page in 0..<30 {
            var fields = session?.fields ?? [:]
            fields.merge(["DeviceId": deviceID, "DeviceType": "Frame", "StartNum": page * 100 + 1,
                          "EndNum": (page + 1) * 100], uniquingKeysWith: { _, new in new })
            // This route also accepts POST (verified against the service). URLSession
            // rejects GET requests with a JSON body even though the docs show GET.
            let result = try await request("Channel/MyClockGetList", fields: fields)
            guard let rows = result["ClockList"] as? [[String: Any]] else {
                throw FrameError.message("云端没有返回表盘／相册列表。")
            }
            let next = rows.compactMap { row -> FrameClock? in
                guard let id = (row["ClockId"] as? NSNumber)?.intValue,
                      let name = row["ClockName"] as? String else { return nil }
                return FrameClock(id: id, name: name, type: (row["ClockType"] as? NSNumber)?.intValue ?? 0)
            }
            let unique = next.filter { seen.insert($0.id).inserted }
            clocks += unique
            if rows.count < 100 { return clocks }
            guard !unique.isEmpty else { throw FrameError.message("云端重复返回同一页，无法核对完整列表。") }
        }
        throw FrameError.message("云端列表超过读取上限。")
    }
}

enum AccountKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.timesframe.album.divoom-session", kSecAttrAccount as String: "active"]
    static func load() -> DivoomSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DivoomSession.self, from: data)
    }
    static func save(_ session: DivoomSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw FrameError.message("无法更新钥匙串会话（\(update)）。") }
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let code = SecItemAdd(query as CFDictionary, nil)
        guard code == errSecSuccess else { throw FrameError.message("无法保存钥匙串会话（\(code)）。") }
    }
    static func clear() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw FrameError.message("无法清除钥匙串会话（\(code)）。") }
    }
}

@MainActor final class AccountModel: ObservableObject {
    static let shared = AccountModel()
    @Published private(set) var session: DivoomSession? = AccountKeychain.load()
    @Published var email = ""
    @Published var password = ""
    @Published var remember = true
    @Published var busy = false
    @Published var error = false
    @Published var message = "登录与手机 App 相同的 Divoom 邮箱账号。"
    @Published var profileDeviceID: Int?
    private var prefix: String { "frame.account.\(session.map { String($0.userID) } ?? "guest")." }
    var connection: (ip: String, port: String) {
        let defaults = UserDefaults.standard
        let legacy = session == nil ? defaults.string(forKey: "albumFrameIP") : nil
        return (defaults.string(forKey: prefix + "ip") ?? legacy ?? "", defaults.string(forKey: prefix + "port") ?? "9000")
    }
    func saveConnection(ip: String, port: String) {
        UserDefaults.standard.set(ip, forKey: prefix + "ip")
        UserDefaults.standard.set(port, forKey: prefix + "port")
    }
    func login() {
        guard !busy else { return }
        let email = email, password = password, remember = remember
        self.password = ""; busy = true; error = false; message = "正在登录 Divoom…"
        Task {
            defer { busy = false }
            do {
                let signedIn = try await DivoomCloud.login(email: email, password: password)
                if remember { try AccountKeychain.save(signedIn) } else { try AccountKeychain.clear() }
                profileDeviceID = nil
                session = signedIn
                message = "已登录；连接设置按账号保存。请关闭设置后连接设备。"
            } catch { self.error = true; message = error.localizedDescription }
        }
    }
    func logout() {
        guard !busy else { return }
        do {
            try AccountKeychain.clear()
            session = nil; password = ""; profileDeviceID = nil; error = false
            message = "已退出登录并清除本机保存的会话。"
        } catch { self.error = true; message = error.localizedDescription }
    }
    func refreshProfile() {
        guard !busy, let session else { return }
        busy = true; error = false
        Task {
            defer { busy = false }
            do {
                let value = try await DivoomCloud.request("User/GetUserInfo", fields: session.fields)
                profileDeviceID = (value["DeviceId"] as? NSNumber)?.intValue
                message = "账号会话有效。\(value["Nickname"] as? String ?? session.nickname)"
            } catch { self.error = true; message = "账号验证失败，请重新登录：\(error.localizedDescription)" }
        }
    }
}

@MainActor final class DeviceControlModel: ObservableObject {
    @Published var minutes = 25
    @Published var seconds = 0
    @Published var blue = 0
    @Published var red = 0
    @Published var mirror = false
    @Published var hour24 = true
    @Published var showReboot = false

    @Published var brightness = 50.0
    @Published var readBrightness = false
    @Published var clocks: [FrameClock] = []
    @Published var selectedClock: Int?
    @Published var busy = false
    @Published var isError = false
    @Published var message = "读取设备状态或选择需要应用的控制。"
    func perform(_ ip: String, port: Int, label: String,
                 operation: @escaping (AlbumAPI) async throws -> Void) {
        guard !busy else { return }
        busy = true; isError = false; message = "\(label)…"
        Task {
            defer { busy = false }
            do {
                try await operation(AlbumAPI(ip: ip, port: port))
                message = "\(label)完成。"
            } catch { isError = true; message = error.localizedDescription }
        }
    }
    func send(_ ip: String, port: Int, name: String, fields: [String: Any] = [:], label: String) {
        perform(ip, port: port, label: label) { api in _ = try await api.command(name, fields: fields) }
    }
    func refresh(_ ip: String, port: Int, deviceID: Int?) {
        perform(ip, port: port, label: "读取设备") { api in
            let value = try await api.command("Sys/GetBrightness")
            guard let number = (value["Brightness"] as? NSNumber)?.doubleValue, (0...100).contains(number) else {
                throw FrameError.message("设备未返回有效亮度。")
            }
            self.brightness = number; self.readBrightness = true
            if let deviceID {
                self.clocks = try await DivoomCloud.clocks(deviceID: deviceID, session: AccountModel.shared.session)
                if !self.clocks.contains(where: { $0.id == self.selectedClock }) { self.selectedClock = self.clocks.first?.id }
            }
        }
    }
    func setBrightness(_ ip: String, port: Int) {
        let requested = Int(brightness)
        perform(ip, port: port, label: "设置亮度") { api in
            _ = try await api.command("Channel/SetBrightness", fields: ["Brightness": requested])
            let value = try await api.command("Sys/GetBrightness")
            guard (value["Brightness"] as? NSNumber)?.intValue == requested else {
                throw FrameError.message("设备回读亮度与设置值不符，请重新读取。")
            }
            self.readBrightness = true
        }
    }
    func selectClock(_ ip: String, port: Int) {
        guard let selectedClock else { return }
        perform(ip, port: port, label: "切换表盘／相册") { api in
            // Official TimesFrame client sends twice to override the active routine.
            for _ in 0..<2 { _ = try await api.command("Channel/SetClockSelectId", fields: ["ClockId": selectedClock]) }
        }
    }
}

struct DeviceSettingsView: View {
    let ip: String
    let port: Int
    let deviceID: Int?
    let connected: Bool
    let syncMessage: String
    @ObservedObject private var account = AccountModel.shared
    @StateObject private var controls = DeviceControlModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账号与设备控制").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(account.busy || controls.busy)
            }
            TabView {
                accountTab.tabItem { Label("账号", systemImage: "person.crop.circle") }
                deviceTab.tabItem { Label("设备", systemImage: "display") }
                toolsTab.tabItem { Label("工具", systemImage: "timer") }
            }
        }
        .padding(20).frame(width: 760, height: 620)
        .interactiveDismissDisabled(account.busy || controls.busy)
        .alert("重启 Times Frame？", isPresented: $controls.showReboot) {
            Button("重启设备", role: .destructive) {
                controls.send(ip, port: port, name: "Device/SysReboot", label: "发送重启请求（设备将暂时离线）")
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var accountTab: some View {
        Form {
            if let session = account.session {
                Text(session.nickname).font(.headline)
                Text("\(session.email) · 用户 ID \(session.userID)").textSelection(.enabled)
                if let device = account.profileDeviceID { Text("账号资料中的设备 ID：\(device)") }
                HStack {
                    Button("验证账号／读取资料") { account.refreshProfile() }
                    Button("退出登录") { account.logout() }
                }.disabled(account.busy || controls.busy)
            } else {
                TextField("Divoom 邮箱", text: $account.email).textFieldStyle(.roundedBorder)
                SecureField("密码", text: $account.password).textFieldStyle(.roundedBorder)
                Toggle("在 macOS 钥匙串保存登录会话", isOn: $account.remember)
                Button("登录 Divoom") { account.login() }.buttonStyle(.borderedProminent)
                    .disabled(account.busy || controls.busy || account.email.isEmpty || account.password.isEmpty)
                Text("使用邮箱密码登录；第三方账号请先在官方 App 设置邮箱密码。应用不保存密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if account.busy { ProgressView() }
            Text(account.message).foregroundStyle(account.error ? Color.red : Color.secondary).textSelection(.enabled)
            Divider()
            Text("连接地址和端口按账号分别保存；未登录时使用访客设置。登录不会自动绑定或更换相框。")
            Text("相册同步").font(.headline)
            Text(syncMessage).foregroundStyle(.secondary)
            Text("本地新建相册不会自动注册到手机云端。需要手机可见的相册，请在手机 App 创建，再回到主窗口刷新并上传。登录不会自动迁移已有本地相册。")
            Text("当前已接入登录、账号资料和公开的局域网控制；云端建相册、RGB、日程／闹钟和社区编辑尚未接入。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    private var deviceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(connected ? "\(ip):\(port) · 设备 \(deviceID.map(String.init) ?? "未知")" : "请先在主窗口连接 Times Frame。")
                Spacer()
                Button("读取状态与表盘") { controls.refresh(ip, port: port, deviceID: deviceID) }
            }
            GroupBox("屏幕") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("开屏") { send("Channel/OnOffScreen", ["OnOff": 1], "开屏") }
                        Button("关屏") { send("Channel/OnOffScreen", ["OnOff": 0], "关屏") }
                        Spacer()
                        Text(controls.readBrightness ? "亮度已读取" : "亮度尚未读取").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("亮度 \(Int(controls.brightness))%")
                        Slider(value: $controls.brightness, in: 0...100, step: 1)
                        Button("应用亮度") { controls.setBrightness(ip, port: port) }
                    }
                }.padding(8)
            }
            GroupBox("表盘与相册播放") {
                HStack {
                    Picker("选择", selection: $controls.selectedClock) {
                        Text("请选择").tag(Optional<Int>.none)
                        ForEach(controls.clocks) { clock in Text("\(clock.name) · #\(clock.id)").tag(Optional(clock.id)) }
                    }
                    Button("在设备上播放") { controls.selectClock(ip, port: port) }.disabled(controls.selectedClock == nil)
                }.padding(8)
            }
            HStack {
                Toggle("镜像", isOn: $controls.mirror)
                Button("应用镜像") { send("Device/SetMirrorMode", ["Mode": controls.mirror ? 1 : 0], "设置镜像") }
                Spacer()
                Toggle("24 小时制", isOn: $controls.hour24)
                Button("应用时间格式") { send("Device/SetTime24Flag", ["Mode": controls.hour24 ? 1 : 0], "设置时间格式") }
            }
            Text("镜像和时间格式为待应用选项，未读取设备当前值；固件可能在重启后复原。表盘列表来自 Divoom 云端。")
                .font(.caption).foregroundStyle(.secondary)
            Button("重启设备…") { controls.showReboot = true }
            controlStatus
            Spacer()
        }.padding(20).disabled(!connected || controls.busy || account.busy)
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("倒计时") {
                HStack {
                    Stepper("\(controls.minutes) 分", value: $controls.minutes, in: 0...999)
                    Stepper("\(controls.seconds) 秒", value: $controls.seconds, in: 0...59)
                    Button("开始") { send("Tools/SetTimer", ["Minute": controls.minutes, "Second": controls.seconds, "Status": 1], "启动倒计时") }
                        .disabled(controls.minutes == 0 && controls.seconds == 0)
                    Button("停止") { send("Tools/SetTimer", ["Minute": 0, "Second": 0, "Status": 0], "停止倒计时") }
                }.padding(8)
            }
            GroupBox("秒表") {
                HStack {
                    ForEach(Array(["停止", "开始", "复位"].enumerated()), id: \.offset) { index, name in
                        Button(name) { send("Tools/SetStopWatch", ["Status": index], "秒表\(name)") }
                    }
                    Spacer()
                }.padding(8)
            }
            GroupBox("记分牌") {
                HStack {
                    Stepper("蓝方 \(controls.blue)", value: $controls.blue, in: 0...999)
                    Stepper("红方 \(controls.red)", value: $controls.red, in: 0...999)
                    Button("显示记分牌") { send("Tools/SetScoreBoard", ["BlueScore": controls.blue, "RedScore": controls.red], "设置记分牌") }
                }.padding(8)
            }
            HStack {
                Text("噪声工具")
                Button("开启") { send("Tools/SetNoiseStatus", ["NoiseStatus": 1], "开启噪声工具") }
                Button("关闭") { send("Tools/SetNoiseStatus", ["NoiseStatus": 0], "关闭噪声工具") }
            }
            Text("工具会切换设备显示内容；完成后可在“设备”中重新选择表盘或相册。")
                .font(.caption).foregroundStyle(.secondary)
            controlStatus
            Spacer()
        }.padding(20).disabled(!connected || controls.busy || account.busy)
    }
    private var controlStatus: some View {
        HStack {
            if controls.busy { ProgressView().controlSize(.small) }
            Text(controls.message).foregroundStyle(controls.isError ? Color.red : Color.secondary).textSelection(.enabled)
        }
    }
    private func send(_ command: String, _ fields: [String: Any], _ label: String) {
        controls.send(ip, port: port, name: command, fields: fields, label: label)
    }
}

// Observe only the primary content window. Sheets and file panels must not keep
// a windowless process running, nor trigger termination when they close.
struct MainWindowLifecycle: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowObserver { MainWindowObserver() }
    func updateNSView(_ view: MainWindowObserver, context: Context) { }
}
final class MainWindowObserver: NSView {
    private var observation: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        guard let window else { return }
        observation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { _ in
                NSApplication.shared.terminate(nil)
            }
    }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
}
