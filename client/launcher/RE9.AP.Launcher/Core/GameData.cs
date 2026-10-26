using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace RE9.AP.Launcher.Core
{
    public static class GameData
    {
        private static readonly HashSet<string> KeyCategories = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "KeyItem", "Flag" };

        // Comme VANILLA_LOCATIONS de l'apworld : jamais des checks (Wire Cutters, Old Key)
        private static readonly HashSet<string> VanillaLocations = new HashSet<string> { "7091006", "7091007" };

        private sealed class ItemMeta
        {
            public bool IsKey;
            public bool IsFlag;
        }

        private sealed class Loc
        {
            public string Id;
            public string[] Difficulties;
            public bool IsKey;
            public bool IsFlag;
            public string Chapter;
        }

        private static List<Loc> locations;
        private static List<string> chapters;

        private static bool Load()
        {
            if (locations != null) return locations.Count > 0;
            locations = new List<Loc>();
            chapters = new List<string>();
            string path = Path.Combine(AppInfo.AssetsDir, @"Lua\data\ArchipelagoRE9\re9_ap_ids.json");
            if (!File.Exists(path)) return false;
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path)))
                {
                    JsonElement root = doc.RootElement;
                    Dictionary<string, ItemMeta> items = new Dictionary<string, ItemMeta>();
                    JsonElement itemRoot;
                    if (root.TryGetProperty("items", out itemRoot))
                    {
                        foreach (JsonProperty p in itemRoot.EnumerateObject())
                        {
                            string gid = Text(p.Value, "game_id");
                            string cat = Text(p.Value, "category");
                            string name = Text(p.Value, "name");
                            bool isFlag = string.Equals(cat, "Flag", StringComparison.OrdinalIgnoreCase);
                            items[gid] = new ItemMeta
                            {
                                IsFlag = isFlag,
                                IsKey = isFlag || KeyCategories.Contains(cat) || name == "Lockpick",
                            };
                        }
                    }
                    JsonElement ch;
                    if (root.TryGetProperty("chapters", out ch))
                    {
                        foreach (JsonElement c in ch.EnumerateArray()) chapters.Add(c.GetString());
                    }
                    foreach (JsonElement l in root.GetProperty("locations").EnumerateArray())
                    {
                        List<string> diffs = new List<string>();
                        JsonElement d;
                        if (l.TryGetProperty("difficulties", out d) && d.ValueKind == JsonValueKind.Array)
                        {
                            foreach (JsonElement x in d.EnumerateArray()) diffs.Add(x.GetString());
                        }
                        bool isKey = false;
                        bool isFlag = false;
                        ItemMeta meta;
                        if (items.TryGetValue(Text(l, "vanilla_game_id"), out meta))
                        {
                            isKey = meta.IsKey;
                            isFlag = meta.IsFlag;
                        }
                        JsonElement idEl;
                        string id = l.TryGetProperty("id", out idEl) ? idEl.ToString() : "";
                        locations.Add(new Loc { Id = id, Difficulties = diffs.ToArray(), IsKey = isKey, IsFlag = isFlag, Chapter = Text(l, "chapter") });
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("re9_ap_ids.json illisible : " + ex.Message);
            }
            return locations.Count > 0;
        }

        // Un tableau (ancien générateur) donne son premier élément.
        private static string Text(JsonElement e, string name)
        {
            JsonElement v;
            if (!e.TryGetProperty(name, out v)) return "";
            if (v.ValueKind == JsonValueKind.Array) v = v.GetArrayLength() > 0 ? v[0] : default(JsonElement);
            return v.ValueKind == JsonValueKind.String ? v.GetString() : "";
        }

        public static int ChapterCount
        {
            get { return Load() ? chapters.Count : 0; }
        }

        public static int TotalLocations
        {
            get { return Load() ? locations.Count : 0; }
        }

        public static int CountChecks(string difficulty, bool shuffledKeys)
        {
            if (!Load()) return 0;
            string wanted = difficulty;
            Dictionary<string, List<Loc>> byChapter = new Dictionary<string, List<Loc>>();
            foreach (Loc l in locations)
            {
                if (VanillaLocations.Contains(l.Id)) continue;
                if (l.Difficulties.Length > 0 && Array.FindIndex(l.Difficulties, x => string.Equals(x, wanted, StringComparison.OrdinalIgnoreCase)) < 0) continue;
                if (l.IsKey && !shuffledKeys) continue;
                List<Loc> list;
                if (!byChapter.TryGetValue(l.Chapter, out list)) byChapter[l.Chapter] = list = new List<Loc>();
                list.Add(l);
            }

            // shuffled : clés et lockpick sont des checks. Le set histoire (hôtel, joint, ciné) reste au sol côté monde.
            int n = 0;
            foreach (string ch in chapters)
            {
                List<Loc> list;
                if (!byChapter.TryGetValue(ch, out list)) continue;
                if (!shuffledKeys)
                    n += list.FindAll(x => !x.IsKey).Count;
                else
                    n += list.Count;
            }
            return n;
        }
    }
}
