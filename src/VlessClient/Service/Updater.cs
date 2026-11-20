using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>Checks GitHub Releases and installs a newer MSI. Runs in the service (as SYSTEM), so no UAC prompt.</summary>
    public sealed class Updater
    {
        public static readonly Version CurrentVersion = typeof(Updater).Assembly.GetName().Version;

        private readonly object gate = new object();
        private string latestTag = "";
        private Version latest;
        private string msiUrl = "", msiSha256 = "", notes = "";
        private string status = "";      // "", checking, available, uptodate, downloading, installing, error
        private string error = "";
        private DateTime lastCheck = DateTime.MinValue;

        public JObj StatusJson()
        {
            lock (gate)
                return new JObj().Set("status", status).Set("error", error).Set("latest", latest?.ToString(3) ?? "")
                    .Set("notes", notes).Set("checked", lastCheck == DateTime.MinValue ? "" : lastCheck.ToString("s"));
        }

        private static HttpClient Http()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromMinutes(5) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("VlessClient/" + CurrentVersion.ToString(3));
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return http;
        }

        public async Task<string> CheckAsync()
        {
            lock (gate) { status = "checking"; error = ""; }
            try
            {
                using (var http = Http())
                {
                    var resp = await http.GetAsync($"https://api.github.com/repos/{Paths.GitHubRepo}/releases/latest").ConfigureAwait(false);
                    if (resp.StatusCode == HttpStatusCode.NotFound) throw new InvalidDataException("на GitHub пока нет опубликованных версий");
                    resp.EnsureSuccessStatusCode();
                    var text = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var j = Json.ParseObject(text);
                    var tag = j.Str("tag_name");
                    if (!Version.TryParse(tag.TrimStart('v', 'V').Split('-')[0], out var v)) throw new InvalidDataException("непонятная версия релиза: " + tag);
                    var asset = j.Objects("assets").FirstOrDefault(a => a.Str("name").EndsWith(".msi", StringComparison.OrdinalIgnoreCase));
                    if (asset == null) throw new InvalidDataException("в релизе " + tag + " нет установщика .msi");
                    var digest = asset.Str("digest");
                    if (!digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("у установщика нет контрольной суммы");
                    lock (gate)
                    {
                        latestTag = tag; latest = v; msiUrl = asset.Str("browser_download_url"); msiSha256 = digest.Substring(7).ToLowerInvariant();
                        notes = j.Str("body"); if (notes.Length > 2000) notes = notes.Substring(0, 2000);
                        lastCheck = DateTime.Now;
                        status = Newer(v) ? "available" : "uptodate";
                    }
                    Log.Write($"update: latest {tag}, current {CurrentVersion.ToString(3)}");
                    return null;
                }
            }
            catch (Exception e)
            {
                var m = "Не удалось проверить обновления: " + Engine.Flatten(e);
                lock (gate) { status = "error"; error = m; lastCheck = DateTime.Now; }
                Log.Write("update: " + m);
                return m;
            }
        }

        private static bool Newer(Version v) => new Version(v.Major, v.Minor, Math.Max(0, v.Build)) > new Version(CurrentVersion.Major, CurrentVersion.Minor, Math.Max(0, CurrentVersion.Build));

        public async Task<string> InstallAsync()
        {
            string url, sha, tag;
            lock (gate) { url = msiUrl; sha = msiSha256; tag = latestTag; }
            if (string.IsNullOrEmpty(url)) { var e = await CheckAsync().ConfigureAwait(false); if (e != null) return e; lock (gate) { url = msiUrl; sha = msiSha256; tag = latestTag; } }
            lock (gate) if (latest == null || !Newer(latest)) return "Установлена последняя версия.";
            if (!url.StartsWith("https://github.com/" + Paths.GitHubRepo + "/releases/download/", StringComparison.OrdinalIgnoreCase)) return "Подозрительная ссылка на установщик: " + url;
            lock (gate) { status = "downloading"; error = ""; }
            try
            {
                var dir = Path.Combine(Paths.DataDir, "updates");
                Directory.CreateDirectory(dir);
                foreach (var old in Directory.GetFiles(dir, "*.msi")) { try { File.Delete(old); } catch { } }
                var file = Path.Combine(dir, "VlessClient-" + tag + ".msi");
                using (var http = Http())
                using (var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                {
                    resp.EnsureSuccessStatusCode();
                    using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var dst = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None))
                        await src.CopyToAsync(dst).ConfigureAwait(false);
                }
                string actual;
                using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var h = SHA256.Create())
                {
                    actual = BitConverter.ToString(h.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
                    if (actual != sha) throw new InvalidDataException("контрольная сумма не совпала, установка отменена");
                    lock (gate) status = "installing";
                    Log.Write("update: installing " + file);
                    // msiexec stops this service, replaces the files and starts the service again.
                    var log = Path.Combine(Paths.LogsDir, "update-msi.log");
                    Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "msiexec.exe"),
                        $"/i \"{file}\" /qn /norestart /l*v \"{log}\"") { UseShellExecute = false, CreateNoWindow = true });
                }
                return null;
            }
            catch (Exception e)
            {
                var m = "Не удалось установить обновление: " + Engine.Flatten(e);
                lock (gate) { status = "error"; error = m; }
                Log.Write("update: " + m);
                return m;
            }
        }

        /// <summary>Called hourly when auto-update is on: checks at most twice a day and installs a newer version.</summary>
        public async Task AutoUpdateTickAsync()
        {
            DateTime last; lock (gate) last = lastCheck;
            if ((DateTime.Now - last).TotalHours < 12) return;
            if (await CheckAsync().ConfigureAwait(false) != null) return;
            bool available; lock (gate) available = status == "available";
            if (available) await InstallAsync().ConfigureAwait(false);
        }
    }
}
