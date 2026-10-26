using System;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public partial class SetupView : UserControl, IScreen
    {
        private const string Ok = "\uE73E";
        private const string Bad = "\uE783";
        private const string Wait = "\uE9CE";

        private bool loading;

        public SetupView()
        {
            InitializeComponent();
        }

        private Settings S
        {
            get { return Settings.Current; }
        }

        public void OnShown()
        {
            loading = true;
            GamePathBox.Text = S.GamePath;
            LegacyCheck.IsChecked = S.DisableLegacyScripts;
            loading = false;
            MainWindow.Instance.SetFooter(new FooterAction("Actualiser", false, Refresh),
                new FooterAction("Rejoindre un multimonde", true, () => MainWindow.Instance.Navigate("join")));
            Refresh();
        }

        private void Mark(TextBlock icon, bool? ok)
        {
            icon.Text = ok == true ? Ok : ok == false ? Bad : Wait;
            icon.Foreground = (Brush)FindResource(ok == true ? "SuccessTextBrush" : ok == false ? "WarningTextBrush" : "SubtleTextBrush");
        }

        private void Refresh()
        {
            ClientStatus st = ClientInstaller.Inspect(S.GamePath);
            Mark(GameIcon, st.GameFound);
            GameText.Text = st.GameFound ? TF("{0} trouvé.", AppInfo.GameExe) : TF("Indique le dossier qui contient {0}.", AppInfo.GameExe);

            Mark(RefIcon, st.GameFound ? st.ReFramework : (bool?)null);
            RefText.Text = T(!st.GameFound ? "En attente du dossier du jeu." : st.ReFramework
                ? "dinput8.dll présent. Le menu REFramework s'ouvre avec Insert."
                : "Absent : le client ne se chargera pas. Le lanceur installe le REFramework inclus (Nightly 01313).");
            RefButton.Content = T(st.ReFramework ? "Mettre à jour" : "Installer REFramework");
            RefButton.IsEnabled = st.GameFound;

            string missing;
            bool payload = ClientInstaller.PayloadReady(out missing);
            Mark(ClientIcon, st.GameFound ? st.ClientInstalled && st.ClientUpToDate : (bool?)null);
            ClientText.Text = !payload ? TF("Paquet incomplet : {0}", missing)
                : !st.GameFound ? T("En attente du dossier du jeu.")
                : !st.ClientInstalled ? T("Pas encore installé.")
                : st.ClientUpToDate ? TF("Installé et à jour ({0} emplacements).", GameData.TotalLocations)
                : T("Installé, mais différent de la version du lanceur : mets-le à jour.");
            ClientButton.Content = T(st.ClientInstalled ? "Mettre à jour" : "Installer");
            ClientButton.IsEnabled = st.GameFound && payload;
            RemoveButton.IsEnabled = st.ClientInstalled;

            const string skip = ClientInstaller.ChapterSkipFile;
            bool skipAvailable = ClientInstaller.OptionalAvailable(skip);
            bool skipInstalled = st.GameFound && ClientInstaller.OptionalInstalled(S.GamePath, skip);
            bool skipUpToDate = skipInstalled && ClientInstaller.OptionalUpToDate(S.GamePath, skip);
            Mark(SkipIcon, skipInstalled ? skipUpToDate : (bool?)null);
            SkipText.Text = T(!st.GameFound ? "En attente du dossier du jeu."
                : !st.ClientInstalled ? "Installe d'abord le client Archipelago RE Requiem."
                : !skipAvailable && !skipInstalled ? "Absent du paquet : mets le lanceur à jour."
                : !skipInstalled ? "Avec Grace, F sur le point d'enquête du début saute au chapitre choisi et termine les chapitres sautés (checks envoyés ou objets au coffre)."
                : skipUpToDate ? "Installé et à jour. Réglages dans l'onglet « Saut de chapitre » du client en jeu."
                : !skipAvailable ? "Installé (version manuelle, absente du paquet)."
                : "Installé, mais différent de la version du lanceur : mets-le à jour.");
            SkipButton.Content = T(skipInstalled ? "Mettre à jour" : "Installer");
            SkipButton.IsEnabled = st.ClientInstalled && skipAvailable && !skipUpToDate;
            SkipRemoveButton.IsEnabled = skipInstalled;

            Mark(ConnIcon, st.GameFound && st.ClientInstalled ? st.ConnectionWritten : (bool?)null);
            ConnText.Text = st.ConnectionWritten ? st.ConnectionSummary : T("Aucune room enregistrée : passe par « Rejoindre un multimonde ».");

            Mark(LegacyIcon, st.GameFound ? st.LegacyActive.Count == 0 : (bool?)null);
            LegacyText.Text = st.LegacyActive.Count == 0 ? T("Aucun ancien script actif.")
                : TF("Actifs : {0}. Ils seront désactivés à la prochaine installation.", string.Join(", ", st.LegacyActive));

            bool ap = ArchipelagoTools.IsInstall(S.ArchipelagoPath);
            Mark(ApIcon, ap ? true : (bool?)null);
            ApText.Text = ap ? TF("Archipelago {0} dans {1}", ArchipelagoTools.Version(S.ArchipelagoPath), S.ArchipelagoPath)
                : T("Non trouvé. Nécessaire seulement pour générer une partie (page « Héberger »).");
            bool world = ap && ArchipelagoTools.ApworldUpToDate(S.ArchipelagoPath);
            Mark(WorldIcon, ap ? world : (bool?)null);
            WorldText.Text = T(!ap ? "En attente d'Archipelago." : world ? "Installé et à jour."
                : "Absent ou différent : clique sur le bouton pour l'installer dans custom_worlds.");
            WorldButton.Content = T(ap && File.Exists(ArchipelagoTools.InstalledApworld(S.ArchipelagoPath)) ? "Mettre à jour" : "Installer");
            WorldButton.IsEnabled = ap;
            MainWindow.Instance.RefreshSession();
        }

        private void GamePathBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (loading) return;
            S.GamePath = GamePathBox.Text.Trim();
            S.Save();
            Refresh();
        }

        private void Detect_Click(object sender, RoutedEventArgs e)
        {
            string found = GameLocator.Find();
            if (found == null)
            {
                MainWindow.Instance.ShowError(TF("RE Requiem (Steam {0}) introuvable. Indique le dossier à la main.", AppInfo.SteamAppId));
                return;
            }
            GamePathBox.Text = found;
            MainWindow.Instance.SetStatus(TF("Jeu trouvé : {0}", found));
        }

        private void Browse_Click(object sender, RoutedEventArgs e)
        {
            OpenFolderDialog dlg = new OpenFolderDialog { Title = T("Dossier qui contient re9.exe") };
            if (dlg.ShowDialog() == true) GamePathBox.Text = dlg.FolderName;
        }

        private void OpenGame_Click(object sender, RoutedEventArgs e)
        {
            if (Directory.Exists(S.GamePath)) Process.Start("explorer.exe", S.GamePath);
        }

        private void OpenData_Click(object sender, RoutedEventArgs e)
        {
            string dir = ClientInstaller.DataFolder(S.GamePath);
            if (Directory.Exists(dir)) Process.Start("explorer.exe", dir);
        }

        private async void InstallRef_Click(object sender, RoutedEventArgs e)
        {
            RefButton.IsEnabled = false;
            MainWindow.Instance.SetStatus("Installation de REFramework...");
            try
            {
                await ReFrameworkInstaller.InstallAsync(S.GamePath);
                MainWindow.Instance.SetStatus("REFramework installé.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("REFramework : {0}", ex.Message));
            }
            Refresh();
        }

        private void InstallClient_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ClientInstaller.Install(S.GamePath, S.DisableLegacyScripts);
                if (S.Session != null)
                {
                    ClientInstaller.WriteConnection(S.GamePath, S.Session.Server, S.Session.Slot, S.Session.Password);
                    S.Session.InstalledAt = DateTime.Now;
                    S.Save();
                }
                MainWindow.Instance.SetStatus("Client installé.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(ex.Message);
            }
            Refresh();
        }

        private void InstallWorld_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ArchipelagoTools.InstallApworld(S.ArchipelagoPath);
                MainWindow.Instance.SetStatus("apworld RE Requiem installé.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Impossible d'installer l'apworld : {0}", ex.Message));
            }
            Refresh();
        }

        private void RemoveClient_Click(object sender, RoutedEventArgs e)
        {
            if (MessageBox.Show(T("Retirer le client Archipelago de RE Requiem ? REFramework et les données de partie restent en place."),
                    AppInfo.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            try
            {
                ClientInstaller.Uninstall(S.GamePath);
                MainWindow.Instance.SetStatus("Client retiré.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(ex.Message);
            }
            Refresh();
        }

        private void InstallSkip_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ClientInstaller.InstallOptional(S.GamePath, ClientInstaller.ChapterSkipFile);
                MainWindow.Instance.SetStatus(GameLocator.IsGameRunning()
                    ? "Saut de chapitre installé. En jeu : Reset Scripts dans REFramework."
                    : "Saut de chapitre installé.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Saut de chapitre : {0}", ex.Message));
            }
            Refresh();
        }

        private void RemoveSkip_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ClientInstaller.UninstallOptional(S.GamePath, ClientInstaller.ChapterSkipFile);
                MainWindow.Instance.SetStatus(GameLocator.IsGameRunning()
                    ? "Saut de chapitre retiré. En jeu : Reset Scripts dans REFramework."
                    : "Saut de chapitre retiré.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Saut de chapitre : {0}", ex.Message));
            }
            Refresh();
        }

        private void LegacyCheck_Changed(object sender, RoutedEventArgs e)
        {
            if (loading) return;
            S.DisableLegacyScripts = LegacyCheck.IsChecked == true;
            S.Save();
        }
    }
}
