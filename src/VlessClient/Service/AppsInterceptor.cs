using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.ServiceProcess;
using System.Threading.Tasks;
using Microsoft.Win32;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>
    /// "Selected programs only" mode: ProxiFyre (wiresock, on the Windows Packet Filter driver) catches the TCP/UDP traffic of the
    /// chosen exe files and sends it to our sing-box SOCKS inbound; everything else on the PC is not touched at all.
    /// The components are third-party products: they are downloaded from their official GitHub releases on first use
    /// (pinned versions, SHA-256 checked), installed silently, and removed again when VlessClient is uninstalled.
    /// </summary>
    public sealed class AppsInterceptor
    {
        public const string ServiceName = "ProxiFyreService";
        private const string DriverService = "NDISRD";

        private const string DriverUrl = "https://github.com/wiresock/ndisapi/releases/download/v3.6.2/Windows.Packet.Filter.3.6.2.1.x64.msi";
        private const string DriverSha256 = "9c388c0b7f189f7fa98720bae2caecf7d64f30910838b80b438ecf8956b8502c";
        private const string ProxiFyreUrl = "https://github.com/wiresock/proxifyre/releases/download/v2.7.0/ProxiFyre-2.7.0-win-x64.msi";
        private const string ProxiFyreSha256 = "8238b1a14eab067bee1223440117b9245a8dbd052d59666f5a6af499aead76ac";
        private const string VcRedistUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe";   // Microsoft's permalink; checked by its Microsoft signature
        private static readonly Version VcMinimum = new Version(14, 44, 35211, 0);

        private static string ComponentsDir { get { var d = Path.Combine(Paths.DataDir, "components"); Directory.CreateDirectory(d); return d; } }
        private static string MarkerFile => Path.Combine(ComponentsDir, "installed-by-vlessclient.json");

        public string LastError { get; private set; } = "";
        public bool Running { get; private set; }
        public int AppCount { get; private set; }

        // ------------------------------------------------------------------ start / stop

        /// <summary>Installs what is missing, writes the ProxiFyre config and (re)starts its service. Returns null or an error text.</summary>
        public async Task<string> StartAsync(Settings s, Action<string> progress)
        {
            try
            {
                var err = await EnsureInstalledAsync(s, progress).ConfigureAwait(false);
                if (err != null) return Fail(err);
                return Apply(s);
            }
            catch (Exception e) { return Fail("перехват программ не включился: " + Engine.Flatten(e)); }
        }

        /// <summary>Rewrites the list of programs and restarts ProxiFyre (selected programs reconnect).</summary>
        public string Apply(Settings s)
        {
            try
            {
                var dir = InstallDir();
                if (dir == null) return Fail("ProxiFyre не установлен");
                var apps = s.Apps.Where(a => a.Vpn).SelectMany(a => a.Processes).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                AppCount = apps.Count;
                if (apps.Count == 0)
                {
                    Stop();
                    Log.Write("apps mode: no program has the VPN rule, ProxiFyre stopped");
                    LastError = "";
                    return null;
                }
                var cfg = new JObj()
                    .Set("logLevel", "Error")
                    .Set("bypassLan", true)
                    .Set("proxies", new List<object>
                    {
                        new JObj().Set("id", "vlessclient").Set("appNames", apps)
                            .Set("socks5ProxyEndpoint", "127.0.0.1:" + s.AppsPort)
                            .Set("socks5Transport", "TCP")
                            .Set("supportedProtocols", new List<object> { "TCP", "UDP" })
                            // IPv4 only: IPv6 of the selected programs is blocked by ProxiFyre (they fall back to IPv4) instead of leaking past the VPN
                            .Set("supportedAddressFamilies", new List<object> { "IPv4" }),
                    })
                    // never catch the VPN's own carrier processes, or the tunnel would depend on itself
                    .Set("excludes", new List<object> { Paths.XrayExe, Paths.SingBoxExe, Path.Combine(Paths.AppDir, "VlessClient.exe") })
                    .Set("dns", new JObj().Set("mode", "Direct").Set("proxyId", null).Set("serverOverride", null));
                var file = Path.Combine(dir, "app-config.json");
                var text = Json.Serialize(cfg, true) + "\n";
                File.WriteAllText(file, text, Paths.Utf8);
                RestartService();
                Running = true; LastError = "";
                Log.Write("apps mode: ProxiFyre started for " + string.Join(", ", apps));
                return null;
            }
            catch (Exception e) { return Fail("не удалось запустить ProxiFyre: " + Engine.Flatten(e)); }
        }

        /// <summary>Stops ProxiFyre: all programs go direct again. Safe to call any time.</summary>
        public void Stop()
        {
            Running = false;
            try
            {
                using (var sc = Find(ServiceName))
                {
                    if (sc == null || sc.Status == ServiceControllerStatus.Stopped) return;
                    sc.Stop();
                    sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
                }
            }
            catch (Exception e) { Log.Write("apps mode: cannot stop ProxiFyre: " + e.Message); }
        }

        private string Fail(string e) { LastError = e; Running = false; Log.Write("apps mode: " + e); return e; }

        private static ServiceController Find(string name) =>
            ServiceController.GetServices().FirstOrDefault(x => x.ServiceName.Equals(name, StringComparison.OrdinalIgnoreCase));

        private static void RestartService()
        {
            using (var sc = Find(ServiceName) ?? throw new InvalidOperationException("служба " + ServiceName + " не найдена"))
            {
                if (sc.Status != ServiceControllerStatus.Stopped)
                {
                    sc.Stop();
                    sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
                }
                sc.Start();
                sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20));
            }
        }

        // ------------------------------------------------------------------ installation

        public static bool IsInstalled => InstallDir() != null && DriverInstalled();

        /// <summary>Kernel drivers are not in the list of Win32 services, so look at the registration itself.</summary>
        private static bool DriverInstalled()
        {
            try { using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + DriverService)) return k?.GetValue("ImagePath") != null; }
            catch { return false; }
        }

        /// <summary>ProxiFyre's folder, from its service registration.</summary>
        private static string InstallDir()
        {
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + ServiceName))
                {
                    var image = (k?.GetValue("ImagePath") as string ?? "").Trim();
                    if (image.Length == 0) return null;
                    if (image.StartsWith("\"")) image = image.Substring(1, image.IndexOf('"', 1) - 1);
                    else if (image.IndexOf(".exe", StringComparison.OrdinalIgnoreCase) > 0) image = image.Substring(0, image.IndexOf(".exe", StringComparison.OrdinalIgnoreCase) + 4);
                    var dir = Path.GetDirectoryName(image);
                    return dir != null && Directory.Exists(dir) ? dir : null;
                }
            }
            catch { return null; }
        }

        private async Task<string> EnsureInstalledAsync(Settings s, Action<string> progress)
        {
            if (!Engine.IsElevated) return "для этого режима служба VlessClient должна работать с правами системы";
            var marker = LoadMarker();

            if (!VcRuntimeOk())
            {
                progress("Устанавливаю среду Microsoft Visual C++…");
                var file = await DownloadAsync(s, VcRedistUrl, "vc_redist.x64.exe", null).ConfigureAwait(false);
                if (!SignedByMicrosoft(file)) return "загруженный установщик Visual C++ не подписан Microsoft — установка отменена";
                var code = Run(file, "/install /quiet /norestart");
                if (code != 0 && code != 3010 && code != 1638) return "установщик Visual C++ завершился с кодом " + code;
                if (!VcRuntimeOk() && code != 3010) return "среда Visual C++ не установилась";
            }

            if (!DriverInstalled())
            {
                progress("Устанавливаю драйвер Windows Packet Filter…");
                var file = await DownloadAsync(s, DriverUrl, "Windows.Packet.Filter.x64.msi", DriverSha256).ConfigureAwait(false);
                var before = ProductCodes("Windows Packet Filter");
                var code = Msi("/i \"" + file + "\"", "wpf-install.log");
                if (code != 0 && code != 3010) return "драйвер Windows Packet Filter не установился (код " + code + ")";
                marker.AddRange(ProductCodes("Windows Packet Filter").Except(before));
                SaveMarker(marker);
                if (!DriverInstalled()) return "драйвер Windows Packet Filter не появился в системе" + (code == 3010 ? " — нужна перезагрузка компьютера" : "");
            }

            if (InstallDir() == null)
            {
                progress("Устанавливаю ProxiFyre…");
                var file = await DownloadAsync(s, ProxiFyreUrl, "ProxiFyre-x64.msi", ProxiFyreSha256).ConfigureAwait(false);
                var before = ProductCodes("ProxiFyre");
                // The standalone MSI re-checks the Visual C++ files with AppSearch, which misses ucrtbase.dll on some Windows builds.
                // VcRuntimeOk() above has already checked the same files and version floors, so pass the markers ProxiFyre's own
                // setup bundle passes (documented in its docs/installer.md; they skip only that diagnostic launch condition).
                var code = Msi("/i \"" + file + "\" BURNMSIINSTALL=1 PROXIFYRE_SETUP_CHAIN=1", "proxifyre-install.log");
                if (code != 0 && code != 3010) return "ProxiFyre не установился (код " + code + "), журнал: logs\\proxifyre-install.log";
                marker.AddRange(ProductCodes("ProxiFyre").Except(before));
                SaveMarker(marker);
                if (InstallDir() == null) return "ProxiFyre установился, но его служба не найдена";
            }
            return null;
        }

        /// <summary>Downloads through our own local proxy: works on networks where GitHub is blocked.</summary>
        private static async Task<string> DownloadAsync(Settings s, string url, string name, string sha256)
        {
            var file = Path.Combine(ComponentsDir, name);
            var handler = new HttpClientHandler { Proxy = new WebProxy("http://127.0.0.1:" + s.ProxyPort), UseProxy = true };
            using (var http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(5) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("VlessClient/" + Updater.CurrentVersion.ToString(3));
                using (var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                {
                    resp.EnsureSuccessStatusCode();
                    using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var dst = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None))
                        await src.CopyToAsync(dst).ConfigureAwait(false);
                }
            }
            if (sha256 != null)
            {
                string actual;
                using (var fs = File.OpenRead(file)) using (var h = SHA256.Create()) actual = BitConverter.ToString(h.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
                if (actual != sha256) { File.Delete(file); throw new InvalidDataException("контрольная сумма " + name + " не совпала, файл удалён"); }
            }
            return file;
        }

        private static int Msi(string args, string log) =>
            Run(Path.Combine(Environment.SystemDirectory, "msiexec.exe"), args + " /qn /norestart /l*v \"" + Path.Combine(Paths.LogsDir, log) + "\"");

        private static int Run(string exe, string args)
        {
            using (var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true }))
            {
                if (!p.WaitForExit(15 * 60 * 1000)) { try { p.Kill(); } catch { } return -1; }
                return p.ExitCode;
            }
        }

