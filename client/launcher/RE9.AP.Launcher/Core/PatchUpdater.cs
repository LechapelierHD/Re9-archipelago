using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace RE9.AP.Launcher.Core
{
    public sealed class PatchInfo
    {
        public string Version = "";
        public string Date = "";
        public string Title = "";
        public string Label = "";
        public List<string> Notes = new List<string>();
        public string TitleEn = "";
        public List<string> NotesEn = new List<string>();
        public string File = "";
        public string Sha256 = "";   // empreinte du zip (patches.json)

        public string Name
        {
            get { return Label.Length > 0 ? Label : Version; }
        }

        public string LocalTitle
        {
            get { return Lang.English && TitleEn.Length > 0 ? TitleEn : Title; }
        }

        public List<string> LocalNotes
        {
            get { return Lang.English && NotesEn.Count > 0 ? NotesEn : Notes; }
        }
    }

    public sealed class PatchFeed
    {
        public string Source = "";
        public string DeclaredLatest = "";
        public List<PatchInfo> Patches = new List<PatchInfo>();
        public string Error;
        public Dictionary<string, string> Assets = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public PatchInfo Latest
        {
            get
            {
                // patches.json « latest » gagne (ex. epoch « 1.0 » après une série 1.0.x)
                if (DeclaredLatest.Length > 0)
                {
                    foreach (PatchInfo p in Patches)
                    {
                        if (string.Equals(p.Version, DeclaredLatest, StringComparison.OrdinalIgnoreCase))
                            return p;
                    }
                }
                PatchInfo best = null;
                foreach (PatchInfo p in Patches)
                {
                    if (best == null || PatchUpdater.Compare(p.Version, best.Version) > 0) best = p;
                }
                return best;
            }
        }

        public List<PatchInfo> NewerThan(string version)
        {
            List<PatchInfo> list = new List<PatchInfo>();
            PatchInfo declared = null;
            foreach (PatchInfo p in Patches)
            {
                if (DeclaredLatest.Length > 0
                    && string.Equals(p.Version, DeclaredLatest, StringComparison.OrdinalIgnoreCase))
                {
                    declared = p;
                    continue;
                }
                if (PatchUpdater.Compare(p.Version, version) > 0) list.Add(p);
            }
            // Déjà sur le latest déclaré : un numéro plus haut (ancienne série) n'est pas une mise à jour.
            if (declared != null
                && string.Equals(declared.Version, version ?? "", StringComparison.OrdinalIgnoreCase))
                return new List<PatchInfo>();
            // Epoch déclaré (ex. 1.0) : proposé dès que l'installée n'est pas déjà cette version.
            // Un patch au numéro plus haut que ce latest reste une ancienne série.
            if (declared != null)
                list.RemoveAll(p => PatchUpdater.Compare(p.Version, declared.Version) > 0);
            if (declared != null
                && !string.Equals(declared.Version, version ?? "", StringComparison.OrdinalIgnoreCase))
            {
                list.RemoveAll(p => PatchUpdater.Compare(declared.Version, p.Version) >= 0
                    || IsSameSeries(declared.Version, p.Version));
                list.Insert(0, declared);
            }
            list.Sort((a, b) =>
            {
                if (declared != null)
                {
                    if (ReferenceEquals(a, declared)) return -1;
                    if (ReferenceEquals(b, declared)) return 1;
                }
                return PatchUpdater.Compare(b.Version, a.Version);
            });
            return list;
        }

        // « 1.0 » remplace toute la série 1.0.x (ne pas proposer 1.0.104 par-dessus)
        private static bool IsSameSeries(string epoch, string other)
        {
            if (string.IsNullOrEmpty(epoch) || string.IsNullOrEmpty(other)) return false;
            if (epoch.IndexOf('.') < 0) return other.StartsWith(epoch + ".", StringComparison.Ordinal);
            // epoch "1.0" → série "1.0."
            return other.StartsWith(epoch + ".", StringComparison.OrdinalIgnoreCase);
        }
    }

    // Chaque zip est une copie complète des scripts, données et apworld : appliquer le dernier suffit.
    public static class PatchUpdater
    {
        public const string FeedFile = "patches.json";
        public const string FolderName = "RE9 AP Patches";
        public const string VersionFile = @"Lua\data\ArchipelagoRE9\client_version.json";
        public const string LauncherEntry = @"Launcher\RE9.AP.Launcher.exe";

        public static bool LauncherReplaced { get; private set; }

        // Seulement le lanceur publié (pas « dotnet » en développement)
        private static string RunningExe
        {
            get
            {
                string exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return null;
                return Path.GetFileName(exe).Equals("RE9.AP.Launcher.exe", StringComparison.OrdinalIgnoreCase) ? exe : null;
            }
        }

        public static void CleanupOldLauncher()
        {
            string exe = RunningExe;
            if (exe == null) return;
            foreach (string old in Directory.GetFiles(Path.GetDirectoryName(exe), Path.GetFileName(exe) + ".old*"))
            {
                try
                {
                    File.Delete(old);
                }
                catch (Exception)
                {
                }
            }
        }

        // Anciens lanceurs : patch local lu seulement dans « RE9 AP Patches ». On le range, sinon il passerait avant GitHub.
        // Le dossier de publication (avec notes_en.json) n'est jamais touché.
        public static void RetireOldDropFolder()
        {
            string exe = RunningExe;
            if (exe == null || (Settings.Current.PatchSource ?? "").Trim().Length > 0) return;
            string folder = Path.Combine(Path.GetDirectoryName(exe), FolderName);
            if (!Directory.Exists(folder) || File.Exists(Path.Combine(folder, "notes_en.json"))) return;
            try
            {
                string feed = Path.Combine(folder, FeedFile);
                string latest = File.Exists(feed) ? ReadVersion(feed, "latest") : null;
                if (latest != null && Compare(latest, CurrentVersion) > 0) return;
                string done = Path.Combine(ManualFolder, ManualDoneName);
                Directory.CreateDirectory(done);
                string to = Path.Combine(done, FolderName + " " + DateTime.Now.ToString("yyyyMMdd_HHmmss"));
                Directory.Move(folder, to);
                Log.Info("Dossier « " + FolderName + " » rangé dans " + to + " : les mises à jour reviennent sur GitHub.");
            }
            catch (Exception ex)
            {
                Log.Warn("Dossier « " + FolderName + " » non rangé : " + ex.Message);
            }
        }

        // Jamais renommer l'exe en cours : en « single file » il relit ses assemblies dedans et plante s'il est déplacé.
        // Le nouvel exe attend en .new ; RestartIntoNewLauncher le met en place après la fin du processus.
        private static bool ReplaceLauncher(string newExe)
        {
            string exe = RunningExe;
            if (exe == null)
            {
                Log.Warn("Lanceur non remplacé : il ne tourne pas depuis RE9.AP.Launcher.exe.");
                return false;
            }
            File.Copy(newExe, exe + ".new", true);
            Log.Info("Nouveau lanceur prêt : " + exe + ".new");
            return true;
        }

        public static void RestartIntoNewLauncher()
        {
            string exe = RunningExe;
            if (exe == null) return;
            string script =
                "$p = Get-Process -Id " + Environment.ProcessId + " -ErrorAction SilentlyContinue; if ($p) { [void]$p.WaitForExit(30000) }; " +
                "for ($i = 0; $i -lt 30; $i++) { try { Move-Item -LiteralPath '" + (exe + ".new").Replace("'", "''") + "' -Destination '" + exe.Replace("'", "''") + "' -Force -ErrorAction Stop; break } catch { Start-Sleep -Seconds 1 } }; " +
                "Start-Process -FilePath '" + exe.Replace("'", "''") + "'";
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("powershell.exe")
            {
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + script.Replace("\"", "\\\"") + "\"",
                CreateNoWindow = true,
                UseShellExecute = false,
            });
            Log.Info("Redémarrage sur le nouveau lanceur.");
        }

        public static string CurrentVersion
        {
            get { return ReadVersion(Path.Combine(AppInfo.AssetsDir, VersionFile)) ?? AppInfo.Version; }
        }

        // Affichage (ex. « 1.0 ») ; la comparaison utilise CurrentVersion
        public static string CurrentLabel
        {
            get
            {
                string label = ReadVersion(Path.Combine(AppInfo.AssetsDir, VersionFile), "label");
                if (!string.IsNullOrEmpty(label)) return label;
                return CurrentVersion;
            }
        }

        // null si client absent ou trop ancien
        public static string GameVersion(string gamePath)
        {
            if (string.IsNullOrEmpty(gamePath)) return null;
            return ReadVersion(Path.Combine(gamePath, @"reframework\data\ArchipelagoRE9\client_version.json"));
        }

        public static string GameLabel(string gamePath)
        {
            if (string.IsNullOrEmpty(gamePath)) return null;
            string label = ReadVersion(Path.Combine(gamePath, @"reframework\data\ArchipelagoRE9\client_version.json"), "label");
            if (!string.IsNullOrEmpty(label)) return label;
            return GameVersion(gamePath);
        }

        // Après apply : version = ordre de MAJ ; label = texte affiché (ex. « 1.0 »)
        private static void StampClientVersion(string assetsDir, PatchInfo patch)
        {
            if (patch == null || string.IsNullOrEmpty(patch.Version)) return;
            string path = Path.Combine(assetsDir, VersionFile);
            string apworld = "";
            try
            {
                if (File.Exists(path))
                {
                    using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8)))
                    {
                        JsonElement a;
                        if (doc.RootElement.TryGetProperty("apworld", out a) && a.ValueKind == JsonValueKind.String)
                            apworld = (a.GetString() ?? "").Trim();
                    }
                }
            }
            catch (Exception)
            {
            }
            string shown = !string.IsNullOrEmpty(patch.Label) ? patch.Label : patch.Version;
            var obj = new Dictionary<string, object>
            {
                ["version"] = patch.Version,
                ["date"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm"),
                ["label"] = shown,
            };
            if (apworld.Length > 0) obj["apworld"] = apworld;
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true }), Encoding.UTF8);
            Log.Info("Version affichée : " + shown + " (compare " + patch.Version + ")");
        }

        private static string ReadVersion(string file, string field = "version")
        {
            try
            {
                if (File.Exists(file))
                {
                    using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(file)))
                    {
                        JsonElement v;
                        if (doc.RootElement.TryGetProperty(field, out v) && v.ValueKind == JsonValueKind.String && v.GetString().Trim().Length > 0)
                            return v.GetString().Trim();
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("Version du client illisible (" + file + ") : " + ex.Message);
            }
            return null;
        }

        public static string DefaultSource
        {
            get
            {
                DirectoryInfo dir = new DirectoryInfo(AppContext.BaseDirectory);
                while (dir != null)
                {
                    string candidate = Path.Combine(dir.FullName, FolderName);
                    if (Directory.Exists(candidate)) return candidate;
                    dir = dir.Parent;
                }
                return "";
            }
        }

        // Réglage PatchSource, sinon « RE9 AP Patches » (PC de développement), sinon GitHub
        public static string Source
        {
            get
            {
                string custom = (Settings.Current.PatchSource ?? "").Trim();
                if (custom.Length > 0) return custom;
                string local = DefaultSource;
                return local.Length > 0 ? local : AppInfo.UpdateFeedUrl;
            }
        }

        private static bool IsWeb(string source)
        {
            return source.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                || source.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        }

        // « github:proprio/dépôt » : dépôt privé lu par l'API avec AppInfo.UpdateToken
        private static bool IsGitHub(string source)
        {
            return source.StartsWith("github:", StringComparison.OrdinalIgnoreCase);
        }

        public static bool IsRemote(string source)
        {
            return IsWeb(source) || IsGitHub(source);
        }

        private static HttpRequestMessage GitHubRequest(string url, string accept)
        {
            HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Accept.ParseAdd(accept);
            if (AppInfo.UpdateToken.Length > 0)
                req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", AppInfo.UpdateToken);
            req.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
            return req;
        }

        private static async Task<HttpResponseMessage> GitHubGetAsync(string url, string accept)
        {
            HttpResponseMessage resp = await Http.SendAsync(GitHubRequest(url, accept));
            if (resp.IsSuccessStatusCode) return resp;
            int code = (int)resp.StatusCode;
            resp.Dispose();
            if (code == 401 || code == 404)
                throw new InvalidOperationException(Lang.TF("dépôt des mises à jour inaccessible [{0}]", code));
            if (code == 403 || code == 429)
                throw new InvalidOperationException(Lang.TF("GitHub limite les vérifications pour l'instant, réessaie plus tard [{0}]", code));
            throw new InvalidOperationException(Lang.TF("GitHub a répondu {0}", code));
        }

        private static async Task<string> GitHubFeedAsync(PatchFeed feed)
        {
            string repo = feed.Source.Substring("github:".Length).Trim().Trim('/');
            string json;
            using (HttpResponseMessage resp = await GitHubGetAsync("https://api.github.com/repos/" + repo + "/releases?per_page=50", "application/vnd.github+json"))
            {
                json = await resp.Content.ReadAsStringAsync();
            }
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                foreach (JsonElement release in doc.RootElement.EnumerateArray())
                {
                    JsonElement draft, assets;
                    if (release.TryGetProperty("draft", out draft) && draft.ValueKind == JsonValueKind.True) continue;
                    if (!release.TryGetProperty("assets", out assets) || assets.ValueKind != JsonValueKind.Array) continue;
                    foreach (JsonElement a in assets.EnumerateArray())
                    {
                        string name = Str(a, "name"), url = Str(a, "url");
                        if (name.Length > 0 && url.Length > 0 && !feed.Assets.ContainsKey(name)) feed.Assets[name] = url;
                    }
                }
            }
            string feedUrl;
            if (!feed.Assets.TryGetValue(FeedFile, out feedUrl)) throw new InvalidOperationException(Lang.TF("aucune release avec {0} dans {1}", FeedFile, repo));
            using (HttpResponseMessage resp = await GitHubGetAsync(feedUrl, "application/octet-stream"))
            {
                return await resp.Content.ReadAsStringAsync();
            }
        }

        private static string FeedLocation(string source)
        {
            if (source.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) return source;
            return IsWeb(source) ? source.TrimEnd('/') + "/" + FeedFile : Path.Combine(source, FeedFile);
        }

        private static string ZipLocation(string source, string file)
        {
            if (IsWeb(file) || Path.IsPathRooted(file)) return file;
            string feed = FeedLocation(source);
            if (IsWeb(feed)) return feed.Substring(0, feed.LastIndexOf('/') + 1) + Uri.EscapeDataString(file);
            return Path.Combine(Path.GetDirectoryName(feed), file);
        }

        public static int Compare(string a, string b)
        {
            Version va, vb;
            if (!System.Version.TryParse(Normalize(a), out va)) va = new Version(0, 0, 0);
            if (!System.Version.TryParse(Normalize(b), out vb)) vb = new Version(0, 0, 0);
            return va.CompareTo(vb);
        }

        private static string Normalize(string v)
        {
            v = (v ?? "").Trim().TrimStart('v', 'V');
            return v.Contains(".") ? v : v + ".0";
        }

        private static readonly HttpClient Http = CreateHttp();

        private static HttpClient CreateHttp()
        {
            // Le patch peut contenir le lanceur (~60 Mo)
            HttpClient http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("RE9-AP-Wizard/" + AppInfo.Version);
            return http;
        }

        public static async Task<PatchFeed> CheckAsync()
        {
            PatchFeed feed = new PatchFeed { Source = Source };
            if (feed.Source.Length == 0)
            {
                feed.Error = Lang.TF("Aucune source de mises à jour (dossier « {0} » introuvable).", FolderName);
                return feed;
            }
            try
            {
                string location = IsGitHub(feed.Source) ? feed.Source : FeedLocation(feed.Source);
                string text;
                if (IsGitHub(location))
                {
                    text = await GitHubFeedAsync(feed);
                }
                else if (IsWeb(location))
                {
                    text = await Http.GetStringAsync(location);
                }
                else
                {
                    if (!File.Exists(location))
                    {
                        feed.Error = Lang.TF("Fichier de mises à jour introuvable : {0}", location);
                        return feed;
                    }
                    text = await Task.Run(() => File.ReadAllText(location));
                }
                using (JsonDocument doc = JsonDocument.Parse(text))
                {
                    JsonElement latestEl;
                    if (doc.RootElement.TryGetProperty("latest", out latestEl)
                        && latestEl.ValueKind == JsonValueKind.String)
                    {
                        feed.DeclaredLatest = latestEl.GetString() ?? "";
                    }
                    JsonElement list;
                    if (doc.RootElement.TryGetProperty("patches", out list) && list.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement e in list.EnumerateArray())
                        {
                            PatchInfo p = new PatchInfo
                            {
                                Version = Str(e, "version"),
                                Date = Str(e, "date"),
                                Title = Str(e, "title"),
                                Label = Str(e, "label"),
                                TitleEn = Str(e, "title_en"),
                                File = Str(e, "file"),
                                Sha256 = Str(e, "sha256"),
                            };
                            ReadNotes(e, "notes", p.Notes);
                            ReadNotes(e, "notes_en", p.NotesEn);
                            if (p.Version.Length > 0 && p.File.Length > 0) feed.Patches.Add(p);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                feed.Error = Lang.TF("Vérification des mises à jour impossible : {0}", ex.Message);
            }
            return feed;
        }

        private static void ReadNotes(JsonElement e, string name, List<string> into)
        {
            JsonElement notes;
            if (!e.TryGetProperty(name, out notes) || notes.ValueKind != JsonValueKind.Array) return;
            foreach (JsonElement n in notes.EnumerateArray())
            {
                if (n.ValueKind == JsonValueKind.String) into.Add(n.GetString());
            }
        }

        private static string Str(JsonElement e, string name)
        {
            JsonElement v;
            return e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String ? v.GetString().Trim() : "";
        }

        // Zip de patch téléchargé à la main : installé comme une mise à jour en ligne puis rangé dans « installés ».
        public const string ManualFolderName = "Patchs";
        public const string ManualDoneName = "installés";

        public static string ManualFolder
        {
            get
            {
                string exe = RunningExe;
                string dir = Path.Combine(exe != null ? Path.GetDirectoryName(exe) : AppContext.BaseDirectory, ManualFolderName);
                try
                {
                    Directory.CreateDirectory(dir);
                }
                catch (Exception ex)
                {
                    Log.Warn("Dossier des patchs impossible à créer (" + dir + ") : " + ex.Message);
                }
                return dir;
            }
        }

        public static string ManualDoneFolder
        {
            get { return Path.Combine(ManualFolder, ManualDoneName); }
        }

        // Cache lanceur : %AppData%\RE9-AP-Wizard\patches (zip + sauvegarde_* / extract_*)
        public static string WorkPatchesFolder
        {
            get { return Path.Combine(AppInfo.DataDir, "patches"); }
        }

        private static int CountZipsIn(string dir, bool recursive)
        {
            if (!Directory.Exists(dir)) return 0;
            try
            {
                return Directory.GetFiles(dir, "*.zip",
                    recursive ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly).Length;
            }
            catch { return 0; }
        }

        public static int CountInstalledPatchZips()
        {
            return CountZipsIn(ManualDoneFolder, false) + CountZipsIn(WorkPatchesFolder, true);
        }

        private static int DeleteZipsIn(string dir, bool recursive)
        {
            if (!Directory.Exists(dir)) return 0;
            int n = 0;
            string[] files;
            try
            {
                files = Directory.GetFiles(dir, "*.zip",
                    recursive ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly);
            }
            catch { return 0; }
            foreach (string zip in files)
            {
                try
                {
                    File.Delete(zip);
                    n++;
                }
                catch (Exception ex)
                {
                    Log.Warn("Vieux patch non supprimé (" + zip + ") : " + ex.Message);
                }
            }
            return n;
        }

        // Supprime aussi les dossiers temporaires extract_* / sauvegarde_* du cache AppData.
        private static int DeleteWorkCacheFolders()
        {
            string work = WorkPatchesFolder;
            if (!Directory.Exists(work)) return 0;
            int n = 0;
            foreach (string dir in Directory.GetDirectories(work))
            {
                string name = Path.GetFileName(dir);
                if (name == null) continue;
                bool junk = name.StartsWith("extract_", StringComparison.OrdinalIgnoreCase)
                    || name.StartsWith("sauvegarde_", StringComparison.OrdinalIgnoreCase);
                if (!junk) continue;
                try
                {
                    Directory.Delete(dir, true);
                    n++;
                }
                catch (Exception ex)
                {
                    Log.Warn("Cache patch non supprimé (" + dir + ") : " + ex.Message);
                }
            }
            return n;
        }

        // Patchs\installés + cache AppData\patches — le client / mod en jeu ne sont pas touchés.
        public static int ClearInstalledPatches()
        {
            int n = DeleteZipsIn(ManualDoneFolder, false);
            n += DeleteZipsIn(WorkPatchesFolder, true);
            int folders = DeleteWorkCacheFolders();
            if (n > 0 || folders > 0)
                Log.Info(Lang.TF("{0} vieux patch(s) supprimé(s).", n) + (folders > 0 ? " (+" + folders + " dossier(s) cache)" : ""));
            return n;
        }

        public static PatchInfo ReadZipPatch(string zip)
        {
            try
            {
                using (ZipArchive archive = ZipFile.OpenRead(zip))
                {
                    ZipArchiveEntry entry = archive.GetEntry("patch.json");
                    if (entry == null || (archive.GetEntry("Lua/ArchipelagoRE9.lua") == null && archive.GetEntry("Lua\\ArchipelagoRE9.lua") == null)) return null;
                    using (StreamReader reader = new StreamReader(entry.Open(), Encoding.UTF8))
                    using (JsonDocument doc = JsonDocument.Parse(reader.ReadToEnd()))
                    {
                        JsonElement e = doc.RootElement;
                        PatchInfo p = new PatchInfo
                        {
                            Version = Str(e, "version"),
                            Date = Str(e, "date"),
                            Title = Str(e, "title"),
                            Label = Str(e, "label"),
                            File = zip,
                        };
                        ReadNotes(e, "notes", p.Notes);
                        return p.Version.Length > 0 ? p : null;
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn("Patch illisible (" + zip + ") : " + ex.Message);
                return null;
            }
        }

        public static PatchInfo FindManualPatch()
        {
            string folder = ManualFolder;
            if (!Directory.Exists(folder)) return null;
            string current = CurrentVersion;
            PatchInfo best = null;
            foreach (string zip in Directory.GetFiles(folder, "*.zip"))
            {
                PatchInfo p = ReadZipPatch(zip);
                if (p == null) continue;
                // « 1.0 » remplace la série 1.0.x même si Version.Compare la voit plus petite
                bool epochReplace = string.Equals(p.Version, "1.0", StringComparison.OrdinalIgnoreCase)
                    && (current ?? "").StartsWith("1.0.", StringComparison.OrdinalIgnoreCase);
                if (!epochReplace && Compare(p.Version, current) <= 0)
                {
                    MoveToDone(zip);
                    continue;
                }
                if (best == null || epochReplace || Compare(p.Version, best.Version) > 0) best = p;
            }
            return best;
        }

        private static void MoveToDone(string zip)
        {
            try
            {
                string done = Path.Combine(Path.GetDirectoryName(zip), ManualDoneName);
                Directory.CreateDirectory(done);
                string to = Path.Combine(done, Path.GetFileName(zip));
                if (File.Exists(to)) File.Delete(to);
                File.Move(zip, to);
            }
            catch (Exception ex)
            {
                Log.Warn("Patch non rangé (" + zip + ") : " + ex.Message);
            }
        }

        public static async Task<string> ApplyManualAsync(PatchInfo patch)
        {
            if (GameLocator.IsGameRunning()) throw new InvalidOperationException(Lang.T("RE Requiem est lancé. Ferme le jeu avant de mettre à jour."));
            string work = Path.Combine(AppInfo.DataDir, "patches");
            Directory.CreateDirectory(work);
            string zip = Path.Combine(work, "re9ap_patch_" + patch.Version + ".zip");
            Log.Info("Mise à jour " + patch.Version + " depuis le dossier des patchs : " + patch.File);
            File.Copy(patch.File, zip, true);
            // zip manuel : sha256 lu dans patch.json après extract si absent du PatchInfo
            string summary = await ApplyZipAsync(zip, patch);
            MoveToDone(patch.File);
            return summary;
        }

        public static async Task<string> ApplyAsync(PatchFeed feed, PatchInfo patch)
        {
            if (GameLocator.IsGameRunning()) throw new InvalidOperationException(Lang.T("RE Requiem est lancé. Ferme le jeu avant de mettre à jour."));
            string work = Path.Combine(AppInfo.DataDir, "patches");
            Directory.CreateDirectory(work);
            string zip = Path.Combine(work, "re9ap_patch_" + patch.Version + ".zip");
            string from;
            if (IsGitHub(feed.Source))
            {
                string assetUrl;
                if (!feed.Assets.TryGetValue(patch.File, out assetUrl)) throw new FileNotFoundException(Lang.TF("Patch absent du dépôt des mises à jour : {0}", patch.File));
                Log.Info("Mise à jour " + patch.Version + " : " + feed.Source + " / " + patch.File);
                using (HttpResponseMessage resp = await GitHubGetAsync(assetUrl, "application/octet-stream"))
                {
                    File.WriteAllBytes(zip, await resp.Content.ReadAsByteArrayAsync());
                }
            }
            else
            {
                from = ZipLocation(feed.Source, patch.File);
                Log.Info("Mise à jour " + patch.Version + " : " + from);
                if (IsWeb(from))
                {
                    byte[] bytes = await Http.GetByteArrayAsync(from);
                    File.WriteAllBytes(zip, bytes);
                }
                else
                {
                    if (!File.Exists(from)) throw new FileNotFoundException(Lang.TF("Patch introuvable : {0}", from));
                    File.Copy(from, zip, true);
                }
            }
            return await ApplyZipAsync(zip, patch);
        }

        private static void VerifyZipSha256(string zip, string expected)
        {
            if (string.IsNullOrEmpty(expected))
            {
                Log.Warn(Lang.T("Patch sans empreinte SHA256 dans la liste : vérification zip ignorée (ancien patch)."));
                return;
            }
            if (expected.Length != 64)
                throw new InvalidDataException(Lang.T("Empreinte SHA256 du patch invalide (attendu 64 caractères hex)."));
            string actual = Hashing.Sha256File(zip);
            if (!Hashing.EqualsHex(actual, expected))
            {
                try { File.Delete(zip); } catch (Exception) { }
                throw new InvalidDataException(Lang.TF(
                    "Patch altéré ou corrompu : SHA256 du zip ne correspond pas (reçu {0}…, attendu {1}…). Rien n'a été installé.",
                    actual.Substring(0, 8), expected.Substring(0, 8)));
            }
            Log.Info("SHA256 du zip OK (" + actual.Substring(0, 12) + "…)");
        }

        private static Dictionary<string, string> ReadFileHashes(string patchJsonPath)
        {
            Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(patchJsonPath)) return map;
            using (JsonDocument doc = JsonDocument.Parse(File.ReadAllText(patchJsonPath, Encoding.UTF8)))
            {
                JsonElement files;
                if (!doc.RootElement.TryGetProperty("files", out files) || files.ValueKind != JsonValueKind.Object)
                    return map;
                foreach (JsonProperty prop in files.EnumerateObject())
                {
                    if (prop.Value.ValueKind == JsonValueKind.String)
                    {
                        string hex = prop.Value.GetString().Trim();
                        if (hex.Length == 64) map[Hashing.ManifestPath(prop.Name)] = hex.ToLowerInvariant();
                    }
                }
            }
            return map;
        }

        private static void VerifyExtractedFiles(string extracted, Dictionary<string, string> expected)
        {
            if (expected.Count == 0)
            {
                Log.Warn(Lang.T("patch.json sans liste « files » : vérification fichier par fichier ignorée (ancien patch)."));
                return;
            }
            List<string> bad = new List<string>();
            foreach (KeyValuePair<string, string> kv in expected)
            {
                string path = Path.Combine(extracted, kv.Key.Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(path))
                {
                    bad.Add(kv.Key + " (absent)");
                    continue;
                }
                string actual = Hashing.Sha256File(path);
                if (!Hashing.EqualsHex(actual, kv.Value))
                    bad.Add(kv.Key + " (" + actual.Substring(0, 8) + "… ≠ " + kv.Value.Substring(0, 8) + "…)");
            }
            if (bad.Count > 0)
                throw new InvalidDataException(Lang.TF(
                    "Fichiers du patch altérés ({0}) : {1}. Rien n'a été installé.",
                    bad.Count, string.Join("; ", bad)));
            Log.Info(expected.Count + " fichier(s) vérifiés (SHA256 OK)");
        }

        private static async Task<string> ApplyZipAsync(string zip, PatchInfo patch)
        {
            await Task.Run(() => VerifyZipSha256(zip, patch.Sha256));

            string work = Path.GetDirectoryName(zip);
            string extracted = Path.Combine(work, "extract_" + patch.Version);
            if (Directory.Exists(extracted)) Directory.Delete(extracted, true);
            await Task.Run(() => ZipFile.ExtractToDirectory(zip, extracted));
            if (!File.Exists(Path.Combine(extracted, "patch.json")) || !File.Exists(Path.Combine(extracted, @"Lua\ArchipelagoRE9.lua")))
                throw new InvalidDataException(Lang.T("Ce zip n'est pas un patch du client RE Requiem (patch.json ou scripts absents)."));

            Dictionary<string, string> fileHashes = await Task.Run(() => ReadFileHashes(Path.Combine(extracted, "patch.json")));
            await Task.Run(() => VerifyExtractedFiles(extracted, fileHashes));

            string assets = AppInfo.AssetsDir;
            string backup = Path.Combine(work, "sauvegarde_" + CurrentVersion + "_" + DateTime.Now.ToString("yyyyMMdd_HHmmss"));
            await Task.Run(() =>
            {
                foreach (string sub in new[] { "Lua", "Data" })
                {
                    string src = Path.Combine(assets, sub);
                    if (Directory.Exists(src)) CopyTree(src, Path.Combine(backup, sub));
                }
            });
            Log.Info("Ancienne version sauvegardée : " + backup);

            int copied = 0;
            bool launcher = false;
            await Task.Run(() =>
            {
                foreach (string file in Directory.GetFiles(extracted, "*", SearchOption.AllDirectories))
                {
                    string rel = file.Substring(extracted.Length).TrimStart('\\', '/');
                    if (rel.Equals("patch.json", StringComparison.OrdinalIgnoreCase)) continue;
                    if (rel.Equals(LauncherEntry, StringComparison.OrdinalIgnoreCase))
                    {
                        launcher = ReplaceLauncher(file);
                        continue;
                    }
                    string to = Path.Combine(assets, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(to));
                    File.Copy(file, to, true);
                    string expectKey = Hashing.ManifestPath(rel);
                    string expected;
                    if (fileHashes.TryGetValue(expectKey, out expected))
                    {
                        string actual = Hashing.Sha256File(to);
                        if (!Hashing.EqualsHex(actual, expected))
                            throw new InvalidDataException(Lang.TF(
                                "Copie altérée vers assets : {0} (SHA256 incorrect). Installation annulée.", rel));
                    }
                    copied++;
                }
            });
            Log.Info(copied + " fichier(s) du lanceur mis à jour (SHA256 vérifié)");
            StampClientVersion(assets, patch);
            try { Directory.Delete(extracted, true); } catch (Exception) { }
            if (launcher) LauncherReplaced = true;

            StringBuilder summary = new StringBuilder(Lang.TF("Client mis à jour en version {0}.", patch.Version));
            if (launcher) summary.Append(Lang.T(" Le lanceur a aussi été mis à jour : il va redémarrer."));
            Settings s = Settings.Current;
            if (GameLocator.IsGameFolder(s.GamePath) && ClientInstaller.Inspect(s.GamePath).ClientInstalled)
            {
                ClientInstaller.Install(s.GamePath, s.DisableLegacyScripts);
                if (s.Session != null) s.Session.InstalledAt = DateTime.Now;
                summary.Append(Lang.T(" Installé dans le jeu (ta partie est gardée)."));
                try
                {
                    ApScenePatcher.PatchResult scene = ClientInstaller.TryInstallApScenePatchesFromSession(s.GamePath);
                    if (scene != null && scene.PatchedOccurrences > 0)
                        summary.Append(Lang.TF(" Visuels AP re-patchés ({0} rewrite(s)).", scene.PatchedOccurrences));
                }
                catch (Exception ex)
                {
                    Log.Warn("Re-patch scn AP après update : " + ex.Message);
                }
            }
            else
            {
                summary.Append(Lang.T(" Le client n'est pas encore installé dans le jeu : il le sera en rejoignant un multimonde."));
            }
            if (ArchipelagoTools.IsInstall(s.ArchipelagoPath) && File.Exists(ArchipelagoTools.BundledApworld))
            {
                try
                {
                    ArchipelagoTools.InstallApworld(s.ArchipelagoPath);
                    summary.Append(Lang.T(" apworld mis à jour dans Archipelago."));
                }
                catch (Exception ex)
                {
                    Log.Warn("apworld non mis à jour : " + ex.Message);
                }
            }
            s.Save();
            Log.Info(summary.ToString());
            return summary.ToString();
        }

        private static void CopyTree(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (string file in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
            {
                string target = Path.Combine(to, file.Substring(from.Length).TrimStart('\\', '/'));
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                File.Copy(file, target, true);
            }
        }
    }
}
