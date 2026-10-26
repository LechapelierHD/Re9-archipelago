using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public partial class JoinView : UserControl, IScreen
    {
        private static readonly string[] Difficulties = { "casual", "modern", "classic", "insanity" };
        private static readonly string[] Balancing = { "disabled", "normal", "extreme" };

        private int step = 1;
        private bool loading;

        public JoinView()
        {
            InitializeComponent();
        }

        private Settings S
        {
            get { return Settings.Current; }
        }

        private bool Shuffled
        {
            get { return S.YamlKeyItems == "shuffled"; }
        }

        public void OnShown()
        {
            loading = true;
            SlotBox.Text = S.YamlSlot;
            int d = Array.IndexOf(Difficulties, S.YamlDifficulty);
            DifficultyPicker.SelectedIndex = d < 0 ? 1 : d;
            int drops = S.YamlEnemyDrops;
            if (drops < 0 || drops > 50) drops = 15;
            EnemyDropsSlider.Value = drops;
            EnemyDropsValue.Text = drops.ToString();
            SupplyBoxPicker.SelectedIndex = S.YamlSupplyBox ? 1 : 0;
            DeathLinkPicker.SelectedIndex = S.YamlDeathLink ? 1 : 0;
            int b = Array.IndexOf(Balancing, S.YamlProgressionBalancing);
            BalancePicker.SelectedIndex = b < 0 ? 1 : b;
            AccessPicker.SelectedIndex = S.YamlAccessibility == "minimal" ? 1 : 0;
            loading = false;
            RefreshCounts();
            ShowStep(S.Session != null ? 3 : 1);
        }

        public void Relabel()
        {
            RefreshCounts();
            ShowStep(step);
        }

        private void ShowStep(int n)
        {
            step = n;
            Step1.Visibility = n == 1 ? Visibility.Visible : Visibility.Collapsed;
            Step2.Visibility = n == 2 ? Visibility.Visible : Visibility.Collapsed;
            Step3.Visibility = n == 3 ? Visibility.Visible : Visibility.Collapsed;
            Step4.Visibility = n == 4 ? Visibility.Visible : Visibility.Collapsed;
            MainWindow w = MainWindow.Instance;
            w.HideError();
            w.ScrollToTop();
            switch (n)
            {
                case 1:
                    w.SetFooter(new FooterAction("Retour", false, () => w.Navigate("home")),
                        new FooterAction("Continuer", true, FromStep1));
                    break;
                case 2:
                    if (YamlPreview.Text.Length == 0 && File.Exists(S.LastYamlPath))
                    {
                        YamlPathText.Text = S.LastYamlPath;
                        YamlPreview.Text = File.ReadAllText(S.LastYamlPath);
                    }
                    w.SetFooter(new FooterAction("Retour", false, () => ShowStep(1)),
                        new FooterAction("Continuer", true, () => ShowStep(3)));
                    break;
                case 3:
                    PrepareStep3();
                    w.SetFooter(new FooterAction("Retour", false, () => ShowStep(2)),
                        new FooterAction("Installer et rejoindre", true, InstallAndJoin));
                    break;
                case 4:
                    w.SetFooter(new FooterAction("Retour à l'accueil", false, () => w.Navigate("home")),
                        new FooterAction("Lancer RE Requiem", true, Launch));
                    break;
            }
        }

        private void RefreshCounts()
        {
            TileVanilla.IsChecked = !Shuffled;
            TileShuffled.IsChecked = Shuffled;
            CheckVanilla.Visibility = Shuffled ? Visibility.Collapsed : Visibility.Visible;
            CheckShuffled.Visibility = Shuffled ? Visibility.Visible : Visibility.Collapsed;
            int vanilla = GameData.CountChecks(S.YamlDifficulty, false);
            int shuffled = GameData.CountChecks(S.YamlDifficulty, true);
            int shop = S.YamlSupplyBox ? 0 : 11;
            vanilla = Math.Max(0, vanilla - shop);
            shuffled = Math.Max(0, shuffled - shop);
            CountVanilla.Text = TF("{0} checks dans {1} chapitres", vanilla, GameData.ChapterCount);
            CountShuffled.Text = TF("{0} checks, dont {1} objets clés", shuffled, shuffled - vanilla);
            int drops = S.YamlEnemyDrops;
            if (drops < 0) drops = 0;
            if (drops > 50) drops = 50;
            TotalText.Text = TF("Ton slot contient {0} checks.", (Shuffled ? shuffled : vanilla) + drops);
        }

        private void SlotBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (loading) return;
            S.YamlSlot = SlotBox.Text.Trim();
        }

        private void TileVanilla_Click(object sender, RoutedEventArgs e)
        {
            S.YamlKeyItems = "vanilla";
            RefreshCounts();
        }

        private void TileShuffled_Click(object sender, RoutedEventArgs e)
        {
            S.YamlKeyItems = "shuffled";
            RefreshCounts();
        }

        private void DifficultyPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loading || DifficultyPicker.SelectedIndex < 0) return;
            S.YamlDifficulty = Difficulties[DifficultyPicker.SelectedIndex];
            RefreshCounts();
        }

        private void EnemyDrops_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (loading || EnemyDropsValue == null) return;
            int n = (int)Math.Round(EnemyDropsSlider.Value);
            S.YamlEnemyDrops = n;
            EnemyDropsValue.Text = n.ToString();
            RefreshCounts();
        }

        private void SupplyBoxPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loading || SupplyBoxPicker.SelectedIndex < 0) return;
            S.YamlSupplyBox = SupplyBoxPicker.SelectedIndex == 1;
            RefreshCounts();
        }

        private void DeathLinkPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loading || DeathLinkPicker.SelectedIndex < 0) return;
            S.YamlDeathLink = DeathLinkPicker.SelectedIndex == 1;
        }

        private void BalancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loading || BalancePicker.SelectedIndex < 0) return;
            S.YamlProgressionBalancing = Balancing[BalancePicker.SelectedIndex];
        }

        private void AccessPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loading || AccessPicker.SelectedIndex < 0) return;
            S.YamlAccessibility = AccessPicker.SelectedIndex == 1 ? "minimal" : "full";
        }

        private void FromStep1()
        {
            string slot = SlotBox.Text.Trim();
            if (!YamlTools.SlotNamePattern.IsMatch(slot))
            {
                MainWindow.Instance.ShowError("Indique un nom de slot (1 à 16 caractères, sans espace au début).");
                return;
            }
            S.YamlSlot = slot;
            string text = YamlTools.Build(slot, S.YamlDifficulty, S.YamlKeyItems, S.YamlEnemyDrops, S.YamlSupplyBox, S.YamlDeathLink, S.YamlProgressionBalancing, S.YamlAccessibility);
            string path = Path.Combine(AppInfo.YamlDir, YamlTools.SafeFileName(slot));
            File.WriteAllText(path, text, new UTF8Encoding(false));
            S.LastYamlPath = path;
            if (!S.HostYamls.Exists(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase))) S.HostYamls.Add(path);
            S.Save();
            Log.Info("YAML enregistré : " + path);
            YamlPathText.Text = path;
            YamlPreview.Text = text;
            ShowStep(2);
        }

        private void SaveAs_Click(object sender, RoutedEventArgs e)
        {
            SaveFileDialog dlg = new SaveFileDialog
            {
                FileName = Path.GetFileName(S.LastYamlPath),
                Filter = "YAML Archipelago (*.yaml)|*.yaml",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            };
            if (dlg.ShowDialog() != true) return;
            File.WriteAllText(dlg.FileName, YamlPreview.Text, new UTF8Encoding(false));
            MainWindow.Instance.SetStatus(TF("YAML enregistré : {0}", dlg.FileName));
        }

        private void Copy_Click(object sender, RoutedEventArgs e)
        {
            Clipboard.SetText(YamlPreview.Text);
            MainWindow.Instance.SetStatus("YAML copié dans le presse-papiers.");
        }

        private void Reveal_Click(object sender, RoutedEventArgs e)
        {
            if (File.Exists(S.LastYamlPath)) Process.Start("explorer.exe", "/select,\"" + S.LastYamlPath + "\"");
        }

        private void PrepareStep3()
        {
            SessionRecord r = S.Session;
            if (ServerBox.Text.Length == 0) ServerBox.Text = r != null ? r.Server : "";
            if (JoinSlotBox.Text.Length == 0) JoinSlotBox.Text = r != null ? r.Slot : S.YamlSlot;
            if (PasswordBox.Password.Length == 0 && r != null) PasswordBox.Password = r.Password;
            ClientStatus st = ClientInstaller.Inspect(S.GamePath);
            if (!st.GameFound)
            {
                GameWarningText.Text = T("Le dossier de RE Requiem n'est pas configuré : le lanceur ne pourra pas installer le client.");
                GameWarning.Visibility = Visibility.Visible;
            }
            else if (!st.ReFramework)
            {
                GameWarningText.Text = T("REFramework n'est pas installé dans RE Requiem : sans lui, le client ne se chargera pas. Installe-le depuis l'état de la configuration.");
                GameWarning.Visibility = Visibility.Visible;
            }
            else
            {
                GameWarning.Visibility = Visibility.Collapsed;
            }
        }

        private void ShowProbe(RoomProbeResult res)
        {
            ProbeBanner.Visibility = Visibility.Visible;
            ProbeBanner.Background = (System.Windows.Media.Brush)FindResource(res.Ok ? "SuccessBackgroundBrush" : "DangerBackgroundBrush");
            ProbeBanner.BorderBrush = (System.Windows.Media.Brush)FindResource(res.Ok ? "SuccessBorderBrush" : "DangerBorderBrush");
            ProbeText.Foreground = (System.Windows.Media.Brush)FindResource(res.Ok ? "SuccessTextBrush" : "DangerTextBrush");
            ProbeText.Text = res.Message;
        }

        private async System.Threading.Tasks.Task<RoomProbeResult> Probe()
        {
            TestButton.IsEnabled = false;
            MainWindow.Instance.SetStatus("Test de la room...");
            try
            {
                RoomProbeResult res = await RoomProbe.ProbeAsync(ServerBox.Text, JoinSlotBox.Text.Trim(), PasswordBox.Password);
                ShowProbe(res);
                MainWindow.Instance.SetStatus(res.Message);
                return res;
            }
            finally
            {
                TestButton.IsEnabled = true;
            }
        }

        private async void Test_Click(object sender, RoutedEventArgs e)
        {
            await Probe();
        }

        private async void InstallAndJoin()
        {
            string server = RoomProbe.Normalize(ServerBox.Text);
            string slot = JoinSlotBox.Text.Trim();
            if (server.Length == 0 || slot.Length == 0)
            {
                MainWindow.Instance.ShowError("Indique l'adresse de la room et le nom de slot.");
                return;
            }
            if (!GameLocator.IsGameFolder(S.GamePath))
            {
                MainWindow.Instance.ShowError("Configure d'abord le dossier de RE Requiem dans l'état de la configuration.");
                return;
            }
            RoomProbeResult res = await Probe();
            if (!res.Ok)
            {
                if (MessageBox.Show(TF("{0}\n\nInstaller quand même ? Le jeu réessaiera de se connecter tout seul.", res.Message), AppInfo.DisplayName,
                        MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            }
            else if (res.GoalDone)
            {
                if (MessageBox.Show(T("La victoire de ce slot est déjà enregistrée sur la room : la partie est terminée, "
                        + "le serveur t'a déjà renvoyé tous tes objets et tes checks ne servent plus à rien.\n\n"
                        + "Génère plutôt une nouvelle partie (Héberger un multimonde). Installer quand même ?"), AppInfo.DisplayName,
                        MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            }
            try
            {
                SessionRecord previous = S.Session;
                bool newRoom = previous == null || previous.Slot != slot
                    || (res.Seed.Length > 0 && previous.Seed.Length > 0 && previous.Seed != res.Seed);
                ClientInstaller.Install(S.GamePath, S.DisableLegacyScripts);
                string sceneNote = "";
                try
                {
                    MainWindow.Instance.SetStatus("Scout AP + patch scènes (style RE4R)...");
                    ApScoutResult scout = await ApPlacementScout.ScoutForeignAsync(server, slot, PasswordBox.Password);
                    if (scout.Ok && scout.ForeignCount > 0)
                    {
                        ApScenePatcher.PatchResult patch = ClientInstaller.InstallApScenePatches(S.GamePath, scout.ForeignLocationIds);
                        sceneNote = " " + TF("Visuels AP : {0} checks foreign, {1} rewrite(s) scn.",
                            scout.ForeignCount, patch.PatchedOccurrences);
                        Log.Info(scout.Message + sceneNote);
                    }
                    else if (scout.Ok)
                    {
                        sceneNote = " " + T("Visuels AP : aucun check foreign (tous pour toi).");
                        Log.Info(scout.Message);
                    }
                    else
                    {
                        Log.Warn("Patch scènes AP ignoré : " + scout.Message);
                        sceneNote = " " + T("Visuels AP : scout room échoué (Lua runtime en secours).");
                    }
                }
                catch (Exception ex)
                {
                    Log.Warn("Patch scènes AP : " + ex.Message);
                    sceneNote = " " + T("Visuels AP : patch scn échoué (Lua runtime en secours).");
                }
                if (newRoom) ClientInstaller.ResetSessionState(S.GamePath, res.Seed, slot);
                ClientInstaller.WriteConnection(S.GamePath, server, slot, PasswordBox.Password, res);
                S.Session = new SessionRecord
                {
                    Server = server,
                    Slot = slot,
                    Password = PasswordBox.Password,
                    Seed = res.Seed.Length > 0 ? res.Seed : (previous != null && !newRoom ? previous.Seed : ""),
                    Difficulty = S.YamlDifficulty,
                    TotalChecks = res.Total,
                    DoneChecks = res.Checked,
                    InstalledAt = DateTime.Now,
                    VerifiedAt = res.Ok ? DateTime.Now : (DateTime?)null,
                };
                S.Save();
                // Comme RE2R : connexion in-game via lua-apclientpp.dll (pas de pont Python).
                try { BridgeHost.Stop(); }
                catch (Exception ex) { Log.Warn("Stop bridge : " + ex.Message); }
                MainWindow.Instance.RefreshSession();
                DoneText.Text = TF("Le client est installé dans RE Requiem et connecté à {0} pour le slot « {1} ».", server, slot)
                    + (res.Total > 0 ? TF(" {0} / {1} checks déjà faits.", res.Checked, res.Total) : "")
                    + sceneNote
                    + " " + T("Connexion AP : lua-apclientpp.dll (comme RE2R).");
                ShowStep(4);
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Installation interrompue : {0}", ex.Message));
            }
        }

        private void OpenSetup_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate("setup");
        }

        private void Launch()
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
    }
}
