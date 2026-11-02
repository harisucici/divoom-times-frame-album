using System.Text.RegularExpressions;
using System.Text.Json.Nodes;
namespace TimesFrame.Core;
public sealed record DialAsset(byte[] Bytes, bool Bundle, string Name) {
    public static DialAsset Load(string path) {
        if (path.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".tgz", StringComparison.OrdinalIgnoreCase)) {
            var info = new FileInfo(path); if (info.Length > 100 * 1024 * 1024) throw new FrameException("素材包不能超过 100 MB。");
            var data = File.ReadAllBytes(path); if (data.Length < 3 || data[0] != 0x1f || data[1] != 0x8b) throw new FrameException("需要 gzip 素材包。"); return new(data, true, Path.GetFileName(path));
        }
        return new(ImageTools.Encode(path, true).Bytes, false, Path.GetFileName(path));
    }
}
public sealed class WatchfaceClient(FrameClient frame) {
    public const int ManagedId = 60000;
    static readonly HashSet<string> Allowed = ["DeviceImageUrl", "DevicePreviewImageUrl", "DevicePreviewImageUrl2", "SetColorList", "ItemList", "ItemIdList", "ItemPatchList", "ItemPatchByRoleList"];
    public async Task<JsonObject> Local(int? clockId = null, CancellationToken ct = default) => await frame.Command("Device/GetLocalClockInfo", clockId.HasValue ? new() { ["ClockId"] = clockId } : new() { ["UseCurrentDisplayClock"] = 1 }, ct);
    public async Task<JsonObject?> Managed(CancellationToken ct = default) {
        try { var value = await Local(ManagedId, ct); return value.Int("ClockId") == ManagedId && value["ItemList"] is JsonArray { Count: > 0 } ? value : null; }
        catch (DeviceException e) when (Regex.IsMatch(e.DeviceMessage, @"not\s*(?:found|exist)|missing|no\s+local\s+(?:sys\s+)?clock\s+file|不存在|未找到", RegexOptions.IgnoreCase)) { return null; }
    }
    public static JsonObject Configuration(JsonObject input, bool complete) {
        var informational = new HashSet<string> { "ClockId", "ClockName", "NameCn", "NameEn", "Command", "ReturnCode", "ReturnMessage", "DeviceType" };
        var unknown = input.Select(k => k.Key).Except(Allowed.Union(informational)).ToArray(); if (unknown.Length > 0) throw new FrameException("不支持的配置字段：" + string.Join(", ", unknown));
        var result = new JsonObject(); foreach (var field in input.Where(p => Allowed.Contains(p.Key))) result[field.Key] = field.Value?.DeepClone();
        if (result.Count == 0) throw new FrameException("没有表盘配置字段。");
        if (complete || result.ContainsKey("ItemList")) {
            if (result["ItemList"] is not JsonArray { Count: > 0 } items || result["ItemIdList"] is not JsonArray ids || ids.Count != items.Count) throw new FrameException("完整配置需要非空 ItemList 和对应的 ItemIdList。");
            var unique = new HashSet<string>();
            for (var i = 0; i < items.Count; i++) {
                if (items[i] is not JsonObject row || row["disp"] is not JsonValue d || !d.TryGetValue<int>(out _)) throw new FrameException("每个元素需要整数 disp。");
                var id = row.Str("item_id"); if (id.Length == 0 || !unique.Add(id) || ids[i]?.ToString() != id) throw new FrameException("item_id 必须唯一并与 ItemIdList 顺序一致。");
            }
        }
        result["ClockId"] = ManagedId; return result;
    }
    public static JsonObject Minimal(JsonObject body, JsonObject before) {
        if (body["ItemList"] is not JsonArray next || before["ItemList"] is not JsonArray old || old.Count != next.Count) return body;
        if (body.ContainsKey("ItemPatchList") || body.ContainsKey("ItemPatchByRoleList")) throw new FrameException("完整列表和局部补丁请选择一种。");
        var fields = new HashSet<string> { "size", "size_delta", "x", "y", "w", "h", "disp", "alig", "sep", "font", "image_id", "angle", "hier", "transp", "animation", "image_addr", "color_1", "color_2", "bundle_image" };
        var patches = new JsonArray();
        for (var i = 0; i < next.Count; i++) {
            var a = old[i]!.AsObject(); var b = next[i]!.AsObject(); if (a.Str("item_id") != b.Str("item_id")) throw new FrameException("请保留原 item_id，避免破坏菜单绑定。");
            var patch = new JsonObject(); foreach (var pair in b.Where(p => p.Key != "item_id" && !JsonNode.DeepEquals(p.Value, a[p.Key]))) { if (!fields.Contains(pair.Key)) throw new FrameException("字段不支持局部更新：" + pair.Key); patch[pair.Key] = pair.Value?.DeepClone(); }
            if (patch.Count > 0) patches.Add(new JsonObject { ["index"] = i, ["patch"] = patch });
        }
        body.Remove("ItemList"); body.Remove("ItemIdList"); if (patches.Count > 0) body["ItemPatchList"] = patches; return body;
    }
    public async Task<JsonObject> Upsert(JsonObject input, DialAsset? asset, string name, bool requireExisting, CancellationToken ct = default) {
        await frame.Identify(ct); var before = await Managed(ct); var creating = before == null;
        if (requireExisting && creating) throw new FrameException("60000 尚未创建，请用完整配置和背景创建。");
        var body = Configuration(input, creating); if (creating && asset == null) throw new FrameException("创建表盘需要背景或素材包。");
        if (before != null) body = Minimal(body, before);
        if (body["ItemPatchList"] is JsonArray patches) foreach (var p in patches.OfType<JsonObject>()) {
            var index = p.Int("index", -1); if (before?["ItemList"] is not JsonArray rows || index < 0 || index >= rows.Count || p["patch"] is not JsonObject { Count: > 0 }) throw new FrameException("补丁 index 越界或缺少 patch。");
        }
        var fonts = (await frame.Command("Device/GetLocalFontList", ct: ct)).Rows("FontList").Select(f => f.Int("id")).ToHashSet();
        void Check(JsonNode? node) {
            if (node is JsonObject obj) { if (obj.Int("font") > 0 && !fonts.Contains(obj.Int("font"))) throw new FrameException("设备尚未安装字体 " + obj.Int("font")); foreach (var p in obj) Check(p.Value); }
            else if (node is JsonArray a) foreach (var p in a) Check(p);
        }
        Check(body);
        var command = creating ? "Device/CreateLocalClock" : "Device/PatchLocalClockInfo";
        if (creating) { body["ClockName"] = string.IsNullOrWhiteSpace(name) ? "Windows 本地表盘" : name.Trim(); body["DialAssets"] = asset!.Bundle ? "bundle" : "image"; }
        if (asset != null) { body["Command"] = command; body["ReturnCode"] = 0; await Upload(creating ? "create_local_clock" : "patch_local_clock", body, asset, ct); }
        else await frame.Command(command, body, ct);
        var after = await Local(ManagedId, ct); if (after["ItemList"] is not JsonArray { Count: > 0 }) throw new FrameException("写入已接收，但回读配置为空，请重新读取。"); return after;
    }
    async Task<JsonObject> Upload(string route, JsonObject metadata, DialAsset asset, CancellationToken ct) {
        if (asset.Bytes.Length > 100 * 1024 * 1024) throw new FrameException("素材不能超过 100 MB。");
        var boundary = "DivoomWindows-" + Guid.NewGuid().ToString("N");
        return await frame.Post(route, FrameClient.Multipart(metadata, asset.Bytes, asset.Bundle ? "clock_bg.tar.gz" : "clock_bg.jpg", boundary, true), "multipart/form-data; boundary=" + boundary, ct, 90);
    }
    public async Task<JsonObject> Replace(DialAsset asset, int? id, CancellationToken ct = default) {
        await frame.Identify(ct); if (asset.Bundle || asset.Bytes.Length >= 500 * 1024) throw new FrameException("背景仅接受小于 500 KiB 的 800×1280 JPEG。");
        await Local(id, ct); var body = new JsonObject { ["Command"] = "Device/ReplaceClockDialBgFile", ["ReturnCode"] = 0 };
        if (id.HasValue) body["ClockId"] = id; else body["UseCurrentDisplayClock"] = 1; return await Upload("replace_clock_dial_bg", body, asset, ct);
    }
    public async Task<byte[]> Snapshot(CancellationToken ct = default) {
        await frame.Identify(ct); var result = await frame.Command("Device/GetScreenSnapshot", ct: ct); await Task.Delay(2000, ct);
        foreach (var path in new[] { result.Str("snapShotPath"), "/userdata/snapshot.webp", "/userdata/app_pic/snapshot.webp" }.Distinct()) {
            try { return ImageTools.Png(await frame.Download(path, ct)); } catch (Exception e) when (e is not OperationCanceledException) { }
        }
        throw new FrameException("设备尚未返回可解码截图，请稍后重试。固件截图可能存在缓存延迟。");
    }
}
