using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace RE9.AP.Launcher.Core
{
    public sealed class ClientStatus
    {
        public bool GameFound;
        public bool ReFramework;
        public bool ClientInstalled;
        public bool ClientUpToDate;
        public bool ConnectionWritten;
        public string ConnectionSummary = "";
        public List<string> LegacyActive = new List<string>();
    }

    public static class ClientInstaller
    {
        public const string EntryScript = @"reframework\autorun\ArchipelagoRE9.lua";
        public const string ModuleDir = @"reframework\autorun\ArchipelagoRE9";
        public const string DataDir = @"reframework\data\ArchipelagoRE9";

        private static readonly string[] LegacyScripts =
        {
            @"reframework\autorun\AP_client.lua",
            @"reframework\autorun\randomizer\pickup.lua",
            @"reframework\autorun\ArchipelagoRE9_old.lua",
        };

        private static readonly string[] DataFiles = { "re9_ap_ids.json", "item_list.json", "client_version.json" };

        // Optionnels : installés seulement depuis « État de la configuration »
        public const string ChapterSkipFile = "chapterskip.lua";
        private const string OptionalDir = @"Lua\Optional";
        private static readonly string[] OptionalModules = { ChapterSkipFile };

        // Overlays Modular Chapter Skip (MaVeRicK) — requis pour le dialogue + scènes de skip
        private const string ChapterSkipNativesDir = "natives";
        private static readonly string[] ChapterSkipNativeFiles =
        {
            @"STM\GameAssets\Content\MainGame\Scene\Chap1_01.scn.21",
            @"STM\GameAssets\Content\MainGame\Scene\Chap1_10.scn.21",
            @"STM\GameAssets\Content\MainGame\Scene\Chap3_10.scn.21",
            @"STM\GameAssets\Content\MainGame\Scene\Chap3_20.scn.21",
            @"STM\GameAssets\Content\MainGame\Scene\Chap3_40.scn.21",
            @"STM\GUI\UserData\GuiDialogBoxUserData.user.3",
            @"STM\LevelDesign\Chapter\Chap4_10\Chap4_10_level.scn.21",
            @"STM\LevelDesign\Item\UserData\InventorySetupUserData\Chap1_10_InventorySetupUserData.user.3",
            @"STM\Message\GUI\GUI_DialogBox.msg.23",
        };

        private static bool IsOptional(string file)
        {
            return Array.IndexOf(OptionalModules, Path.GetFileName(file).ToLowerInvariant()) >= 0;
        }

        private static string Assets
        {
            get { return AppInfo.AssetsDir; }
        }

        public static bool PayloadReady(out string missing)
        {
            string[] required =
            {
                @"Lua\ArchipelagoRE9.lua",
                @"Lua\ArchipelagoRE9\apclient.lua",
                @"Lua\data\ArchipelagoRE9\re9_ap_ids.json",
                @"native\lua-apclientpp.dll",
            };
            foreach (string r in required)
            {
                if (!File.Exists(Path.Combine(Assets, r)))
                {
                    missing = Path.Combine(Assets, r);
                    return false;
                }
            }
            missing = null;
            return true;
        }

        public static ClientStatus Inspect(string game)
        {
            ClientStatus s = new ClientStatus();
            s.GameFound = GameLocator.IsGameFolder(game);
            if (!s.GameFound) return s;
            s.ReFramework = File.Exists(Path.Combine(game, "dinput8.dll"));
            s.ClientInstalled = File.Exists(Path.Combine(game, EntryScript))
                && File.Exists(Path.Combine(game, "lua-apclientpp.dll"))
                && File.Exists(Path.Combine(game, DataDir, "re9_ap_ids.json"));
            s.ClientUpToDate = s.ClientInstalled && SameAsPayload(game);
            foreach (string legacy in LegacyScripts)
            {
                if (File.Exists(Path.Combine(game, legacy))) s.LegacyActive.Add(legacy);
            }
            string conn = Path.Combine(game, DataDir, "ap_connection.json");
            if (File.Exists(conn))
            {
                try
                {
                    using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(conn)))
                    {
                        string server = Str(doc.RootElement, "server_address");
                        string slot = Str(doc.RootElement, "slot_name");
                        s.ConnectionWritten = server.Length > 0 && slot.Length > 0;
                        s.ConnectionSummary = slot + " @ " + server;
                    }
                }
                catch (Exception)
                {
                }
            }
            return s;
        }

        private static bool SameAsPayload(string game)
        {
            try
            {
                foreach (string file in Directory.GetFiles(Path.Combine(Assets, @"Lua\ArchipelagoRE9"), "*.lua"))
                {
                    if (IsOptional(file)) continue;
                    string target = Path.Combine(game, ModuleDir, Path.GetFileName(file));
                    if (!File.Exists(target) || !Hashing.EqualsHex(Hashing.Sha256File(file), Hashing.Sha256File(target)))
                        return false;
                }
                foreach (string name in DataFiles)
                {
                    string src = Path.Combine(Assets, @"Lua\data\ArchipelagoRE9", name);
                    string dst = Path.Combine(game, DataDir, name);
                    if (!File.Exists(src)) continue;
                    if (!File.Exists(dst) || !Hashing.EqualsHex(Hashing.Sha256File(src), Hashing.Sha256File(dst)))
                        return false;
                }
                string entrySrc = Path.Combine(Assets, @"Lua\ArchipelagoRE9.lua");
                string entryDst = Path.Combine(game, EntryScript);
                if (File.Exists(entrySrc) && (!File.Exists(entryDst)
                    || !Hashing.EqualsHex(Hashing.Sha256File(entrySrc), Hashing.Sha256File(entryDst))))
                    return false;
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        private static string Str(JsonElement e, string name)
        {
            JsonElement v;
            return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String ? v.GetString().Trim() : "";
        }

        public static void Install(string game, bool disableLegacy)
        {
            if (!GameLocator.IsGameFolder(game)) throw new InvalidOperationException(Lang.T("Dossier du jeu invalide : re9.exe introuvable."));
            if (GameLocator.IsGameRunning()) throw new InvalidOperationException(Lang.T("RE Requiem est lancé. Ferme le jeu avant d'installer le client."));
            string missing;
            if (!PayloadReady(out missing)) throw new FileNotFoundException(Lang.TF("Fichier du client manquant dans assets : {0}", missing));

            Copy(@"native\lua-apclientpp.dll", "lua-apclientpp.dll", game);
            Copy(@"native\THIRD-PARTY-NOTICES-lua-apclientpp.txt", "THIRD-PARTY-NOTICES-lua-apclientpp.txt", game);
            // Pont Python (reste dans assets/bridge du lanceur ; démarré par BridgeHost)
            Copy(@"Lua\ArchipelagoRE9.lua", EntryScript, game);
            foreach (string file in Directory.GetFiles(Path.Combine(Assets, @"Lua\ArchipelagoRE9"), "*.lua"))
            {
                if (IsOptional(file)) continue;
                Copy(@"Lua\ArchipelagoRE9\" + Path.GetFileName(file), Path.Combine(ModuleDir, Path.GetFileName(file)), game);
            }
            foreach (string name in OptionalModules)
            {
                if (OptionalInstalled(game, name))
                {
                    Copy(Path.Combine(OptionalDir, name), Path.Combine(ModuleDir, name), game);
                    if (name == ChapterSkipFile) InstallChapterSkipNatives(game);
                }
            }
            foreach (string name in DataFiles)
            {
                Copy(@"Lua\data\ArchipelagoRE9\" + name, Path.Combine(DataDir, name), game);
            }

            if (disableLegacy)
            {
                foreach (string legacy in LegacyScripts)
                {
                    string path = Path.Combine(game, legacy);
                    if (!File.Exists(path)) continue;
                    string disabled = path + ".disabled";
                    if (File.Exists(disabled)) File.Delete(disabled);
                    File.Move(path, disabled);
                    Log.Info("Ancien script désactivé : " + legacy);
                }
            }
            Log.Info("Client Archipelago RE Requiem installé dans " + game);
        }

        /// <summary>
        /// Style RE4R (1.0.73) : scout foreign → ItemID + Layouter.pfb → Empty Injector.
        /// </summary>
        public static ApScenePatcher.PatchResult InstallApScenePatches(string game, IEnumerable<long> foreignLocationIds)
        {
            var placements = ApScenePatcher.BuildPlacements(foreignLocationIds);
            ApScenePatcher.PatchResult r = ApScenePatcher.Apply(game, placements);
            foreach (string note in r.Notes) Log.Info("AP scene patch : " + note);
            return r;
        }

        /// <summary>
        /// Re-patche les scn depuis session_state.json (scouts mine=false), sans re-contacter le serveur.
        /// </summary>
        public static ApScenePatcher.PatchResult TryInstallApScenePatchesFromSession(string game)
        {
            string sessionPath = Path.Combine(game, DataDir, "session_state.json");
            if (!File.Exists(sessionPath)) return null;
            var foreign = new List<long>();
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(sessionPath)))
                {
                    JsonElement scouts;
                    if (!doc.RootElement.TryGetProperty("scouts", out scouts)) return null;
                    foreach (JsonProperty p in scouts.EnumerateObject())
                    {
                        long id;
                        if (!long.TryParse(p.Name, out id)) continue;
                        JsonElement mine;
                        if (p.Value.TryGetProperty("mine", out mine) && mine.ValueKind == JsonValueKind.True)
                            continue;
                        foreign.Add(id);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("session_state scouts illisibles : " + ex.Message);
                return null;
            }
            if (foreign.Count == 0)
            {
                Log.Info("AP scene patch : 0 foreign dans session_state");
                return null;
            }
            return InstallApScenePatches(game, foreign);
        }

        private static void Copy(string source, string destination, string game)
        {
            string from = Path.Combine(Assets, source);
            if (!File.Exists(from))
            {
                Log.Warn("Absent du paquet, ignoré : " + source);
                return;
            }
            string to = Path.Combine(game, destination);
            Directory.CreateDirectory(Path.GetDirectoryName(to));
            File.Copy(from, to, true);
            string expect = Hashing.Sha256File(from);
            string actual = Hashing.Sha256File(to);
            if (!Hashing.EqualsHex(expect, actual))
                throw new InvalidDataException(Lang.TF(
                    "Copie altérée dans le jeu : {0} (SHA256 incorrect). Réessaie l'installation.", destination));
            Log.Info("Copié " + destination + " (SHA256 OK)");
        }

        // Sans relevé de room, on garde celui déjà écrit pour le même serveur et le même slot.
        public static void WriteConnection(string game, string server, string slot, string password, RoomProbeResult room = null)
        {
            string dir = Path.Combine(game, DataDir);
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, "ap_connection.json");
            Dictionary<string, object> data = new Dictionary<string, object>
            {
                { "server_address", server ?? "" },
                { "slot_name", slot ?? "" },
                { "password", password ?? "" },
            };
            if (room != null && room.Ok)
            {
                data["seed"] = room.Seed;
                data["difficulty"] = room.Difficulty;
                data["key_items"] = room.KeyItems;
                data["locations"] = room.Locations;
            }
            else if ((server ?? "").Length > 0)
            {
                KeepRoomInfo(file, server, slot, data);
            }
            File.WriteAllText(file, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            Log.Info("Connexion enregistrée pour le jeu : " + slot + " @ " + server
                + (data.ContainsKey("locations") ? " (" + ((System.Collections.ICollection)data["locations"]).Count + " checks relevés)" : ""));
        }

        private static void KeepRoomInfo(string file, string server, string slot, Dictionary<string, object> data)
        {
            if (!File.Exists(file)) return;
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(file)))
                {
                    JsonElement root = doc.RootElement;
                    if (Str(root, "server_address") != server || Str(root, "slot_name") != slot) return;
                    JsonElement locs;
                    if (!root.TryGetProperty("locations", out locs) || locs.ValueKind != JsonValueKind.Array) return;
                    List<long> ids = new List<long>();
                    foreach (JsonElement id in locs.EnumerateArray()) ids.Add(id.GetInt64());
                    data["seed"] = Str(root, "seed");
                    data["difficulty"] = Str(root, "difficulty");
                    data["key_items"] = Str(root, "key_items");
                    data["locations"] = ids;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("Relevé de room précédent illisible : " + ex.Message);
            }
        }

        // Fichier vide valide plutôt que supprimé : REFramework affiche une erreur si le fichier manque.
        public static void ResetSessionState(string game, string seed, string slot)
        {
            if (SessionMatches(game, seed, slot))
            {
                Log.Info("État de session gardé : même seed et même slot que la partie en cours dans le jeu.");
                return;
            }
            foreach (KeyValuePair<string, string> f in new Dictionary<string, string> { { "session_state.json", "{}" }, { "last_pickups.json", "[]" } })
            {
                string path = Path.Combine(game, DataDir, f.Key);
                if (!File.Exists(path)) continue;
                string backup = path + "." + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".bak";
                File.Move(path, backup);
                File.WriteAllText(path, f.Value);
                Log.Info("Ancien état de session archivé : " + Path.GetFileName(backup));
            }
        }

        private static bool SessionMatches(string game, string seed, string slot)
        {
            if (string.IsNullOrEmpty(seed)) return false;
            string path = Path.Combine(game, DataDir, "session_state.json");
            if (!File.Exists(path)) return false;
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path)))
                {
                    JsonElement root = doc.RootElement;
                    return Str(root, "seed") == seed && Str(root, "slot") == slot;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("session_state.json illisible : " + ex.Message);
                return false;
            }
        }

        public static void Uninstall(string game)
        {
            if (GameLocator.IsGameRunning()) throw new InvalidOperationException(Lang.T("Ferme RE Requiem avant de retirer le client."));
            List<string> files = new List<string> { "lua-apclientpp.dll", "THIRD-PARTY-NOTICES-lua-apclientpp.txt", EntryScript };
            string modules = Path.Combine(game, ModuleDir);
            if (Directory.Exists(modules))
            {
                Directory.Delete(modules, true);
                Log.Info("Retiré " + ModuleDir);
            }
            foreach (string f in files)
            {
                string path = Path.Combine(game, f);
                if (!File.Exists(path)) continue;
                File.Delete(path);
                Log.Info("Retiré " + f);
            }
            Log.Info("Client retiré. Les données de partie (" + DataDir + ") sont conservées.");
        }

        public static bool OptionalAvailable(string name)
        {
            return File.Exists(Path.Combine(Assets, OptionalDir, name));
        }

        public static bool OptionalInstalled(string game, string name)
        {
            return GameLocator.IsGameFolder(game) && File.Exists(Path.Combine(game, ModuleDir, name));
        }

        public static bool OptionalUpToDate(string game, string name)
        {
            string src = Path.Combine(Assets, OptionalDir, name);
            string dst = Path.Combine(game, ModuleDir, name);
            try
            {
                return File.Exists(src) && File.Exists(dst) && HashOf(src) == HashOf(dst);
            }
            catch (Exception)
            {
                return false;
            }
        }

        // Le jeu peut rester lancé : « Reset Scripts » dans REFramework recharge le client.
        public static void InstallOptional(string game, string name)
        {
            if (!Inspect(game).ClientInstalled) throw new InvalidOperationException(Lang.T("Installe d'abord le client Archipelago RE Requiem."));
            if (!OptionalAvailable(name)) throw new FileNotFoundException(Lang.TF("Fichier du client manquant dans assets : {0}", Path.Combine(Assets, OptionalDir, name)));
            Copy(Path.Combine(OptionalDir, name), Path.Combine(ModuleDir, name), game);
            if (name == ChapterSkipFile) InstallChapterSkipNatives(game);
            Log.Info("Module optionnel installé : " + name);
        }

        public static void UninstallOptional(string game, string name)
        {
            string path = Path.Combine(game, ModuleDir, name);
            if (!File.Exists(path)) return;
            File.Delete(path);
            if (name == ChapterSkipFile) RemoveChapterSkipNatives(game);
            Log.Info("Module optionnel retiré : " + name);
        }

        private static void InstallChapterSkipNatives(string game)
        {
            string root = Path.Combine(Assets, ChapterSkipNativesDir);
            if (!Directory.Exists(root))
            {
                Log.Warn("Natives Chapter Skip absents du paquet : " + root);
                return;
            }
            int n = 0;
            foreach (string rel in ChapterSkipNativeFiles)
            {
                string from = Path.Combine(root, rel);
                if (!File.Exists(from))
                {
                    Log.Warn("Natif Chapter Skip manquant : " + rel);
                    continue;
                }
                string to = Path.Combine(game, ChapterSkipNativesDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                File.Copy(from, to, true);
                n++;
            }
            Log.Info("Chapter Skip natives installés : " + n + " fichier(s)");
        }

        private static void RemoveChapterSkipNatives(string game)
        {
            int n = 0;
            foreach (string rel in ChapterSkipNativeFiles)
            {
                string path = Path.Combine(game, ChapterSkipNativesDir, rel);
                if (!File.Exists(path)) continue;
                File.Delete(path);
                n++;
            }
            Log.Info("Chapter Skip natives retirés : " + n + " fichier(s)");
        }

        private static string HashOf(string file)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
            using (FileStream fs = File.OpenRead(file))
            {
                return Convert.ToHexString(sha.ComputeHash(fs));
            }
        }

        public static string DataFolder(string game)
        {
            return Path.Combine(game, DataDir);
        }
    }
}
