using System;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace RE9.AP.Launcher.Core
{
    public static class BugReport
    {
        public static string Create()
        {
            Settings s = Settings.Current;
            string name = "RE9-bugreport-" + (s.Session != null && s.Session.Slot.Length > 0 ? s.Session.Slot : "sans-session")
                + "-" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".zip";
            foreach (char c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), name);

            using (ZipArchive zip = ZipFile.Open(path, ZipArchiveMode.Create))
            {
                AddFile(zip, Log.FilePath, "launcher.log");
                StringBuilder summary = new StringBuilder();
                summary.AppendLine(AppInfo.DisplayName + " " + AppInfo.Version);
                summary.AppendLine("Date : " + DateTime.Now.ToString("u"));
                summary.AppendLine("Jeu : " + s.GamePath);
                summary.AppendLine("Archipelago : " + s.ArchipelagoPath);
                if (s.Session != null)
                {
                    summary.AppendLine("Session : " + s.Session.Slot + " @ " + s.Session.Server + " (seed " + s.Session.Seed + ")");
                    summary.AppendLine("Difficulté : " + s.Session.Difficulty);
                }
                ClientStatus st = ClientInstaller.Inspect(s.GamePath);
                summary.AppendLine("REFramework : " + st.ReFramework + ", client installé : " + st.ClientInstalled + ", à jour : " + st.ClientUpToDate);
                AddText(zip, "resume.txt", summary.ToString());

                if (GameLocator.IsGameFolder(s.GamePath))
                {
                    AddFile(zip, Path.Combine(s.GamePath, "re2_framework_log.txt"), "game/re2_framework_log.txt");
                    AddFile(zip, Path.Combine(s.GamePath, "reframework_log.txt"), "game/reframework_log.txt");
                    string data = ClientInstaller.DataFolder(s.GamePath);
                    AddFile(zip, Path.Combine(data, "session_state.json"), "game/session_state.json");
                    AddFile(zip, Path.Combine(data, "last_pickups.json"), "game/last_pickups.json");
                }
            }
            Log.Info("Rapport de bug créé : " + path);
            return path;
        }

        private static void AddFile(ZipArchive zip, string file, string entry)
        {
            if (!File.Exists(file)) return;
            try
            {
                using (FileStream src = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (Stream dst = zip.CreateEntry(entry).Open())
                {
                    src.CopyTo(dst);
                }
            }
            catch (IOException)
            {
            }
        }

        private static void AddText(ZipArchive zip, string entry, string text)
        {
            using (StreamWriter w = new StreamWriter(zip.CreateEntry(entry).Open(), new UTF8Encoding(false)))
            {
                w.Write(text);
            }
        }
    }
}
