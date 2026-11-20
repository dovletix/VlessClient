using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.ServiceProcess;
using System.Threading.Tasks;
using Microsoft.Win32;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>
    /// Version 2.1.0 had a "selected programs only" mode that installed ProxiFyre and the Windows Packet Filter driver on
    /// first use and recorded their product codes in components\installed-by-vlessclient.json. The mode is gone; this
    /// removes what it installed (only those products, never a copy the user installed).
    /// </summary>
    public static class OldComponents
    {
        private const string ProxiFyreService = "ProxiFyreService";
        private static string Dir => Path.Combine(Paths.DataDir, "components");
        private static string Marker => Path.Combine(Dir, "installed-by-vlessclient.json");

        /// <summary>Service start: stops ProxiFyre at once, uninstalls in the background (our own upgrade may still be running).</summary>
        public static void RemoveInBackground()
        {
            if (!File.Exists(Marker)) return;
            StopProxiFyre();
            Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(20000).ConfigureAwait(false);
                    var left = new List<string>();
                    foreach (var p in Ordered(Load()))
                    {
                        var code = -1;
                        for (var attempt = 0; attempt < 20; attempt++)
                        {
                            code = Run(Path.Combine(Environment.SystemDirectory, "msiexec.exe"), "/x " + p + " /qn /norestart");
                            if (code != 1618) break;   // another installation is running (the upgrade that started us)
                            await Task.Delay(30000).ConfigureAwait(false);
                        }
                        Log.Write($"old components: msiexec /x {p} -> {code}");
                        if (code != 0 && code != 1605 && code != 3010) left.Add(p);   // 1605: already gone, 3010: done, reboot later
                    }
                    if (left.Count == 0) { Directory.Delete(Dir, true); Log.Write("old components: ProxiFyre and its driver removed"); }
                    else Save(left);
                }
                catch (Exception e) { Log.Write("old components: " + e.Message); }
            });
        }

        /// <summary>Uninstall of VlessClient: msiexec cannot run inside our own uninstall transaction, so start it detached and delayed.</summary>
        public static void RemoveDetached()
        {
            if (!File.Exists(Marker)) return;
            StopProxiFyre();
            var products = Ordered(Load());
            if (products.Count == 0) return;
            var cmd = "ping -n 40 127.0.0.1 >nul";
            foreach (var p in products) cmd += " & msiexec /x " + p + " /qn /norestart";
            Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c " + cmd) { UseShellExecute = false, CreateNoWindow = true });
        }

        /// <summary>Stops ProxiFyre and keeps it from starting at boot: its config points programs at a port nobody listens on any more.</summary>
        private static void StopProxiFyre()
        {
            try
            {
                using (var sc = ServiceController.GetServices().FirstOrDefault(x => x.ServiceName.Equals(ProxiFyreService, StringComparison.OrdinalIgnoreCase)))
                {
                    if (sc == null) return;
                    if (sc.Status != ServiceControllerStatus.Stopped) { sc.Stop(); sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20)); }
                    Run(Path.Combine(Environment.SystemDirectory, "sc.exe"), "config " + ProxiFyreService + " start= disabled");
                }
            }
            catch (Exception e) { Log.Write("old components: cannot stop ProxiFyre: " + e.Message); }
        }

        /// <summary>ProxiFyre first (it depends on the driver), then the driver.</summary>
        private static List<string> Ordered(List<string> products)
        {
            var proxifyre = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (var root = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"))
                    if (root != null)
                        foreach (var sub in root.GetSubKeyNames())
                            using (var k = root.OpenSubKey(sub))
                                if ((k?.GetValue("DisplayName") as string ?? "").StartsWith("ProxiFyre", StringComparison.OrdinalIgnoreCase)) proxifyre.Add(sub);
            }
            catch { }
            return products.OrderBy(p => proxifyre.Contains(p) ? 0 : 1).ToList();
        }

        private static List<string> Load()
        {
            try { return Json.ParseObject(File.ReadAllText(Marker)).Strings("products").Where(p => p.StartsWith("{") && p.EndsWith("}")).ToList(); }
            catch { return new List<string>(); }
        }

        private static void Save(List<string> products) =>
            File.WriteAllText(Marker, Json.Serialize(new JObj().Set("products", products), true), Paths.Utf8);

        private static int Run(string exe, string args)
        {
            using (var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true }))
            {
                if (!p.WaitForExit(10 * 60 * 1000)) { try { p.Kill(); } catch { } return -1; }
                return p.ExitCode;
            }
        }
    }
}
