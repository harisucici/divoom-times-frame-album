using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using TimesFrame.Core;
namespace TimesFrame.Windows;
public static class Ui {
    public static BitmapImage Image(byte[] data) { var image = new BitmapImage(); using var stream = new MemoryStream(ImageTools.Png(data)); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = stream; image.EndInit(); image.Freeze(); return image; }
    public static bool Confirm(Window owner, string text, string title = "确认操作") => MessageBox.Show(owner, text, title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
    public static string? Ask(Window owner, string title, string message, string initial = "") {
        var window = new Window { Owner = owner, Title = title, Width = 510, Height = 230, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var stack = new StackPanel { Margin = new Thickness(20) }; stack.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,0,0,12) });
        var text = new TextBox { Text = initial }; stack.Children.Add(text); var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0,16,0,0) };
        var ok = new Button { Content = "确定", IsDefault = true }; ok.Click += (_,_) => window.DialogResult = true;
        buttons.Children.Add(ok); buttons.Children.Add(new Button { Content = "取消", IsCancel = true }); stack.Children.Add(buttons); window.Content = stack; window.Loaded += (_,_) => { text.Focus(); text.SelectAll(); };
        return window.ShowDialog() == true ? text.Text : null;
    }
    public static TextBox Editor(string text = "") => new() { Text = text, AcceptsReturn = true, AcceptsTab = true, FontFamily = new FontFamily("Consolas"), HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.NoWrap };
}
