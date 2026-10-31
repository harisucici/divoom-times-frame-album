import AppKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct LibraryAsset: Identifiable {
    let id: Int
    let asset: PHAsset
}

struct LibraryAlbum: Identifiable {
    let id: String
    let name: String
    let icon: String
    let section: String
    let collection: PHAssetCollection?
    var children: [LibraryAlbum]? = nil

    func descendant(withID id: String) -> LibraryAlbum? {
        if self.id == id { return self }
        return children?.compactMap { $0.descendant(withID: id) }.first
    }

    static func userHierarchy(_ collections: PHFetchResult<PHCollection>, visited: inout Set<String>) -> [LibraryAlbum] {
        var nodes: [LibraryAlbum] = []
        for index in 0..<collections.count {
            let item = collections.object(at: index)
            guard visited.insert(item.localIdentifier).inserted else { continue }
            if let folder = item as? PHCollectionList {
                let children = userHierarchy(PHCollection.fetchCollections(in: folder, options: nil), visited: &visited)
                nodes.append(LibraryAlbum(id: folder.localIdentifier, name: folder.localizedTitle ?? "未命名文件夹",
                    icon: "folder", section: "我的相册", collection: nil, children: children))
            } else if let album = item as? PHAssetCollection {
                nodes.append(LibraryAlbum(id: album.localIdentifier, name: album.localizedTitle ?? "未命名相册",
                    icon: "rectangle.stack", section: "我的相册", collection: album))
            }
        }
        return nodes
    }
}

@MainActor final class MacPhotoLibrary: ObservableObject {
    @Published var assets: [LibraryAsset] = []
    @Published var albums: [LibraryAlbum] = []
    @Published var selectedAlbumID = ""
    @Published var selectedIDs = Set<Int>()
    @Published var generation = UUID()
    @Published var loading = false
    @Published var message = ""
    @Published var needsPermission = false
    private var result: PHFetchResult<PHAsset>?
    private var folderAssets: [PHAsset]?
    var canLoadMore: Bool { assets.count < (folderAssets?.count ?? result?.count ?? 0) }
    var selectedAssets: [PHAsset] {
        assets.filter { selectedIDs.contains($0.id) }.map(\.asset)
    }

    func open() async {
        loading = true
        defer { loading = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            needsPermission = true
            message = "需要照片访问权限才能浏览和框选。请在系统设置 → 隐私与安全性 → 照片中允许此应用访问，然后点击重试。"
            return
        }
        needsPermission = false
        albums = [LibraryAlbum(id: "", name: "所有照片", icon: "photo.on.rectangle", section: "图库", collection: nil)]
        let smart: [(PHAssetCollectionSubtype, String, String, String)] = [
            (.smartAlbumRecentlyAdded, "最近添加", "clock", "图库"),
            (.smartAlbumFavorites, "个人收藏", "heart", "图库"),
            (.smartAlbumSelfPortraits, "自拍", "person.crop.square", "媒体类型"),
            (.smartAlbumLivePhotos, "实况照片", "livephoto", "媒体类型"),
            (.smartAlbumDepthEffect, "人像", "person.crop.rectangle", "媒体类型"),
            (.smartAlbumPanoramas, "全景照片", "pano", "媒体类型"),
            (.smartAlbumBursts, "连拍快照", "square.stack", "媒体类型"),
            (.smartAlbumScreenshots, "屏幕快照", "camera.viewfinder", "媒体类型"),
            (.smartAlbumAnimated, "动图", "photo.stack", "媒体类型"),
            (.smartAlbumLongExposures, "长曝光", "camera.aperture", "媒体类型"),
            (.smartAlbumRAW, "RAW", "camera", "媒体类型")
        ]
        for (subtype, name, icon, section) in smart {
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            collections.enumerateObjects { collection, _, _ in
                self.albums.append(LibraryAlbum(id: collection.localIdentifier, name: name,
                                               icon: icon, section: section, collection: collection))
            }
        }
        var visited = Set<String>()
        albums += LibraryAlbum.userHierarchy(PHCollection.fetchTopLevelUserCollections(with: nil), visited: &visited)
        let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        shared.enumerateObjects { collection, _, _ in
            self.albums.append(LibraryAlbum(id: collection.localIdentifier, name: collection.localizedTitle ?? "未命名相册",
                                           icon: "rectangle.stack", section: "共享相册", collection: collection))
        }
        selectAlbum()
    }

