using Microsoft.Win32;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace VlessClient
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            using (var theme = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            {
                if (theme?.GetValue("AppsUseLightTheme") is int light && light == 0)
                {
                    var colors = new Dictionary<string, string>
                    {
                        ["Background"] = "#111418", ["Panel"] = "#1A1E24", ["Control"] = "#252B33",
                        ["Border"] = "#2A3039", ["Text"] = "#E7EAEE", ["Muted"] = "#9CA7B6",
                        ["Accent"] = "#6B9BFF", ["AccentSoft"] = "#1D2B47", ["PrimaryText"] = "#101620",
                        ["Ok"] = "#4ADE80", ["OkSoft"] = "#153223", ["Danger"] = "#F87171", ["DangerSoft"] = "#3A1D1F"
                    };
                    foreach (var pair in colors)
                    {
                        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(pair.Value));
                        brush.Freeze();
                        Resources[pair.Key] = brush;
                    }
                }
            }
            base.OnStartup(e);
        }
    }
}
