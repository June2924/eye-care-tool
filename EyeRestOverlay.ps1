param(
    [int]$Seconds = 20
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;
using ThreadingTimer = System.Threading.Timer;

public static class EyeRestOverlayApp
{
    private static bool allowClose = false;
    private static List<Form> forms = new List<Form>();
    private static ThreadingTimer timer;

    public static void Run(int seconds)
    {
        if (seconds <= 0) { seconds = 20; }

        Application.EnableVisualStyles();
        DateTime deadline = DateTime.Now.AddSeconds(seconds);
        forms = new List<Form>();
        allowClose = false;

        Form primary = null;
        Label countdown = null;
        Button closeButton = null;

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
                if (!allowClose) { e.Cancel = true; }
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

        countdown = new Label();
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

        closeButton = new Button();
        closeButton.Text = "休息完成";
        closeButton.Enabled = false;
        closeButton.Anchor = AnchorStyles.None;
        closeButton.Width = 180;
        closeButton.Height = 48;
        closeButton.Font = new Font("Microsoft YaHei UI", 12, FontStyle.Bold);
        closeButton.Click += delegate(object sender, EventArgs e) { CloseAll(); };

        panel.Controls.Add(title, 0, 0);
        panel.Controls.Add(instruction, 0, 1);
        panel.Controls.Add(countdown, 0, 2);
        panel.Controls.Add(hint, 0, 3);
        panel.Controls.Add(closeButton, 0, 4);
        primary.Controls.Add(panel);

        foreach (Form form in forms) { form.Show(); }
        primary.Activate();

        Form target = primary;
        Label targetCountdown = countdown;
        Button targetButton = closeButton;
        timer = new ThreadingTimer(delegate(object state)
        {
            int left = (int)Math.Ceiling((deadline - DateTime.Now).TotalSeconds);
            if (left < 0) { left = 0; }
            try
            {
                if (target == null || target.IsDisposed) { return; }
                target.BeginInvoke(new Action(delegate
                {
                    if (target.IsDisposed) { return; }
                    targetCountdown.Text = left.ToString();
                    if (left <= 0)
                    {
                        targetButton.Enabled = true;
                        CloseAll();
                    }
                }));
            }
            catch { }
        }, null, 0, 250);

        Application.Run(primary);
    }

    private static void CloseAll()
    {
        allowClose = true;
        if (timer != null)
        {
            timer.Dispose();
            timer = null;
        }
        foreach (Form form in forms)
        {
            try
            {
                if (form != null && !form.IsDisposed) { form.Close(); }
            }
            catch { }
        }
        Application.ExitThread();
    }
}
"@

if (-not ("EyeRestOverlayApp" -as [type])) {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms,System.Drawing
}

[EyeRestOverlayApp]::Run($Seconds)
