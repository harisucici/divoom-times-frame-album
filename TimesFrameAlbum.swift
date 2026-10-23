import AppKit
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
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

struct AlbumAPI {
    let ip: String
    let port: Int

    init(ip: String, port: Int = 9000) throws {
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
    }

    private var root: URL { URL(string: "http://\(ip):\(port)")! }

    private func post(_ path: String, body: Data, contentType: String, timeout: TimeInterval = 20) async throws -> [String: Any] {
        var request = URLRequest(url: root.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw FrameError.message("无法连接相框：\(error.localizedDescription)") }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FrameError.message("相框返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameError.message("相框返回了无法解析的数据。")
        }
        let code = (object["ReturnCode"] as? NSNumber)?.intValue ?? -1
        guard code == 0 else {
            throw FrameError.message("设备错误 \(code)：\(object["ReturnMessage"] as? String ?? "未知原因")")
        }
        return object
    }

    private func command(_ name: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        var value = fields
        value["Command"] = name
        value["ReturnCode"] = 0
        let body = try JSONSerialization.data(withJSONObject: value)
        return try await post("divoom_api", body: body, contentType: "application/json; charset=utf-8")
    }

    func check() async throws -> String {
        let hardware = try await command("Device/GetHardwareVersion")
        let code = (hardware["Hardware"] as? NSNumber)?.intValue ?? -1
        guard [510, 511, 512].contains(code) else {
            throw FrameError.message("检测到设备型号 \(code)，不是已支持的 Times Frame。")
        }
        _ = try await command("Photo/GetLocalAlbumList")
        let firmware = (hardware["Software"] as? NSNumber)?.intValue ?? 0
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

    func mediaURL(_ path: String) -> URL? {
        guard path.hasPrefix("/userdata/"), !path.contains(".."), !path.contains("?") else { return nil }
        return URL(string: "http://\(ip):\(port)\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)")
    }

    func download(_ photo: Photo) async throws -> Data {
        guard let url = mediaURL(photo.originalPath) else { throw FrameError.message("相框返回的原图路径无效。") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FrameError.message("原图下载失败。") }
        return data
    }

    func remove(_ ids: [Int], from album: Album) async throws {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能修改普通相册。") }
        _ = try await command("Photo/RemovePhotoFromAlbum", fields: [
            "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": ids
        ])
    }

    func delete(_ ids: [Int], from album: Album) async throws {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能从普通相册删除照片。") }
        _ = try await command("Photo/DeletePhoto", fields: [
            "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": ids
        ])
    }

    func addExisting(_ ids: [Int], to album: Album) async throws {
        guard album.canEdit, !ids.isEmpty else { throw FrameError.message("只能添加到普通相册。") }
        _ = try await command("Photo/DevicePhotoToAlbum", fields: [
            "ToClockId": album.id, "ParentItemId": 0, "ParentClockId": 0, "PhotoList": ids
        ])
    }

    func upload(_ url: URL, to album: Album) async throws {
        guard album.canEdit else { throw FrameError.message("请先选择普通相册。") }
        let image = try PhotoEncoder.encode(url)
        let before = try await photos(albumID: album.id, start: 1)
        let oldIDs = Set(before.map(\.id))
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let batchFlag = Int(Date().timeIntervalSince1970)
        let filename = "mac-\(UUID().uuidString.prefix(16)).jpg"
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
        let metadata: [String: Any] = [
            "Command": "Photo/LocalAddToAlbum", "ReturnCode": 0,
            "ClockId": album.id, "ParentItemId": 0, "ParentClockId": 0,
            "UserId": 0, "PhotoX": 0, "PhotoY": 0,
            "PhotoWidth": image.width, "PhotoHeight": image.height,
            "PhotoIndex": 0, "PhotoTotalCnt": 1, "PhotoFlag": batchFlag,
            "SendTime": timestamp, "TakingTime": timestamp,
            "FileName": filename, "PreviewFileName": "", "PhotoTitle": title
        ]
        let (body, type) = try multipart(metadata: metadata, filename: filename, image: image.data)
        guard body.count <= 100 * 1024 * 1024 else { throw FrameError.message("图片超过当前固件的 100 MB 上传限制。") }
        _ = try await post("upload", body: body, contentType: type, timeout: 90)
        // The upload acknowledgement precedes the background database insertion.
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let current = try await photos(albumID: album.id, start: 1)
            if current.contains(where: { !oldIDs.contains($0.id) }) { return }
        }
        throw FrameError.message("相框已接收图片，但 12 秒内未在相册中看到新增记录。请刷新相册确认，避免重复上传。")
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
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            throw FrameError.message("无法打开图片：\(url.lastPathComponent)")
        }
        let scale = min(1.0, 2048 / max(source.size.width, source.size.height))
        let width = max(1, Int((source.size.width * scale).rounded()))
        let height = max(1, Int((source.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw FrameError.message("无法转换图片。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw FrameError.message("无法编码 JPEG。")
        }
        return (data, width, height)
    }
}

@MainActor final class AlbumModel: ObservableObject {
    @Published var ip = UserDefaults.standard.string(forKey: "albumFrameIP") ?? ""
    @Published var port = "9000"
    @Published var found: [FoundDevice] = []
    @Published var albums: [Album] = []
    @Published var selectedAlbumID: Int?
    @Published var photos: [Photo] = []
    @Published var selectedPhotoIDs = Set<Int>()
    @Published var busy = false
    @Published var status = "连接 Times Frame 后选择相册。"
    @Published var isError = false
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
    private func api() throws -> AlbumAPI { try AlbumAPI(ip: ip.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0) }

    private func run(_ work: @escaping () async throws -> Void) {
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
        run {
            let api = try self.api()
            self.status = "正在读取相册…"
            let device = try await api.check()
            self.albums = try await api.albums()
            UserDefaults.standard.set(self.ip, forKey: "albumFrameIP")
            self.selectedAlbumID = self.albums.first(where: { $0.canEdit })?.id ?? self.albums.first?.id
            if let album = self.selectedAlbum { self.photos = try await api.photos(albumID: album.id, start: 1) }
            self.canLoadMore = self.photos.count == 100
            self.selectedPhotoIDs.removeAll()
            self.status = "\(device) · \(self.albums.count) 个相册"
        }
    }

    func select(_ album: Album) {
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
        guard let album = selectedAlbum else { return }
        select(album)
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
            self.status = "已新建相册“\(created.name)”。"
        }
    }

    func renameSelectedAlbum() {
        guard let album = selectedAlbum else { return }
        let name = albumNameInput
        run {
            let api = try self.api()
            try await api.renameAlbum(album, to: name)
            self.albums = try await api.albums()
            self.status = "已将相册重命名为“\(name.trimmingCharacters(in: .whitespacesAndNewlines))”。"
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

    func importFiles(_ urls: [URL]) {
        guard let album = selectedAlbum, album.canEdit, !urls.isEmpty else { return }
        run {
            let api = try self.api()
            var completed = 0
            for url in urls {
                self.status = "正在上传 \(completed + 1)/\(urls.count)：\(url.lastPathComponent)"
                try await api.upload(url, to: album)
                completed += 1
            }
            self.photos = try await api.photos(albumID: album.id, start: 1)
            self.canLoadMore = self.photos.count == 100
            self.status = "已上传 \(completed) 张到“\(album.name)”。"
        }
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
            try await self.api().addExisting(ids, to: album)
            self.photos = try await self.api().photos(albumID: album.id, start: 1)
            self.status = "已将 \(ids.count) 张已有照片加入“\(album.name)”。"
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

struct PhotoTile: View {
    let photo: Photo
    let url: URL?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: photo.mediaType == "video" ? "film" : "photo")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                }
                .frame(width: 142, height: 142).clipped()
                Text("#\(photo.id)")
                    .font(.caption2).padding(4)
                    .background(.black.opacity(0.55)).foregroundStyle(.white)
            }
            .frame(width: 142, height: 142)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @StateObject private var model = AlbumModel()
    private let columns = [GridItem(.adaptive(minimum: 142, maximum: 142), spacing: 12)]
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
                Spacer()
                Text("TimesFrame 相册管理").font(.headline)
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("相册").font(.headline)
                        Spacer()
                        Button { model.albumNameInput = ""; model.showNewAlbum = true } label: {
                            Image(systemName: "plus")
                        }
                        .help("新建相册")
                        .disabled(model.busy || model.albums.isEmpty)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    List(model.albums, selection: $model.selectedAlbumID) { album in
                        HStack {
                            Image(systemName: album.type == 1 ? "photo.on.rectangle" : "rectangle.stack")
                            Text(album.name).lineLimit(1)
                            if !album.canEdit { Image(systemName: "lock").font(.caption2) }
                        }
                        .tag(album.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(album) }
                    }
                    .listStyle(.sidebar)
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
                        Spacer()
                        Button("刷新") { model.refresh() }.disabled(model.busy || model.selectedAlbum == nil)
                        Button("上传照片…") { model.showImporter = true }
                            .disabled(model.busy || model.selectedAlbum?.canEdit != true)
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.photos) { photo in
                                PhotoTile(photo: photo, url: try? model.apiURL(photo.thumbnailPath), selected: model.selectedPhotoIDs.contains(photo.id)) {
                                    if model.selectedPhotoIDs.contains(photo.id) { model.selectedPhotoIDs.remove(photo.id) }
                                    else { model.selectedPhotoIDs.insert(photo.id) }
                                }
                            }
                        }
                        .padding(14)
                        if model.canLoadMore {
                            Button("加载更多") { model.loadMore() }
                                .disabled(model.busy).padding()
                        }
                    }
                    HStack(spacing: 10) {
                        Text("已选 \(model.selectedPhotoIDs.count) 张").foregroundStyle(.secondary)
                        Button("下载原图") { model.downloadSelected() }.disabled(model.busy || model.selectedPhotoIDs.count != 1)
                        if model.selectedAlbum?.canEdit == true {
                            Button("加入已有照片…") { model.prepareAdd() }.disabled(model.busy)
                            Button("移出相册") { model.removeSelected() }.disabled(model.busy || model.selectedPhotoIDs.isEmpty)
                            Button("从设备删除") { model.showDelete = true }
                                .disabled(model.busy || model.selectedPhotoIDs.isEmpty)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 850, minHeight: 580)
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.importFiles(urls) }
        }
        .alert("从设备删除照片？", isPresented: $model.showDelete) {
            Button("删除设备原图", role: .destructive) { model.deleteSelected() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会删除选中的 \(model.selectedPhotoIDs.count) 张设备照片，并影响引用它们的其他相册。此操作无法撤销。")
        }
        .alert("新建相册", isPresented: $model.showNewAlbum) {
            TextField("相册名称", text: $model.albumNameInput)
            Button("创建") { model.createAlbum() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("相册会直接创建在 Times Frame 上。")
        }
        .alert("重命名相册", isPresented: $model.showRenameAlbum) {
            TextField("相册名称", text: $model.albumNameInput)
            Button("保存") { model.renameSelectedAlbum() }
            Button("取消", role: .cancel) { }
        }
        .alert("删除相册？", isPresented: $model.showDeleteAlbum) {
            Button("删除相册", role: .destructive) { model.deleteSelectedAlbum() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将从相框删除“\(model.selectedAlbum?.name ?? "")”及其相册归属。此操作无法撤销；原图是否保留取决于设备固件。")
        }
        .sheet(isPresented: $model.showAddSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("从全部照片加入“\(model.selectedAlbum?.name ?? "相册")”").font(.headline)
                Text("从设备照片中选择；每次加载 100 张，加入时不会复制文件。")
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.allPhotosForAdd) { photo in
                            PhotoTile(photo: photo, url: try? model.apiURL(photo.thumbnailPath), selected: model.addSelected.contains(photo.id)) {
                                if model.addSelected.contains(photo.id) { model.addSelected.remove(photo.id) }
                                else { model.addSelected.insert(photo.id) }
                            }
                        }
                    }
                    if model.canLoadMoreForAdd {
                        Button("加载更多") { model.loadMoreForAdd() }
                            .disabled(model.busy).padding()
                    }
                }
                HStack {
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

#if !FRAME_TEST
@main struct TimesFrameAlbumApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
#endif
