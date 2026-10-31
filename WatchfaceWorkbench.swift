import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Mirrors DivoomDevelop/mcp-divoom-lan's TimesFrame managed slot and transports.
struct WatchfaceService {
    static let managedID = 60000
    let api: AlbumAPI

    func identify() async throws -> [String: Any] {
        let value = try await api.command("Device/GetHardwareVersion")
        guard let hardware = (value["Hardware"] as? NSNumber)?.intValue, [510, 511, 512].contains(hardware) else {
            throw FrameError.message("表盘工作台仅适用于 Times Frame 510／511／512。")
        }
        return value
    }
    func local(clockID: Int? = nil) async throws -> [String: Any] {
        try await api.command("Device/GetLocalClockInfo", fields: clockID.map { ["ClockId": $0] } ?? ["UseCurrentDisplayClock": 1])
    }
    func managed() async throws -> [String: Any]? {
        do {
            let value = try await local(clockID: Self.managedID)
            guard (value["ClockId"] as? NSNumber)?.intValue == Self.managedID,
                  let items = value["ItemList"] as? [[String: Any]], !items.isEmpty else { return nil }
            return value
        } catch FrameError.device(_, let message) {
            let pattern = "not\\s*(?:found|exist)|missing|no\\s+local\\s+(?:sys\\s+)?clock\\s+file|不存在|未找到"
            if message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            throw FrameError.message("无法确认本地表盘状态：\(message)")
        }
    }
    static func configuration(_ input: [String: Any], complete: Bool) throws -> [String: Any] {
        let allowed: Set<String> = ["DeviceImageUrl", "DevicePreviewImageUrl", "DevicePreviewImageUrl2", "SetColorList",
            "ItemList", "ItemIdList", "ItemPatchList", "ItemPatchByRoleList"]
        let informational: Set<String> = ["ClockId", "ClockName", "NameCn", "NameEn", "Command", "ReturnCode", "ReturnMessage", "DeviceType"]
        let unknown = Set(input.keys).subtracting(allowed.union(informational))
        guard unknown.isEmpty else { throw FrameError.message("不支持的配置字段：\(unknown.sorted().joined(separator: ", "))") }
        var body = input.filter { allowed.contains($0.key) }
        guard !body.isEmpty else { throw FrameError.message("请提供表盘配置或补丁。") }
        if complete || body["ItemList"] != nil {
            guard let items = body["ItemList"] as? [[String: Any]], !items.isEmpty,
                  let ids = body["ItemIdList"] as? [String], ids.count == items.count,
                  Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }),
                  zip(items, ids).allSatisfy({ ($0.0["item_id"] as? String) == $0.1 }) else {
                throw FrameError.message("完整配置须有非空 ItemList；每个 item_id 须唯一，并与 ItemIdList 按顺序对应。")
            }
            for item in items {
                guard let disp = item["disp"] as? NSNumber, disp.doubleValue.rounded() == disp.doubleValue else {
                    throw FrameError.message("每个显示元素需要整数 disp。")
                }
                for key in ["x", "y", "w", "h", "size", "transp"] {
                    if let value = item[key] {
                        guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw FrameError.message("\(key) 必须是有限数值。") }
                        if ["w", "h", "size"].contains(key), number.doubleValue < 0 { throw FrameError.message("\(key) 不能为负数。") }
                        if key == "transp", !(0...100).contains(number.doubleValue) { throw FrameError.message("透明度须为 0–100。") }
                    }
                }
            }
        }
        if let patches = body["ItemPatchList"] {
            guard let rows = patches as? [[String: Any]], !rows.isEmpty else { throw FrameError.message("ItemPatchList 须为非空数组。") }
            for row in rows {
                guard let index = row["index"] as? Int, index >= 0,
                      let patch = row["patch"] as? [String: Any], !patch.isEmpty else {
                    throw FrameError.message("每个补丁需要非负整数 index 和非空 patch。")
                }
            }
        }
        if let roles = body["ItemPatchByRoleList"], !(roles is [[String: Any]]) {
            throw FrameError.message("ItemPatchByRoleList 须为对象数组。")
        }
        body["ClockId"] = Self.managedID
        return body
    }
    static func minimalUpdate(_ fields: [String: Any], before: [String: Any]) throws -> [String: Any] {
        guard let newRows = fields["ItemList"] as? [[String: Any]],
              let oldRows = before["ItemList"] as? [[String: Any]], newRows.count == oldRows.count else { return fields }
        guard fields["ItemPatchList"] == nil, fields["ItemPatchByRoleList"] == nil else {
            throw FrameError.message("请在完整 ItemList 与字段补丁中选择一种更新方式。")
        }
        let allowed: Set<String> = ["size", "size_delta", "x", "y", "w", "h", "disp", "alig", "sep", "font",
            "image_id", "angle", "hier", "transp", "animation", "image_addr", "color_1", "color_2", "bundle_image"]
        var patches: [[String: Any]] = []
        for (index, pair) in zip(oldRows, newRows).enumerated() {
            let (old, new) = pair
            guard old["item_id"] as? String == new["item_id"] as? String else {
                throw FrameError.message("原有元素的 item_id 发生变化。微调请保留原 ID，避免破坏设备菜单绑定。")
            }
            var patch: [String: Any] = [:]
            for (key, value) in new where key != "item_id" {
                if let oldValue = old[key], NSDictionary(dictionary: ["v": oldValue]).isEqual(to: ["v": value]) { continue }
                guard allowed.contains(key) else { throw FrameError.message("字段 \(key) 不支持局部更新。") }
                patch[key] = value
            }
            if !patch.isEmpty { patches.append(["index": index, "patch": patch]) }
        }
        var result = fields
        result.removeValue(forKey: "ItemList"); result.removeValue(forKey: "ItemIdList")
        if !patches.isEmpty { result["ItemPatchList"] = patches }
        return result
    }
    func validateFonts(_ body: [String: Any]) async throws {
        let fonts = try await api.command("Device/GetLocalFontList")
        let installed = Set((fonts["FontList"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.intValue })
        var used = Set<Int>()
        func collect(_ object: Any) {
            if let row = object as? [String: Any] {
                if let id = (row["font"] as? NSNumber)?.intValue, id > 0 { used.insert(id) }
                row.values.forEach(collect)
            } else if let array = object as? [Any] { array.forEach(collect) }
        }
        collect(body)
        let missing = used.subtracting(installed)
        guard missing.isEmpty else { throw FrameError.message("设备尚未安装字体 \(missing.sorted())，请先选择设备字体列表中的字体。") }
    }
    func upsert(_ input: [String: Any], asset: DialAsset?, name: String, requireExisting: Bool) async throws -> [String: Any] {
        _ = try await identify()
        let before = try await managed()
        if requireExisting, before == nil { throw FrameError.message("本地表盘 60000 尚不存在。请先提供完整配置和背景创建。") }
        let creating = before == nil
        var fields = try Self.configuration(input, complete: creating)
        if creating, asset == nil { throw FrameError.message("创建本地表盘还需要背景图片或素材包。") }
        if let before { fields = try Self.minimalUpdate(fields, before: before) }
        if let patches = fields["ItemPatchList"] as? [[String: Any]], let before {
            let count = (before["ItemList"] as? [Any])?.count ?? 0
            guard patches.allSatisfy({ ($0["index"] as? Int).map { (0..<count).contains($0) } == true }) else {
                throw FrameError.message("补丁 index 超出设备当前元素范围。")
            }
        }
        try await validateFonts(fields)
        let command = creating ? "Device/CreateLocalClock" : "Device/PatchLocalClockInfo"
        fields["Command"] = command; fields["ReturnCode"] = 0
        if creating {
            fields["ClockName"] = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            fields["DialAssets"] = asset?.bundle == true ? "bundle" : "image"
        }
        if let asset {
            _ = try await multipart(creating ? "create_local_clock" : "patch_local_clock", metadata: fields, asset: asset)
        } else {
            fields.removeValue(forKey: "Command"); fields.removeValue(forKey: "ReturnCode")
            _ = try await api.command(command, fields: fields)
        }
        let after = try await local(clockID: Self.managedID)
        guard let rows = after["ItemList"] as? [[String: Any]], !rows.isEmpty else {
            throw FrameError.message("设备已接收写入，但回读配置为空。请重新读取核对，避免重复创建。")
        }
        return after
    }
    func multipart(_ endpoint: String, metadata: [String: Any], asset: DialAsset) async throws -> [String: Any] {
        guard ["create_local_clock", "patch_local_clock", "replace_clock_dial_bg"].contains(endpoint),
              asset.data.count <= 100 * 1024 * 1024 else { throw FrameError.message("不支持的上传路径或素材超过 100 MB。") }
        let boundary = "DivoomMac-\(UUID().uuidString)"
        let body = try Self.multipartBody(metadata: metadata, asset: asset, boundary: boundary)
        return try await api.post(endpoint, body: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 90)
    }
    static func multipartBody(metadata: [String: Any], asset: DialAsset, boundary: String) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"json\"; filename=\"cmd.json\"\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\n\r\n")
        body.append(json)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Int(Date().timeIntervalSince1970 * 1000))\"; filename=\"\(asset.bundle ? "clock_bg.tar.gz" : "clock_bg.jpg")\"\r\nContent-Type: application/octet-stream\r\nContent-Length: \(asset.data.count)\r\n\r\n")
        body.append(asset.data); append("\r\n--\(boundary)--\r\n")
        return body
    }
    func replaceBackground(_ asset: DialAsset, clockID: Int?) async throws -> [String: Any] {
        _ = try await identify()
        guard !asset.bundle, asset.data.count < 500 * 1024 else { throw FrameError.message("缓存背景仅接受小于 500 KiB 的 800×1280 图片。") }
        _ = try await local(clockID: clockID)
        var fields: [String: Any] = ["Command": "Device/ReplaceClockDialBgFile", "ReturnCode": 0]
        if let clockID { fields["ClockId"] = clockID } else { fields["UseCurrentDisplayClock"] = 1 }
        return try await multipart("replace_clock_dial_bg", metadata: fields, asset: asset)
    }
    func snapshot() async throws -> Data {
        _ = try await identify()
        let result = try await api.command("Device/GetScreenSnapshot")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        var paths = [String]()
        if let path = result["snapShotPath"] as? String { paths.append(path) }
        paths += ["/userdata/snapshot.webp", "/userdata/app_pic/snapshot.webp"]
        for path in paths {
            guard let url = api.mediaURL(path) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await api.session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil { return data }
        }
        throw FrameError.message("截图请求已发送，但尚未取得可解码图片。请稍后重试；Times Frame 固件可能返回缓存截图。")
    }
}

