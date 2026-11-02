using SkiaSharp;
namespace TimesFrame.Core;
public static class ImageTools {
    public static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif" };
    public static string[] FolderImages(string folder) => Directory.EnumerateFiles(folder, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Hidden | FileAttributes.System }).Where(p => Extensions.Contains(Path.GetExtension(p))).Order(StringComparer.OrdinalIgnoreCase).ToArray();
    public static EncodedImage Encode(string path, bool background = false) {
        using var stream = File.OpenRead(path); using var codec = SKCodec.Create(stream) ?? throw new FrameException($"无法解码 {Path.GetFileName(path)}；请导出为 JPEG 或 PNG 后重试。");
        var sample = codec.GetScaledDimensions(Math.Min(1f, 4096f / Math.Max(codec.Info.Width, codec.Info.Height)));
        var info = new SKImageInfo(sample.Width, sample.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var source = new SKBitmap(info);
        if (codec.GetPixels(info, source.GetPixels()) != SKCodecResult.Success) throw new FrameException($"无法读取完整图片：{Path.GetFileName(path)}");
        var swap = codec.EncodedOrigin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var ow = swap ? info.Height : info.Width; var oh = swap ? info.Width : info.Height;
        var scale = background ? Math.Max(800d / ow, 1280d / oh) : Math.Min(1, 2048d / Math.Max(ow, oh));
        var width = background ? 800 : Math.Max(1, (int)Math.Round(ow * scale)); var height = background ? 1280 : Math.Max(1, (int)Math.Round(oh * scale));
        using var target = new SKBitmap(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque);
        using (var canvas = new SKCanvas(target)) {
            canvas.Clear(SKColors.White); canvas.Translate((float)((width - ow * scale) / 2), (float)((height - oh * scale) / 2)); canvas.Scale((float)scale);
            var w = info.Width; var h = info.Height;
            var matrix = codec.EncodedOrigin switch {
                SKEncodedOrigin.TopRight => Matrix(-1,0,w,0,1,0), SKEncodedOrigin.BottomRight => Matrix(-1,0,w,0,-1,h), SKEncodedOrigin.BottomLeft => Matrix(1,0,0,0,-1,h),
                SKEncodedOrigin.LeftTop => Matrix(0,1,0,1,0,0), SKEncodedOrigin.RightTop => Matrix(0,-1,h,1,0,0), SKEncodedOrigin.RightBottom => Matrix(0,-1,h,-1,0,w), SKEncodedOrigin.LeftBottom => Matrix(0,1,0,-1,0,w), _ => SKMatrix.Identity };
            canvas.Concat(in matrix); canvas.DrawBitmap(source, 0, 0);
        }
        using var image = SKImage.FromBitmap(target);
        foreach (var quality in background ? new[] { 90, 75, 55, 35, 15 } : new[] { 88 }) {
            using var data = image.Encode(SKEncodedImageFormat.Jpeg, quality);
            if (data != null && (!background || data.Size < 500 * 1024)) return new(data.ToArray(), width, height);
        }
        throw new FrameException("背景压缩后仍超过 500 KiB，请选择细节较少的图片。");
    }
    static SKMatrix Matrix(float sx, float kx, float tx, float ky, float sy, float ty) => new() { ScaleX = sx, SkewX = kx, TransX = tx, SkewY = ky, ScaleY = sy, TransY = ty, Persp2 = 1 };
    public static byte[] Png(byte[] bytes) {
        using var bitmap = SKBitmap.Decode(bytes) ?? throw new FrameException("设备图片无法解码。");
        using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Png, 100); return data.ToArray();
    }
}
