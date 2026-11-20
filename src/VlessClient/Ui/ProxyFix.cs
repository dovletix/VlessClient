using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace VlessClient.Ui
{
    /// <summary>
    /// Other VPN apps (Happ and alike) switch on the Windows proxy 127.0.0.1:port and leave it behind when they crash,
    /// after which no website opens. VlessClient never uses the Windows proxy, so a proxy that points to a closed local
    /// port is always such a leftover and is switched off.
    /// </summary>
    public static class ProxyFix
    {
        private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

        /// <summary>Returns the removed proxy address, or null when nothing was wrong.</summary>
        public static string FixDeadLocalProxy()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(Key, true))
                {
                    if (k == null || !(k.GetValue("ProxyEnable") is int en) || en == 0) return null;
                    var server = k.GetValue("ProxyServer") as string ?? "";
                    var m = Regex.Match(server, @"(?:^|[=;])(?:[a-z]+=)?(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})", RegexOptions.IgnoreCase);
                    if (!m.Success) return null;
                    var port = int.Parse(m.Groups[2].Value);
                    if (IsListening(port)) return null;   // the app that set it is alive
                    k.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
                    InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); // INTERNET_OPTION_SETTINGS_CHANGED
                    InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); // INTERNET_OPTION_REFRESH
                    return server;
                }
            }
            catch { return null; }
        }

        private static bool IsListening(int port)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var t = c.ConnectAsync(IPAddress.Loopback, port);
                    return t.Wait(700) && c.Connected;
                }
            }
            catch { return false; }
        }

        [DllImport("wininet.dll", SetLastError = true)]
        private static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
    }
}
