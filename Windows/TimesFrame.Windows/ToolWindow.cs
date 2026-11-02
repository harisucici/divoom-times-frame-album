using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace TimesFrame.Windows;

public class ToolWindow : Window
{
    protected readonly TabControl Tabs = new();
    protected readonly TextBlock Status = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.DimGray, Margin = new Thickness(4, 8, 4, 4) };
    protected CancellationTokenSource? Operation; bool busy;
    protected ToolWindow(string title, double width = 1000, double height = 730)
    {
        Title = title;
        Width = width;
        Height = height;
        MinWidth = 760;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var dock = new DockPanel { Margin = new Thickness(16) };
        var footer = new DockPanel();
        var cancel = new Button { Content = "取消当前操作" };
        cancel.Click += (_, _) => Operation?.Cancel();
        DockPanel.SetDock(cancel, Dock.Right);
        footer.Children.Add(cancel);
        footer.Children.Add(Status);
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(footer);
        dock.Children.Add(Tabs);
        Content = dock;
        Closing += (_, _) => Operation?.Cancel();
    }
    protected async Task Run(string label, Func<CancellationToken, Task> work)
    {
        if (busy)
            return;
        busy = true;
        Tabs.IsEnabled = false;
        Status.Foreground = Brushes.DimGray;
        Status.Text = label + "…";
        Operation = new();
        try
        {
            await work(Operation.Token);
            Status.Text = label + "完成。";
        }
        catch (OperationCanceledException) { Status.Text = "操作已取消，已发送的写入请重新读取确认。"; }
        catch (Exception e) { Status.Foreground = Brushes.Firebrick; Status.Text = e.Message; }
        finally { Operation.Dispose(); Operation = null; busy = false; Tabs.IsEnabled = true; }
    }
    protected static StackPanel Row(params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        foreach (var child in children)
            p.Children.Add(child);
        return p;
    }
    protected static StackPanel Stack() => new() { Margin = new Thickness(14) };
    protected static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.DimGray, Margin = new Thickness(3, 6, 3, 8) };
    protected static Button Button(string label, Action click)
    {
        var button = new Button { Content = label };
        button.Click += (_, _) => click();
        return button;
    }
    protected static TextBox Field(string text, double width = 100) => new() { Text = text, Width = width, Margin = new Thickness(4, 0, 4, 0) };
    protected void Tab(string name, UIElement content, bool enabled = true) => Tabs.Items.Add(new TabItem { Header = name, Content = content, IsEnabled = enabled });
}