struct DialAsset {
    let data: Data
    let bundle: Bool
    let sourceName: String
    static func load(_ url: URL) throws -> DialAsset {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        if url.lastPathComponent.lowercased().hasSuffix(".tar.gz") || url.pathExtension.lowercased() == "tgz" {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count > 2, data.count <= 100 * 1024 * 1024,
                  data[0] == 0x1f, data[1] == 0x8b else { throw FrameError.message("需要有效的 gzip 素材包，最大 100 MB。") }
            return DialAsset(data: data, bundle: true, sourceName: url.lastPathComponent)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary),
              let context = CGContext(data: nil, width: 800, height: 1280, bitsPerComponent: 8, bytesPerRow: 3200,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FrameError.message("无法读取背景图片。")
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1280))
        let scale = max(800 / Double(image.width), 1280 / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (800-w)/2, y: (1280-h)/2, width: w, height: h))
        guard let rendered = context.makeImage() else { throw FrameError.message("背景转换失败。") }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        for quality in [0.9, 0.75, 0.55, 0.35, 0.15] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count < 500 * 1024 {
                return DialAsset(data: data, bundle: false, sourceName: url.lastPathComponent)
            }
        }
        throw FrameError.message("图片在转换后仍超过 500 KiB，请换用细节更少的背景。")
    }
}

