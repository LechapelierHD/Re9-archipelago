using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public partial class HostView : UserControl, IScreen
    {
        private const int StepCount = 6;
        private static readonly string[] Titles =
        {
            "Installer Archipelago 0.6.8",
            "Installer l'apworld RE Requiem",
            "Rassembler les YAML",
            "Générer le multimonde",
            "Ouvrir la room",
            "C'est parti !",
        };

        private bool loading;

        public HostView()
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
            ApPathBox.Text = S.ArchipelagoPath;
            loading = false;
            ShowStep(Math.Max(0, Math.Min(StepCount - 1, S.HostStep)));
        }

        private void ShowStep(int index)
        {
            S.HostStep = index;
            S.Save();
            StepCounter.Text = TF("Étape {0} sur {1}", index + 1, StepCount);
            StepNumber.Text = (index + 1).ToString();
            StepTitle.Text = T(Titles[index]);
            UIElement[] panels = { PanelAp, PanelWorld, PanelYaml, PanelGenerate, PanelHost, PanelDone };
            for (int i = 0; i < panels.Length; i++) panels[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
            Refresh();

            MainWindow w = MainWindow.Instance;
            w.HideError();
            List<FooterAction> footer = new List<FooterAction>
            {
                new FooterAction("Quitter le guide", false, () => w.Navigate("home")),
                new FooterAction("Retour", false, () => ShowStep(index - 1)) { Enabled = index > 0 },
            };
            if (index < StepCount - 1) footer.Add(new FooterAction("Suivant", true, Next) { Enabled = StepComplete(index) });
            else footer.Add(new FooterAction("Recommencer", false, () => ShowStep(2)));
            w.SetFooter(footer.ToArray());
        }

        private void Next()
        {
            if (!StepComplete(S.HostStep)) return;
            ShowStep(S.HostStep + 1);
        }

        private bool StepComplete(int index)
        {
            switch (index)
            {
                case 0: return ArchipelagoTools.IsInstall(S.ArchipelagoPath);
                case 1: return ArchipelagoTools.IsInstall(S.ArchipelagoPath) && ArchipelagoTools.ApworldUpToDate(S.ArchipelagoPath);
                case 2: return ValidYamls().Count > 0;
                case 3: return File.Exists(S.LastGeneratedZip);
                default: return true;
            }
        }

        private void Refresh()
        {
            int index = S.HostStep;
            StepDone.Visibility = index < StepCount - 1 && StepComplete(index) ? Visibility.Visible : Visibility.Collapsed;

            if (ArchipelagoTools.IsInstall(S.ArchipelagoPath))
            {
                string v = ArchipelagoTools.Version(S.ArchipelagoPath);
                ApStatus.Text = TF("Archipelago {0} trouvé dans {1}.", v, S.ArchipelagoPath);
                ApStatus.Foreground = (System.Windows.Media.Brush)FindResource("SuccessTextBrush");
            }
            else
            {
                ApStatus.Text = T("ArchipelagoGenerate.exe introuvable dans ce dossier.");
                ApStatus.Foreground = (System.Windows.Media.Brush)FindResource("WarningTextBrush");
            }

            if (!ArchipelagoTools.IsInstall(S.ArchipelagoPath))
            {
                WorldStatus.Text = T("Configure d'abord Archipelago (étape 1).");
            }
            else if (ArchipelagoTools.ApworldUpToDate(S.ArchipelagoPath))
            {
                WorldStatus.Text = TF("apworld RE Requiem installé et à jour : {0}", ArchipelagoTools.InstalledApworld(S.ArchipelagoPath));
            }
            else if (File.Exists(ArchipelagoTools.InstalledApworld(S.ArchipelagoPath)))
            {
                WorldStatus.Text = T("Une autre version de l'apworld RE Requiem est installée : mets-la à jour pour qu'elle corresponde au client.");
            }
            else
            {
                WorldStatus.Text = T("apworld RE Requiem pas encore installé.");
            }

            YamlList.Items.Clear();
            int re9 = 0;
            foreach (string path in S.HostYamls)
            {
                if (!File.Exists(path)) continue;
                YamlInfo info = YamlTools.Inspect(path);
                if (info.IsRe9) re9++;
                YamlList.Items.Add(new ListBoxItem { Content = info.Display, Tag = path });
            }
            YamlStatus.Text = TF("{0} YAML, dont {1} pour RE Requiem.", YamlList.Items.Count, re9);

            GenerateStatus.Text = File.Exists(S.LastGeneratedZip) ? TF("Dernière partie générée : {0}", S.LastGeneratedZip) : T("Aucune partie générée pour l'instant.");
        }

        private List<string> ValidYamls()
        {
            return S.HostYamls.FindAll(File.Exists);
        }

        private void RefreshFooter()
        {
            ShowStep(S.HostStep);
        }

        private void ApPathBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (loading) return;
            S.ArchipelagoPath = ApPathBox.Text.Trim();
            S.Save();
            RefreshFooter();
        }

        private void BrowseAp_Click(object sender, RoutedEventArgs e)
        {
            OpenFolderDialog dlg = new OpenFolderDialog { Title = T("Dossier d'Archipelago (contient ArchipelagoGenerate.exe)") };
            if (dlg.ShowDialog() == true) ApPathBox.Text = dlg.FolderName;
        }

        private void GetAp_Click(object sender, RoutedEventArgs e)
        {
            GameLocator.Open(ArchipelagoTools.ReleasesUrl);
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
            RefreshFooter();
        }

        private void OpenWorlds_Click(object sender, RoutedEventArgs e)
        {
            string dir = Path.Combine(S.ArchipelagoPath, "custom_worlds");
            if (Directory.Exists(dir)) Process.Start("explorer.exe", dir);
        }

        private void AddYaml_Click(object sender, RoutedEventArgs e)
        {
            OpenFileDialog dlg = new OpenFileDialog { Filter = "YAML Archipelago (*.yaml;*.yml)|*.yaml;*.yml", Multiselect = true };
            if (dlg.ShowDialog() != true) return;
            foreach (string f in dlg.FileNames)
            {
                if (!S.HostYamls.Exists(p => string.Equals(p, f, StringComparison.OrdinalIgnoreCase))) S.HostYamls.Add(f);
            }
            S.Save();
            RefreshFooter();
        }

        private void RemoveYaml_Click(object sender, RoutedEventArgs e)
        {
            ListBoxItem item = YamlList.SelectedItem as ListBoxItem;
            if (item == null) return;
            S.HostYamls.Remove((string)item.Tag);
            S.Save();
            RefreshFooter();
        }

        private void OpenYamlDir_Click(object sender, RoutedEventArgs e)
        {
            Process.Start("explorer.exe", AppInfo.YamlDir);
        }

        private async void Generate_Click(object sender, RoutedEventArgs e)
        {
            List<string> yamls = ValidYamls();
            if (yamls.Count == 0)
            {
                MainWindow.Instance.ShowError("Ajoute au moins un YAML (étape 3).");
                return;
            }
            if (!ArchipelagoTools.ApworldUpToDate(S.ArchipelagoPath))
            {
                MainWindow.Instance.ShowError("L'apworld RE Requiem n'est pas à jour : installe-le d'abord (étape 2).");
                return;
            }
            GenerateButton.IsEnabled = false;
            GenerateStatus.Text = T("Génération en cours...");
            MainWindow.Instance.SetStatus("Génération en cours...");
            try
            {
                S.LastGeneratedZip = await ArchipelagoTools.GenerateAsync(S.ArchipelagoPath, yamls);
                S.Save();
                MainWindow.Instance.SetStatus("Multimonde généré.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(ex.Message);
            }
            finally
            {
                GenerateButton.IsEnabled = true;
            }
            RefreshFooter();
        }

        private void Upload_Click(object sender, RoutedEventArgs e)
        {
            GameLocator.Open(ArchipelagoTools.UploadUrl);
            RevealZip_Click(sender, e);
        }

        private void RevealZip_Click(object sender, RoutedEventArgs e)
        {
            if (File.Exists(S.LastGeneratedZip)) Process.Start("explorer.exe", "/select,\"" + S.LastGeneratedZip + "\"");
        }

        private void LocalServer_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ArchipelagoTools.StartLocalServer(S.ArchipelagoPath, S.LastGeneratedZip);
                MainWindow.Instance.SetStatus("Serveur local démarré : localhost:38281.");
            }
            catch (Exception ex)
            {
                MainWindow.Instance.ShowError(TF("Impossible de démarrer le serveur : {0}", ex.Message));
            }
        }

        private void JoinMine_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate("join");
        }
    }
}
