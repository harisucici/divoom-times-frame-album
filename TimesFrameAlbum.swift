import AppKit
import Photos
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Album: Identifiable, Hashable {
    let id: Int
    let name: String
    let type: Int
    var canEdit: Bool { type == 0 }
}

struct Photo: Identifiable, Hashable {
    let id: Int
    let thumbnailPath: String
    let originalPath: String
    let mediaType: String
    let time: Double
}

struct FoundDevice: Identifiable {
    var id: String { ip }
    let name: String
    let ip: String
}

enum FrameError: LocalizedError {
    case message(String)
    case device(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .device(let code, let message): return "设备错误 \(code)：\(message)"
        }
    }
}

enum FrameNetwork {
    static func configuration(waitForConnectivity: Bool = false, resourceTimeout: TimeInterval = 120) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // LAN device requests go directly to the device. Cloud requests retain
        // the system proxy settings in their own independent sessions.
        config.connectionProxyDictionary = [:]
        // macOS may initially deny a request while displaying its permission alert.
        config.waitsForConnectivity = waitForConnectivity
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = resourceTimeout
        return config
    }
    static let localSession = URLSession(configuration: configuration())
    static let connectionSession = URLSession(configuration: configuration(waitForConnectivity: true, resourceTimeout: 25))

    static func message(for error: Error, target: String) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "无法访问相框 \(target)（网络错误 \(error.code)）。请在系统设置 → 隐私与安全性 → 本地网络中允许 TimesFrame，然后重试；若已允许，请检查同一局域网及 VPN／网络过滤。"
            case NSURLErrorTimedOut:
                return "连接相框 \(target) 超时（-1001）。首次连接请允许本地网络访问；若已允许，请检查相框 IP、端口和 Wi-Fi。"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "无法连接相框 \(target)（\(error.code)）。请检查 IP／端口，并确认 Mac 与相框在同一局域网。"
            default: break
            }
        }
        return "无法连接相框 \(target)：\(error.localizedDescription)（\(error.domain) \(error.code)）"
    }
}

struct AlbumAPI {
    static let maxPhotosPerAlbum = 100
    let ip: String
    let port: Int
    let userID: Int
    let session: URLSession

