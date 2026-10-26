using System;
using System.IO;
using System.Reflection;

namespace RE9.AP.Launcher.Core
{
    public static class AppInfo
    {
        public const string DisplayName = "Re9 archipelago";
        public const string GameName = "Resident Evil Requiem";
        public const string ApworldFile = "resident_evil_requiem.apworld";
        public const int SteamAppId = 3764200;
        public const string GameExe = "re9.exe";
        public const string GameProcess = "re9";

        // Tenu à jour avec RAPPORT_IA.txt à chaque modification faite par une IA
        public const int AiCodePercent = 2;

        // Dépôt public : pas de jeton. update_token.txt (lecture seule) ne sert que si le dépôt passe en privé.
        public const string GitHubRepo = "LechapelierHD/Re9-archipelago";
        public const string UpdateFeedUrl = "github:" + GitHubRepo;

        private static string updateToken;
        public static string UpdateToken
        {
            get
            {
                if (updateToken != null) return updateToken;
                updateToken = "";
                try
                {
                    using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("update_token.txt"))
                    {
                        if (s != null)
                        {
                            using (StreamReader r = new StreamReader(s)) updateToken = r.ReadToEnd().Trim();
                        }
                    }
                }
                catch (Exception)
                {
                }
                return updateToken;
            }
        }

        public static string Version
        {
            get
            {
                Version v = Assembly.GetExecutingAssembly().GetName().Version;
                return v == null ? "0.0.0" : v.Major + "." + v.Minor + "." + v.Build;
            }
        }

        public static string DataDir
        {
            get
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RE9-AP-Wizard");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static string LogDir
        {
            get
            {
                string dir = Path.Combine(DataDir, "logs");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static string YamlDir
        {
            get
            {
                string dir = Path.Combine(DataDir, "yaml");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static string AssetsDir
        {
            get
            {
                string beside = Path.Combine(AppContext.BaseDirectory, "assets");
                if (Directory.Exists(beside)) return beside;
                DirectoryInfo dir = new DirectoryInfo(AppContext.BaseDirectory);
                while (dir != null)
                {
                    string staged = Path.Combine(dir.FullName, "package", "assets");
                    if (Directory.Exists(staged)) return staged;
                    dir = dir.Parent;
                }
                return beside;
            }
        }
    }
}
