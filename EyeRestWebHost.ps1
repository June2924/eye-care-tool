Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$source = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using ThreadingTimer = System.Threading.Timer;

public static class EyeRestOverlayController
{
    private static readonly object Gate = new object();
    private static List<Form> activeForms = new List<Form>();
    private static ThreadingTimer activeTimer;
    private static bool allowClose = true;

    public static void CloseActive()
    {
        List<Form> formsToClose;
        ThreadingTimer timerToDispose;

        lock (Gate)
        {
            allowClose = true;
            formsToClose = new List<Form>(activeForms);
            activeForms.Clear();
            timerToDispose = activeTimer;
            activeTimer = null;
        }

        if (timerToDispose != null) { timerToDispose.Dispose(); }

        foreach (Form form in formsToClose)
        {
            if (form == null || form.IsDisposed) { continue; }
            try
            {
                if (form.InvokeRequired)
                {
                    form.BeginInvoke(new Action(delegate { if (!form.IsDisposed) { form.Close(); } }));
                }
                else
                {
                    form.Close();
                }
            }
            catch { }
        }
    }

    public static void Show(int seconds)
    {
        if (seconds <= 0) { seconds = 20; }
        CloseActive();

        DateTime deadline = DateTime.Now.AddSeconds(seconds);
        List<Form> forms = new List<Form>();
        Form primary = null;

        lock (Gate) { allowClose = false; }

        foreach (Screen screen in Screen.AllScreens)
        {
            Form form = new Form();
            form.StartPosition = FormStartPosition.Manual;
            form.Bounds = screen.Bounds;
            form.FormBorderStyle = FormBorderStyle.None;
            form.TopMost = true;
            form.BackColor = Color.FromArgb(16, 49, 47);
            form.ForeColor = Color.White;
            form.ShowInTaskbar = false;
            form.KeyPreview = true;
            form.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; }
            };
            form.FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                lock (Gate) { if (!allowClose) { e.Cancel = true; } }
            };
            forms.Add(form);
            if (screen.Primary) { primary = form; }
        }

        if (forms.Count == 0) { return; }
        if (primary == null) { primary = forms[0]; }

        TableLayoutPanel panel = new TableLayoutPanel();
        panel.Dock = DockStyle.Fill;
        panel.ColumnCount = 1;
        panel.RowCount = 5;
        panel.Padding = new Padding(48);
        panel.BackColor = Color.Transparent;
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 18));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 20));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 34));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 16));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 12));

        Label title = new Label();
        title.Text = "该休息眼睛了";
        title.Dock = DockStyle.Fill;
        title.TextAlign = ContentAlignment.MiddleCenter;
        title.Font = new Font("Microsoft YaHei UI", 34, FontStyle.Bold);

        Label instruction = new Label();
        instruction.Text = "看向约 6 米外，眨眨眼，保持 20 秒。";
        instruction.Dock = DockStyle.Fill;
        instruction.TextAlign = ContentAlignment.MiddleCenter;
        instruction.Font = new Font("Microsoft YaHei UI", 20, FontStyle.Regular);

        Label countdown = new Label();
        countdown.Text = seconds.ToString();
        countdown.Dock = DockStyle.Fill;
        countdown.TextAlign = ContentAlignment.MiddleCenter;
        countdown.Font = new Font("Segoe UI", 96, FontStyle.Bold);

        Label hint = new Label();
        hint.Text = "这 20 秒内无法用 Esc 关闭。休息结束后自动返回。";
        hint.Dock = DockStyle.Fill;
        hint.TextAlign = ContentAlignment.MiddleCenter;
        hint.Font = new Font("Microsoft YaHei UI", 14, FontStyle.Regular);
        hint.ForeColor = Color.FromArgb(207, 237, 229);

        Button closeButton = new Button();
        closeButton.Text = "休息完成";
        closeButton.Enabled = false;
        closeButton.Anchor = AnchorStyles.None;
        closeButton.Width = 180;
        closeButton.Height = 48;
        closeButton.Font = new Font("Microsoft YaHei UI", 12, FontStyle.Bold);
        closeButton.Click += delegate(object sender, EventArgs e) { CloseActive(); };

        panel.Controls.Add(title, 0, 0);
        panel.Controls.Add(instruction, 0, 1);
        panel.Controls.Add(countdown, 0, 2);
        panel.Controls.Add(hint, 0, 3);
        panel.Controls.Add(closeButton, 0, 4);
        primary.Controls.Add(panel);

        foreach (Form form in forms) { form.Show(); }
        primary.Activate();

        lock (Gate) { activeForms = forms; }

        Form targetForm = primary;
        ThreadingTimer timer = null;
        timer = new ThreadingTimer(delegate(object state)
        {
            int left = (int)Math.Ceiling((deadline - DateTime.Now).TotalSeconds);
            if (left < 0) { left = 0; }
            try
            {
                if (targetForm == null || targetForm.IsDisposed) { return; }
                targetForm.BeginInvoke(new Action(delegate
                {
                    if (targetForm.IsDisposed) { return; }
                    countdown.Text = left.ToString();
                    if (left <= 0)
                    {
                        closeButton.Enabled = true;
                        CloseActive();
                    }
                }));
            }
            catch { }
        }, null, 0, 250);

        lock (Gate) { activeTimer = timer; }
    }
}

