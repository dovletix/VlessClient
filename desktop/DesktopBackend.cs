using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace VlessClient
{
    internal sealed class DesktopBackend : IDisposable
    {
        private readonly SemaphoreSlim gate = new SemaphoreSlim(1);
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
        private Process worker;
        private StreamWriter input;
        private bool disposed;

        public async Task<Reply> SendAsync(string action, object data)
        {
            await gate.WaitAsync();
            try
            {
                if (disposed) throw new ObjectDisposedException(nameof(DesktopBackend));
                if (worker == null || worker.HasExited)
                {
                    ReleaseWorker(false);
                    StartWorker();
                }

                await input.WriteLineAsync(json.Serialize(new { action, data }));
                await input.FlushAsync();
                var response = worker.StandardOutput.ReadLineAsync();
                using (var timeout = new CancellationTokenSource())
                {
                    if (await Task.WhenAny(response, Task.Delay(TimeSpan.FromSeconds(140), timeout.Token)) != response)
                        throw new TimeoutException("Время ожидания ответа клиента истекло.");
                    timeout.Cancel();
                }
                var line = await response;
                if (line == null) throw new IOException("Процесс управления завершился.");
                return json.Deserialize<Reply>(line);
            }
            catch
            {
                if (!disposed) ReleaseWorker(true);
                throw;
            }
            finally
            {
                if (disposed) ReleaseWorker(false);
                gate.Release();
            }
        }

        private void StartWorker()
        {
            var folder = AppDomain.CurrentDomain.BaseDirectory;
            if (!File.Exists(Path.Combine(folder, "vpn.ps1"))) folder = Environment.CurrentDirectory;
            var script = Path.Combine(folder, "vpn.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Файл vpn.ps1 отсутствует в папке клиента.");
            var powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var utf8 = new UTF8Encoding(false);
            worker = Process.Start(new ProcessStartInfo(powershell,
                $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{script}\" desktop-worker")
            {
                WorkingDirectory = folder,
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = utf8,
                StandardErrorEncoding = utf8
            });
            worker.BeginErrorReadLine();
            input = new StreamWriter(worker.StandardInput.BaseStream, utf8);
        }

        private void ReleaseWorker(bool terminate)
        {
            if (worker == null) return;
            try { input?.Dispose(); } catch (IOException) { }
            if (terminate)
            {
                try { if (!worker.HasExited) worker.Kill(); } catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
            worker.Dispose();
            worker = null;
            input = null;
        }

        public void Dispose()
        {
            disposed = true;
            if (!gate.Wait(0)) return;
            try { ReleaseWorker(false); }
            finally { gate.Release(); }
        }
    }

    internal sealed class Reply
    {
        public bool ok { get; set; }
        public string error { get; set; }
        public DesktopState state { get; set; }
        public bool configured { get; set; }
        public bool insecureTls { get; set; }
        public bool autostart { get; set; }
        public string mode { get; set; }
        public string @default { get; set; }
        public string node { get; set; }
        public Node[] nodes { get; set; }
        public string path { get; set; }
    }

    internal sealed class DesktopState
    {
        public ConnectionStatus status { get; set; }
        public AppRule[] apps { get; set; }
        public ProcessRow[] rows { get; set; }
        public DomainRules domains { get; set; }
        public bool configured { get; set; }
    }

    internal sealed class ConnectionStatus
    {
        public bool running { get; set; }
        public bool ready { get; set; }
        public bool tun { get; set; }
        public bool api { get; set; }
        public string mode { get; set; }
        public string node { get; set; }
        public string proxy { get; set; }
        public string error { get; set; }
    }

    internal sealed class AppRule
    {
        public string name { get; set; }
        public bool vpn { get; set; }
        public bool running { get; set; }
        public string[] processes { get; set; }
        public string Executables => string.Join(", ", processes);
        public string Route => vpn ? "Через VPN" : "Напрямую";
    }

    internal sealed class ProcessRow
    {
        public string key { get; set; }
        public string name { get; set; }
        public string path { get; set; }
        public string app { get; set; }
        public bool? vpn { get; set; }
        public int active { get; set; }
        public int total { get; set; }
        public int fail { get; set; }
        public int udp { get; set; }
        public long rDown { get; set; }
        public long rUp { get; set; }
        public long rP { get; set; }
        public long rD { get; set; }
        public long pBytes { get; set; }
        public long dBytes { get; set; }
        public Destination[] hosts { get; set; }
        public Failure[] fails { get; set; }
        public double DownRate => rDown * 8d / 1000000;
        public double UpRate => rUp * 8d / 1000000;
        public double TotalRate => DownRate + UpRate;
        public long TotalBytes => pBytes + dBytes;
        public string Speed => $"↓ {DownRate:F2}   ↑ {UpRate:F2}";
        public string Volume => MainWindow.FormatBytes(TotalBytes);
        public string Connections => $"{active} / {total}";
        public string TrafficByRoute => $"VPN {MainWindow.FormatBytes(pBytes)} · Прям. {MainWindow.FormatBytes(dBytes)}";
        public int ProblemCount => fail + udp;
        public string Problems => ProblemCount == 0 ? "—" : $"{fail} · UDP {udp}";
        public string Route => vpn == true ? "VPN" : vpn == false ? "Напрямую" : "Общий";
    }

    internal sealed class Destination
    {
        public string host { get; set; }
        public string @out { get; set; }
        public long up { get; set; }
        public long down { get; set; }
    }

    internal sealed class Failure
    {
        public string dest { get; set; }
        public string reason { get; set; }
        public bool udp { get; set; }
        public int n { get; set; }
    }

    internal sealed class DomainRules
    {
        public string[] direct { get; set; }
        public string[] proxy { get; set; }
    }

    internal sealed class Node
    {
        public int index { get; set; }
        public string name { get; set; }
    }
}