enum FrameCatalog {
    static var directory: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("TimesFrame")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/TimesFrame")
    }
    static func text(_ filename: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8) }
    static func object(_ filename: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(text(filename).utf8)) as? [String: Any] else { throw FrameError.message("目录资源格式错误。") }
        return result
    }
    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "无法显示数据" }
        return text
    }
    static func parse(_ text: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw FrameError.message("请输入 JSON 对象。") }
        return result
    }
    static func draft(_ source: [String: Any]) -> [String: Any] {
        var result = source
        var seen = Set<String>()
        let items = (source["ItemList"] as? [[String: Any]] ?? []).enumerated().map { index, source -> [String: Any] in
            var row = source
            var id = row["item_id"] as? String ?? ""
            if id.isEmpty || seen.contains(id) { id = "mac_item_\(index)" }
            while !seen.insert(id).inserted { id += "_" }
            row["item_id"] = id
            return row
        }
        result["ItemList"] = items; result["ItemIdList"] = items.compactMap { $0["item_id"] as? String }
        result["ClockId"] = WatchfaceService.managedID
        return result
    }
    static func layout(disp: Int) throws -> [String: Any] {
        let catalog = try object("disp-catalog.json")
        guard let row = (catalog["displays"] as? [[String: Any]])?.first(where: { ($0["disp"] as? Int) == disp }) else {
            throw FrameError.message("目录中没有这个显示元素。")
        }
        guard let typography = row["typography"] as? [String: Any] else { return ["disp": disp, "说明": "缺少布局统计，请参考相似模板。"] }
        var fields: [String: Any] = ["disp": disp]
        if let size = typography["size"] as? [String: Any], let median = size["p50"] { fields["size"] = median }
        if let box = typography["box"] as? [String: [String: Any]] {
            for key in ["x", "y", "w", "h"] { if let median = box[key]?["p50"] { fields[key] = median } }
        }
        fields["alig"] = (typography["alig"] as? [String: Any])?["mode"] ?? 3
        if let colors = typography["colorHints"] as? [String: [String]] {
            for key in ["color_1", "color_2"] { if let color = colors[key + "_common"]?.first { fields[key] = color } }
        }
        return ["canvas": ["width": 800, "height": 1280], "suggestedItemFields": fields,
                "说明": "取官方样本中位数作为起点；应用前将位置与尺寸限制在画布内，并以设备截图核对。"]
    }
}

