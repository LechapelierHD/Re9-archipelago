using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace RE9.AP.Launcher.Core
{
    /// <summary>
    /// Démarre ap_bridge.py (websockets officiel + permessage-deflate) pour le jeu.
    /// </summary>
    public static class BridgeHost
    {
        private static Process _proc;

        public static string BridgeDir
        {
            get { return Path.Combine(AppInfo.AssetsDir, "bridge"); }
        }

        public static string ScriptPath
        {
            get { return Path.Combine(BridgeDir, "ap_bridge.py"); }
        }

        public static bool Available
        {
            get { return File.Exists(ScriptPath); }
        }

        public static bool IsRunning
        {
            get
            {
                try { return _proc != null && !_proc.HasExited; }
                catch { return false; }
            }
        }

        public static string Start(string gameDir)
        {
            if (!GameLocator.IsGameFolder(gameDir))
                throw new InvalidOperationException(Lang.T("Dossier du jeu invalide : re9.exe introuvable."));
            if (!Available)
                throw new FileNotFoundException(Lang.T("Pont Python introuvable (assets/bridge/ap_bridge.py)."));

            Stop();

            string py = FindPython();
            if (py == null)
                throw new InvalidOperationException(Lang.T(
                    "Python 3 introuvable. Installe Python puis : py -3 -m pip install websockets"));

            // deps : seulement si websockets manque (pip à chaque Start = connexion très lente)
            try
            {
                if (!PythonHasModule(py, "websockets"))
                {
                    string req = Path.Combine(BridgeDir, "requirements.txt");
                    ProcessStartInfo pip = new ProcessStartInfo(py)
                    {
                        Arguments = File.Exists(req)
                            ? "-m pip install -q -r \"" + req + "\""
                            : "-m pip install -q websockets",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WorkingDirectory = BridgeDir,
                    };
                    using (Process p = Process.Start(pip))
                    {
                        if (p != null) p.WaitForExit(60000);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("pip websockets : " + ex.Message);
            }

            ProcessStartInfo psi = new ProcessStartInfo(py)
            {
                Arguments = "\"" + ScriptPath + "\" --game-dir \"" + gameDir + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = BridgeDir,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            _proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _proc.OutputDataReceived += (_, e) => { if (!string.IsNullOrEmpty(e.Data)) Log.Info("[bridge] " + e.Data); };
            _proc.ErrorDataReceived += (_, e) => { if (!string.IsNullOrEmpty(e.Data)) Log.Warn("[bridge] " + e.Data); };
            _proc.Exited += (_, __) => Log.Info("[bridge] process ended");
            if (!_proc.Start())
                throw new InvalidOperationException(Lang.T("Impossible de démarrer ap_bridge.py"));
            _proc.BeginOutputReadLine();
            _proc.BeginErrorReadLine();
            Log.Info("Bridge Python démarré (pid " + _proc.Id + ") → " + gameDir);
            return Lang.T("Pont Python Archipelago démarré (WebSocket compressé).");
        }

        public static void Stop()
        {
            if (_proc == null) return;
            try
            {
                if (!_proc.HasExited)
                {
                    _proc.Kill(true);
                    _proc.WaitForExit(3000);
                }
            }
            catch (Exception ex) { Log.Warn("Stop bridge : " + ex.Message); }
            try { _proc.Dispose(); } catch { }
            _proc = null;
        }

        private static bool PythonHasModule(string py, string module)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(py)
                {
                    Arguments = "-c \"import " + module + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                using (Process p = Process.Start(psi))
                {
                    if (p == null) return false;
                    p.WaitForExit(5000);
                    return p.ExitCode == 0;
                }
            }
            catch { return false; }
        }

        private static string FindPython()
        {
            foreach (string cand in new[] { "py", "python", "python3" })
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(cand)
                    {
                        Arguments = cand == "py" ? "-3 -c \"import sys; print(sys.executable)\"" : "-c \"import sys; print(sys.executable)\"",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                    };
                    using (Process p = Process.Start(psi))
                    {
                        if (p == null) continue;
                        string outp = p.StandardOutput.ReadToEnd().Trim();
                        p.WaitForExit(5000);
                        if (p.ExitCode == 0 && outp.Length > 0 && File.Exists(outp)) return outp;
                        if (p.ExitCode == 0 && cand != "py") return cand;
                    }
                }
                catch { }
            }
            return null;
        }
    }
}
