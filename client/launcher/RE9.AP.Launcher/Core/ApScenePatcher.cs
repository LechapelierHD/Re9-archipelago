using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace RE9.AP.Launcher.Core
{
    /// <summary>
    /// Pipeline modèle AP = RE4R A→Z, adapté RE9 :
    ///
    /// RE4R :
    ///   1) ap_placeholder_model.zip reskin Glasses (sm75_304) = logo
    ///   2) DropItemModifier.UpdateModels : DropItem.ItemID → Glasses (foreign)
    ///   3) Lua : intercept pickup seulement (pas de setMesh monde)
    ///
    /// RE9 :
    ///   1) pak/natives reskin Empty Injector (wp3442) = logo
    ///   2) Ici : ItemID + Layouter.pfb + path .mesh/.mdf2 → porteur
    ///      — jamais le nom de GameObject
    ///   3) Lua ap_visual : assure ItemID + map vanilla pour le detector
    /// </summary>
    public static class ApScenePatcher
    {
        public const string PlaceholderGid = "it50_00_018";
        // RE9 bake le mesh monde dans le scn (RE4R non) → pointer vers le porteur reskiné
        public const string PlaceholderMeshPath = "Character/wp/wp34/3442/00/wp3442_00.mesh";
        public const string PlaceholderMdfPath = "Character/wp/wp34/3442/00/wp3442_00.mdf2";

        private static readonly Encoding Utf16 = Encoding.Unicode;
        private static readonly byte[] GimmickUtf16 = Encoding.Unicode.GetBytes("Gimmick");

        private static readonly Dictionary<string, string> FolderToScn = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "ChapX_JCT001_Item", @"junction\chapx_jct001_item.scn.21" },
            { "AbandonedHotel_Item", @"abandonedhotel\abandonedhotel_item.scn.21" },
            { "Chap1_10_Item", @"chap1_10\chap1_10_item.scn.21" },
            { "Chap3_01_Item", @"chap3_01\chap3_01_item.scn.21" },
            { "Chap3_02_Item", @"chap3_02\chap3_02_item.scn.21" },
            { "Chap3_03_Item", @"chap3_03\chap3_03_item.scn.21" },
            { "Chap3_04_Item", @"chap3_04\chap3_04_item.scn.21" },
            { "Chap3_05_Item", @"chap3_05\chap3_05_item.scn.21" },
            { "Chap3_10_Item", @"chap3_10\chap3_10_item.scn.21" },
            { "Chap3_20_Item", @"chap3_20\chap3_20_item.scn.21" },
            { "Chap3_324_Item", @"chap3_324\chap3_324_item.scn.21" },
            { "Chap3_40_Item", @"chap3_40\chap3_40_item.scn.21" },
            { "Chap4_10_Item", @"chap4_10\chap4_10_item.scn.21" },
            { "Chap4_1020_Item", @"chap4_1020\chap4_1020_item.scn.21" },
            { "Chap4_20_Item", @"chap4_20\chap4_20_item.scn.21" },
            { "Chap4_40_Item", @"chap4_40\chap4_40_item.scn.21" },
            { "Chap4_50_Item", @"chap4_50\chap4_50_item.scn.21" },
            { "Chap5_02_Item", @"chap5_02\chap5_02_item.scn.21" },
            { "Chap5_03_Item", @"chap5_03\chap5_03_item.scn.21" },
            { "Chap5_10_Item", @"chap5_10\chap5_10_item.scn.21" },
            { "FF_02_item", @"ff_02\ff_02_item.scn.21" },
        };

        public sealed class Placement
        {
            public long LocationId;
            public string ScnRel;
            public string GoName;
            public string VanillaGid;
            public string FolderHint;
        }

        public sealed class PatchResult
        {
            public int ForeignPlacements;
            public int PatchedOccurrences;
            public int ScenesWritten;
            public int SkippedNoScn;
            public int SkippedNoMatch;
            public List<string> Notes = new List<string>();
        }

        public static string VanillaSceneRoot
        {
            get { return Path.Combine(AppInfo.AssetsDir, @"natives_vanilla\STM\leveldesign\item\scene"); }
        }

        public static List<Placement> BuildPlacements(IEnumerable<long> foreignLocationIds)
        {
            var want = new HashSet<long>(foreignLocationIds);
            var list = new List<Placement>();
            string path = Path.Combine(AppInfo.AssetsDir, @"Lua\data\ArchipelagoRE9\re9_ap_ids.json");
            if (!File.Exists(path)) throw new FileNotFoundException("re9_ap_ids.json introuvable", path);

            using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path)))
            {
                foreach (JsonElement loc in doc.RootElement.GetProperty("locations").EnumerateArray())
                {
                    long id = loc.GetProperty("id").GetInt64();
                    if (!want.Contains(id)) continue;
                    string gid = Text(loc, "vanilla_game_id");
                    // Même longueur que le porteur (comme ID int fixe RE4R)
                    if (string.IsNullOrEmpty(gid) || gid.Length != PlaceholderGid.Length) continue;
                    if (string.Equals(gid, PlaceholderGid, StringComparison.Ordinal)) continue;

                    string key = FirstFpKey(loc);
                    if (key == null) continue;
                    Placement p = FromKey(id, gid, key);
                    if (p != null) list.Add(p);
                }
            }
            return list;
        }

        private static string FirstFpKey(JsonElement loc)
        {
            JsonElement keys;
            if (!loc.TryGetProperty("keys", out keys) || keys.ValueKind != JsonValueKind.Array) return null;
            foreach (JsonElement k in keys.EnumerateArray())
            {
                string s = k.GetString();
                if (s != null && s.StartsWith("fp::", StringComparison.Ordinal)) return s;
            }
            return null;
        }

        private static Placement FromKey(long id, string gid, string key)
        {
            string body = key.Substring(4);
            int at = body.IndexOf('@');
            if (at >= 0) body = body.Substring(0, at);
            string[] parts = body.Split('/');
            if (parts.Length < 2) return null;

            string go = parts[parts.Length - 1];
            string folderHint = parts.Length >= 2 ? parts[parts.Length - 2] : null;
            string itemSeg = null;
            foreach (string part in parts)
            {
                if (part.IndexOf("Item", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    itemSeg = part;
                    break;
                }
            }
            if (itemSeg == null) return null;

            string scnRel;
            if (!FolderToScn.TryGetValue(itemSeg, out scnRel)) return null;

            return new Placement
            {
                LocationId = id,
                ScnRel = scnRel,
                GoName = go,
                VanillaGid = gid,
                FolderHint = folderHint != null && folderHint.IndexOf("Item", StringComparison.OrdinalIgnoreCase) < 0
                    ? folderHint : null,
            };
        }

        private static string Text(JsonElement e, string name)
        {
            JsonElement v;
            if (!e.TryGetProperty(name, out v)) return "";
            return v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : v.ToString();
        }

        /// <summary>
        /// Comme BioRand : part du vanilla, écrit les scn patchés dans le jeu.
        /// </summary>
        public static PatchResult Apply(string gameFolder, IEnumerable<Placement> placements)
        {
            var result = new PatchResult();
            result.Notes.Add("Modeles Capcom laisses en place (pas de rewrite scn).");
            return result;
        }

        /// <summary>
        /// UpdateModels RE9 : près du GO, rewrite ItemID champ + Layouter/*.pfb → placeholder.
        /// Ne touche JAMAIS au nom de GameObject ni aux .mesh Environment/sm.
        /// </summary>
        private static int PatchBuffer(byte[] data, Placement p)
        {
            byte[] oldId = Utf16.GetBytes(p.VanillaGid);
            byte[] newId = Utf16.GetBytes(PlaceholderGid);
            if (oldId.Length != newId.Length) return 0;

            byte[] go = Utf16.GetBytes(p.GoName);
            int replaced = 0;
            var anchors = new List<int>();

            foreach (int goAt in FindAll(data, go))
                anchors.Add(goAt);

            if (anchors.Count == 0 && !string.IsNullOrEmpty(p.FolderHint) && p.FolderHint.Length >= 2)
            {
                byte[] hint = Utf16.GetBytes(p.FolderHint);
                foreach (int hAt in FindAll(data, hint))
                {
                    int winEnd = Math.Min(data.Length, hAt + 1200);
                    int goAt = IndexOf(data, go, hAt, winEnd);
                    anchors.Add(goAt >= 0 ? goAt : hAt);
                }
            }

            foreach (int anchor in anchors)
            {
                int winFrom = Math.Max(0, anchor - 256);
                int winTo = Math.Min(data.Length, anchor + 2500);
                int n = RewriteAllNear(data, oldId, newId, winFrom, winTo);
                n += RewriteResourcePathsNear(data, anchor, winTo);
                if (n > 0) replaced += n;
            }
            return replaced;
        }

        /// <summary>
        /// 1re paire .mesh + .mdf2 après l'ancre → paths logo (pad null si plus court).
        /// </summary>
        private static int RewriteResourcePathsNear(byte[] data, int from, int end)
        {
            int hits = 0;
            int meshAt, meshChars;
            if (!FindUtf16PathEnding(data, from, end, ".mesh", out meshAt, out meshChars)) return 0;
            if (WritePaddedPath(data, meshAt, meshChars, PlaceholderMeshPath)) hits++;

            int mdfAt, mdfChars;
            int mdfFrom = meshAt + meshChars * 2;
            if (FindUtf16PathEnding(data, mdfFrom, Math.Min(end, mdfFrom + 400), ".mdf2", out mdfAt, out mdfChars))
            {
                if (WritePaddedPath(data, mdfAt, mdfChars, PlaceholderMdfPath)) hits++;
            }
            return hits;
        }

        private static bool FindUtf16PathEnding(byte[] data, int from, int end, string suffix, out int pathStart, out int charCount)
        {
            pathStart = -1;
            charCount = 0;
            byte[] suf = Utf16.GetBytes(suffix);
            int i = IndexOf(data, suf, from, end);
            if (i < 0) return false;
            int start = i;
            while (start >= 2)
            {
                if (data[start - 2] == 0 && data[start - 1] == 0) break;
                start -= 2;
            }
            int nullAt = i + suf.Length;
            if (nullAt + 1 >= data.Length || data[nullAt] != 0 || data[nullAt + 1] != 0) return false;
            pathStart = start;
            charCount = (nullAt - start) / 2;
            return charCount > 0;
        }

        private static bool WritePaddedPath(byte[] data, int at, int oldCharCount, string newPath)
        {
            if (newPath.Length > oldCharCount) return false;
            int clearBytes = (oldCharCount + 1) * 2;
            for (int i = 0; i < clearBytes && at + i < data.Length; i++) data[at + i] = 0;
            byte[] nb = Utf16.GetBytes(newPath);
            Buffer.BlockCopy(nb, 0, data, at, nb.Length);
            return true;
        }

        /// <summary>
        /// Rewrite toutes les occurrences éligibles de oldId dans la fenêtre :
        /// - .../oldId.pfb (Layouter) → placeholder.pfb
        /// - champ ItemID oldId (pas nom GO / pas suffixe _01)
        /// </summary>
        private static int RewriteAllNear(byte[] data, byte[] oldId, byte[] newId, int from, int end)
        {
            int hits = 0;
            int at = from;
            while (at < end)
            {
                int i = IndexOf(data, oldId, at, end);
                if (i < 0) break;

                if (IsItemIdBoundary(data, i, oldId.Length) && !IsGameObjectName(data, i, oldId.Length))
                {
                    Buffer.BlockCopy(newId, 0, data, i, newId.Length);
                    hits++;
                }
                at = i + 2;
            }
            return hits;
        }

        /// <summary>
        /// Nom de GO item : id suivi de près par "Gimmick".
        /// </summary>
        private static bool IsGameObjectName(byte[] data, int idAt, int idByteLen)
        {
            int from = idAt + idByteLen;
            int win = Math.Min(data.Length, from + 96);
            return IndexOf(data, GimmickUtf16, from, win) >= 0;
        }

        private static bool IsItemIdBoundary(byte[] data, int at, int idByteLen)
        {
            if (at >= 2)
            {
                char prev = (char)(data[at - 2] | (data[at - 1] << 8));
                if (IsIdentChar(prev)) return false;
            }
            int after = at + idByteLen;
            if (after + 1 >= data.Length) return true;
            char next = (char)(data[after] | (data[after + 1] << 8));
            // \0 (champ) ou '.' (.pfb Layouter) OK
            if (next == '\0' || next == '.') return true;
            return !IsIdentChar(next);
        }

        private static bool IsIdentChar(char c)
        {
            return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
        }

        private static List<int> FindAll(byte[] data, byte[] needle)
        {
            var list = new List<int>();
            int start = 0;
            while (true)
            {
                int i = IndexOf(data, needle, start, data.Length);
                if (i < 0) break;
                list.Add(i);
                start = i + 2;
            }
            return list;
        }

        private static int IndexOf(byte[] data, byte[] needle, int start, int end)
        {
            if (needle.Length == 0 || end - start < needle.Length) return -1;
            int last = end - needle.Length;
            for (int i = start; i <= last; i++)
            {
                bool ok = true;
                for (int j = 0; j < needle.Length; j++)
                {
                    if (data[i + j] != needle[j]) { ok = false; break; }
                }
                if (ok) return i;
            }
            return -1;
        }
    }
}
