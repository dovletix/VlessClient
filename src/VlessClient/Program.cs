using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.ServiceProcess;
using System.Threading;
using VlessClient.Core;
using VlessClient.Service;
using VlessClient.Ui;

namespace VlessClient
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            var a = args.Select(x => x.ToLowerInvariant()).ToList();
            try
            {
                if (a.Contains("--service")) { ServiceBase.Run(new WinService()); return 0; }
                if (a.Contains("--console")) return RunConsole();
                if (a.Contains("--cleanup")) return Cleanup();
                var snap = a.IndexOf("--snapshot");
                if (snap >= 0 && snap + 1 < args.Length) return UiApp.Snapshot(args[snap + 1]);
                return UiApp.Run(a.Contains("--tray"));
            }
            catch (Exception e)
            {
                Log.Write("fatal: " + e);
                if (!a.Contains("--service") && !a.Contains("--cleanup") && !a.Contains("--snapshot"))
                    System.Windows.MessageBox.Show("VlessClient: " + e.Message, "VlessClient", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error);
                return 1;
            }
        }

        /// <summary>Development mode: the engine and the control pipe inside this process (no service install needed).</summary>
        private static int RunConsole()
        {
            var engine = new Engine();
            var pipe = new PipeServer(engine);
            pipe.Start();
            engine.Start();
            var stop = new ManualResetEvent(false);
            var stopFile = Path.Combine(Paths.DataDir, "console.stop");
            if (File.Exists(stopFile)) File.Delete(stopFile);
            while (!stop.WaitOne(500)) if (File.Exists(stopFile)) { File.Delete(stopFile); break; }
            pipe.Dispose();
            engine.Shutdown();
            return 0;
        }

        /// <summary>Run by the uninstaller (not on upgrade): removes settings, logs and anything the cores left behind.</summary>
        private static int Cleanup()
        {
            // ProxiFyre and its driver, if version 2.1.0 installed them (reads the marker before the data folder goes away)
            try { OldComponents.RemoveDetached(); } catch { }
            foreach (var name in new[] { "sing-box", "xray" })
                foreach (var p in Process.GetProcessesByName(name))
                {
                    try { if ((p.MainModule?.FileName ?? "").StartsWith(Paths.AppDir, StringComparison.OrdinalIgnoreCase)) p.Kill(); } catch { }
                    finally { p.Dispose(); }
                }
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VlessClient");
                if (Directory.Exists(dir)) Directory.Delete(dir, true);
            }
            catch { }
            return 0;
        }
    }
}
