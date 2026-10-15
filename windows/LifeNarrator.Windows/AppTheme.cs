using Avalonia.Markup.Xaml;
using Avalonia.Styling;

namespace LifeNarrator.Windows;

internal sealed class AppTheme : Styles
{
    public AppTheme() => AvaloniaXamlLoader.Load(this);
}