public static class EyeRestWebHost
{
    private static HttpListener listener;
    private static Thread serverThread;
    private static Control uiControl;
    private static string webRoot;
    private static readonly object ScheduleGate = new object();
    private static ThreadingTimer scheduledRestTimer;
    private static DateTime scheduledDeadline = DateTime.MinValue;
    private static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        { ".html", "text/html; charset=utf-8" },
        { ".css", "text/css; charset=utf-8" },
        { ".js", "text/javascript; charset=utf-8" },
        { ".json", "application/json; charset=utf-8" },
        { ".webmanifest", "application/manifest+json; charset=utf-8" },
        { ".svg", "image/svg+xml" },
        { ".png", "image/png" }
    };

    public static void Start(string root, int port, Control control)
    {
        webRoot = Path.GetFullPath(root);
        uiControl = control;
        listener = new HttpListener();
        listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
        listener.Start();
        serverThread = new Thread(ListenLoop);
        serverThread.IsBackground = true;
        serverThread.Start();
    }

    public static void Stop()
    {
        CancelScheduledRest();
        try { if (listener != null) { listener.Stop(); listener.Close(); } } catch { }
    }

    private static void ListenLoop()
    {
        while (listener != null && listener.IsListening)
        {
            try
            {
                HttpListenerContext context = listener.GetContext();
                ThreadPool.QueueUserWorkItem(delegate { Handle(context); });
            }
            catch { }
        }
    }

    private static void AddCors(HttpListenerResponse response)
    {
        response.Headers["Access-Control-Allow-Origin"] = "*";
        response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
        response.Headers["Access-Control-Allow-Headers"] = "content-type";
        response.Headers["Cache-Control"] = "no-cache";
    }

    private static void WriteText(HttpListenerResponse response, int status, string text, string type)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        response.StatusCode = status;
        response.ContentType = type;
        response.ContentLength64 = bytes.Length;
        AddCors(response);
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.OutputStream.Close();
    }

    private static void Handle(HttpListenerContext context)
    {
        HttpListenerRequest request = context.Request;
        HttpListenerResponse response = context.Response;
        AddCors(response);

        if (request.HttpMethod == "OPTIONS")
        {
            response.StatusCode = 204;
            response.Close();
            return;
        }

        if (request.Url.AbsolutePath == "/api/status")
        {
            bool scheduled;
            lock (ScheduleGate) { scheduled = scheduledRestTimer != null; }
            WriteText(response, 200, "{\"ok\":true,\"name\":\"EyeRest Local Bridge\",\"version\":\"7\",\"scheduled\":" + (scheduled ? "true" : "false") + "}", "application/json; charset=utf-8");
            return;
        }

        if (request.Url.AbsolutePath == "/api/rest")
        {
            string body = "";
            using (StreamReader reader = new StreamReader(request.InputStream, request.ContentEncoding ?? Encoding.UTF8))
            {
                body = reader.ReadToEnd();
            }
            string action = ReadJsonString(body, "action", "overlay").ToLowerInvariant();
            int seconds = ReadJsonInt(body, "seconds", 20);
            TriggerRest(action, seconds);
            WriteText(response, 200, "{\"ok\":true}", "application/json; charset=utf-8");
            return;
        }

        if (request.Url.AbsolutePath == "/api/schedule")
        {
            string body = "";
            using (StreamReader reader = new StreamReader(request.InputStream, request.ContentEncoding ?? Encoding.UTF8))
            {
                body = reader.ReadToEnd();
            }
            string action = ReadJsonString(body, "action", "overlay").ToLowerInvariant();
            int delaySeconds = ReadJsonInt(body, "delaySeconds", 1200);
            int restSeconds = ReadJsonInt(body, "restSeconds", 20);
            ScheduleRest(action, delaySeconds, restSeconds);
            WriteText(response, 200, "{\"ok\":true}", "application/json; charset=utf-8");
            return;
        }

        if (request.Url.AbsolutePath == "/api/cancel")
        {
            CancelScheduledRest();
            WriteText(response, 200, "{\"ok\":true}", "application/json; charset=utf-8");
            return;
        }

        ServeFile(request, response);
    }

    private static string ReadJsonString(string json, string name, string fallback)
    {
        Match match = Regex.Match(json ?? "", "\"" + Regex.Escape(name) + "\"\\s*:\\s*\"([^\"]*)\"");
        return match.Success ? match.Groups[1].Value : fallback;
    }

    private static int ReadJsonInt(string json, string name, int fallback)
    {
        Match match = Regex.Match(json ?? "", "\"" + Regex.Escape(name) + "\"\\s*:\\s*(\\d+)");
        int value;
        return match.Success && Int32.TryParse(match.Groups[1].Value, out value) ? value : fallback;
    }

    private static void TriggerRest(string action, int seconds)
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            PlayReminderSound();
            if (action == "lock")
            {
                System.Diagnostics.Process.Start("rundll32.exe", "user32.dll,LockWorkStation");
                return;
            }
            if (action == "screensaver")
            {
                string screenSaver = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32\\scrnsave.scr");
                if (File.Exists(screenSaver)) { System.Diagnostics.Process.Start(screenSaver); }
            }
            StartOverlayProcess(seconds);
        });
    }

    private static void StartOverlayProcess(int seconds)
    {
        string script = Path.Combine(webRoot, "EyeRestOverlay.ps1");
        if (!File.Exists(script))
        {
            return;
        }

        System.Diagnostics.ProcessStartInfo info = new System.Diagnostics.ProcessStartInfo();
        info.FileName = "powershell.exe";
        info.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\" -Seconds " + seconds;
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        System.Diagnostics.Process.Start(info);
    }

    private static void ScheduleRest(string action, int delaySeconds, int restSeconds)
    {
        CancelScheduledRest();
        if (delaySeconds < 1) { delaySeconds = 1; }
        if (restSeconds < 1) { restSeconds = 20; }

        ThreadingTimer timer = null;
        timer = new ThreadingTimer(delegate(object state)
        {
            lock (ScheduleGate)
            {
                if (scheduledRestTimer != timer) { return; }
                scheduledRestTimer = null;
                scheduledDeadline = DateTime.MinValue;
            }
            timer.Dispose();
            TriggerRest(action, restSeconds);
        }, null, delaySeconds * 1000, Timeout.Infinite);

        lock (ScheduleGate)
        {
            scheduledRestTimer = timer;
            scheduledDeadline = DateTime.Now.AddSeconds(delaySeconds);
        }
    }

    private static void CancelScheduledRest()
    {
        ThreadingTimer timerToDispose = null;
        lock (ScheduleGate)
        {
            timerToDispose = scheduledRestTimer;
            scheduledRestTimer = null;
            scheduledDeadline = DateTime.MinValue;
        }
        if (timerToDispose != null) { timerToDispose.Dispose(); }
    }

    private static void PlayReminderSound()
    {
        for (int i = 0; i < 3; i++)
        {
            Console.Beep(880, 180);
            Thread.Sleep(90);
            Console.Beep(660, 180);
            Thread.Sleep(120);
        }
    }

    private static void ServeFile(HttpListenerRequest request, HttpListenerResponse response)
    {
        string relative = Uri.UnescapeDataString(request.Url.AbsolutePath.TrimStart('/')).Replace('/', Path.DirectorySeparatorChar);
        if (String.IsNullOrWhiteSpace(relative)) { relative = "index.html"; }
        string full = Path.GetFullPath(Path.Combine(webRoot, relative));
        string rootWithSlash = webRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(rootWithSlash, StringComparison.OrdinalIgnoreCase) && !String.Equals(full, webRoot, StringComparison.OrdinalIgnoreCase))
        {
            WriteText(response, 403, "Forbidden", "text/plain; charset=utf-8");
            return;
        }
        if (Directory.Exists(full)) { full = Path.Combine(full, "index.html"); }
        if (!File.Exists(full))
        {
            WriteText(response, 404, "Not found", "text/plain; charset=utf-8");
            return;
        }

        string extension = Path.GetExtension(full);
        string type = Types.ContainsKey(extension) ? Types[extension] : "application/octet-stream";
        byte[] bytes = File.ReadAllBytes(full);
        response.StatusCode = 200;
        response.ContentType = type;
        response.ContentLength64 = bytes.Length;
        AddCors(response);
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.OutputStream.Close();
    }
}

