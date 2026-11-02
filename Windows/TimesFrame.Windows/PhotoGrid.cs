using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
namespace TimesFrame.Windows;
public sealed class PhotoGrid : ListBox {
    Point? origin; object[] before = []; SelectionAdorner? adorner; bool dragging;
    public PhotoGrid() { SelectionMode = SelectionMode.Extended; }
    protected override void OnPreviewMouseLeftButtonDown(MouseButtonEventArgs e) { before = SelectedItems.Cast<object>().ToArray(); origin = e.GetPosition(this); dragging = false; base.OnPreviewMouseLeftButtonDown(e); }
    protected override void OnPreviewMouseMove(MouseEventArgs e) {
        if (origin is not Point start || e.LeftButton != MouseButtonState.Pressed) { base.OnPreviewMouseMove(e); return; }
        var point = e.GetPosition(this); if (!dragging && (point - start).Length < 5) return;
        if (!dragging) { dragging = true; CaptureMouse(); var layer = AdornerLayer.GetAdornerLayer(this); if (layer != null) { adorner = new SelectionAdorner(this); layer.Add(adorner); } }
        var rect = new Rect(start, point); SelectRectangle(rect, before);
        if (adorner != null) { adorner.Rectangle = rect; adorner.InvalidateVisual(); }
        var scroll = Find<ScrollViewer>(this);
        if (scroll != null) { var old = scroll.VerticalOffset; if (point.Y < 25) scroll.ScrollToVerticalOffset(old - 22); else if (point.Y > ActualHeight - 25) scroll.ScrollToVerticalOffset(old + 22); scroll.UpdateLayout(); origin = new Point(start.X, start.Y - (scroll.VerticalOffset - old)); }
        e.Handled = true;
    }
    public void SelectRectangle(Rect rectangle, IEnumerable<object> previous) {
        var selected = previous.ToHashSet();
        foreach (var item in Items) if (ItemContainerGenerator.ContainerFromItem(item) is FrameworkElement element && element.TransformToAncestor(this).TransformBounds(new Rect(element.RenderSize)).IntersectsWith(rectangle)) selected.Add(item);
        foreach (var item in SelectedItems.Cast<object>().Where(i => !selected.Contains(i)).ToArray()) SelectedItems.Remove(item);
        foreach (var item in selected.Where(i => !SelectedItems.Contains(i))) SelectedItems.Add(item);
    }
    protected override void OnPreviewMouseLeftButtonUp(MouseButtonEventArgs e) { if (dragging) { End(); e.Handled = true; } else End(); base.OnPreviewMouseLeftButtonUp(e); }
    protected override void OnLostMouseCapture(MouseEventArgs e) { End(); base.OnLostMouseCapture(e); }
    void End() { origin = null; dragging = false; if (adorner != null) { AdornerLayer.GetAdornerLayer(this)?.Remove(adorner); adorner = null; } if (IsMouseCaptured) ReleaseMouseCapture(); }
    protected override void OnPreviewKeyDown(KeyEventArgs e) { if (e.Key == Key.Escape && dragging) { SelectedItems.Clear(); foreach (var item in before) SelectedItems.Add(item); End(); e.Handled = true; } base.OnPreviewKeyDown(e); }
    static T? Find<T>(DependencyObject node) where T : DependencyObject { for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) { var child = VisualTreeHelper.GetChild(node,i); if (child is T found) return found; if (Find<T>(child) is T nested) return nested; } return null; }
    sealed class SelectionAdorner(UIElement element) : Adorner(element) {
        public Rect Rectangle;
        protected override void OnRender(DrawingContext context) { IsHitTestVisible = false; context.DrawRectangle(new SolidColorBrush(Color.FromArgb(35,30,100,220)), new Pen(Brushes.DodgerBlue,1), Rectangle); }
    }
}