    var selectedAlbum: LibraryAlbum? {
        albums.compactMap { $0.descendant(withID: selectedAlbumID) }.first
    }

    func selectAlbum() {
        generation = UUID()
        selectedIDs.removeAll()
        assets = []
        result = nil
        folderAssets = nil
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if let folder = selectedAlbum, folder.children != nil {
            var unique: [String: PHAsset] = [:]
            func collect(_ node: LibraryAlbum) {
                if let collection = node.collection {
                    PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                        unique[asset.localIdentifier] = asset
                    }
                }
                node.children?.forEach(collect)
            }
            collect(folder)
            folderAssets = unique.values.sorted {
                if $0.creationDate == $1.creationDate { return $0.localIdentifier < $1.localIdentifier }
                return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        } else if let collection = selectedAlbum?.collection {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: .image, options: options)
        }
        loadMore()
        message = assets.isEmpty ? "这个相册没有可访问的照片。" : "点击单选，⌘+点击追加或取消；拖动框选，滚动后可继续累加框选。"
    }

    func loadMore() {
        let count = folderAssets?.count ?? result?.count ?? 0
        let end = min(assets.count + 200, count)
        guard assets.count < end else { return }
        assets += (assets.count..<end).compactMap { index in
            guard let asset = folderAssets?[index] ?? result?.object(at: index) else { return nil }
            return LibraryAsset(id: index, asset: asset)
        }
    }

    // Request the current rendition so edits and orientation from Photos are preserved.
    static func export(_ asset: PHAsset, to directory: URL, index: Int) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, _, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let data {
                    let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                    let url = directory.appendingPathComponent("照片-\(index + 1).\(ext)")
                    do {
                        try data.write(to: url, options: .atomic)
                        continuation.resume(returning: url)
                    } catch { continuation.resume(throwing: error) }
                } else {
                    continuation.resume(throwing: FrameError.message("无法读取第 \(index + 1) 张照片，请确认 iCloud 原图可以下载后重试。"))
                }
            }
        }
    }
}

struct LibrarySidebar: View {
    let albums: [LibraryAlbum]
    @Binding var selectedID: String

