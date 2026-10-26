using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace RE9.AP.Launcher.Core
{
    public static class ArchipelagoTools
    {
        public const string RecommendedVersion = "0.6.8";
        public const string ReleasesUrl = "https://github.com/ArchipelagoMW/Archipelago/releases/tag/0.6.8";
        public const string UploadUrl = "https://archipelago.gg/uploads";

        public static bool IsInstall(string path)
        {
            return !string.IsNullOrWhiteSpace(path) && File.Exists(Path.Combine(path, "ArchipelagoGenerate.exe"));
        }

        public static string Find()
        {
            List<string> candidates = new List<string>
            {
                @"C:\ProgramData\Archipelago",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Archipelago"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Archipelago"),
            };
            foreach (string c in candidates)
            {
                if (IsInstall(c)) return c;
            }
            return null;
        }

        public static string Version(string path)
        {
            try
            {
                FileVersionInfo v = FileVersionInfo.GetVersionInfo(Path.Combine(path, "ArchipelagoGenerate.exe"));
                if (!string.IsNullOrEmpty(v.ProductVersion)) return v.ProductVersion.Split('+')[0];
                return v.FileMajorPart + "." + v.FileMinorPart + "." + v.FileBuildPart;
            }
            catch (Exception)
            {
                return "?";
            }
        }

        public static string BundledApworld
        {
            get { return Path.Combine(AppInfo.AssetsDir, "Data", AppInfo.ApworldFile); }
        }

        public static string InstalledApworld(string apPath)
        {
            return Path.Combine(apPath, "custom_worlds", AppInfo.ApworldFile);
        }

        public static bool ApworldUpToDate(string apPath)
        {
            string installed = InstalledApworld(apPath);
            if (!File.Exists(installed) || !File.Exists(BundledApworld)) return false;
            return HashOf(installed) == HashOf(BundledApworld);
        }

        private static string HashOf(string path)
        {
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            using (FileStream f = File.OpenRead(path))
            {
                return Convert.ToHexString(sha.ComputeHash(f));
            }
        }

        public static void InstallApworld(string apPath)
        {
            if (!File.Exists(BundledApworld)) throw new FileNotFoundException(Lang.TF("apworld absent du paquet : {0}", BundledApworld));
            string dir = Path.Combine(apPath, "custom_worlds");
            Directory.CreateDirectory(dir);
            File.Copy(BundledApworld, InstalledApworld(apPath), true);
            Log.Info("apworld installé : " + InstalledApworld(apPath));
        }

        public static string HostDir
        {
            get
            {
                string dir = Path.Combine(AppInfo.DataDir, "host");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static async Task<string> GenerateAsync(string apPath, IList<string> yamls)
        {
            string players = Path.Combine(HostDir, "players");
            string output = Path.Combine(HostDir, "output");
            if (Directory.Exists(players)) Directory.Delete(players, true);
            Directory.CreateDirectory(players);
            Directory.CreateDirectory(output);
            foreach (string y in yamls)
            {
                File.Copy(y, Path.Combine(players, Path.GetFileName(y)), true);
            }
            DateTime started = DateTime.Now;

            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(apPath, "ArchipelagoGenerate.exe"))
            {
                WorkingDirectory = apPath,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            psi.ArgumentList.Add("--player_files_path");
            psi.ArgumentList.Add(players);
            psi.ArgumentList.Add("--outputpath");
            psi.ArgumentList.Add(output);
            psi.Environment["PYTHONIOENCODING"] = "utf-8";

            Log.Info("Génération lancée avec " + yamls.Count + " YAML.");
            using (Process p = new Process { StartInfo = psi, EnableRaisingEvents = true })
            {
                p.OutputDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Info("  " + e.Data); };
                p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Warn("  " + e.Data); };
                p.Start();
                p.StandardInput.Close();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                await p.WaitForExitAsync();
                if (p.ExitCode != 0) throw new InvalidOperationException(Lang.TF("La génération a échoué (code {0}). Le détail est dans le journal en bas.", p.ExitCode));
            }

            string newest = null;
            DateTime newestTime = started.AddSeconds(-5);
            foreach (string zip in Directory.GetFiles(output, "AP_*.zip"))
            {
                DateTime t = File.GetLastWriteTime(zip);
                if (t >= newestTime)
                {
                    newest = zip;
                    newestTime = t;
                }
            }
            if (newest == null) throw new InvalidOperationException(Lang.T("La génération s'est terminée sans produire de fichier AP_*.zip."));
            Log.Info("Multimonde généré : " + newest);
            return newest;
        }

        public static void StartLocalServer(string apPath, string zip)
        {
            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(apPath, "ArchipelagoServer.exe"))
            {
                WorkingDirectory = apPath,
                UseShellExecute = true,
            };
            psi.ArgumentList.Add(zip);
            Process.Start(psi);
            Log.Info("Serveur local démarré (port 38281 par défaut).");
        }
    }
}
