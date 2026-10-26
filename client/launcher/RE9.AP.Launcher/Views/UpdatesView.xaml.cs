using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using RE9.AP.Launcher.Core;
using static RE9.AP.Launcher.Core.Lang;

namespace RE9.AP.Launcher.Views
{
    public partial class UpdatesView : UserControl, IScreen
    {
        private int loadId;

        public UpdatesView()
        {
            InitializeComponent();
        }

        public void OnShown()
        {
            MainWindow.Instance.SetFooter(new FooterAction("Rechercher des mises à jour", true, async () =>
            {
                await MainWindow.Instance.CheckForUpdatesAsync(false);
                Load();
            }));
            Load();
        }

        private async void Load()
        {
            int id = ++loadId;
            string current = PatchUpdater.CurrentVersion;
            InstalledText.Text = TF("Version installée dans le lanceur : {0}", Display(PatchUpdater.CurrentLabel, current));
            string gamePath = Settings.Current.GamePath;
            string inGame = GameLocator.IsGameFolder(gamePath) ? PatchUpdater.GameVersion(gamePath) : null;
            GameText.Text = inGame == null
                ? T("Client dans le jeu : non installé")
                : TF("Client dans le jeu : {0}", Display(PatchUpdater.GameLabel(gamePath), inGame));
            int archived = PatchUpdater.CountInstalledPatchZips();
            ManualText.Text = archived > 0
                ? TF("{0}  ·  {1} vieux patch(s) (installés + cache AppData)", PatchUpdater.ManualFolder, archived)
                : PatchUpdater.ManualFolder;
            ClearInstalledBtn.IsEnabled = archived > 0;
            ClearInstalledBtn.Content = archived > 0
                ? TF("Vider les vieux patchs ({0})", archived)
                : T("Vider les vieux patchs");
            SourceText.Text = T("Chargement de la liste des patchs...");
            PatchList.Children.Clear();
            EmptyText.Visibility = Visibility.Collapsed;
            PatchFeed feed = await PatchUpdater.CheckAsync();
            if (id != loadId) return;
            SourceText.Text = feed.Source.Length > 0 ? TF("Source : {0}", feed.Source) : "";
            if (feed.Error != null || feed.Patches.Count == 0)
            {
                EmptyText.Text = feed.Error != null ? TF("Liste des patchs indisponible : {0}", feed.Error) : T("Aucun patch publié pour l'instant.");
                EmptyText.Visibility = Visibility.Visible;
                return;
            }
            PatchInfo latest = feed.Latest;
            PatchList.Children.Add(Card(latest, PatchUpdater.Compare(latest.Version, current), false));
        }

        private void OpenPatches_Click(object sender, RoutedEventArgs e)
        {
            string dir = PatchUpdater.ManualFolder;
            if (Directory.Exists(dir)) Process.Start("explorer.exe", "\"" + dir + "\"");
        }

        private void ClearInstalled_Click(object sender, RoutedEventArgs e)
        {
            int n = PatchUpdater.CountInstalledPatchZips();
            if (n <= 0)
            {
                MessageBox.Show(T("Aucun vieux patch à supprimer."), AppInfo.DisplayName,
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (MessageBox.Show(
                    TF("Supprimer {0} zip déjà appliqué(s) ?\n\n• Patchs\\installés (à côté du lanceur)\n• Cache AppData (RE9-AP-Wizard\\patches)\n\nLe client et le mod en jeu restent inchangés.", n),
                    AppInfo.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
                return;
            int deleted = PatchUpdater.ClearInstalledPatches();
            MessageBox.Show(
                deleted > 0
                    ? TF("{0} vieux patch(s) supprimé(s).", deleted)
                    : T("Aucun fichier n'a pu être supprimé."),
                AppInfo.DisplayName, MessageBoxButton.OK,
                deleted > 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
            Load();
        }

        private static string Display(string label, string version)
        {
            return string.IsNullOrEmpty(label) ? version : label;
        }

        private UIElement Card(PatchInfo p, int vsCurrent, bool expanded)
        {
            StackPanel body = new StackPanel();
            Grid head = new Grid { Background = Brushes.Transparent, Cursor = Cursors.Hand };
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock chevron = new TextBlock
            {
                FontSize = 12,
                Margin = new Thickness(0, 3, 0, 0),
                Foreground = (Brush)FindResource("AccentBrush"),
                Text = expanded ? "▼" : "▶",
            };
            head.Children.Add(chevron);
            StackPanel titles = new StackPanel();
            titles.Children.Add(new TextBlock
            {
                FontSize = 15,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                Text = p.LocalTitle.Length > 0 ? p.LocalTitle : Display(p.Label, p.Version),
            });
            string meta = Display(p.Label, p.Version) + "  ·  " + p.Version + (p.Date.Length > 0 ? "  ·  " + p.Date : "");
            titles.Children.Add(new TextBlock
            {
                Margin = new Thickness(0, 2, 0, 0),
                FontSize = 12,
                Foreground = (Brush)FindResource("SubtleTextBrush"),
                Text = meta,
            });
            Grid.SetColumn(titles, 1);
            head.Children.Add(titles);

            string badge = vsCurrent == 0 ? T("Installée") : vsCurrent > 0 ? T("Nouveau") : T("Déjà incluse");
            Border tag = new Border
            {
                Padding = new Thickness(10, 3, 10, 3),
                CornerRadius = new CornerRadius(10),
                VerticalAlignment = VerticalAlignment.Top,
                Background = (Brush)FindResource(vsCurrent > 0 ? "AccentSoftBrush" : "SurfaceBrush"),
                BorderBrush = (Brush)FindResource(vsCurrent > 0 ? "AccentBrush" : "SubtleBorderBrush"),
                BorderThickness = new Thickness(1),
                Child = new TextBlock
                {
                    FontSize = 12,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = (Brush)FindResource(vsCurrent == 0 ? "SuccessTextBrush" : vsCurrent > 0 ? "AccentBrush" : "SubtleTextBrush"),
                    Text = badge,
                },
            };
            Grid.SetColumn(tag, 2);
            head.Children.Add(tag);
            body.Children.Add(head);

            StackPanel notes = new StackPanel
            {
                Margin = new Thickness(22, 2, 0, 0),
                Visibility = expanded ? Visibility.Visible : Visibility.Collapsed,
            };
            body.Children.Add(notes);
            head.MouseLeftButtonUp += (s, e) =>
            {
                bool open = notes.Visibility != Visibility.Visible;
                notes.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
                chevron.Text = open ? "▼" : "▶";
            };

            if (p.LocalNotes.Count == 0)
            {
                notes.Children.Add(new TextBlock
                {
                    Margin = new Thickness(0, 8, 0, 0),
                    Foreground = (Brush)FindResource("SubtleTextBrush"),
                    Text = T("Pas de détail pour ce patch."),
                });
            }
            foreach (string n in p.LocalNotes)
            {
                Grid line = new Grid { Margin = new Thickness(0, 8, 0, 0) };
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.Children.Add(new TextBlock { Text = "•", Foreground = (Brush)FindResource("AccentBrush") });
                TextBlock note = new TextBlock { Text = n, TextWrapping = TextWrapping.Wrap };
                Grid.SetColumn(note, 1);
                line.Children.Add(note);
                notes.Children.Add(line);
            }

            return new Border
            {
                Style = (Style)FindResource("CardStyle"),
                Child = body,
            };
        }
    }
}
