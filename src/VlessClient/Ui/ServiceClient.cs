using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Ui
{
    /// <summary>Talks to the service over the named pipe. Thread-safe; reconnects on demand.</summary>
    public sealed class ServiceClient : IDisposable
    {
        private readonly SemaphoreSlim gate = new SemaphoreSlim(1);
        private NamedPipeClientStream pipe;
        private StreamReader reader;
        private StreamWriter writer;

        public async Task<Dictionary<string, object>> SendAsync(JObj request, int timeoutMs = 15000)
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                Exception last = null;
                for (var attempt = 0; attempt < 2; attempt++)
                {
                    try
                    {
                        if (pipe == null || !pipe.IsConnected)
                        {
                            Drop();
                            pipe = new NamedPipeClientStream(".", Paths.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                            pipe.Connect(1500);
                            reader = new StreamReader(pipe, Paths.Utf8, false, 4096, true);
                            writer = new StreamWriter(pipe, Paths.Utf8, 4096, true) { AutoFlush = true, NewLine = "\n" };
                        }
                        await writer.WriteLineAsync(Json.Serialize(request)).ConfigureAwait(false);
                        var read = reader.ReadLineAsync();
                        if (await Task.WhenAny(read, Task.Delay(timeoutMs)).ConfigureAwait(false) != read)
                        {
                            Drop();
                            throw new IOException("Служба VlessClient не ответила вовремя.");
                        }
                        var line = await read.ConfigureAwait(false);
                        if (line == null) throw new IOException("Служба закрыла соединение.");
                        return Json.ParseObject(line);
                    }
                    catch (Exception e) when (e is IOException || e is TimeoutException || e is ObjectDisposedException || e is InvalidOperationException)
                    {
                        last = e;
                        Drop();
                    }
                }
                throw new IOException("Нет связи со службой VlessClient.", last);
            }
            finally { gate.Release(); }
        }

        public static JObj Cmd(string name) => new JObj().Set("cmd", name);

        private void Drop()
        {
            try { reader?.Dispose(); } catch { }
            try { writer?.Dispose(); } catch { }
            try { pipe?.Dispose(); } catch { }
            reader = null; writer = null; pipe = null;
        }

        public void Dispose() => Drop();
    }
}