public static class EyeRestTcpWebHost
{
    private static TcpListener listener;
    private static Thread serverThread;
    private static volatile bool running;
    private static Control uiControl;
    private static string webRoot;
    private static readonly object ScheduleGate = new object();
    private static ThreadingTimer scheduledRestTimer;
    private static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        { ".html", "text/html; charset=utf-8" },
        { ".css", "text/css; charset=utf-8" },
        { ".js", "text/javascript; charset=utf-8" },
        { ".json", "application/json; charset=utf-8" },
        { ".webmanifest", "application/manifest+json; charset=utf-8" },
        { ".svg", "image/svg+xml" },
        { ".png", "image/png" }
    };

    public static void Start(string root, int port, Control control)
    {
        webRoot = Path.GetFullPath(root);
        uiControl = control;
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        running = true;
        serverThread = new Thread(ListenLoop);
        serverThread.IsBackground = true;
        serverThread.Start();
    }

    public static void Stop()
    {
        running = false;
        CancelScheduledRest();
        try { if (listener != null) { listener.Stop(); } } catch { }
    }

    private static void ListenLoop()
    {
        while (running)
        {
            try
            {
                TcpClient client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(delegate { HandleClient(client); });
            }
            catch { }
        }
    }

    private static void HandleClient(TcpClient client)
    {
        using (client)
        {
            NetworkStream stream = client.GetStream();
            stream.ReadTimeout = 5000;
            byte[] requestBytes = ReadRequest(stream);
            if (requestBytes.Length == 0) { return; }

            int headerEnd = FindHeaderEnd(requestBytes);
            if (headerEnd < 0)
            {
                WriteText(stream, 400, "Bad Request", "text/plain; charset=utf-8");
                return;
            }

            string headerText = Encoding.UTF8.GetString(requestBytes, 0, headerEnd);
            string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0)
            {
                WriteText(stream, 400, "Bad Request", "text/plain; charset=utf-8");
                return;
            }

            string[] firstLine = lines[0].Split(' ');
            if (firstLine.Length < 2)
            {
                WriteText(stream, 400, "Bad Request", "text/plain; charset=utf-8");
                return;
            }

            string method = firstLine[0].ToUpperInvariant();
            string path = firstLine[1].Split('?')[0];
            string body = "";
            int bodyOffset = headerEnd + 4;
            if (requestBytes.Length > bodyOffset)
            {
                body = Encoding.UTF8.GetString(requestBytes, bodyOffset, requestBytes.Length - bodyOffset);
            }

            if (method == "OPTIONS")
            {
                WriteBytes(stream, 204, "No Content", "text/plain; charset=utf-8", new byte[0]);
                return;
            }

            if (path == "/api/status")
            {
                bool scheduled;
                lock (ScheduleGate) { scheduled = scheduledRestTimer != null; }
                WriteText(stream, 200, "{\"ok\":true,\"name\":\"EyeRest Local Bridge\",\"version\":\"9\",\"scheduled\":" + (scheduled ? "true" : "false") + "}", "application/json; charset=utf-8");
                return;
            }

            if (path == "/api/rest")
            {
                string action = ReadJsonString(body, "action", "overlay").ToLowerInvariant();
                int seconds = ReadJsonInt(body, "seconds", 20);
                TriggerRest(action, seconds);
                WriteText(stream, 200, "{\"ok\":true}", "application/json; charset=utf-8");
                return;
            }

            if (path == "/api/schedule")
            {
                string action = ReadJsonString(body, "action", "overlay").ToLowerInvariant();
                int delaySeconds = ReadJsonInt(body, "delaySeconds", 1200);
                int restSeconds = ReadJsonInt(body, "restSeconds", 20);
                ScheduleRest(action, delaySeconds, restSeconds);
                WriteText(stream, 200, "{\"ok\":true}", "application/json; charset=utf-8");
                return;
            }

            if (path == "/api/cancel")
            {
                CancelScheduledRest();
                WriteText(stream, 200, "{\"ok\":true}", "application/json; charset=utf-8");
                return;
            }

            ServeFile(stream, path);
        }
    }

    private static byte[] ReadRequest(NetworkStream stream)
    {
        MemoryStream memory = new MemoryStream();
        byte[] buffer = new byte[4096];
        int contentLength = -1;
        int headerEnd = -1;

        while (true)
        {
            int read = stream.Read(buffer, 0, buffer.Length);
            if (read <= 0) { break; }
            memory.Write(buffer, 0, read);
            byte[] current = memory.ToArray();
            if (headerEnd < 0)
            {
                headerEnd = FindHeaderEnd(current);
                if (headerEnd >= 0)
                {
                    string headerText = Encoding.UTF8.GetString(current, 0, headerEnd);
                    contentLength = GetContentLength(headerText);
                }
            }
            if (headerEnd >= 0)
            {
                int bodyBytes = current.Length - (headerEnd + 4);
                if (contentLength <= 0 || bodyBytes >= contentLength) { break; }
            }
            if (current.Length > 1024 * 1024) { break; }
        }

        return memory.ToArray();
    }

    private static int FindHeaderEnd(byte[] bytes)
    {
        for (int i = 0; i <= bytes.Length - 4; i++)
        {
            if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) { return i; }
        }
        return -1;
    }

    private static int GetContentLength(string headerText)
    {
        Match match = Regex.Match(headerText ?? "", "(?im)^Content-Length:\\s*(\\d+)\\s*$");
        int value;
        return match.Success && Int32.TryParse(match.Groups[1].Value, out value) ? value : 0;
    }

    private static string ReadJsonString(string json, string name, string fallback)
    {
        Match match = Regex.Match(json ?? "", "\"" + Regex.Escape(name) + "\"\\s*:\\s*\"([^\"]*)\"");
        return match.Success ? match.Groups[1].Value : fallback;
    }

    private static int ReadJsonInt(string json, string name, int fallback)
    {
        Match match = Regex.Match(json ?? "", "\"" + Regex.Escape(name) + "\"\\s*:\\s*(\\d+)");
        int value;
        return match.Success && Int32.TryParse(match.Groups[1].Value, out value) ? value : fallback;
    }

    private static void ScheduleRest(string action, int delaySeconds, int restSeconds)
    {
        CancelScheduledRest();
        if (delaySeconds < 1) { delaySeconds = 1; }
        if (restSeconds < 1) { restSeconds = 20; }

        ThreadingTimer timer = null;
        timer = new ThreadingTimer(delegate(object state)
        {
            lock (ScheduleGate)
            {
                if (scheduledRestTimer != timer) { return; }
                scheduledRestTimer = null;
            }
            timer.Dispose();
            TriggerRest(action, restSeconds);
        }, null, delaySeconds * 1000, Timeout.Infinite);

        lock (ScheduleGate) { scheduledRestTimer = timer; }
    }

    private static void CancelScheduledRest()
    {
        ThreadingTimer timerToDispose = null;
        lock (ScheduleGate)
        {
            timerToDispose = scheduledRestTimer;
            scheduledRestTimer = null;
        }
        if (timerToDispose != null) { timerToDispose.Dispose(); }
    }

    private static void TriggerRest(string action, int seconds)
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            PlayReminderSound();
            if (action == "lock")
            {
                System.Diagnostics.Process.Start("rundll32.exe", "user32.dll,LockWorkStation");
                return;
            }
            if (action == "screensaver")
            {
                string screenSaver = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32\\scrnsave.scr");
                if (File.Exists(screenSaver)) { System.Diagnostics.Process.Start(screenSaver); }
            }
            StartOverlayProcess(seconds);
        });
    }

    private static void StartOverlayProcess(int seconds)
    {
        string script = Path.Combine(webRoot, "EyeRestOverlay.ps1");
        if (!File.Exists(script))
        {
            return;
        }

        System.Diagnostics.ProcessStartInfo info = new System.Diagnostics.ProcessStartInfo();
        info.FileName = "powershell.exe";
        info.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\" -Seconds " + seconds;
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        System.Diagnostics.Process.Start(info);
    }

    private static void PlayReminderSound()
    {
        for (int i = 0; i < 3; i++)
        {
            Console.Beep(880, 180);
            Thread.Sleep(90);
            Console.Beep(660, 180);
            Thread.Sleep(120);
        }
    }

    private static void ServeFile(NetworkStream stream, string path)
    {
        string relative = Uri.UnescapeDataString((path ?? "/").TrimStart('/')).Replace('/', Path.DirectorySeparatorChar);
        if (String.IsNullOrWhiteSpace(relative)) { relative = "index.html"; }
        string full = Path.GetFullPath(Path.Combine(webRoot, relative));
        string rootWithSlash = webRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(rootWithSlash, StringComparison.OrdinalIgnoreCase) && !String.Equals(full, webRoot, StringComparison.OrdinalIgnoreCase))
        {
            WriteText(stream, 403, "Forbidden", "text/plain; charset=utf-8");
            return;
        }
        if (Directory.Exists(full)) { full = Path.Combine(full, "index.html"); }
        if (!File.Exists(full))
        {
            WriteText(stream, 404, "Not found", "text/plain; charset=utf-8");
            return;
        }
        string extension = Path.GetExtension(full);
        string type = Types.ContainsKey(extension) ? Types[extension] : "application/octet-stream";
        WriteBytes(stream, 200, "OK", type, File.ReadAllBytes(full));
    }

    private static void WriteText(NetworkStream stream, int status, string text, string type)
    {
        WriteBytes(stream, status, StatusText(status), type, Encoding.UTF8.GetBytes(text));
    }

    private static string StatusText(int status)
    {
        if (status == 200) { return "OK"; }
        if (status == 204) { return "No Content"; }
        if (status == 400) { return "Bad Request"; }
        if (status == 403) { return "Forbidden"; }
        if (status == 404) { return "Not Found"; }
        return "OK";
    }

    private static void WriteBytes(NetworkStream stream, int status, string statusText, string type, byte[] body)
    {
        string header =
            "HTTP/1.1 " + status + " " + statusText + "\r\n" +
            "Content-Type: " + type + "\r\n" +
            "Content-Length: " + body.Length + "\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: content-type\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n";
        byte[] headerBytes = Encoding.UTF8.GetBytes(header);
        stream.Write(headerBytes, 0, headerBytes.Length);
        if (body.Length > 0) { stream.Write(body, 0, body.Length); }
    }
}
"@

