using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace RE9.AP.Launcher.Core
{
    public sealed class SessionRecord
    {
        public string Server { get; set; } = "";
        public string Slot { get; set; } = "";
        public string Password { get; set; } = "";
        public string Seed { get; set; } = "";
        public string Difficulty { get; set; } = "";
        public int TotalChecks { get; set; }
        public int DoneChecks { get; set; }
        public DateTime? InstalledAt { get; set; }
        public DateTime? VerifiedAt { get; set; }
    }

    public sealed class Settings
    {
        public string GamePath { get; set; } = "";
        public string ArchipelagoPath { get; set; } = "";

        public string YamlSlot { get; set; } = "";
        public string YamlDifficulty { get; set; } = "modern";
        public string YamlKeyItems { get; set; } = "vanilla";
        public int YamlEnemyDrops { get; set; } = 15;
        public bool YamlSupplyBox { get; set; }
        public bool YamlDeathLink { get; set; }
        public string YamlProgressionBalancing { get; set; } = "normal";
        public string YamlAccessibility { get; set; } = "full";
        public string LastYamlPath { get; set; } = "";

        public int HostStep { get; set; }
        public List<string> HostYamls { get; set; } = new List<string>();
        public string LastGeneratedZip { get; set; } = "";

        public bool DisableLegacyScripts { get; set; } = true;

        public string Language { get; set; } = "fr";

        // Vide = dossier « RE9 AP Patches » trouvé tout seul
        public string PatchSource { get; set; } = "";
        public string SkippedPatch { get; set; } = "";

        public SessionRecord Session { get; set; }

        private static string FilePath
        {
            get { return Path.Combine(AppInfo.DataDir, "settings.json"); }
        }

        private static readonly JsonSerializerOptions Options = new JsonSerializerOptions { WriteIndented = true };

        public static Settings Current { get; private set; } = Load();

        private static Settings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                {
                    Settings s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Options);
                    if (s != null)
                    {
                        if (s.HostYamls == null) s.HostYamls = new List<string>();
                        return s;
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("Réglages illisibles, valeurs par défaut utilisées : " + ex.Message);
            }
            return new Settings();
        }

        public void Save()
        {
            try
            {
                File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options), new UTF8Encoding(false));
            }
            catch (Exception ex)
            {
                Log.Warn("Impossible d'enregistrer les réglages : " + ex.Message);
            }
        }
    }
}
