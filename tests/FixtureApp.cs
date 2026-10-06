using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

// An isolated test application. It never opens Antigravity or reads user files.
internal static class FixtureApp
{
    [STAThread]
    private static void Main()
    {
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string pid = Process.GetCurrentProcess().Id.ToString();
        string[] keys = { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY" };
        using (StreamWriter writer = new StreamWriter(Path.Combine(folder, "env-" + pid + ".txt")))
            foreach (string key in keys) writer.WriteLine(key + "=" + Environment.GetEnvironmentVariable(key));

        using (Form form = new Form())
        using (Timer timer = new Timer())
        {
            form.Text = "Isolated proxy launcher fixture";
            // A normal unowned window is needed for Process.CloseMainWindow. Opacity
            // keeps the fixture itself invisible; no real application is involved.
            form.ShowInTaskbar = true;
            form.Opacity = 0;
            form.Shown += delegate
            {
                string external = Environment.GetEnvironmentVariable("PROXY_FIXTURE_EXTERNAL_PATH");
                if (!String.IsNullOrEmpty(external))
                {
                    ProcessStartInfo info = new ProcessStartInfo(external);
                    info.UseShellExecute = false;
                    info.EnvironmentVariables["PROXY_FIXTURE_EXTERNAL_PATH"] = "";
                    info.EnvironmentVariables["PROXY_FIXTURE_MODE"] = "";
                    Process child = Process.Start(info);
                    File.WriteAllText(Path.Combine(folder, "child.pid"), child.Id.ToString());
                    child.Dispose();
                }
                File.WriteAllText(Path.Combine(folder, "ready-" + pid), "ready");
            };
            form.FormClosing += delegate(object sender, FormClosingEventArgs args)
            {
                if (Environment.GetEnvironmentVariable("PROXY_FIXTURE_MODE") == "refuse_close" &&
                    !File.Exists(Path.Combine(folder, "exit.signal"))) args.Cancel = true;
                else File.WriteAllText(Path.Combine(folder, "closed-" + pid), "closed normally");
            };
            timer.Interval = 100;
            timer.Tick += delegate
            {
                if (File.Exists(Path.Combine(folder, "exit.signal"))) form.Close();
            };
            timer.Start();
            Application.Run(form);
        }
    }
}