    var body: some View {
        List(selection: $selectedID) {
            ForEach(["图库", "媒体类型", "我的相册", "共享相册"], id: \.self) { section in
                let rows = albums.filter { $0.section == section }
                if !rows.isEmpty {
                    Section(section) {
                        OutlineGroup(rows, children: \.children) { album in
                            Label(album.name, systemImage: album.icon).tag(album.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct MacPhotoLibraryView: View {
    let maxSelection: Int
    let albumName: String
    let cancel: () -> Void
    let upload: ([PHAsset]) -> Void
    @StateObject private var library = MacPhotoLibrary()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("从 Mac 相册上传到“\(albumName)”").font(.headline)
                Spacer()
                Text("Mac 图库 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(library.message).foregroundStyle(.secondary)
            if library.loading { ProgressView("正在读取照片图库…") }
            if library.needsPermission {
                HStack {
                    Button("打开照片隐私设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("重试") { Task { await library.open() } }
                }
            }
            HStack(spacing: 0) {
                LibrarySidebar(albums: library.albums, selectedID: $library.selectedAlbumID)
                    .frame(width: 230)
                    .onChange(of: library.selectedAlbumID) { _ in library.selectAlbum() }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(library.selectedAlbum?.name ?? "所有照片")
                        .font(.headline).padding(.horizontal, 12)
                    NativeLibraryGrid(entries: library.assets.map { NativeLibraryEntry(id: $0.id, asset: $0.asset) },
                                      selectedIDs: $library.selectedIDs)
                        .id(library.generation)
                    if library.canLoadMore {
                        Button("加载更多照片") { library.loadMore() }.padding(.horizontal, 12)
                    }
                }
            }
            HStack {
                Text("已选 \(library.selectedIDs.count) 张 · 最多可上传 \(maxSelection) 张")
                    .foregroundStyle(library.selectedIDs.count > maxSelection ? Color.red : Color.secondary)
                Button("清空选择") { library.selectedIDs.removeAll() }
                    .disabled(library.selectedIDs.isEmpty)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("上传 \(library.selectedIDs.count) 张") { upload(library.selectedAssets) }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.selectedIDs.isEmpty || library.selectedIDs.count > maxSelection || library.loading)
            }
        }
        .padding(20)
        .frame(width: 1000, height: 680)
        .task { await library.open() }
    }
}

struct NativeLibraryEntry {
    let id: Int
    var asset: PHAsset? = nil
    var remoteURL: URL? = nil
}

// AppKit owns the entire pointer sequence; image content cannot intercept a drag.
struct NativeLibraryGrid: NSViewRepresentable {
    let entries: [NativeLibraryEntry]
    @Binding var selectedIDs: Set<Int>
    var deleteSelection: (() -> Void)? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> LibraryScrollView {
        let scroll = LibraryScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = LibraryGridCanvas()
        return scroll
    }

    func updateNSView(_ scroll: LibraryScrollView, context: Context) {
        guard let canvas = scroll.documentView as? LibraryGridCanvas else { return }
        canvas.updateEntries(entries)
        canvas.isEnabled = isEnabled
        canvas.deleteSelection = deleteSelection
        canvas.selection = selectedIDs
        canvas.selectionChanged = { selectedIDs = $0 }
        scroll.needsLayout = true
        canvas.needsDisplay = true
    }

    static func dismantleNSView(_ scroll: LibraryScrollView, coordinator: ()) {
        (scroll.documentView as? LibraryGridCanvas)?.cancelRequests()
    }
}

final class LibraryScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let canvas = documentView as? LibraryGridCanvas else { return }
        let width = contentSize.width
        let height = max(contentSize.height, canvas.contentHeight(for: width))
        if canvas.frame.size != CGSize(width: width, height: height) {
            canvas.setFrameSize(CGSize(width: width, height: height))
            canvas.needsDisplay = true
        }
    }
}

final class LibraryGridCanvas: NSView {
    var entries: [NativeLibraryEntry] = []
    var selection = Set<Int>()
    var isEnabled = true
    var deleteSelection: (() -> Void)?
    private var remoteTasks: [URL: URLSessionDataTask] = [:]
    func updateEntries(_ newEntries: [NativeLibraryEntry]) {
        let urls = Set(newEntries.compactMap(\.remoteURL))
        for url in Array(remoteTasks.keys) where !urls.contains(url) {
            remoteTasks.removeValue(forKey: url)?.cancel()
        }
        entries = newEntries
    }
    var selectionChanged: (Set<Int>) -> Void = { _ in }
    private let thumbnails = NSCache<NSString, NSImage>()
    private var requests: [String: PHImageRequestID] = [:]
    private var failedThumbnails = Set<String>()
    private var origin: CGPoint?
    private var beforeDrag = Set<Int>()
    private var commandAtMouseDown = false
    private var marquee: CGRect?
    private let tile: CGFloat = 142
    private let gap: CGFloat = 12
    private let inset: CGFloat = 16
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func columns(for width: CGFloat) -> Int { max(1, Int((width - inset * 2 + gap) / (tile + gap))) }
    func contentHeight(for width: CGFloat) -> CGFloat {
        let rows = (entries.count + columns(for: width) - 1) / columns(for: width)
        return inset * 2 + CGFloat(rows) * (tile + gap)
    }
    private func tileRect(_ index: Int) -> CGRect {
        let columns = columns(for: bounds.width)
        return CGRect(x: inset + CGFloat(index % columns) * (tile + gap),
                      y: inset + CGFloat(index / columns) * (tile + gap), width: tile, height: tile)
    }
    private func hit(_ point: CGPoint) -> Int? {
        let column = Int(floor((point.x - inset) / (tile + gap)))
        let row = Int(floor((point.y - inset) / (tile + gap)))
        let columns = columns(for: bounds.width)
        guard column >= 0, column < columns, row >= 0 else { return nil }
        let index = row * columns + column
        guard entries.indices.contains(index), tileRect(index).contains(point) else { return nil }
        return entries[index].id
    }
    private func publish(_ ids: Set<Int>) {
        selection = ids
        selectionChanged(ids)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        beforeDrag = selection
        commandAtMouseDown = event.modifierFlags.contains(.command)
        marquee = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard marquee != nil || hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        let rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        marquee = rect
        let intersecting = Set(entries.indices.filter { tileRect($0).intersects(rect) }.map { entries[$0].id })
        publish(beforeDrag.union(intersecting))
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        if marquee == nil {
            if let id = hit(origin) {
                if commandAtMouseDown {
                    var ids = beforeDrag
                    if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
                    publish(ids)
                } else { publish([id]) }
            } else if !commandAtMouseDown { publish([]) }
        }
        self.origin = nil
        marquee = nil
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            publish(Set(entries.map(\.id)))
        } else if event.keyCode == 51 || event.keyCode == 117 {
            if !selection.isEmpty { deleteSelection?() }
        } else if event.keyCode == 53, origin != nil { origin = nil; marquee = nil; publish(beforeDrag) }
        else { super.keyDown(with: event) }
    }
    func cancelRequests() {
        for request in requests.values { PHImageManager.default().cancelImageRequest(request) }
        requests.removeAll()
        remoteTasks.values.forEach { $0.cancel() }
        remoteTasks.removeAll()
    }
    private func remoteThumbnail(_ url: URL) -> NSImage? {
        let key = url.absoluteString as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        guard remoteTasks[url] == nil, !failedThumbnails.contains(url.absoluteString) else { return nil }
        thumbnails.countLimit = 400
        let task = FrameNetwork.localSession.dataTask(with: url) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, self.remoteTasks.removeValue(forKey: url) != nil else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let data, let image = NSImage(data: data) { self.thumbnails.setObject(image, forKey: key) }
                else { self.failedThumbnails.insert(url.absoluteString) }
                self.needsDisplay = true
            }
        }
        remoteTasks[url] = task
        task.resume()
        return nil
    }
    private func thumbnail(for asset: PHAsset) -> NSImage? {
        let key = asset.localIdentifier
        if let image = thumbnails.object(forKey: key as NSString) { return image }
        guard requests[key] == nil, !failedThumbnails.contains(key) else { return nil }
        thumbnails.countLimit = 400
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requests[key] = PHImageManager.default().requestImage(for: asset,
            targetSize: CGSize(width: 284, height: 284), contentMode: .aspectFill, options: options) { [weak self] image, info in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let image { self.thumbnails.setObject(image, forKey: key as NSString) }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        self.requests.removeValue(forKey: key)
                        if image == nil { self.failedThumbnails.insert(key) }
                    }
                    self.needsDisplay = true
                }
            }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        for index in entries.indices {
            let rect = tileRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            let entry = entries[index]
            let image = entry.asset.flatMap { thumbnail(for: $0) } ?? entry.remoteURL.flatMap { remoteThumbnail($0) }
            if let image {
                let size = image.size
                let side = min(size.width, size.height)
                let source = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let label = "照片 \(index + 1)" as NSString
                label.draw(at: CGPoint(x: rect.minX + 12, y: rect.midY - 7),
                           withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            }
            NSGraphicsContext.restoreGraphicsState()
            if selection.contains(entries[index].id) {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
                path.lineWidth = 4
                path.stroke()
            }
        }
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            marquee.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: marquee).stroke()
        }
    }
}