if (-not ("EyeRestTcpWebHost" -as [type])) {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Net
}

$port = 17891
$root = $PSScriptRoot
$url = "http://127.0.0.1:$port/index.html"

$hostForm = New-Object System.Windows.Forms.Form
$hostForm.Text = "眼息本机桥接"
$hostForm.StartPosition = "CenterScreen"
$hostForm.Size = New-Object System.Drawing.Size(360, 180)
$hostForm.FormBorderStyle = "FixedDialog"
$hostForm.MaximizeBox = $false
$hostForm.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$label = New-Object System.Windows.Forms.Label
$label.Dock = "Fill"
$label.TextAlign = "MiddleCenter"
$label.Text = "眼息网页桥接已运行。`r`n关闭这个窗口会停止电脑强提醒。"
$hostForm.Controls.Add($label)

$buttonOpen = New-Object System.Windows.Forms.Button
$buttonOpen.Dock = "Bottom"
$buttonOpen.Height = 44
$buttonOpen.Text = "打开眼息网页"
$buttonOpen.Add_Click({ Start-Process $url })
$hostForm.Controls.Add($buttonOpen)

$hostForm.Add_Shown({
    try {
        [EyeRestTcpWebHost]::Start($root, $port, $hostForm)
        Start-Process $url
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "眼息桥接启动失败",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        $hostForm.Close()
    }
})

$hostForm.Add_FormClosed({
    [EyeRestTcpWebHost]::Stop()
})

[void][System.Windows.Forms.Application]::Run($hostForm)
