using System.IO;
using System.Windows;
namespace TimesFrame.Windows;
public partial class App : Application {
    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);
        if (e.Args.Contains("--self-test")) {
            try {
                var main = new MainWindow(); MainWindow = main; main.Show(); main.UpdateLayout();
                if (main.Width < 900 || ShutdownMode != ShutdownMode.OnMainWindowClose) throw new Exception("Invalid window lifecycle");
                var grid = new PhotoGrid(); if (grid.SelectionMode != System.Windows.Controls.SelectionMode.Extended) throw new Exception("Multi-selection disabled");
                // Exercise actual Windows WIC/WPF WebP-independent image rendering.
                using var bitmap = new SkiaSharp.SKBitmap(1,1);
                bitmap.Erase(SkiaSharp.SKColors.Red);
                using var image = SkiaSharp.SKImage.FromBitmap(bitmap);
                using var data = image.Encode(SkiaSharp.SKEncodedImageFormat.Png,100);
                if (Ui.Image(data.ToArray()).PixelWidth != 1) throw new Exception("Image decoding failed");
                var actual = (PhotoGrid)main.FindName("Photos");
                actual.ItemsSource = Enumerable.Range(1,12).Select(i => new PhotoCard(new TimesFrame.Core.Photo(i,"","","photo"))).ToArray();
                main.UpdateLayout();
                var first = (System.Windows.FrameworkElement)actual.ItemContainerGenerator.ContainerFromIndex(0);
                var box = first.TransformToAncestor(actual).TransformBounds(new Rect(first.RenderSize));
                actual.SelectRectangle(box, []);
                if (actual.SelectedItems.Count == 0) throw new Exception("Marquee selection failed");
                var before = actual.SelectedItems.Cast<object>().ToArray();
                var next = (System.Windows.FrameworkElement)actual.ItemContainerGenerator.ContainerFromIndex(5);
                actual.SelectRectangle(next.TransformToAncestor(actual).TransformBounds(new Rect(next.RenderSize)), before);
                if (!before.All(actual.SelectedItems.Contains) || actual.SelectedItems.Count < 2) throw new Exception("Cumulative marquee failed");
                new SettingsWindow(null,null).Close();
                var visual = (System.Windows.Media.Visual)main.Content;
                var element = (FrameworkElement)main.Content;
                var render = new System.Windows.Media.Imaging.RenderTargetBitmap((int)element.ActualWidth,(int)element.ActualHeight,96,96,System.Windows.Media.PixelFormats.Pbgra32);
                render.Render(visual);
                var png = new System.Windows.Media.Imaging.PngBitmapEncoder();
                png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(render));
                using (var file = File.Create("windows-smoke.png")) png.Save(file);
                main.Close(); Environment.ExitCode = 0;
            } catch (Exception ex) { File.WriteAllText("windows-smoke-error.txt", ex.ToString()); Shutdown(1); }
            return;
        }
        var window = new MainWindow(); MainWindow = window; window.Show();
    }
}
