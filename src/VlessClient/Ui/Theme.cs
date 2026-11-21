using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace VlessClient.Ui
{
    /// <summary>
    /// Colours of the window, taken from the web UI of the PowerShell edition. Dark is the default; the choice is stored per user.
    /// Every brush is a DynamicResource, so switching the theme repaints the open window at once.
    /// </summary>
    public static class Theme
    {
        private const string UserKey = @"Software\VlessClient";

        private static readonly Dictionary<string, string> DarkColors = new Dictionary<string, string>
        {
            ["Bg"] = "#111418", ["Panel"] = "#1A1E24", ["Text"] = "#E7EAEE", ["Muted"] = "#8D97A5", ["Line"] = "#2A3039",
            ["Accent"] = "#6B9BFF", ["AccentSoft"] = "#1D2B47", ["Ok"] = "#4ADE80", ["OkSoft"] = "#153223",
            ["Bad"] = "#F87171", ["BadSoft"] = "#3A1D1F", ["Warn"] = "#FBBF24", ["WarnSoft"] = "#3A2C10", ["Chip"] = "#252B33",
            ["Track"] = "#4A525E", ["Hover"] = "#1F242C", ["OnAccent"] = "#FFFFFF", ["Overlay"] = "#B3111418", ["Shadow"] = "#00000000",
        };

        private static readonly Dictionary<string, string> LightColors = new Dictionary<string, string>
        {
            ["Bg"] = "#F3F4F6", ["Panel"] = "#FFFFFF", ["Text"] = "#171A1F", ["Muted"] = "#68717D", ["Line"] = "#E2E5EA",
            ["Accent"] = "#2563EB", ["AccentSoft"] = "#E6EEFD", ["Ok"] = "#15803D", ["OkSoft"] = "#E3F4E8",
            ["Bad"] = "#C93434", ["BadSoft"] = "#FDE8E8", ["Warn"] = "#B45309", ["WarnSoft"] = "#FDF0D9", ["Chip"] = "#EEF0F4",
            ["Track"] = "#B6BCC6", ["Hover"] = "#F5F8FE", ["OnAccent"] = "#FFFFFF", ["Overlay"] = "#B3F3F4F6", ["Shadow"] = "#0F101828",
        };

        public static bool Dark
        {
            get
            {
                try { using (var k = Registry.CurrentUser.OpenSubKey(UserKey)) return !(k?.GetValue("Theme") is string v) || v != "light"; }
                catch { return true; }
            }
            set
            {
                try { using (var k = Registry.CurrentUser.CreateSubKey(UserKey)) k.SetValue("Theme", value ? "dark" : "light", RegistryValueKind.String); }
                catch { }
            }
        }

        /// <summary>Puts the theme's brushes into the application resources (call before the window is created, and on every switch).</summary>
        public static void Apply(bool dark)
        {
            var res = Application.Current.Resources;
            foreach (var kv in dark ? DarkColors : LightColors)
            {
                var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(kv.Value));
                b.Freeze();
                res[kv.Key] = b;
            }
            foreach (Window w in Application.Current.Windows) TitleBar(w, dark);
        }

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        /// <summary>Dark title bar on Windows 10 2004+ / 11 (attribute 20; 19 on older builds). Harmless where unsupported.</summary>
        public static void TitleBar(Window w, bool dark)
        {
            try
            {
                var hwnd = new WindowInteropHelper(w).Handle;
                if (hwnd == IntPtr.Zero) return;
                var v = dark ? 1 : 0;
                if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref v, 4);
            }
            catch { }
        }
    }
}