    init(ip: String, port: Int = 9000, userID: Int = 0, session: URLSession = FrameNetwork.localSession) throws {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard let number = Int(part), (0...255).contains(number) else { return false }
                  return String(number) == part
              }), (1...65535).contains(port) else {
            throw FrameError.message("请输入有效的相框局域网 IPv4 地址和端口。")
        }
        self.ip = ip
        self.port = port
        self.userID = userID
        self.session = session
    }

    private var root: URL { URL(string: "http://\(ip):\(port)")! }

    func post(_ path: String, body: Data, contentType: String, timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = URLRequest(url: root.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FrameError.message(FrameNetwork.message(for: error, target: "\(ip):\(port)")) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FrameError.message("相框返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameError.message("相框返回了无法解析的数据。")
        }
        let code = (object["ReturnCode"] as? NSNumber)?.intValue ?? -1
        guard code == 0 else {
            throw FrameError.device(code, object["ReturnMessage"] as? String ?? "未知原因")
        }
        return object
    }

    func command(_ name: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        var value = fields
        value["Command"] = name
        value["ReturnCode"] = 0
        let body = try JSONSerialization.data(withJSONObject: value)
        return try await post("divoom_api", body: body, contentType: "application/json; charset=utf-8")
    }

    func connectionState() async throws -> (hardware: [String: Any], albums: [Album]) {
        let hardware = try await command("Device/GetHardwareVersion")
        let code = (hardware["Hardware"] as? NSNumber)?.intValue ?? -1
        guard [510, 511, 512].contains(code) else {
            throw FrameError.message("检测到设备型号 \(code)，不是已支持的 Times Frame。")
        }
        return (hardware, try await albums())
    }

    func check() async throws -> String {
        let state = try await connectionState()
        let firmware = (state.hardware["Software"] as? NSNumber)?.intValue ?? 0
        return "已连接 Times Frame · 固件 \(firmware)"
    }

    func albums() async throws -> [Album] {
        let value = try await command("Photo/GetLocalAlbumList")
        guard let records = value["AlbumList"] as? [[String: Any]] else {
            throw FrameError.message("相框没有返回相册列表。")
        }
        return records.compactMap { row in
            guard let id = (row["ClockId"] as? NSNumber)?.intValue,
                  let name = row["ClockName"] as? String,
                  let type = (row["AlbumType"] as? NSNumber)?.intValue else { return nil }
            return Album(id: id, name: name, type: type)
        }
    }

    func createAlbum(named rawName: String) async throws -> Album {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 63 else {
            throw FrameError.message("相册名称须为 1–63 个 UTF-8 字节。")
        }
        let existing = try await albums()
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FrameError.message("已存在同名相册。")
        }
        let used = Set(existing.map(\.id))
        var id: Int
        repeat { id = Int.random(in: 800000...899999) } while used.contains(id)
        _ = try await command("Photo/NewAlbum", fields: ["ClockId": id, "ClockName": name])
        for _ in 0..<8 {
            if let created = try await albums().first(where: { $0.id == id && $0.name == name && $0.canEdit }) {
                return created
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("相框已接收新建请求，但未看到相册。请刷新列表，避免重复创建。")
    }

    func renameAlbum(_ album: Album, to rawName: String) async throws {
        guard album.canEdit else { throw FrameError.message("只能重命名普通相册。") }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 63 else {
            throw FrameError.message("相册名称须为 1–63 个 UTF-8 字节。")
        }
        _ = try await command("Photo/RenameAlbum", fields: ["ClockId": album.id, "ClockName": name])
        for _ in 0..<8 {
            if try await albums().contains(where: { $0.id == album.id && $0.name == name }) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("相框已接收重命名请求，但未看到新名称。请刷新列表确认。")
    }

    func deleteAlbum(_ album: Album) async throws {
        guard album.canEdit else { throw FrameError.message("不能删除系统相册。") }
        guard try await albums().contains(where: { $0.id == album.id && $0.canEdit }) else {
            throw FrameError.message("相册不存在或不可编辑。")
        }
        _ = try await command("Photo/DeleteAlbum", fields: ["ClockId": album.id])
        for _ in 0..<8 {
            if try await !albums().contains(where: { $0.id == album.id }) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("相框已接收删除请求，但相册仍在列表中。请刷新确认，避免重复操作。")
    }

    func photos(albumID: Int, start: Int) async throws -> [Photo] {
        let value = try await command("Photo/GetPhotoList", fields: [
            "ClockId": albumID, "StartNum": start, "EndNum": start + 99
        ])
        guard let records = value["PhotoList"] as? [[String: Any]] else {
            throw FrameError.message("相框没有返回照片列表。")
        }
        return records.compactMap { row in
            guard let id = (row["PhotoId"] as? NSNumber)?.intValue else { return nil }
            return Photo(
                id: id,
                thumbnailPath: row["FileId"] as? String ?? "",
                originalPath: row["OriginalFileId"] as? String ?? "",
                mediaType: row["MediaType"] as? String ?? "photo",
                time: (row["Time"] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }

    private func allPhotoIDs(albumID: Int) async throws -> Set<Int> {
        var result = Set<Int>()
        for page in 0..<100 {
            let items = try await photos(albumID: albumID, start: page * 100 + 1)
            result.formUnion(items.map(\.id))
            if items.count < 100 { return result }
        }
        throw FrameError.message("相册照片过多，无法完成删除结果校验。")
    }

    private func batches(_ ids: [Int], size: Int = 10) -> [[Int]] {
        stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    func mediaURL(_ path: String) -> URL? {
        guard path.hasPrefix("/userdata/"), !path.contains(".."), !path.contains("?") else { return nil }
        return URL(string: "http://\(ip):\(port)\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)")
    }

    func download(_ photo: Photo) async throws -> Data {
        guard let url = mediaURL(photo.originalPath) else { throw FrameError.message("相框返回的原图路径无效。") }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FrameError.message("原图下载失败。") }
        return data
    }

    func remove(_ ids: [Int], from album: Album) async throws {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能修改普通相册。") }
        for batch in batches(Array(Set(ids)).sorted()) {
            _ = try await command("Photo/RemovePhotoFromAlbum", fields: [
                "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": batch
            ])
        }
        for _ in 0..<10 {
            let remaining = Set(ids).intersection(try await allPhotoIDs(albumID: album.id))
            if remaining.isEmpty { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("部分图片仍在相册中，请刷新列表核对后重试。")
    }

    func delete(_ ids: [Int], from album: Album) async throws {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能从普通相册删除照片。") }
        let uniqueIDs = Array(Set(ids)).sorted()
        for batch in batches(uniqueIDs) {
            _ = try await command("Photo/DeletePhoto", fields: [
                "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": batch
            ])
        }
        let allAlbum = try await albums().first(where: { $0.type == 1 })
        for _ in 0..<10 {
            let selected = Set(uniqueIDs)
            let inAlbum = selected.intersection(try await allPhotoIDs(albumID: album.id))
            var inAll = Set<Int>()
            if let allAlbum {
                inAll = selected.intersection(try await allPhotoIDs(albumID: allAlbum.id))
            }
            if inAlbum.isEmpty && inAll.isEmpty { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("部分设备原图仍未删除，请刷新列表核对后重试。")
    }

    func addExisting(_ ids: [Int], to album: Album) async throws -> Int {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能添加到普通相册。") }
        let existing = try await photos(albumID: album.id, start: 1)
        let existingIDs = Set(existing.map(\.id))
        let newIDs = Array(Set(ids)).filter { !existingIDs.contains($0) }.sorted()
        guard existing.count + newIDs.count <= Self.maxPhotosPerAlbum else {
            throw FrameError.message("每个相册最多 100 张图片；当前已有至少 \(existing.count) 张，无法再加入 \(newIDs.count) 张。")
        }
        guard !newIDs.isEmpty else { return 0 }
        for batch in batches(newIDs) {
            _ = try await command("Photo/DevicePhotoToAlbum", fields: [
                "ToClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": batch
            ])
        }
        let expected = Set(newIDs)
        for _ in 0..<10 {
            let current = Set(try await photos(albumID: album.id, start: 1).map(\.id))
            if expected.isSubset(of: current) { return newIDs.count }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrameError.message("相框已接收添加请求，但未在相册中看到全部图片。请刷新相册确认。")
    }

    func upload(_ url: URL, to album: Album) async throws {
        try await upload([url], to: album)
    }

    func upload(_ urls: [URL], to album: Album,
                progress: ((Int, Int, String) async -> Void)? = nil) async throws {
        guard album.canEdit, !urls.isEmpty else { throw FrameError.message("请先选择普通相册和图片。") }
        let before = try await photos(albumID: album.id, start: 1)
        guard before.count + urls.count <= Self.maxPhotosPerAlbum else {
            throw FrameError.message("每个相册最多 100 张图片；当前已有至少 \(before.count) 张，本次选了 \(urls.count) 张。")
        }
        // Prepare every image before sending the first batch item. A decoding failure must
        // not leave the frame waiting for the rest of an incomplete batch.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimesFrame-Prepared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var prepared: [(URL, Int, Int)] = []
        for (index, url) in urls.enumerated() {
            if let progress { await progress(index + 1, urls.count, "准备图片：\(url.lastPathComponent)") }
            let image = try PhotoEncoder.encode(url)
            let file = directory.appendingPathComponent("\(index).jpg")
            try image.data.write(to: file)
            prepared.append((file, image.width, image.height))
        }
        let oldIDs = Set(before.map(\.id))
        let baseTime = Int(Date().timeIntervalSince1970 * 1000)
        let batchFlag = Int.random(in: 1...Int(Int32.max))
        for (index, url) in urls.enumerated() {
            if let progress { await progress(index + 1, urls.count, url.lastPathComponent) }
            let staged = prepared[index]
            let image = (data: try Data(contentsOf: staged.0), width: staged.1, height: staged.2)
            let filename = "mac-\(UUID().uuidString.prefix(16)).jpg"
            let title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
            let metadata: [String: Any] = [
                "Command": "Photo/LocalAddToAlbum", "ReturnCode": 0,
                "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0,
                "UserId": userID, "PhotoX": 0, "PhotoY": 0,
                "PhotoWidth": image.width, "PhotoHeight": image.height,
                "PhotoIndex": index, "PhotoTotalCnt": urls.count, "PhotoFlag": batchFlag,
                "SendTime": baseTime + index, "TakingTime": baseTime + index,
                "FileName": filename, "PreviewFileName": "", "PhotoTitle": title
            ]
            let (body, type) = try multipart(metadata: metadata, filename: filename, image: image.data)
            guard body.count <= 100 * 1024 * 1024 else {
                throw FrameError.message("图片超过当前固件的 100 MB 上传限制。")
            }
            _ = try await post("upload", body: body, contentType: type, timeout: 90)
        }
        // A batch is committed asynchronously after its final item reaches the device.
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let current = try await photos(albumID: album.id, start: 1)
            if current.filter({ !oldIDs.contains($0.id) }).count >= urls.count { return }
        }
        throw FrameError.message("相框已接收图片，但 30 秒内未在相册中看到全部新增记录。请刷新相册确认，避免重复上传。")
    }

    private func multipart(metadata: [String: Any], filename: String, image: Data) throws -> (Data, String) {
        let boundary = "TimesFrameAlbum-\(UUID().uuidString)"
        let json = try JSONSerialization.data(withJSONObject: metadata)
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"json\"\r\n")
        append("Content-Type: application/json; charset=utf-8\r\n")
        append("Content-Length: \(json.count)\r\n\r\n")
        data.append(json)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: image/jpeg\r\n")
        append("Content-Length: \(image.count)\r\n\r\n")
        data.append(image)
        append("\r\n--\(boundary)--\r\n")
        return (data, "multipart/form-data; boundary=\(boundary)")
    }

    static func discover() async throws -> [FoundDevice] {
        let url = URL(string: "https://app.divoom-gz.com/Device/ReturnSameLANDevice")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["DeviceList"] as? [[String: Any]] else {
            throw FrameError.message("自动发现未返回设备列表。")
        }
        return rows.compactMap { row in
            let hardware = (row["Hardware"] as? NSNumber)?.intValue ?? -1
            guard [510, 511, 512].contains(hardware),
                  let ip = row["DevicePrivateIP"] as? String else { return nil }
            return FoundDevice(name: row["DeviceName"] as? String ?? "Times Frame", ip: ip)
        }
    }
}

enum PhotoEncoder {
    static func encode(_ url: URL) throws -> (data: Data, width: Int, height: Int) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw FrameError.message("无法解码图片：\(url.lastPathComponent)。请确认原文件已下载，或导出为 JPEG 后重试。")
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FrameError.message("无法转换图片：\(url.lastPathComponent)")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: flattened).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw FrameError.message("无法编码 JPEG：\(url.lastPathComponent)")
        }
        return (data, width, height)
    }
}

@MainActor final class AlbumModel: ObservableObject {
    @Published var ip = UserDefaults.standard.string(forKey: "albumFrameIP") ?? ""
    @Published var port = "9000"
    @Published var showSettings = false
    @Published var showWorkbench = false
    @Published var deviceID: Int?
    @Published var cloudClockIDs: Set<Int>?
    @Published var syncMessage = "尚未核对手机端相册"
    let account = AccountModel.shared
    @Published private(set) var connectedIP = ""
    @Published private(set) var connectedPort = 9000
    private var connection: AlbumAPI?
    @Published var found: [FoundDevice] = []
    @Published var albums: [Album] = []
    @Published var selectedAlbumID: Int?
    @Published var photos: [Photo] = []
    @Published var selectedPhotoIDs = Set<Int>()
    @Published var busy = false
    @Published var status = "连接 Times Frame 后选择相册。"
    @Published var isError = false
    @Published var showLibrary = false
    @Published var showImporter = false
    @Published var showDelete = false
    @Published var showAddSheet = false
    @Published var showNewAlbum = false
    @Published var showRenameAlbum = false
    @Published var showDeleteAlbum = false
    @Published var albumNameInput = ""
    @Published var allPhotosForAdd: [Photo] = []
    @Published var canLoadMoreForAdd = false
    @Published var addSelected = Set<Int>()
    @Published var canLoadMore = false

    var selectedAlbum: Album? { albums.first(where: { $0.id == selectedAlbumID }) }
    private func api() throws -> AlbumAPI {
        guard let connection else { throw FrameError.message("请先连接设备。") }
        return connection
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        isError = false
        Task {
            defer { busy = false }
            do { try await work() }
            catch { isError = true; status = error.localizedDescription }
        }
    }

    func discover() {
        run {
            self.status = "正在查找同网段设备…"
            self.found = try await AlbumAPI.discover()
            self.status = self.found.isEmpty ? "没有发现 Times Frame，请手动输入 IP。" : "发现 \(self.found.count) 台设备，请选择并连接。"
        }
    }

    func connect() {
        guard !busy else { return }
        let address = ip.trimmingCharacters(in: .whitespacesAndNewlines), port = Int(port) ?? 0
        run {
            let userID = self.account.session?.userID ?? 0
            let api = try AlbumAPI(ip: address, port: port, userID: userID, session: FrameNetwork.connectionSession)
            self.status = "正在连接 \(address):\(port)… 首次使用请在系统提示中允许本地网络访问。"
            let state = try await api.connectionState()
            let hardware = state.hardware, albums = state.albums
            // Commit only after the new local endpoint is known to be usable.
            // The permission-wait session is bounded at 25s; media keeps its normal transfer budget.
            self.connection = try AlbumAPI(ip: address, port: port, userID: userID)
            self.connectedIP = address; self.connectedPort = port
            self.albums = albums
            self.deviceID = (hardware["DeviceId"] as? NSNumber)?.intValue
            self.account.saveConnection(ip: address, port: String(port))
            self.cloudClockIDs = nil
            self.syncMessage = "手机端列表尚未核对，可在连接后点击核对。"
            self.selectedAlbumID = albums.first(where: { $0.canEdit })?.id ?? albums.first?.id
            self.selectedPhotoIDs.removeAll()
            self.photos = []
            self.canLoadMore = false
            let firmware = (hardware["Software"] as? NSNumber)?.intValue ?? 0
            let connected = "已连接 Times Frame · 固件 \(firmware) · \(address):\(port) · \(albums.count) 个相册"
            do {
                if let album = self.selectedAlbum { self.photos = try await api.photos(albumID: album.id, start: 1) }
                self.canLoadMore = self.photos.count == 100
                self.status = connected
            } catch {
                self.isError = true
                self.status = connected + "；照片列表读取失败，可刷新重试：" + error.localizedDescription
            }
        }
    }

    func checkCloudAlbums() {
        guard deviceID != nil else { return }
        run {
            self.status = "正在核对手机端列表；本地连接不依赖此查询。"
            await self.updateCloudStatus()
            self.status = self.syncMessage
        }
    }

    func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    func select(_ album: Album) {
        guard !busy else { return }
        selectedAlbumID = album.id
        photos = []
        selectedPhotoIDs.removeAll()
        run {
            self.photos = try await self.api().photos(albumID: album.id, start: 1)
            self.canLoadMore = self.photos.count == 100
            self.status = "\(album.name)：已显示 \(self.photos.count) 张"
        }
    }

    func refresh() {
        run {
            let api = try self.api()
            self.albums = try await api.albums()
            if !self.albums.contains(where: { $0.id == self.selectedAlbumID }) {
                self.selectedAlbumID = self.albums.first?.id
            }
            if let album = self.selectedAlbum {
                self.photos = try await api.photos(albumID: album.id, start: 1)
            } else { self.photos = [] }
            self.selectedPhotoIDs.formIntersection(self.photos.map(\.id))
            self.canLoadMore = self.photos.count == 100
            self.status = "已刷新设备本地相册。"
        }
    }

    private func updateCloudStatus() async {
        cloudClockIDs = nil
        guard let deviceID else { return }
        do {
            let clocks = try await DivoomCloud.clocks(deviceID: deviceID, session: account.session)
            cloudClockIDs = Set(clocks.map(\.id))
            let localOnly = albums.filter { $0.canEdit && !(cloudClockIDs?.contains($0.id) ?? false) }.count
            syncMessage = localOnly == 0 ? "已核对手机端列表" : "\(localOnly) 个相册仅在设备本地；手机端相册请在手机 App 创建后刷新。"
        } catch { syncMessage = "无法核对手机端列表：\(error.localizedDescription)" }
    }

    func connectionForAccount() {
        guard !busy else { return }
        let connection = account.connection
        ip = connection.ip; port = connection.port
        self.connection = nil; connectedIP = ""; connectedPort = 9000
        deviceID = nil; albums = []; photos = []; selectedAlbumID = nil
        selectedPhotoIDs = []; cloudClockIDs = nil
        status = "账号已切换，请连接设备。"
    }

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "读取文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        do {
            guard let iterator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw FrameError.message("无法读取文件夹。")
            }
            var urls: [URL] = []
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                if values.isRegularFile == true, values.contentType?.conforms(to: .image) == true { urls.append(url) }
            }
            guard !urls.isEmpty else { throw FrameError.message("文件夹中没有可上传的图片。") }
            importFiles(urls.sorted { $0.path < $1.path }, scopedDirectory: directory)
        } catch { isError = true; status = error.localizedDescription }
    }

    func createAlbum() {
        let name = albumNameInput
        run {
            let api = try self.api()
            let created = try await api.createAlbum(named: name)
            self.albums = try await api.albums()
            self.selectedAlbumID = created.id
            self.photos = []
            self.canLoadMore = false
            self.selectedPhotoIDs.removeAll()
            await self.updateCloudStatus()
            self.status = "已新建设备本地相册“\(created.name)”。手机端相册需在手机 App 创建后刷新。"
        }
    }

    func renameSelectedAlbum() {
        guard let album = selectedAlbum else { return }
        let name = albumNameInput
        run {
            let api = try self.api()
            try await api.renameAlbum(album, to: name)
            self.albums = try await api.albums()
            self.status = "已在设备本地重命名为“\(name.trimmingCharacters(in: .whitespacesAndNewlines))”；手机云端名称不变。"
        }
    }

    func deleteSelectedAlbum() {
        guard let album = selectedAlbum else { return }
        run {
            let api = try self.api()
            try await api.deleteAlbum(album)
            self.albums = try await api.albums()
            self.selectedAlbumID = self.albums.first(where: { $0.canEdit })?.id ?? self.albums.first?.id
            if let selected = self.selectedAlbum {
                self.photos = try await api.photos(albumID: selected.id, start: 1)
            } else {
                self.photos = []
            }
            self.canLoadMore = self.photos.count == 100
            self.selectedPhotoIDs.removeAll()
            self.status = "已删除相册“\(album.name)”。"
        }
    }

    func loadMore() {
        guard let album = selectedAlbum, canLoadMore else { return }
        run {
            let next = try await self.api().photos(albumID: album.id, start: self.photos.count + 1)
            self.photos += next
            self.canLoadMore = next.count == 100
            self.status = "\(album.name)：已显示 \(self.photos.count) 张"
        }
    }

    func selectAllPhotos() {
        guard let album = selectedAlbum else { return }
        run {
            let api = try self.api()
            var loaded: [Photo] = []
            var reachedEnd = false
            for page in 0..<100 {
                let next = try await api.photos(albumID: album.id, start: page * 100 + 1)
                loaded += next
                if next.count < 100 { reachedEnd = true; break }
            }
            guard reachedEnd else { throw FrameError.message("相册照片过多，无法全选。") }
            self.photos = loaded
            self.canLoadMore = false
            self.selectedPhotoIDs = Set(loaded.map(\.id))
            self.status = "已选中“\(album.name)”中的 \(self.selectedPhotoIDs.count) 张。"
        }
    }

    func importFiles(_ urls: [URL], scopedDirectory: URL? = nil) {
        guard !busy, let album = selectedAlbum, album.canEdit, !urls.isEmpty else { return }
        // Acquire scope before leaving the panel callback, retaining it through async work.
        let accessible = (urls + [scopedDirectory].compactMap { $0 }).filter { $0.startAccessingSecurityScopedResource() }
        run {
            defer { accessible.forEach { $0.stopAccessingSecurityScopedResource() } }
            try await self.uploadFiles(urls, to: album)
        }
    }

    func importLibraryPhotos(_ assets: [PHAsset]) {
        guard !busy, let album = selectedAlbum, album.canEdit, !assets.isEmpty else { return }
        showLibrary = false
        run {
            // Recheck before downloading iCloud originals; upload also checks again before writing.
            let existing = try await self.api().photos(albumID: album.id, start: 1)
            guard existing.count + assets.count <= AlbumAPI.maxPhotosPerAlbum else {
                throw FrameError.message("相册剩余容量不足，请刷新后重新选择。")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TimesFrame-Photos-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var urls: [URL] = []
            for (index, asset) in assets.enumerated() {
                self.status = "正在读取 Mac 相册照片 \(index + 1)/\(assets.count)（iCloud 照片可能需要下载）…"
                urls.append(try await MacPhotoLibrary.export(asset, to: directory, index: index))
            }
            try await self.uploadFiles(urls, to: album)
        }
    }

    private func uploadFiles(_ urls: [URL], to album: Album) async throws {
        let api = try self.api()
        do {
            try await api.upload(urls, to: album) { index, total, filename in
                await MainActor.run { self.status = "正在上传 \(index)/\(total)：\(filename)" }
            }
        } catch {
            self.photos = (try? await api.photos(albumID: album.id, start: 1)) ?? self.photos
            self.canLoadMore = self.photos.count == 100
            throw error
        }
        self.photos = try await api.photos(albumID: album.id, start: 1)
        self.canLoadMore = self.photos.count == 100
        self.status = "已上传 \(urls.count) 张到“\(album.name)”。"
    }

    func removeSelected() {
        guard let album = selectedAlbum else { return }
        let ids = Array(selectedPhotoIDs)
        run {
            try await self.api().remove(ids, from: album)
            self.photos = try await self.api().photos(albumID: album.id, start: 1)
            self.selectedPhotoIDs.removeAll()
            self.status = "已从“\(album.name)”移出 \(ids.count) 张；设备原图仍保留。"
        }
    }

    func deleteSelected() {
        guard let album = selectedAlbum else { return }
        let ids = Array(selectedPhotoIDs)
        run {
            try await self.api().delete(ids, from: album)
            self.photos = try await self.api().photos(albumID: album.id, start: 1)
            self.selectedPhotoIDs.removeAll()
            self.status = "已删除 \(ids.count) 张设备照片。"
        }
    }

    func prepareAdd() {
        guard let all = albums.first(where: { $0.type == 1 }) else {
            isError = true; status = "设备没有返回“全部照片”相册。"; return
        }
        run {
            self.allPhotosForAdd = try await self.api().photos(albumID: all.id, start: 1)
            self.canLoadMoreForAdd = self.allPhotosForAdd.count == 100
            self.addSelected.removeAll()
            self.showAddSheet = true
        }
    }

    func loadMoreForAdd() {
        guard let all = albums.first(where: { $0.type == 1 }), canLoadMoreForAdd else { return }
        run {
            let next = try await self.api().photos(albumID: all.id, start: self.allPhotosForAdd.count + 1)
            self.allPhotosForAdd += next
            self.canLoadMoreForAdd = next.count == 100
        }
    }

    func addExisting() {
        guard let album = selectedAlbum else { return }
        let ids = Array(addSelected)
        showAddSheet = false
        run {
            let added = try await self.api().addExisting(ids, to: album)
            self.photos = try await self.api().photos(albumID: album.id, start: 1)
            self.canLoadMore = self.photos.count == 100
            self.status = "已将 \(added) 张已有照片加入“\(album.name)”。"
        }
    }

    func downloadSelected() {
        guard selectedPhotoIDs.count == 1,
              let photo = photos.first(where: { selectedPhotoIDs.contains($0.id) }) else { return }
        let panel = NSSavePanel()
        let extensionName = URL(fileURLWithPath: photo.originalPath).pathExtension
        panel.nameFieldStringValue = "TimesFrame-\(photo.id).\(extensionName.isEmpty ? "jpg" : extensionName)"
        if panel.runModal() != .OK { return }
        guard let destination = panel.url else { return }
        run {
            let data = try await self.api().download(photo)
            try data.write(to: destination, options: .atomic)
            self.status = "已保存原图：\(destination.lastPathComponent)"
        }
    }
}

struct SelectablePhotoGrid: View {
    let photos: [Photo]
    let mediaURL: (Photo) -> URL?
    @Binding var selectedIDs: Set<Int>
    var deleteSelection: (() -> Void)? = nil

    var body: some View {
        NativeLibraryGrid(entries: photos.map { NativeLibraryEntry(id: $0.id, remoteURL: mediaURL($0)) },
                          selectedIDs: $selectedIDs, deleteSelection: deleteSelection)
    }
}

struct ContentView: View {
    @StateObject private var model = AlbumModel()
    @ObservedObject private var account = AccountModel.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("相框 IP", text: $model.ip).textFieldStyle(.roundedBorder).frame(width: 180)
                TextField("端口", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 65)
                Button("查找设备") { model.discover() }.disabled(model.busy)
                if !model.found.isEmpty {
                    Menu("选择设备") {
                        ForEach(model.found) { device in
                            Button("\(device.name) · \(device.ip)") { model.ip = device.ip; model.connect() }
                        }
                    }
                }
                Button("连接") { model.connect() }.disabled(model.busy)
                Button("核对手机端") { model.checkCloudAlbums() }.disabled(model.busy || model.deviceID == nil)
                Spacer()
                Text("TimesFrame · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.headline)
                Button("表盘工作台") { model.showWorkbench = true }.disabled(model.busy || model.deviceID == nil)
                Button(account.session?.nickname ?? "账号与设备控制") { model.showSettings = true }.disabled(model.busy)
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("相册").font(.headline)
                        Spacer()
                        Button("新建本地") { model.albumNameInput = ""; model.showNewAlbum = true }
                        .help("只在设备本地新建；手机同步相册请在手机 App 创建后刷新")
                        .disabled(model.busy || model.albums.isEmpty)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    List(model.albums, selection: Binding(get: { model.selectedAlbumID }, set: { id in
                        if let album = model.albums.first(where: { $0.id == id }) { model.select(album) }
                    })) { album in
                        HStack {
                            Image(systemName: album.type == 1 ? "photo.on.rectangle" : "rectangle.stack")
                            Text(album.name).lineLimit(1)
                            if album.canEdit, let cloudIDs = model.cloudClockIDs {
                                Image(systemName: cloudIDs.contains(album.id) ? "icloud" : "internaldrive")
                                    .help(cloudIDs.contains(album.id) ? "手机端列表中存在此相册" : "仅设备本地，手机端列表中不存在")
                            }
                            if !album.canEdit { Image(systemName: "lock").font(.caption2) }
                        }
                        .tag(album.id)
                        .contentShape(Rectangle())
                    }
                    .listStyle(.sidebar)
                    .disabled(model.busy)
                    HStack {
                        Button("重命名") {
                            model.albumNameInput = model.selectedAlbum?.name ?? ""
                            model.showRenameAlbum = true
                        }
                        Button("删除相册") { model.showDeleteAlbum = true }
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                    .disabled(model.busy || model.selectedAlbum?.canEdit != true)
                }
                .frame(width: 210)
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(model.selectedAlbum?.name ?? "请选择相册").font(.headline)
                        if model.selectedAlbum != nil {
                            Text(model.photos.count >= AlbumAPI.maxPhotosPerAlbum
                                 ? "已达 100 张上限" : "\(model.photos.count)/100 张")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("刷新") { model.refresh() }.disabled(model.busy || model.selectedAlbum == nil)
                        Button("从 Mac 相册…") { model.showLibrary = true }
                            .disabled(model.busy || model.selectedAlbum?.canEdit != true || model.photos.count >= AlbumAPI.maxPhotosPerAlbum)
                        Button("上传文件夹…") { model.importFolder() }
                            .disabled(model.busy || model.selectedAlbum?.canEdit != true || model.photos.count >= AlbumAPI.maxPhotosPerAlbum)
                        Button("上传照片…") { model.showImporter = true }
                            .disabled(model.busy || model.selectedAlbum?.canEdit != true || model.photos.count >= AlbumAPI.maxPhotosPerAlbum)
                    }
                    .padding(12)
                    Divider()
                    VStack(spacing: 0) {
                        SelectablePhotoGrid(photos: model.photos,
                            mediaURL: { try? model.apiURL($0.thumbnailPath) },
                            selectedIDs: $model.selectedPhotoIDs,
                            deleteSelection: { if model.selectedAlbum?.canEdit == true { model.showDelete = true } })
                        .id(model.selectedAlbumID)
                        .disabled(model.busy)
                        if model.canLoadMore {
                            Button("加载更多") { model.loadMore() }
                                .disabled(model.busy).padding()
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("已选 \(model.selectedPhotoIDs.count) 张 · 再次框选可累加")
                                .foregroundStyle(.secondary)
                            Button("全选相册") { model.selectAllPhotos() }
                                .disabled(model.photos.isEmpty || model.busy)
                            Button("清空选择") { model.selectedPhotoIDs.removeAll() }
                                .disabled(model.selectedPhotoIDs.isEmpty || model.busy)
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            Button("下载原图") { model.downloadSelected() }.disabled(model.busy || model.selectedPhotoIDs.count != 1)
                            if model.selectedAlbum?.canEdit == true {
                                Button("加入已有照片…") { model.prepareAdd() }
                                    .disabled(model.busy || model.photos.count >= AlbumAPI.maxPhotosPerAlbum)
                                Button("移出相册") { model.removeSelected() }.disabled(model.busy || model.selectedPhotoIDs.isEmpty)
                                Button("从设备删除") { model.showDelete = true }
                                    .disabled(model.busy || model.selectedPhotoIDs.isEmpty)
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                if !model.connectedIP.isEmpty {
                    Text("设备 \(model.connectedIP):\(model.connectedPort)").font(.caption).foregroundStyle(.secondary)
                    Divider().frame(height: 14)
                }
                Text(model.status).foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("本地网络权限…") { model.openNetworkSettings() }
            }
            .padding(10)
        }
        .frame(minWidth: 1050, minHeight: 650)
        .background(MainWindowLifecycle().allowsHitTesting(false))
        .onAppear { model.connectionForAccount() }
        .onChange(of: account.session?.userID) { _ in model.connectionForAccount() }
        .sheet(isPresented: $model.showSettings, onDismiss: {
            if model.deviceID != nil { model.refresh() }
        }) {
            DeviceSettingsView(ip: model.connectedIP, port: model.connectedPort,
                               deviceID: model.deviceID, connected: model.deviceID != nil,
                               syncMessage: model.syncMessage)
        }
        .sheet(isPresented: $model.showWorkbench) {
            WatchfaceWorkbench(ip: model.connectedIP, port: model.connectedPort)
        }
        .sheet(isPresented: $model.showLibrary) {
            MacPhotoLibraryView(maxSelection: max(0, AlbumAPI.maxPhotosPerAlbum - model.photos.count),
                                albumName: model.selectedAlbum?.name ?? "相册",
                                cancel: { model.showLibrary = false },
                                upload: { model.importLibraryPhotos($0) })
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.isError = true; model.status = "读取文件失败：\(error.localizedDescription)"
            }
        }
        .alert("从设备删除照片？", isPresented: $model.showDelete) {
            Button("删除设备原图", role: .destructive) { model.deleteSelected() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会删除选中的 \(model.selectedPhotoIDs.count) 张设备照片，并影响引用它们的其他相册。此操作无法撤销。")
        }
        .alert("新建设备本地相册", isPresented: $model.showNewAlbum) {
            TextField("相册名称", text: $model.albumNameInput)
            Button("创建") { model.createAlbum() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作仅在相框本地创建，手机 App 不会自动显示。需要手机可见的相册，请先在手机 App 创建，然后点击本客户端的刷新。")
        }
        .alert("重命名设备本地相册", isPresented: $model.showRenameAlbum) {
            TextField("相册名称", text: $model.albumNameInput)
            Button("保存") { model.renameSelectedAlbum() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只修改设备本地名称；手机云端的相册名称不会改变。")
        }
        .alert("删除相册？", isPresented: $model.showDeleteAlbum) {
            Button("删除相册", role: .destructive) { model.deleteSelectedAlbum() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作只修改设备本地相册，不会删除手机云端列表中的记录。将从相框删除“\(model.selectedAlbum?.name ?? "")”及其相册归属。此操作无法撤销；原图是否保留取决于设备固件。")
        }
        .sheet(isPresented: $model.showAddSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("从全部照片加入“\(model.selectedAlbum?.name ?? "相册")”").font(.headline)
                Text("从设备照片中选择；每次加载 100 张，加入时不会复制文件。")
                    .foregroundStyle(.secondary)
                VStack {
                    SelectablePhotoGrid(photos: model.allPhotosForAdd,
                        mediaURL: { try? model.apiURL($0.thumbnailPath) },
                        selectedIDs: $model.addSelected)
                        .disabled(model.busy)
                    if model.canLoadMoreForAdd {
                        Button("加载更多") { model.loadMoreForAdd() }
                            .disabled(model.busy).padding()
                    }
                }
                HStack {
                    Button("全选已加载") {
                        model.addSelected = Set(model.allPhotosForAdd.map(\.id))
                    }.disabled(model.allPhotosForAdd.isEmpty || model.busy)
                    Button("清空选择") { model.addSelected.removeAll() }
                        .disabled(model.addSelected.isEmpty || model.busy)
                    Spacer()
                    Button("取消") { model.showAddSheet = false }
                    Button("加入 \(model.addSelected.count) 张") { model.addExisting() }
                        .buttonStyle(.borderedProminent).disabled(model.addSelected.isEmpty)
                }
            }
            .padding(20).frame(width: 650, height: 550)
        }
    }
}

extension AlbumModel {
    func apiURL(_ path: String) throws -> URL? { try api().mediaURL(path) }
}

final class TimesFrameAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !FRAME_TEST
@main struct TimesFrameAlbumApp: App {
    @NSApplicationDelegateAdaptor(TimesFrameAppDelegate.self) private var appDelegate
    var body: some Scene { Window("TimesFrame 相册管理", id: "main") { ContentView() } }
}
#endif