struct CatalogEntry: Identifiable {
    let id: Int
    let title: String
    let raw: [String: Any]
    var searchable: String { title + " " + FrameCatalog.pretty(raw) }
}

@MainActor final class WatchfaceModel: ObservableObject {
    let ip: String
    let port: Int
    @Published var busy = false
    @Published var isError = false
    @Published var status = "先读取设备信息。表盘编辑使用官方管理槽位 60000，不覆盖其他表盘。"
    @Published var output = ""
    @Published var configurationText = (try? FrameCatalog.text("example-minimal.json")) ?? "{}"
    @Published var clockName = "Mac 本地表盘"
    @Published var clockID = "60000"
    @Published var useCurrent = true
    @Published var asset: DialAsset?
    @Published var snapshotData: Data?
    @Published var showConfirm = false
    @Published var confirmTitle = "确认操作"
    @Published var confirmDetail = ""
    private var pendingAction: (() -> Void)?
    @Published var catalogKind = "模板"
    @Published var search = ""
    @Published var entries: [CatalogEntry] = []
    @Published var installedFontIDs: Set<Int>?
    @Published var selectedEntry: Int?
    @Published var catalogDetail = ""
    @Published var dispInput = "5"
    @Published var rawCommand = "Device/GetHardwareVersion"
    @Published var rawFields = "{}"
    init(ip: String, port: Int) { self.ip = ip; self.port = port; loadCatalog() }
    func service() throws -> WatchfaceService { WatchfaceService(api: try AlbumAPI(ip: ip, port: port)) }
    var targetID: Int? { useCurrent ? nil : Int(clockID) }
    func validatedTarget() throws -> Int? {
        if useCurrent { return nil }
        guard let id = Int(clockID), id > 0 else { throw FrameError.message("请输入正整数表盘 ID。") }
        return id
    }
    func run(_ label: String, _ operation: @escaping (WatchfaceService) async throws -> Void) {
        guard !busy else { return }; busy = true; isError = false; status = label + "…"
        Task {
            defer { busy = false }
            do { try await operation(service()); status = label + "完成。" }
            catch { isError = true; status = error.localizedDescription }
        }
    }
    func confirm(_ title: String, detail: String, action: @escaping () -> Void) {
        confirmTitle = title; confirmDetail = detail; pendingAction = action; showConfirm = true
    }
    func confirmed() { let action = pendingAction; pendingAction = nil; action?() }
    func read(_ command: String, current: Bool = false) {
        run("读取设备") { service in
            _ = try await service.identify()
            let value = current ? try await service.local(clockID: self.validatedTarget()) : try await service.api.command(command)
            self.output = FrameCatalog.pretty(value)
            if command == "Device/GetLocalFontList" {
                self.installedFontIDs = Set((value["FontList"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.intValue })
                if self.catalogKind == "字体" { self.loadCatalog() }
            }
        }
    }
    func editManaged() {
        run("读取本地表盘 60000") { service in
            _ = try await service.identify()
            guard let value = try await service.managed() else { throw FrameError.message("60000 尚无本地表盘，请从模板起草并选择背景创建。") }
            var configuration = value.filter { ["ItemList", "ItemIdList", "SetColorList", "DeviceImageUrl", "DevicePreviewImageUrl", "DevicePreviewImageUrl2"].contains($0.key) }
            if configuration["ItemIdList"] == nil { configuration["ItemIdList"] = (value["ItemList"] as? [[String: Any]] ?? []).compactMap { $0["item_id"] as? String } }
            self.configurationText = FrameCatalog.pretty(configuration)
            self.output = FrameCatalog.pretty(value)
        }
    }
    func chooseAsset() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .gzip]; panel.prompt = "选择背景或素材包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { asset = try DialAsset.load(url); status = "已准备 \(asset!.sourceName)：\(asset!.bundle ? "素材包" : "800×1280 JPEG，居中裁切")，\(asset!.data.count / 1024) KiB。"; isError = false }
        catch { status = error.localizedDescription; isError = true }
    }
    func write(requireExisting: Bool) {
        let text = configurationText, asset = asset, name = clockName
        run(requireExisting ? "更新表盘 60000 并回读" : "创建／更新表盘 60000 并回读") { service in
            let value = try await service.upsert(FrameCatalog.parse(text), asset: asset, name: name, requireExisting: requireExisting)
            self.output = FrameCatalog.pretty(value)
        }
    }
    func replace() {
        guard let asset else { return }
        run("替换所选表盘的缓存背景") { service in
            self.output = FrameCatalog.pretty(try await service.replaceBackground(asset, clockID: self.validatedTarget()))
        }
    }
    func reset() {
        run("恢复所选表盘的云端版本") { service in
            _ = try await service.identify()
            guard let id = try self.validatedTarget() else { throw FrameError.message("恢复操作需要明确的表盘 ID，请关闭“当前显示”。") }
            self.output = FrameCatalog.pretty(try await service.api.command("Device/ResetLocalClockFromServer", fields: ["ClockId": id]))
        }
    }
    func capture() {
        run("获取设备截图") { service in self.snapshotData = try await service.snapshot() }
    }
    func saveSnapshot() {
        guard let data = snapshotData, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TimesFrame-截图.png"; panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic); status = "截图已保存。" } catch { isError = true; status = error.localizedDescription }
    }
    func raw() {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines), text = rawFields
        run("发送设备命令") { service in
            _ = try await service.identify()
            var fields = try FrameCatalog.parse(text)
            fields.removeValue(forKey: "Command"); fields.removeValue(forKey: "ReturnCode")
            guard !command.isEmpty, command != "Device/UploadLocalAsset", command != "Device/CreateLocalClock",
                  command != "Device/PatchLocalClockInfo" else { throw FrameError.message("请使用本地表盘编辑页执行创建和修改；当前设备不支持 AstroToo 独立素材上传。") }
            self.output = FrameCatalog.pretty(try await service.api.command(command, fields: fields))
        }
    }
    func loadCatalog() {
        do {
            let mapping = ["模板": ("templates-curated.json", "templates"), "表盘": ("clock-catalog.json", "clocks"),
                           "字体": ("font-catalog.json", "fonts"), "显示元素": ("disp-catalog.json", "displays")]
            if let (file, key) = mapping[catalogKind] {
                let rows = try FrameCatalog.object(file)[key] as? [[String: Any]] ?? []
                entries = rows.enumerated().map { index, source in
                    var row = source
                    if self.catalogKind == "字体", let installed = self.installedFontIDs, let id = (row["id"] as? NSNumber)?.intValue {
                        row["设备已安装"] = installed.contains(id)
                    }
                    let number = row["clockId"] ?? row["disp"] ?? row["id"] ?? index
                    let name = row["nameCn"] ?? row["description_zh"] ?? row["name"] ?? ""
                    let installedLabel = (row["设备已安装"] as? Bool).map { $0 ? " · 已安装" : " · 未安装" } ?? ""
                    return CatalogEntry(id: index, title: "\(number) · \(name)\(installedLabel)", raw: row)
                }
                selectedEntry = nil; catalogDetail = "选择一条查看详情；目录是官方参考数据，设备安装情况以“读取设备字体”为准。"
            } else {
                entries = []; selectedEntry = nil
                catalogDetail = try FrameCatalog.text(catalogKind == "协议说明" ? "guide-quick-reference.md" : "ai-font-guide.md")
            }
        } catch { isError = true; status = error.localizedDescription }
    }
    func inspectEntry() {
        guard let entry = entries.first(where: { $0.id == selectedEntry }) else { return }
        var details = entry.raw
        if catalogKind == "表盘", let id = entry.raw["clockId"] {
            details["configuration"] = (try? FrameCatalog.object("clock-configs.json")["configurations"] as? [String: Any])?["\(id)"]
        }
        catalogDetail = FrameCatalog.pretty(details)
    }
    func useTemplate() {
        guard let entry = entries.first(where: { $0.id == selectedEntry }), let config = entry.raw["watchface"] as? [String: Any] else { return }
        guard let items = config["ItemList"] as? [Any], !items.isEmpty else {
            isError = true; status = "此官方模板仅提供背景参考，没有显示元素。请使用最小时间模板起草。"; return
        }
        configurationText = FrameCatalog.pretty(FrameCatalog.draft(config)); asset = nil
        status = "模板已载入草稿；请切换到“本地表盘”检查配置并选择背景。模板不包含图像素材，尚未写入设备。"
    }
    func suggestLayout() {
        do {
            guard let disp = Int(dispInput) else { throw FrameError.message("请输入整数显示元素 ID。") }
            catalogDetail = FrameCatalog.pretty(try FrameCatalog.layout(disp: disp)); isError = false
        } catch { isError = true; status = error.localizedDescription }
    }
    func exportOutput() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TimesFrame-设备数据.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8) } catch { isError = true; status = error.localizedDescription }
    }
}

