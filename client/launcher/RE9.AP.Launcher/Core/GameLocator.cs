using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace RE9.AP.Launcher.Core
{
    public static class GameLocator
    {
        public static bool IsGameFolder(string path)
        {
            return !string.IsNullOrWhiteSpace(path) && File.Exists(Path.Combine(path.Trim(), AppInfo.GameExe));
        }

        public static bool IsGameRunning()
        {
            return Process.GetProcessesByName(AppInfo.GameProcess).Length > 0;
        }

        public static string Find()
        {
            List<string> libraries = SteamLibraries();
            foreach (string library in libraries)
            {
                string manifest = Path.Combine(library, "steamapps", "appmanifest_" + AppInfo.SteamAppId + ".acf");
                if (!File.Exists(manifest)) continue;
                Match m = Regex.Match(File.ReadAllText(manifest), "\"installdir\"\\s+\"([^\"]+)\"");
                if (!m.Success) continue;
                string dir = Path.Combine(library, "steamapps", "common", m.Groups[1].Value);
                if (IsGameFolder(dir)) return Path.GetFullPath(dir);
            }
            foreach (string library in libraries)
            {
                string common = Path.Combine(library, "steamapps", "common");
                if (!Directory.Exists(common)) continue;
                foreach (string dir in Directory.GetDirectories(common))
                {
                    if (IsGameFolder(dir)) return Path.GetFullPath(dir);
                }
            }
            return null;
        }

        private static List<string> SteamLibraries()
        {
            List<string> roots = new List<string>();
            AddRegistry(Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath", roots);
            AddRegistry(Registry.LocalMachine, @"Software\WOW6432Node\Valve\Steam", "InstallPath", roots);
            Add(roots, @"C:\Program Files (x86)\Steam");

            List<string> libraries = new List<string>(roots);
            foreach (string root in roots)
            {
                string vdf = Path.Combine(root, "steamapps", "libraryfolders.vdf");
                if (!File.Exists(vdf)) continue;
                foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                {
                    Add(libraries, m.Groups[1].Value.Replace("\\\\", "\\"));
                }
            }
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                if (drive.DriveType == DriveType.Fixed) Add(libraries, Path.Combine(drive.Name, "SteamLibrary"));
            }
            return libraries;
        }

        private static void AddRegistry(RegistryKey hive, string sub, string name, List<string> list)
        {
            try
            {
                using (RegistryKey key = hive.OpenSubKey(sub))
                {
                    object value = key == null ? null : key.GetValue(name);
                    if (value != null) Add(list, value.ToString());
                }
            }
            catch (Exception)
            {
            }
        }

        private static void Add(List<string> list, string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            try
            {
                path = Path.GetFullPath(path.Replace('/', '\\'));
            }
            catch (Exception)
            {
                return;
            }
            if (!Directory.Exists(path)) return;
            foreach (string existing in list)
            {
                if (string.Equals(existing, path, StringComparison.OrdinalIgnoreCase)) return;
            }
            list.Add(path);
        }

        public static void LaunchViaSteam()
        {
            Process.Start(new ProcessStartInfo("steam://rungameid/" + AppInfo.SteamAppId) { UseShellExecute = true });
        }

        public static void Open(string target)
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
    }
}
