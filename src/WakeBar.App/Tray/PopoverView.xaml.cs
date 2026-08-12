using System.Windows;
using System.Windows.Controls;

namespace WakeBar.App.Tray;

public partial class PopoverView : UserControl
{
    public PopoverView()
    {
        InitializeComponent();
    }

    private void OnQuitClicked(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }
}
