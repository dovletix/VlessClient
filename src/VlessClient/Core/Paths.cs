using System;
using System.IO;
using System.Text;

namespace VlessClient.Core
{
    public static class Paths
    {
        public const string ServiceName = "VlessClient";
        /// <summary>The control pipe. VLESSCLIENT_PIPE overrides it for development, so that a --console engine and a window
        /// started with the same variable never meet the installed service (or its tray window).</summary>
        public static string PipeName
        {
            get
            {
                var env = Environment.GetEnvironmentVariable("VLESSCLIENT_PIPE");
                return string.IsNullOrWhiteSpace(env) ? "VlessClient.Control.v2" : env.Trim();
            }
        }
        public const string GitHubRepo = "dovletix/VlessClient";

        /// <summary>Folder of VlessClient.exe (Program Files\VlessClient when installed).</summary>
        public static string AppDir => AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');

        /// <summary>Cores: bin next to the exe. VLESSCLIENT_BIN overrides it for development.</summary>
        public static string BinDir
        {
            get
            {
                var env = Environment.GetEnvironmentVariable("VLESSCLIENT_BIN");
                return string.IsNullOrEmpty(env) ? Path.Combine(AppDir, "bin") : env;
            }
        }

        /// <summary>Machine-wide data: C:\ProgramData\VlessClient. VLESSCLIENT_DATA overrides it for development.</summary>
        public static string DataDir
        {
            get
            {
                var env = Environment.GetEnvironmentVariable("VLESSCLIENT_DATA");
                var dir = string.IsNullOrEmpty(env)
                    ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VlessClient")
                    : env;
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static string SettingsFile => Path.Combine(DataDir, "settings.json");
        public static string RuntimeDir => Ensure(Path.Combine(DataDir, "runtime"));
        public static string RulesDir => Ensure(Path.Combine(RuntimeDir, "rules"));
        public static string LogsDir => Ensure(Path.Combine(DataDir, "logs"));
        public static string SubscriptionCache => Path.Combine(RuntimeDir, "subscription.txt");
        public static string XrayExe => Path.Combine(BinDir, "xray.exe");
        public static string SingBoxExe => Path.Combine(BinDir, "sing-box.exe");

        private static string Ensure(string dir) { Directory.CreateDirectory(dir); return dir; }

        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
    }

    public static class Log
    {
        private static readonly object Gate = new object();

        public static void Write(string message)
        {
            try
            {
                lock (Gate)
                {
                    var file = Path.Combine(Paths.LogsDir, "service.log");
                    if (File.Exists(file) && new FileInfo(file).Length > 2 * 1024 * 1024)
                    {
                        var old = file + ".old";
                        if (File.Exists(old)) File.Delete(old);
                        File.Move(file, old);
                    }
                    File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + message + "\r\n", Paths.Utf8);
                }
            }
            catch { }
        }

        public static string Tail(string fileName, int lines)
        {
            try
            {
                var file = Path.Combine(Paths.LogsDir, fileName);
                if (!File.Exists(file)) return "";
                using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var len = (int)Math.Min(fs.Length, 256 * 1024);
                    fs.Seek(-len, SeekOrigin.End);
                    var buf = new byte[len];
                    var n = fs.Read(buf, 0, len);
                    var text = Encoding.UTF8.GetString(buf, 0, n);
                    var all = text.Replace("\r", "").Split('\n');
                    var start = Math.Max(0, all.Length - lines - 1);
                    return string.Join("\r\n", all, start, all.Length - start);
                }
            }
            catch (Exception e) { return "(cannot read " + fileName + ": " + e.Message + ")"; }
        }
    }
}