/// <summary>The same native files and version floors that ProxiFyre's installer requires (checked on the files themselves).</summary>
        private static bool VcRuntimeOk()
        {
            try
            {
                var sys = Environment.SystemDirectory;   // a 64-bit process: the real System32
                foreach (var f in new[] { "msvcp140.dll", "msvcp140_atomic_wait.dll", "vcruntime140.dll", "vcruntime140_1.dll" })
                    if (FileVer(Path.Combine(sys, f)) < VcMinimum) return false;
                return FileVer(Path.Combine(sys, "ucrtbase.dll")) >= new Version(10, 0, 10240, 0);
            }
            catch { return false; }
        }

        private static Version FileVer(string path)
        {
            if (!File.Exists(path)) return new Version(0, 0);
            var v = FileVersionInfo.GetVersionInfo(path);
            return new Version(v.FileMajorPart, v.FileMinorPart, v.FileBuildPart, v.FilePrivatePart);
        }

        private static List<string> ProductCodes(string displayNamePrefix)
        {
            var res = new List<string>();
            using (var root = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"))
            {
                if (root == null) return res;
                foreach (var sub in root.GetSubKeyNames())
                    using (var k = root.OpenSubKey(sub))
                        if ((k?.GetValue("DisplayName") as string ?? "").StartsWith(displayNamePrefix, StringComparison.OrdinalIgnoreCase) && sub.StartsWith("{"))
                            res.Add(sub);
            }
            return res;
        }

        private static List<string> LoadMarker()
        {
            try { return File.Exists(MarkerFile) ? Json.ParseObject(File.ReadAllText(MarkerFile)).Strings("products") : new List<string>(); }
            catch { return new List<string>(); }
        }

        private static void SaveMarker(List<string> products) =>
            File.WriteAllText(MarkerFile, Json.Serialize(new JObj().Set("products", products.Distinct().ToList()), true), Paths.Utf8);

        // ------------------------------------------------------------------ uninstall (called by VlessClient's uninstaller)

        /// <summary>
        /// Stops ProxiFyre and removes the products VlessClient installed itself. msiexec cannot run inside our own uninstall
        /// transaction, so the removal is started detached and waits until that transaction is over.
        /// </summary>
        public static void UninstallComponentsDetached()
        {
            try
            {
                using (var sc = Find(ServiceName))
                    if (sc != null && sc.Status != ServiceControllerStatus.Stopped) { sc.Stop(); sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20)); }
            }
            catch { }
            var products = LoadMarker();
            if (products.Count == 0) return;
            // ProxiFyre first (it depends on the driver), then the driver
            var ordered = products.OrderBy(p => ProductCodes("ProxiFyre").Contains(p) ? 0 : 1).ToList();
            var cmd = "ping -n 40 127.0.0.1 >nul";
            foreach (var p in ordered) cmd += " & msiexec /x " + p + " /qn /norestart";
            Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c " + cmd) { UseShellExecute = false, CreateNoWindow = true });
        }

        // ------------------------------------------------------------------ signature check for the Visual C++ download

        private static bool SignedByMicrosoft(string file)
        {
            try
            {
                var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(file));
                if (cert.Subject.IndexOf("O=Microsoft Corporation", StringComparison.OrdinalIgnoreCase) < 0) return false;
                return WinVerifyTrust(file);
            }
            catch { return false; }
        }

        private static bool WinVerifyTrust(string file)
        {
            var fileInfo = new WINTRUST_FILE_INFO { cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)), pcwszFilePath = file };
            var pFile = Marshal.AllocHGlobal(Marshal.SizeOf(fileInfo));
            try
            {
                Marshal.StructureToPtr(fileInfo, pFile, false);
                var data = new WINTRUST_DATA
                {
                    cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_DATA)), dwUIChoice = 2 /* WTD_UI_NONE */, fdwRevocationChecks = 0,
                    dwUnionChoice = 1 /* WTD_CHOICE_FILE */, pFile = pFile, dwStateAction = 0, dwProvFlags = 0x10 /* WTD_CACHE_ONLY_URL_RETRIEVAL */,
                };
                var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
                return WinVerifyTrustNative(IntPtr.Zero, ref action, ref data) == 0;
            }
            finally { Marshal.FreeHGlobal(pFile); }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WINTRUST_FILE_INFO { public uint cbStruct; public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }

        [StructLayout(LayoutKind.Sequential)]
        private struct WINTRUST_DATA
        {
            public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice; public uint fdwRevocationChecks;
            public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction; public IntPtr hWVTStateData; public IntPtr pwszURLReference;
            public uint dwProvFlags; public uint dwUIContext; public IntPtr pSignatureSettings;
        }

        [DllImport("wintrust.dll", EntryPoint = "WinVerifyTrust", CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrustNative(IntPtr hwnd, ref Guid action, ref WINTRUST_DATA data);
    }
}