struct WatchfaceWorkbench: View {
    @StateObject private var model: WatchfaceModel
    @Environment(\.dismiss) private var dismiss
    init(ip: String, port: Int) { _model = StateObject(wrappedValue: WatchfaceModel(ip: ip, port: port)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Times Frame 表盘工作台").font(.title2.bold())
                Text("\(model.ip):\(model.port) · 800×1280").foregroundStyle(.secondary)
                Spacer(); Button("完成") { dismiss() }.disabled(model.busy).keyboardShortcut(.cancelAction)
            }
            TabView {
                overview.tabItem { Label("设备与截图", systemImage: "display") }
                editing.tabItem { Label("本地表盘", systemImage: "slider.horizontal.3") }
                background.tabItem { Label("背景与恢复", systemImage: "photo") }
                catalog.tabItem { Label("官方素材目录", systemImage: "books.vertical") }
                console.tabItem { Label("高级命令", systemImage: "terminal") }
            }.disabled(model.busy)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).foregroundStyle(model.isError ? Color.red : Color.secondary).textSelection(.enabled)
            }.frame(minHeight: 32)
        }.padding(20).frame(width: 1080, height: 760)
        .interactiveDismissDisabled(model.busy)
        .alert(model.confirmTitle, isPresented: $model.showConfirm) {
            Button("执行", role: .destructive) { model.confirmed() }
            Button("取消", role: .cancel) { }
        } message: { Text(model.confirmDetail) }
    }
    private var target: some View {
        HStack {
            Toggle("当前显示的表盘", isOn: $model.useCurrent)
            TextField("表盘 ID", text: $model.clockID).textFieldStyle(.roundedBorder).frame(width: 110).disabled(model.useCurrent)
            Button("读取所选配置") { model.read("Device/GetLocalClockInfo", current: true) }
            Spacer()
        }
    }
    private var overview: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("设备信息") { model.read("Device/GetHardwareVersion") }
                    Button("设备字体") { model.read("Device/GetLocalFontList") }
                    Button("设备商店缓存") { model.read("Device/GetStoreClockMarketList") }
                }
                target
                Text("相册、部分系统表盘没有本地可编辑配置；商店缓存为空可能是设备尚未预取。")
                    .font(.caption).foregroundStyle(.secondary)
                result
            }
            VStack(spacing: 10) {
                if let data = model.snapshotData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 490)
                } else {
                    Image(systemName: "display").font(.system(size: 54)).frame(width: 240, height: 380).foregroundStyle(.secondary)
                }
                Button("获取设备截图") { model.capture() }
                Button("保存为 PNG…") { model.saveSnapshot() }.disabled(model.snapshotData == nil)
                Text("截图由固件生成，可能有缓存延迟。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(width: 250)
        }.padding(16)
    }
    private var editing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑槽位固定为 60000，与官方仓库一致。读取其他表盘用于参考；写入前重新读取 60000 并校验设备字体。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("读取 60000 到编辑器") { model.editManaged() }
                Button("最小时间模板") {
                    model.configurationText = (try? FrameCatalog.text("example-minimal.json")) ?? "{}"
                    model.asset = nil
                }
                Button("选择背景／tar.gz 素材包…") { model.chooseAsset() }
                Text(model.asset?.sourceName ?? "尚未选择素材").lineLimit(1)
            }
            HStack {
                Text("首次创建名称")
                TextField("本地表盘名称", text: $model.clockName).textFieldStyle(.roundedBorder).frame(width: 240)
                Spacer()
                Button("仅更新已有表盘…") {
                    model.confirm("更新表盘 60000？", detail: "将应用编辑器中的配置，可能替换现有元素和背景。已有其他表盘不会被改写。") { model.write(requireExisting: true) }
                }
                Button("创建／更新本地表盘…") {
                    model.confirm("写入本地表盘 60000？", detail: "不存在时会用完整配置和背景创建；已存在时更新该槽位。模板不包含图像素材，请先确认所选文件。") { model.write(requireExisting: false) }
                }
                Button("播放 60000…") {
                    model.confirm("播放本地表盘？", detail: "将切换设备当前显示，并覆盖当前时段的轮播选择。") {
                        model.run("播放本地表盘") { service in
                            _ = try await service.identify()
                            guard try await service.managed() != nil else { throw FrameError.message("请先创建本地表盘 60000。") }
                            for _ in 0..<2 { _ = try await service.api.command("Channel/SetClockSelectId", fields: ["ClockId": 60000]) }
                        }
                    }
                }
            }
            Text("完整配置使用 ItemList + ItemIdList；微调可使用 ItemPatchList／ItemPatchByRoleList，保留原 item_id。写入后在“设备与截图”查看回读结果。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.configurationText).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3))
        }.padding(16)
    }
    private var background: some View {
        VStack(alignment: .leading, spacing: 16) {
            target
            Button("选择背景图片／素材包…") { model.chooseAsset() }
            Text(model.asset.map { "\($0.sourceName) · \($0.data.count / 1024) KiB" } ?? "未选择背景")
            Text("普通图片会居中裁切为 800×1280 JPEG，并压缩至 500 KiB 以下。缓存背景替换只接受图片；tar.gz 素材包用于本地表盘创建和更新。")
                .foregroundStyle(.secondary)
            HStack {
                Button("替换所选表盘缓存背景…") {
                    model.confirm("替换缓存背景？", detail: "只替换所选表盘的缓存位图。不会上传到社区，也不改变相册；恢复云端版本可能覆盖此修改。") { model.replace() }
                }.disabled(model.asset == nil || model.asset?.bundle == true)
                Button("恢复指定表盘云端版本…") {
                    model.confirm("清除本地修改并恢复云端版本？", detail: "将先删除表盘 \(model.clockID) 的本地文件，再尝试从云端恢复。网络失败时可能暂时不可用，此操作不能保留本地修改；建议先读取并导出配置。") { model.reset() }
                }.disabled(model.useCurrent || Int(model.clockID) == nil)
            }
            result
        }.padding(16)
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("目录", selection: $model.catalogKind) {
                    ForEach(["模板", "表盘", "字体", "显示元素", "协议说明", "字体使用说明"], id: \.self) { Text($0) }
                }.frame(width: 220).onChange(of: model.catalogKind) { _ in model.loadCatalog() }
                TextField("按名称、ID、标签或场景搜索", text: $model.search).textFieldStyle(.roundedBorder)
                Button("模板载入草稿") { model.useTemplate() }.disabled(model.catalogKind != "模板" || model.selectedEntry == nil)
            }
            HStack {
                TextField("显示元素 disp", text: $model.dispInput).textFieldStyle(.roundedBorder).frame(width: 140)
                Button("生成布局建议") { model.suggestLayout() }
                Text("建议来自官方样本中位数，不会自动写入设备。第 60000 槽位的创建与编辑均在本地表盘页执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !model.entries.isEmpty {
                    List(model.entries.filter { model.search.isEmpty || $0.searchable.localizedCaseInsensitiveContains(model.search) }, selection: $model.selectedEntry) { entry in
                        Text(entry.title).tag(entry.id)
                    }.frame(width: 290).onChange(of: model.selectedEntry) { _ in model.inspectEntry() }
                }
                ScrollView { Text(model.catalogDetail).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Text("来源：DivoomDevelop/mcp-divoom-lan（MIT）。参考目录与真实设备安装内容可能不同。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级接口：向已连接设备发送 JSON 命令。参数不含 Command 和 ReturnCode；创建／修改表盘请使用专用页面。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Command，例如 Device/GetHardwareVersion", text: $model.rawCommand).textFieldStyle(.roundedBorder)
                Button("发送命令…") {
                    model.confirm("发送高级命令？", detail: "目标 \(model.ip):\(model.port)，命令 \(model.rawCommand)。写入命令可能改变设备状态或删除本地内容，请确认参数。") { model.raw() }
                }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("参数 JSON")
                    TextEditor(text: $model.rawFields).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3))
                }
                result
            }
        }.padding(16)
    }
    private var result: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("设备返回数据").font(.headline); Spacer()
                Button("导出 JSON…") { model.exportOutput() }.disabled(model.output.isEmpty)
            }
            ScrollView { Text(model.output.isEmpty ? "尚未读取。" : model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color.secondary.opacity(0.05))
        }
    }
}
