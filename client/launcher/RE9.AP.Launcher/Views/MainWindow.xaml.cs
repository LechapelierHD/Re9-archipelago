using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public sealed class FooterAction
    {
        public string Label;
        public bool Primary;
        public bool Enabled = true;
        public Action Run;

        public FooterAction(string label, bool primary, Action run)
        {
            Label = label;
            Primary = primary;
            Run = run;
        }
    }

    public interface IScreen
    {
        void OnShown();
    }

    public partial class MainWindow : Window
    {
        public static MainWindow Instance { get; private set; }

        private readonly HomeView home = new HomeView();
        private readonly JoinView join = new JoinView();
        private readonly HostView host = new HostView();
        private readonly SetupView setup = new SetupView();
        private readonly UpdatesView updates = new UpdatesView();

        public MainWindow()
        {
            Instance = this;
            InitializeComponent();
            LogBox.Text = Log.Text;
            Log.Line += line => Dispatcher.BeginInvoke(new Action(() =>
            {
                LogBox.AppendText(line + Environment.NewLine);
                LogBox.ScrollToEnd();
            }));

            Settings s = Settings.Current;
            if (!GameLocator.IsGameFolder(s.GamePath))
            {
                string found = GameLocator.Find();
                if (found != null)
                {
                    s.GamePath = found;
                    Log.Info("Jeu trouvé : " + found);
                }
            }
            if (!ArchipelagoTools.IsInstall(s.ArchipelagoPath))
            {
                string ap = ArchipelagoTools.Find();
                if (ap != null) s.ArchipelagoPath = ap;
            }
            s.Save();
            Lang.Apply(this);
            Lang.Changed += OnLanguageChanged;
            SetStatus(T("Prêt."));
            RefreshSession();
            Navigate("home");
            Loaded += async (sender, e) =>
            {
                await CheckForUpdatesAsync(true);
                WatchForUpdates();
            };
        }

        private PatchFeed updateFeed;
        private PatchInfo updatePatch;
        private bool updating;
        private bool checking;
        private DispatcherTimer updateTimer;
        private DispatcherTimer watcherDelay;
        private FileSystemWatcher patchWatcher;

        // Dossier des patchs surveillé en direct, et revérification toutes les 2 min (10 min depuis GitHub).
        private void WatchForUpdates()
        {
            string source = PatchUpdater.Source;
            bool web = PatchUpdater.IsRemote(source);
            updateTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(web ? 10 : 2) };
            updateTimer.Tick += async (sender, e) => await CheckForUpdatesAsync(true);
            updateTimer.Start();
            watcherDelay = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            watcherDelay.Tick += async (sender, e) =>
            {
                watcherDelay.Stop();
                await CheckForUpdatesAsync(true);
            };
            WatchManualFolder();
            if (source.Length == 0 || web) return;
            string folder = source.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? Path.GetDirectoryName(source) : source;
            if (!Directory.Exists(folder)) return;
            try
            {
                patchWatcher = new FileSystemWatcher(folder, PatchUpdater.FeedFile)
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
                };
                FileSystemEventHandler changed = (sender, e) => Dispatcher.BeginInvoke(new Action(() =>
                {
                    watcherDelay.Stop();
                    watcherDelay.Start();
                }));
                patchWatcher.Changed += changed;
                patchWatcher.Created += changed;
                patchWatcher.Renamed += (sender, e) => changed(sender, e);
                patchWatcher.EnableRaisingEvents = true;
            }
            catch (Exception ex)
            {
                Log.Warn("Surveillance des patchs impossible : " + ex.Message);
            }
        }

        private FileSystemWatcher manualWatcher;

        private void WatchManualFolder()
        {
            string folder = PatchUpdater.ManualFolder;
            if (!Directory.Exists(folder)) return;
            try
            {
                manualWatcher = new FileSystemWatcher(folder, "*.zip")
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
                };
                FileSystemEventHandler changed = (sender, e) => Dispatcher.BeginInvoke(new Action(() =>
                {
                    watcherDelay.Stop();
                    watcherDelay.Start();
                }));
                manualWatcher.Changed += changed;
                manualWatcher.Created += changed;
                manualWatcher.Renamed += (sender, e) => changed(sender, e);
                manualWatcher.EnableRaisingEvents = true;
            }
            catch (Exception ex)
            {
                Log.Warn("Surveillance du dossier des patchs impossible : " + ex.Message);
            }
        }

        public async Task CheckForUpdatesAsync(bool silent)
        {
            if (updating || checking) return;
            checking = true;
            CheckUpdatesText.Text = T("Recherche en cours...");
            PatchFeed feed;
            try
            {
                feed = await PatchUpdater.CheckAsync();
            }
            finally
            {
                checking = false;
                CheckUpdatesText.Text = T("Rechercher des mises à jour");
            }
            string current = PatchUpdater.CurrentVersion;
            List<PatchInfo> newer = new List<PatchInfo>();
            if (feed.Error != null)
            {
                if (!silent) ShowError(feed.Error);
                else if (feed.Error != lastFeedError) Log.Warn(feed.Error);
                lastFeedError = feed.Error;
            }
            else
            {
                lastFeedError = null;
                newer = feed.NewerThan(current);
            }
            PatchInfo manual = PatchUpdater.FindManualPatch();
            if (manual != null && (newer.Count == 0 || PatchUpdater.Compare(manual.Version, newer[0].Version) >= 0))
            {
                ShowManualUpdate(manual, silent);
                return;
            }
            manualPatch = null;
            if (newer.Count == 0)
            {
                if (ShowGameUpdate(feed, current, silent)) return;
                UpdateBanner.Visibility = Visibility.Collapsed;
                gameUpdate = false;
                if (!silent && feed.Error == null) SetStatus(TF("Le client est à jour (version {0}).", PatchUpdater.CurrentLabel));
                return;
            }
            PatchInfo latest = newer[0];
            if (silent && Settings.Current.SkippedPatch == latest.Version) return;
            bool already = UpdateBanner.Visibility == Visibility.Visible && updatePatch != null && updatePatch.Version == latest.Version;
            gameUpdate = false;
            updateFeed = feed;
            updatePatch = latest;
            UpdateTitle.Text = TF("Mise à jour disponible : version {0}", latest.Name) + TF("   (installée : {0})", PatchUpdater.CurrentLabel);
            UpdateButton.IsEnabled = true;
            UpdateBanner.Visibility = Visibility.Visible;
            if (!already) Log.Info("Mise à jour disponible : " + latest.Version + " (installée : " + current + ")");
        }

        private string lastFeedError;
        private bool gameUpdate;
        private PatchInfo manualPatch;

        private void ShowManualUpdate(PatchInfo patch, bool silent)
        {
            string key = "zip:" + patch.Version;
            if (silent && Settings.Current.SkippedPatch == key) return;
            bool already = UpdateBanner.Visibility == Visibility.Visible && manualPatch != null && manualPatch.Version == patch.Version;
            gameUpdate = false;
            updatePatch = null;
            manualPatch = patch;
            UpdateTitle.Text = TF("Patch trouvé dans le dossier des patchs : version {0}", patch.Name) + TF("   (installée : {0})", PatchUpdater.CurrentLabel);
            UpdateButton.IsEnabled = true;
            UpdateBanner.Visibility = Visibility.Visible;
            if (!already) Log.Info("Patch trouvé dans le dossier des patchs : " + patch.Version + " (" + patch.File + ")");
        }

        private bool ShowGameUpdate(PatchFeed feed, string current, bool silent)
        {
            Settings s = Settings.Current;
            if (!GameLocator.IsGameFolder(s.GamePath) || !ClientInstaller.Inspect(s.GamePath).ClientInstalled) return false;
            string inGame = PatchUpdater.GameVersion(s.GamePath);
            if (inGame != null && PatchUpdater.Compare(inGame, current) >= 0) return false;
            string key = "jeu:" + current;
            if (silent && s.SkippedPatch == key) return true;
            bool already = UpdateBanner.Visibility == Visibility.Visible && gameUpdate;
            gameUpdate = true;
            updatePatch = null;
            UpdateTitle.Text = TF("Mise à jour du client dans le jeu : version {0}", PatchUpdater.CurrentLabel)
                + TF("   (dans le jeu : {0})", PatchUpdater.GameLabel(s.GamePath) ?? T("ancienne"));
            UpdateButton.IsEnabled = true;
            UpdateBanner.Visibility = Visibility.Visible;
            if (!already) Log.Info("Client du jeu à mettre à jour : " + (inGame ?? "ancienne version") + " -> " + current);
            return true;
        }

        private async void Update_Click(object sender, RoutedEventArgs e)
        {
            if (updating) return;
            if (gameUpdate)
            {
                InstallInGame();
                return;
            }
            PatchInfo target = manualPatch ?? updatePatch;
            if (target == null) return;
            updating = true;
            UpdateButton.IsEnabled = false;
            HideError();
            SetStatus(TF("Mise à jour vers la version {0}...", target.Name));
            try
            {
                string summary = manualPatch != null
                    ? await PatchUpdater.ApplyManualAsync(manualPatch)
                    : await PatchUpdater.ApplyAsync(updateFeed, updatePatch);
                manualPatch = null;
                UpdateBanner.Visibility = Visibility.Collapsed;
                RefreshSession();
                SetStatus(summary);
                MessageBox.Show(summary, AppInfo.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
                if (PatchUpdater.LauncherReplaced)
                {
                    PatchUpdater.RestartIntoNewLauncher();
                    Application.Current.Shutdown();
                }
            }
            catch (Exception ex)
            {
                UpdateButton.IsEnabled = true;
                ShowError(TF("Mise à jour impossible : {0}", ex.Message));
            }
            finally
            {
                updating = false;
            }
        }

        private void InstallInGame()
        {
            HideError();
            Settings s = Settings.Current;
            try
            {
                if (GameLocator.IsGameRunning()) throw new InvalidOperationException(T("RE Requiem est lancé. Ferme le jeu avant de mettre à jour."));
                string version = PatchUpdater.CurrentLabel;
                ClientInstaller.Install(s.GamePath, s.DisableLegacyScripts);
                if (s.Session != null) s.Session.InstalledAt = DateTime.Now;
                s.Save();
                gameUpdate = false;
                UpdateBanner.Visibility = Visibility.Collapsed;
                RefreshSession();
                string summary = TF("Client version {0} installé dans le jeu (ta partie est gardée).", version);
                Log.Info(summary);
                SetStatus(summary);
                MessageBox.Show(summary, AppInfo.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                ShowError(TF("Mise à jour impossible : {0}", ex.Message));
            }
        }

        private void UpdateLater_Click(object sender, RoutedEventArgs e)
        {
            string key = gameUpdate ? "jeu:" + PatchUpdater.CurrentVersion
                : manualPatch != null ? "zip:" + manualPatch.Version
                : updatePatch != null ? updatePatch.Version : null;
            if (key != null)
            {
                Settings.Current.SkippedPatch = key;
                Settings.Current.Save();
            }
            UpdateBanner.Visibility = Visibility.Collapsed;
        }

        private async void CheckUpdates_Click(object sender, RoutedEventArgs e)
        {
            HideError();
            await CheckForUpdatesAsync(false);
            if (ScreenHost.Content == updates) updates.OnShown();
        }

        public void Navigate(string screen)
        {
            HideError();
            UserControl view = screen == "join" ? join : screen == "host" ? host : screen == "setup" ? (UserControl)setup : screen == "updates" ? updates : home;
            NavHome.Tag = view == home;
            NavJoin.Tag = view == join;
            NavHost.Tag = view == host;
            NavSetup.Tag = view == setup;
            NavUpdates.Tag = view == updates;
            ScreenHost.Content = view;
            ContentScroller.ScrollToTop();
            SetFooter();
            ((IScreen)view).OnShown();
            Lang.Apply(view);
        }

        private void Language_Click(object sender, RoutedEventArgs e)
        {
            Lang.Set(Lang.English ? "fr" : "en");
        }

        private async void OnLanguageChanged()
        {
            HideError();
            Lang.Apply(this);
            RefreshSession();
            if (ScreenHost.Content == join) join.Relabel();
            else if (ScreenHost.Content is IScreen screen) screen.OnShown();
            SetFooter(footer);
            Lang.Apply(this);
            SetStatus(T("Prêt."));
            if (UpdateBanner.Visibility == Visibility.Visible) await CheckForUpdatesAsync(true);
        }

        public void ScrollToTop()
        {
            ContentScroller.ScrollToTop();
        }

        private FooterAction[] footer = new FooterAction[0];

        public void SetFooter(params FooterAction[] actions)
        {
            footer = actions;
            FooterPanel.Children.Clear();
            foreach (FooterAction a in actions)
            {
                Button b = new Button
                {
                    Content = T(a.Label),
                    IsEnabled = a.Enabled,
                    Style = (Style)FindResource(a.Primary ? "FooterPrimaryButtonStyle" : "FooterButtonStyle"),
                };
                FooterAction captured = a;
                b.Click += (s, e) => captured.Run();
                FooterPanel.Children.Add(b);
            }
        }

        public void SetStatus(string text)
        {
            StatusText.Text = T(text);
        }

        public void ShowError(string message)
        {
            ErrorText.Text = T(message);
            ErrorBanner.Visibility = Visibility.Visible;
            Log.Error(message);
        }

        public void HideError()
        {
            ErrorBanner.Visibility = Visibility.Collapsed;
        }

        public void RefreshSession()
        {
            SessionRecord r = Settings.Current.Session;
            if (r == null)
            {
                SessionText.Text = T("Session en cours : aucune");
                SessionDetailText.Text = T("Dernière installation : n/d");
            }
            else
            {
                SessionText.Text = TF("Session en cours : {0} sur {1}", r.Slot, r.Server);
                string progress = r.TotalChecks > 0 ? TF("{0} / {1} checks", r.DoneChecks, r.TotalChecks) : T("progression inconnue");
                SessionDetailText.Text = TF("Installée le {0} · {1}", r.InstalledAt.HasValue ? r.InstalledAt.Value.ToString("yyyy-MM-dd HH:mm") : T("n/d"), progress);
            }
            PayloadText.Text = TF("client {0} · {1} emplacements", PatchUpdater.CurrentLabel, GameData.TotalLocations);
        }

        private void NavHome_Click(object sender, RoutedEventArgs e) { Navigate("home"); }
        private void NavJoin_Click(object sender, RoutedEventArgs e) { Navigate("join"); }
        private void NavHost_Click(object sender, RoutedEventArgs e) { Navigate("host"); }
        private void NavSetup_Click(object sender, RoutedEventArgs e) { Navigate("setup"); }
        private void NavUpdates_Click(object sender, RoutedEventArgs e) { Navigate("updates"); }
        private void DismissError_Click(object sender, RoutedEventArgs e) { HideError(); }

        private void BugReport_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string path = BugReport.Create();
                SetStatus(TF("Rapport de bug créé sur le bureau : {0}", Path.GetFileName(path)));
                Process.Start("explorer.exe", "/select,\"" + path + "\"");
            }
            catch (Exception ex)
            {
                ShowError(TF("Impossible de créer le rapport : {0}", ex.Message));
            }
        }

        private void OpenLogs_Click(object sender, RoutedEventArgs e)
        {
            Process.Start("explorer.exe", AppInfo.LogDir);
        }

        private void Credits_Click(object sender, RoutedEventArgs e)
        {
            MessageBox.Show(T(Credits), T("Crédits"), MessageBoxButton.OK, MessageBoxImage.Information);
        }

        public const string Credits =
            "RE Requiem Archipelago : LechapelierHD\n" +
            "Logo : Aure0re\n\n" +
            "Archipelago : l'équipe ArchipelagoMW\n" +
            "REFramework : praydog\n" +
            "lua-apclientpp : black-sliver, FelicitusNeko, highrow623, NewSoupVi\n" +
            "Client AP de RE2R (base du client) : Fuzzy\n" +
            "RE4R AP Wizard (modèle du lanceur)\n" +
            "Modular Chapter Skip (noms des chapitres) : MaVeRicK";

        private void ArchipelagoLink_Click(object sender, RoutedEventArgs e)
        {
            GameLocator.Open("https://archipelago.gg");
        }

        private void ReFrameworkLink_Click(object sender, RoutedEventArgs e)
        {
            GameLocator.Open("https://github.com/praydog/REFramework");
        }
    }
}
