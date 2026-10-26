using System;
using System.Windows;
using System.Windows.Controls;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public partial class HomeView : UserControl, IScreen
    {
        public HomeView()
        {
            InitializeComponent();
        }

        public void OnShown()
        {
            bool playtest = PatchUpdater.CurrentLabel.IndexOf("playtest", StringComparison.OrdinalIgnoreCase) >= 0;
            PlaytestBanner.Visibility = playtest ? Visibility.Visible : Visibility.Collapsed;
            if (playtest)
                PlaytestText.Text = T("RAPPEL IMPORTANT : Il s'agit d'une version de Playtest (Bêta). Le mod est activement en cours de développement. Vous risquez de rencontrer des bugs, des désynchronisations ou des plantages. Merci de nous remonter vos retours pour nous aider à stabiliser l'expérience !");
            int chapters = GameData.ChapterCount;
            Tagline.Text = TF("Chaque objet ramassé dans les {0}chapitres devient un check partagé avec les autres joueurs de ton multimonde. Les objets des autres arrivent dans ton coffre.",
                chapters > 0 ? chapters + " " : "");
            AiShareText.Text = TF("Code modifié par l'IA : environ {0} %", AppInfo.AiCodePercent);
            SessionRecord r = Settings.Current.Session;
            SessionBanner.Visibility = r == null ? Visibility.Collapsed : Visibility.Visible;
            Hint.Visibility = r == null ? Visibility.Visible : Visibility.Collapsed;
            if (r != null)
            {
                BannerTitle.Text = TF("Ton multimonde {0} est prêt !", r.Slot);
                string progress = r.TotalChecks > 0 ? TF(" Progression : {0} / {1} checks.", r.DoneChecks, r.TotalChecks) : "";
                BannerBody.Text = TF("Le client est installé et connecté à {0}{1}.{2} Lance RE Requiem depuis Steam : le mod se reconnecte tout seul. « Mettre à jour les scripts du jeu » applique les mises à jour du lanceur à cette même partie.",
                    r.Server, r.Seed.Length > 0 ? TF(" (seed {0})", r.Seed) : "", progress);
            }
            RefreshScripts();
        }

        private void RefreshScripts()
        {
            string game = Settings.Current.GamePath;
            string missing;
            bool found = GameLocator.IsGameFolder(game);
            ScriptsButton.IsEnabled = found && ClientInstaller.PayloadReady(out missing);
            string launcher = PatchUpdater.CurrentVersion;
            if (!found)
            {
                ScriptsText.Text = T("Jeu introuvable : indique son dossier dans « État de la configuration ».");
                return;
            }
            if (!ClientInstaller.Inspect(game).ClientInstalled)
            {
                ScriptsText.Text = TF("Scripts pas encore installés dans le jeu (lanceur : {0}).", PatchUpdater.CurrentLabel);
                return;
            }
            string inGame = PatchUpdater.GameVersion(game);
            string inGameLabel = PatchUpdater.GameLabel(game);
            ScriptsText.Text = inGame != null && PatchUpdater.Compare(inGame, launcher) >= 0
                ? TF("Scripts du jeu à jour : {0}.", inGameLabel)
                : TF("Scripts du jeu : {0}, lanceur : {1}.", inGameLabel ?? T("ancienne version"), PatchUpdater.CurrentLabel);
        }

        private void Launch_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                GameLocator.LaunchViaSteam();
                MainWindow.Instance.SetStatus("Steam a reçu la demande de lancement de RE Requiem.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Steam n'a pas pu être contacté : {0}", ex.Message));
            }
        }

        private async void Verify_Click(object sender, RoutedEventArgs e)
        {
            SessionRecord r = Settings.Current.Session;
            if (r == null) return;
            MainWindow.Instance.SetStatus("Vérification de la room...");
            RoomProbeResult res = await RoomProbe.ProbeAsync(r.Server, r.Slot, r.Password);
            if (!res.Ok)
            {
                MainWindow.Instance.ShowError(res.Message);
                MainWindow.Instance.SetStatus("La room ne répond pas comme prévu.");
                return;
            }
            r.TotalChecks = res.Total;
            r.DoneChecks = res.Checked;
            r.VerifiedAt = DateTime.Now;
            Settings.Current.Save();
            if (GameLocator.IsGameFolder(Settings.Current.GamePath) && !GameLocator.IsGameRunning())
            {
                try
                {
                    ClientInstaller.WriteConnection(Settings.Current.GamePath, r.Server, r.Slot, r.Password, res);
                }
                catch (Exception ex)
                {
                    Log.Warn("ap_connection.json non mis à jour : " + ex.Message);
                }
            }
            try { BridgeHost.Stop(); }
            catch (Exception ex) { Log.Warn("Stop bridge : " + ex.Message); }
            MainWindow.Instance.RefreshSession();
            MainWindow.Instance.SetStatus(res.Message);
            if (res.GoalDone) MainWindow.Instance.ShowError(res.Message);
            OnShown();
        }

        private void Repatch_Click(object sender, RoutedEventArgs e)
        {
            Settings s = Settings.Current;
            try
            {
                if (GameLocator.IsGameRunning()) throw new InvalidOperationException(T("RE Requiem est lancé. Ferme le jeu avant de mettre à jour."));
                ClientInstaller.Install(s.GamePath, s.DisableLegacyScripts);
                if (s.Session != null)
                {
                    ClientInstaller.WriteConnection(s.GamePath, s.Session.Server, s.Session.Slot, s.Session.Password);
                    s.Session.InstalledAt = DateTime.Now;
                }
                s.Save();
                MainWindow.Instance.RefreshSession();
                MainWindow.Instance.SetStatus(TF("Scripts du jeu mis à jour (version {0}) : même room, même progression.", PatchUpdater.CurrentLabel));
                OnShown();
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(ex.Message);
            }
        }

        private void Done_Click(object sender, RoutedEventArgs e)
        {
            if (MessageBox.Show(T("Oublier cette session ? Le client reste installé, mais il ne se connectera plus à cette room."),
                    AppInfo.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            Settings s = Settings.Current;
            if (GameLocator.IsGameFolder(s.GamePath))
            {
                try
                {
                    ClientInstaller.WriteConnection(s.GamePath, "", "", "");
                }
                catch (Exception ex)
                {
                    Log.Warn("ap_connection.json non vidé : " + ex.Message);
                }
            }
            s.Session = null;
            s.Save();
            Log.Info("Session terminée.");
            MainWindow.Instance.RefreshSession();
            OnShown();
        }
    }
}
