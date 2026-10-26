using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RE9APWizard
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--check")
            {
                string payload = Payload.Root();
                string game = SteamLocator.Find();
                StringBuilder report = new StringBuilder();
                report.AppendLine("payload=" + payload);
                report.AppendLine("payload_ok=" + File.Exists(Path.Combine(payload, "autorun", "AP_client.lua")));
                report.AppendLine("game=" + (game ?? ""));
                if (!string.IsNullOrEmpty(game))
                {
                    report.AppendLine("reframework=" + File.Exists(Path.Combine(game, "dinput8.dll")));
                }
                File.WriteAllText(
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "wizard-check.txt"),
                    report.ToString(),
                    Encoding.UTF8);
                return;
            }

            try
            {
                SetProcessDPIAware();
            }
            catch (Exception)
            {
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
    }

    internal static class Theme
    {
        public static readonly Color Bg = Color.FromArgb(22, 16, 18);
        public static readonly Color Side = Color.FromArgb(32, 20, 24);
        public static readonly Color Card = Color.FromArgb(42, 28, 32);
        public static readonly Color Text = Color.FromArgb(242, 232, 226);
        public static readonly Color Muted = Color.FromArgb(176, 156, 148);
        public static readonly Color Accent = Color.FromArgb(166, 42, 55);
        public static readonly Color AccentSoft = Color.FromArgb(92, 32, 40);
        public static readonly Color Line = Color.FromArgb(84, 58, 64);
        public static readonly Color Ok = Color.FromArgb(126, 186, 138);
        public static readonly Color Warn = Color.FromArgb(224, 168, 92);
        public static readonly Color Bad = Color.FromArgb(214, 96, 96);
        public static readonly Color Input = Color.FromArgb(18, 12, 14);

        public static readonly Font Ui = new Font("Segoe UI", 10f);
        public static readonly Font UiBold = new Font("Segoe UI", 10f, FontStyle.Bold);
        public static readonly Font Title = new Font("Segoe UI", 18f, FontStyle.Bold);
        public static readonly Font Small = new Font("Segoe UI", 9f);

        public static void StyleInput(TextBox box)
        {
            box.BorderStyle = BorderStyle.FixedSingle;
            box.BackColor = Input;
            box.ForeColor = Text;
            box.Font = Ui;
        }

        public static Button Button(string text, bool primary)
        {
            Button button = new Button();
            button.Text = text;
            button.Height = 36;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.BorderColor = primary ? Accent : Line;
            button.BackColor = primary ? Accent : Card;
            button.ForeColor = Text;
            button.Font = UiBold;
            button.Cursor = Cursors.Hand;
            button.Margin = new Padding(0, 0, 8, 0);
            return button;
        }

        public static Label Caption(string text)
        {
            Label label = new Label();
            label.Text = text;
            label.ForeColor = Muted;
            label.Font = Small;
            label.AutoSize = true;
            label.Margin = new Padding(0, 12, 0, 4);
            return label;
        }
    }

    internal static class JsonMini
    {
        public static string Quote(string value)
        {
            if (value == null)
            {
                value = "";
            }
            StringBuilder builder = new StringBuilder();
            builder.Append('"');
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c == '\\' || c == '"')
                {
                    builder.Append('\\');
                    builder.Append(c);
                }
                else if (c == '\n')
                {
                    builder.Append("\\n");
                }
                else if (c == '\r')
                {
                    builder.Append("\\r");
                }
                else if (c == '\t')
                {
                    builder.Append("\\t");
                }
                else if (c < 32)
                {
                    builder.Append("\\u");
                    builder.Append(((int)c).ToString("x4"));
                }
                else
                {
                    builder.Append(c);
                }
            }
            builder.Append('"');
            return builder.ToString();
        }

        public static string ReadString(string json, string key)
        {
            if (string.IsNullOrEmpty(json))
            {
                return "";
            }
            Match match = Regex.Match(
                json,
                "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"((?:\\\\.|[^\\\\\"])*)\"");
            if (!match.Success)
            {
                return "";
            }
            return Unescape(match.Groups[1].Value);
        }

        public static bool ReadBool(string json, string key, bool fallback)
        {
            if (string.IsNullOrEmpty(json))
            {
                return fallback;
            }
            Match match = Regex.Match(
                json,
                "\"" + Regex.Escape(key) + "\"\\s*:\\s*(true|false)");
            if (!match.Success)
            {
                return fallback;
            }
            return match.Groups[1].Value == "true";
        }

        private static string Unescape(string value)
        {
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c == '\\' && i + 1 < value.Length)
                {
                    char n = value[i + 1];
                    if (n == 'n') builder.Append('\n');
                    else if (n == 'r') builder.Append('\r');
                    else if (n == 't') builder.Append('\t');
                    else builder.Append(n);
                    i++;
                }
                else
                {
                    builder.Append(c);
                }
            }
            return builder.ToString();
        }
    }

    internal static class SteamLocator
    {
        public const int AppId = 3764200;
        public const string ExeName = "re9.exe";

        public static string Find()
        {
            List<string> libraries = Libraries();
            for (int i = 0; i < libraries.Count; i++)
            {
                string manifest = Path.Combine(
                    libraries[i],
                    "steamapps",
                    "appmanifest_" + AppId.ToString() + ".acf");
                if (!File.Exists(manifest))
                {
                    continue;
                }
                string installDir = Acf(File.ReadAllText(manifest), "installdir");
                if (string.IsNullOrEmpty(installDir))
                {
                    continue;
                }
                string full = Path.Combine(libraries[i], "steamapps", "common", installDir);
                if (File.Exists(Path.Combine(full, ExeName)))
                {
                    return Path.GetFullPath(full);
                }
            }

            for (int i = 0; i < libraries.Count; i++)
            {
                string common = Path.Combine(libraries[i], "steamapps", "common");
                if (!Directory.Exists(common))
                {
                    continue;
                }
                string[] dirs = Directory.GetDirectories(common);
                for (int d = 0; d < dirs.Length; d++)
                {
                    if (File.Exists(Path.Combine(dirs[d], ExeName)))
                    {
                        return Path.GetFullPath(dirs[d]);
                    }
                }
            }
            return null;
        }

        private static List<string> Libraries()
        {
            List<string> paths = new List<string>();
            AddReg(Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath", paths);
            AddReg(Registry.LocalMachine, @"Software\WOW6432Node\Valve\Steam", "InstallPath", paths);

            List<string> roots = new List<string>(paths);
            for (int i = 0; i < roots.Count; i++)
            {
                string vdf = Path.Combine(roots[i], "steamapps", "libraryfolders.vdf");
                if (!File.Exists(vdf))
                {
                    continue;
                }
                MatchCollection matches = Regex.Matches(
                    File.ReadAllText(vdf),
                    "\"path\"\\s+\"([^\"]+)\"");
                for (int m = 0; m < matches.Count; m++)
                {
                    Add(paths, matches[m].Groups[1].Value.Replace("\\\\", "\\"));
                }
            }
            return paths;
        }

        private static void AddReg(RegistryKey hive, string sub, string valueName, List<string> paths)
        {
            try
            {
                using (RegistryKey key = hive.OpenSubKey(sub))
                {
                    if (key == null)
                    {
                        return;
                    }
                    object value = key.GetValue(valueName);
                    if (value != null)
                    {
                        Add(paths, value.ToString());
                    }
                }
            }
            catch (Exception)
            {
            }
        }

        private static void Add(List<string> paths, string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return;
            }
            try
            {
                path = Path.GetFullPath(path);
            }
            catch (Exception)
            {
                return;
            }
            for (int i = 0; i < paths.Count; i++)
            {
                if (string.Equals(paths[i], path, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
            }
            paths.Add(path);
        }

        private static string Acf(string text, string key)
        {
            Match match = Regex.Match(text, "\"" + Regex.Escape(key) + "\"\\s+\"([^\"]+)\"");
            return match.Success ? match.Groups[1].Value : "";
        }
    }

    internal static class Payload
    {
        public const string Version = "0.1.0";

        private static readonly string[] ClientFiles = new string[]
        {
            @"autorun\AP_client.lua",
            @"autorun\randomizer\send_to_box.lua",
            @"autorun\randomizer\pickup.lua",
            @"data\item_list.json"
        };

        private static readonly string[] LeonFiles = new string[]
        {
            @"autorun\leon_box.lua"
        };

        private static readonly string[] SpeedFiles = new string[]
        {
            @"autorun\speed_modifier.lua"
        };

        public static string Root()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string bundled = Path.GetFullPath(Path.Combine(baseDir, "assets", "reframework"));
            string sibling = Path.GetFullPath(Path.Combine(baseDir, "..", "reframework"));
            if (File.Exists(Path.Combine(bundled, "autorun", "AP_client.lua")))
            {
                return bundled;
            }
            return sibling;
        }

        public static bool IsReady()
        {
            return File.Exists(Path.Combine(Root(), "autorun", "AP_client.lua"));
        }

        public static List<string> Select(bool client, bool leon, bool speed)
        {
            List<string> files = new List<string>();
            if (client) files.AddRange(ClientFiles);
            if (leon) files.AddRange(LeonFiles);
            if (speed) files.AddRange(SpeedFiles);
            return files;
        }

        public static List<string> AllKnown()
        {
            return Select(true, true, true);
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly Button[] steps = new Button[4];
        private readonly Panel[] pages = new Panel[4];
        private readonly Label pageTitle = new Label();
        private readonly Label pageSubtitle = new Label();
        private readonly Label footer = new Label();

        private TextBox gamePath;
        private Label exeStatus;
        private Label frameworkStatus;
        private Label modStatus;
        private TextBox serverBox;
        private TextBox slotBox;
        private TextBox passwordBox;
        private CheckBox showPassword;
        private CheckBox clientCheck;
        private CheckBox leonCheck;
        private CheckBox speedCheck;
        private TextBox logBox;
        private int current;

        public MainForm()
        {
            Text = "RE9 AP Wizard";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            ClientSize = new Size(980, 640);
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = Theme.Ui;

            Panel side = new Panel();
            side.Dock = DockStyle.Left;
            side.Width = 230;
            side.BackColor = Theme.Side;
            Controls.Add(side);

            Label brand = new Label();
            brand.Text = "RE9 AP";
            brand.Font = Theme.Title;
            brand.ForeColor = Theme.Text;
            brand.AutoSize = true;
            brand.Location = new Point(22, 22);
            side.Controls.Add(brand);

            Label brandSub = new Label();
            brandSub.Text = "Resident Evil Requiem";
            brandSub.Font = Theme.Small;
            brandSub.ForeColor = Theme.Muted;
            brandSub.AutoSize = true;
            brandSub.Location = new Point(24, 58);
            side.Controls.Add(brandSub);

            string[] names = new string[] { "1   Jeu", "2   Session", "3   Installation", "4   Lancer" };
            for (int i = 0; i < names.Length; i++)
            {
                Button step = Theme.Button(names[i], false);
                step.Width = 186;
                step.Location = new Point(22, 110 + i * 48);
                step.TextAlign = ContentAlignment.MiddleLeft;
                step.Padding = new Padding(12, 0, 0, 0);
                int index = i;
                step.Click += delegate { ShowPage(index); };
                steps[i] = step;
                side.Controls.Add(step);
            }

            Label version = new Label();
            version.Text = "v" + Payload.Version + "   ·   scripts seulement";
            version.Font = Theme.Small;
            version.ForeColor = Theme.Muted;
            version.AutoSize = false;
            version.Size = new Size(190, 40);
            version.Location = new Point(22, 580);
            side.Controls.Add(version);

            Panel main = new Panel();
            main.Dock = DockStyle.Fill;
            main.BackColor = Theme.Bg;
            main.Padding = new Padding(28, 22, 28, 16);
            Controls.Add(main);
            Controls.SetChildIndex(side, Controls.Count - 1);

            pageTitle.Font = Theme.Title;
            pageTitle.ForeColor = Theme.Text;
            pageTitle.AutoSize = true;
            pageTitle.Dock = DockStyle.Top;
            pageSubtitle.Font = Theme.Ui;
            pageSubtitle.ForeColor = Theme.Muted;
            pageSubtitle.AutoSize = false;
            pageSubtitle.Height = 48;
            pageSubtitle.Dock = DockStyle.Top;
            pageSubtitle.Padding = new Padding(0, 6, 0, 0);

            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 88;
            header.Controls.Add(pageSubtitle);
            header.Controls.Add(pageTitle);

            footer.Dock = DockStyle.Bottom;
            footer.Height = 28;
            footer.ForeColor = Theme.Muted;
            footer.Font = Theme.Small;
            footer.TextAlign = ContentAlignment.MiddleLeft;

            Panel host = new Panel();
            host.Dock = DockStyle.Fill;
            host.Padding = new Padding(0, 8, 0, 0);
            main.Controls.Add(host);
            main.Controls.Add(footer);
            main.Controls.Add(header);

            pages[0] = BuildGamePage();
            pages[1] = BuildSessionPage();
            pages[2] = BuildInstallPage();
            pages[3] = BuildLaunchPage();
            for (int i = 0; i < pages.Length; i++)
            {
                pages[i].Dock = DockStyle.Fill;
                pages[i].Visible = false;
                host.Controls.Add(pages[i]);
            }

            LoadDraft();
            if (!HasGameExe(gamePath.Text))
            {
                string found = SteamLocator.Find();
                if (!string.IsNullOrEmpty(found))
                {
                    gamePath.Text = found;
                }
            }
            RefreshGameStatus();
            ShowPage(0);
            FormClosing += delegate { SaveDraft(); };
        }

        private Panel BuildGamePage()
        {
            Panel page = new Panel();
            page.BackColor = Theme.Bg;

            Label caption = Theme.Caption("Dossier d'installation");
            caption.Dock = DockStyle.Top;

            Panel row = new Panel();
            row.Dock = DockStyle.Top;
            row.Height = 40;

            Button browse = Theme.Button("Parcourir", false);
            browse.Dock = DockStyle.Right;
            browse.Width = 120;
            browse.Click += delegate { BrowseGame(); };

            Button detect = Theme.Button("Détecter Steam", true);
            detect.Dock = DockStyle.Right;
            detect.Width = 150;
            detect.Click += delegate
            {
                string found = SteamLocator.Find();
                if (string.IsNullOrEmpty(found))
                {
                    footer.Text = "Resident Evil Requiem (Steam 3764200) introuvable. Indique le dossier à la main.";
                    footer.ForeColor = Theme.Warn;
                    return;
                }
                gamePath.Text = found;
                RefreshGameStatus();
                footer.Text = "Jeu trouvé.";
                footer.ForeColor = Theme.Ok;
            };

            gamePath = new TextBox();
            Theme.StyleInput(gamePath);
            gamePath.Dock = DockStyle.Fill;
            gamePath.TextChanged += delegate { RefreshGameStatus(); };
            row.Controls.Add(gamePath);
            row.Controls.Add(browse);
            row.Controls.Add(detect);

            Panel card = new Panel();
            card.Dock = DockStyle.Top;
            card.Height = 150;
            card.BackColor = Theme.Card;
            card.Padding = new Padding(16, 14, 16, 8);
            card.Margin = new Padding(0, 16, 0, 0);

            exeStatus = StatusLine();
            frameworkStatus = StatusLine();
            modStatus = StatusLine();
            exeStatus.Dock = DockStyle.Top;
            frameworkStatus.Dock = DockStyle.Top;
            modStatus.Dock = DockStyle.Top;
            card.Controls.Add(modStatus);
            card.Controls.Add(frameworkStatus);
            card.Controls.Add(exeStatus);

            Panel cardHost = new Panel();
            cardHost.Dock = DockStyle.Top;
            cardHost.Height = 168;
            cardHost.Padding = new Padding(0, 18, 0, 0);
            cardHost.Controls.Add(card);

            TextBox note = Note(
                "Ce wizard fait la même chose que le lanceur RE4R pour la partie scripts : il trouve le jeu, copie le mod REFramework et enregistre la session Archipelago.\r\n\r\n" +
                "Il ne patche pas les fichiers du jeu. REFramework (dinput8.dll) doit déjà être installé. S'il manque, prends la build RE9 sur le dépôt praydog/REFramework, ferme le jeu, puis relance la détection.");
            note.Dock = DockStyle.Top;
            note.Height = 130;

            Panel linkRow = new Panel();
            linkRow.Dock = DockStyle.Top;
            linkRow.Height = 52;
            linkRow.Padding = new Padding(0, 12, 0, 0);
            Button openFramework = Theme.Button("Page REFramework", false);
            openFramework.Width = 180;
            openFramework.Dock = DockStyle.Left;
            openFramework.Click += delegate
            {
                OpenUrl("https://github.com/praydog/REFramework/releases");
            };
            linkRow.Controls.Add(openFramework);

            page.Controls.Add(linkRow);
            page.Controls.Add(note);
            page.Controls.Add(cardHost);
            page.Controls.Add(row);
            page.Controls.Add(caption);

            return page;
        }

        private Panel BuildSessionPage()
        {
            Panel page = new Panel();
            page.BackColor = Theme.Bg;

            showPassword = new CheckBox();
            showPassword.Text = "Afficher le mot de passe";
            showPassword.ForeColor = Theme.Muted;
            showPassword.AutoSize = false;
            showPassword.Height = 32;
            showPassword.Dock = DockStyle.Top;
            showPassword.Padding = new Padding(0, 8, 0, 0);
            showPassword.CheckedChanged += delegate
            {
                passwordBox.UseSystemPasswordChar = !showPassword.Checked;
            };

            TextBox note = Note(
                "L'hôte de la partie a besoin d'un fichier de réglages par joueur avant de générer le multiworld. Ce dépôt n'a pas encore de monde Archipelago pour RE9, donc cette page ne fait qu'enregistrer serveur, slot et mot de passe.\r\n\r\n" +
                "Ces valeurs sont écrites dans le jeu au moment de l'installation : reframework\\data\\re9_ap_session.json.");
            note.Dock = DockStyle.Top;
            note.Height = 120;

            page.Controls.Add(note);
            page.Controls.Add(showPassword);
            passwordBox = Field(page, "Mot de passe", "laisser vide s'il n'y en a pas");
            passwordBox.UseSystemPasswordChar = true;
            slotBox = Field(page, "Nom du slot", "16 caractères maximum, comme Archipelago");
            slotBox.MaxLength = 16;
            serverBox = Field(page, "Adresse du serveur", "archipelago.gg:12345");

            return page;
        }

        private Panel BuildInstallPage()
        {
            Panel page = new Panel();
            page.BackColor = Theme.Bg;

            clientCheck = Option("Client Archipelago et injection dans le coffre", true);
            leonCheck = Option("Boîte Leon (expérimental, actif dès le lancement du jeu)", false);
            speedCheck = Option("Modificateur de vitesse (reste éteint tant que tu ne l'actives pas)", false);

            Panel buttons = new Panel();
            buttons.Dock = DockStyle.Top;
            buttons.Height = 52;
            buttons.Padding = new Padding(0, 14, 0, 0);

            Button install = Theme.Button("Installer dans le jeu", true);
            install.Width = 200;
            install.Dock = DockStyle.Left;
            install.Click += delegate { Install(); };

            Button remove = Theme.Button("Retirer le mod", false);
            remove.Width = 150;
            remove.Dock = DockStyle.Left;
            remove.Margin = new Padding(8, 0, 0, 0);
            remove.Click += delegate { RemoveMod(); };

            buttons.Controls.Add(remove);
            buttons.Controls.Add(install);

            logBox = new TextBox();
            Theme.StyleInput(logBox);
            logBox.Multiline = true;
            logBox.ReadOnly = true;
            logBox.ScrollBars = ScrollBars.Vertical;
            logBox.Dock = DockStyle.Fill;
            logBox.Font = new Font("Consolas", 9f);

            page.Controls.Add(logBox);
            page.Controls.Add(buttons);
            page.Controls.Add(speedCheck);
            page.Controls.Add(leonCheck);
            page.Controls.Add(clientCheck);

            return page;
        }

        private Panel BuildLaunchPage()
        {
            Panel page = new Panel();
            page.BackColor = Theme.Bg;

            TextBox note = Note(
                "1. L'installation des scripts est faite.\r\n" +
                "2. Lance RE9 depuis Steam.\r\n" +
                "3. En jeu, appuie sur Insert pour ouvrir REFramework. L'injection du coffre est dans « RE9 Item Injection ». La fenêtre de connexion Archipelago apparaît quand la librairie AP_REF est présente à côté des scripts.\r\n\r\n" +
                "Si Steam a vérifié les fichiers du jeu, relance simplement l'installation : les .pak ne sont pas touchés, seuls les scripts REFramework le sont.");
            note.Dock = DockStyle.Top;
            note.Height = 170;

            Panel buttons = new Panel();
            buttons.Dock = DockStyle.Top;
            buttons.Height = 52;
            buttons.Padding = new Padding(0, 12, 0, 0);

            Button launch = Theme.Button("Lancer Resident Evil Requiem", true);
            launch.Width = 280;
            launch.Dock = DockStyle.Left;
            launch.Click += delegate { LaunchGame(); };

            Button openDir = Theme.Button("Ouvrir le dossier du jeu", false);
            openDir.Width = 210;
            openDir.Dock = DockStyle.Left;
            openDir.Click += delegate
            {
                if (!HasGameExe(gamePath.Text))
                {
                    footer.Text = "Dossier du jeu invalide.";
                    footer.ForeColor = Theme.Bad;
                    return;
                }
                Process.Start("explorer.exe", gamePath.Text);
            };

            buttons.Controls.Add(openDir);
            buttons.Controls.Add(launch);
            page.Controls.Add(buttons);
            page.Controls.Add(note);
            return page;
        }

        private static Label StatusLine()
        {
            Label label = new Label();
            label.AutoSize = false;
            label.Height = 32;
            label.ForeColor = Theme.Text;
            label.Font = Theme.Ui;
            label.TextAlign = ContentAlignment.MiddleLeft;
            return label;
        }

        private static TextBox Note(string text)
        {
            TextBox box = new TextBox();
            Theme.StyleInput(box);
            box.Multiline = true;
            box.ReadOnly = true;
            box.BorderStyle = BorderStyle.None;
            box.BackColor = Theme.Bg;
            box.Text = text;
            box.TabStop = false;
            return box;
        }

        private TextBox Field(Panel page, string caption, string hint)
        {
            Label help = new Label();
            help.Text = hint;
            help.ForeColor = Theme.Muted;
            help.Font = Theme.Small;
            help.AutoSize = true;
            help.Dock = DockStyle.Top;
            help.Padding = new Padding(0, 4, 0, 8);

            TextBox box = new TextBox();
            Theme.StyleInput(box);
            box.Dock = DockStyle.Top;
            box.Height = 28;

            Label label = Theme.Caption(caption);
            label.Dock = DockStyle.Top;

            page.Controls.Add(help);
            page.Controls.Add(box);
            page.Controls.Add(label);
            return box;
        }

        private static CheckBox Option(string text, bool value)
        {
            CheckBox box = new CheckBox();
            box.Text = text;
            box.ForeColor = Theme.Text;
            box.Font = Theme.Ui;
            box.Checked = value;
            box.AutoSize = true;
            box.Dock = DockStyle.Top;
            box.Padding = new Padding(0, 8, 0, 4);
            return box;
        }

        private void ShowPage(int index)
        {
            current = index;
            string[] titles = new string[] { "Jeu", "Session", "Installation", "Lancer" };
            string[] subs = new string[]
            {
                "Indique le dossier qui contient re9.exe.",
                "Serveur, slot et mot de passe donnés par l'hôte.",
                "Copie les scripts dans reframework, sans toucher au reste du jeu.",
                "Démarre RE9. La connexion se fait dans REFramework."
            };
            pageTitle.Text = titles[index];
            pageSubtitle.Text = subs[index];
            for (int i = 0; i < pages.Length; i++)
            {
                pages[i].Visible = i == index;
                steps[i].BackColor = i == index ? Theme.Accent : Theme.Card;
                steps[i].FlatAppearance.BorderColor = i == index ? Theme.Accent : Theme.Line;
            }
            if (index == 3)
            {
                footer.Text = HasGameExe(gamePath.Text)
                    ? "Prêt à lancer " + gamePath.Text
                    : "Le dossier du jeu n'est pas encore valide.";
                footer.ForeColor = HasGameExe(gamePath.Text) ? Theme.Muted : Theme.Warn;
            }
        }

        private void BrowseGame()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Dossier qui contient re9.exe";
                if (HasGameExe(gamePath.Text))
                {
                    dialog.SelectedPath = gamePath.Text;
                }
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    gamePath.Text = dialog.SelectedPath;
                    RefreshGameStatus();
                }
            }
        }

        private void RefreshGameStatus()
        {
            string path = gamePath.Text.Trim();
            bool exe = HasGameExe(path);
            bool framework = exe && File.Exists(Path.Combine(path, "dinput8.dll"));
            bool mod = exe && File.Exists(Path.Combine(path, "reframework", "autorun", "AP_client.lua"));
            SetStatus(exeStatus, exe, "re9.exe trouvé", "re9.exe absent de ce dossier");
            SetStatus(frameworkStatus, framework, "REFramework détecté (dinput8.dll)", "REFramework absent — le mod ne se chargera pas");
            SetStatus(modStatus, mod, "Scripts RE9 AP déjà installés", "Scripts RE9 AP pas encore installés");
            if (!exe)
            {
                frameworkStatus.Text = "REFramework — en attente du dossier du jeu";
                frameworkStatus.ForeColor = Theme.Muted;
                modStatus.Text = "Scripts RE9 AP — en attente du dossier du jeu";
                modStatus.ForeColor = Theme.Muted;
            }
        }

        private static void SetStatus(Label label, bool ok, string yes, string no)
        {
            label.Text = (ok ? "●  " : "○  ") + (ok ? yes : no);
            label.ForeColor = ok ? Theme.Ok : Theme.Warn;
        }

        private static bool HasGameExe(string path)
        {
            return !string.IsNullOrEmpty(path) && File.Exists(Path.Combine(path.Trim(), SteamLocator.ExeName));
        }

        private void Install()
        {
            string game = gamePath.Text.Trim();
            if (!HasGameExe(game))
            {
                ShowPage(0);
                footer.Text = "Choisis d'abord le dossier qui contient re9.exe.";
                footer.ForeColor = Theme.Bad;
                return;
            }
            if (!Payload.IsReady())
            {
                Log("Scripts sources introuvables : " + Payload.Root());
                footer.Text = "Le dossier reframework du projet est introuvable à côté du wizard.";
                footer.ForeColor = Theme.Bad;
                return;
            }
            if (string.IsNullOrEmpty(slotBox.Text.Trim()) || string.IsNullOrEmpty(serverBox.Text.Trim()))
            {
                DialogResult go = MessageBox.Show(
                    this,
                    "Le serveur ou le nom du slot est vide. Installer les scripts quand même ?",
                    "Session incomplète",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (go != DialogResult.Yes)
                {
                    ShowPage(1);
                    return;
                }
            }
            if (IsGameRunning())
            {
                MessageBox.Show(
                    this,
                    "RE9 est en cours d'exécution. Ferme le jeu, puis relance l'installation.",
                    "Jeu ouvert",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            List<string> files = Payload.Select(clientCheck.Checked, leonCheck.Checked, speedCheck.Checked);
            if (files.Count == 0)
            {
                footer.Text = "Coche au moins un composant.";
                footer.ForeColor = Theme.Warn;
                return;
            }

            try
            {
                string source = Payload.Root();
                string destRoot = Path.Combine(game, "reframework");
                Log("Source : " + source);
                for (int i = 0; i < files.Count; i++)
                {
                    string from = Path.Combine(source, files[i]);
                    string to = Path.Combine(destRoot, files[i]);
                    if (!File.Exists(from))
                    {
                        throw new FileNotFoundException("Fichier source manquant", from);
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(to));
                    File.Copy(from, to, true);
                    Log("Copié  " + files[i]);
                }

                RemoveUnchecked(destRoot);

                string data = Path.Combine(destRoot, "data");
                Directory.CreateDirectory(data);
                File.WriteAllText(Path.Combine(data, "re9_ap_session.json"), SessionJson(), Encoding.UTF8);
                Log("Écrit  data\\re9_ap_session.json");

                string stamp = "{\r\n"
                    + "  \"launcher_version\": " + JsonMini.Quote(Payload.Version) + ",\r\n"
                    + "  \"payload\": \"re9-ap-client\",\r\n"
                    + "  \"installed_utc\": " + JsonMini.Quote(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")) + "\r\n"
                    + "}\r\n";
                File.WriteAllText(Path.Combine(data, "version_stamp.json"), stamp, Encoding.UTF8);

                StringBuilder manifest = new StringBuilder();
                manifest.Append("{\r\n  \"files\": [\r\n");
                for (int i = 0; i < files.Count; i++)
                {
                    manifest.Append("    " + JsonMini.Quote(files[i].Replace('\\', '/')));
                    if (i + 1 < files.Count) manifest.Append(",");
                    manifest.Append("\r\n");
                }
                manifest.Append("  ]\r\n}\r\n");
                File.WriteAllText(Path.Combine(data, "re9_ap_installed.json"), manifest.ToString(), Encoding.UTF8);

                SaveDraft();
                RefreshGameStatus();
                footer.Text = "Installation terminée.";
                footer.ForeColor = Theme.Ok;
                Log("Terminé.");
                ShowPage(3);
            }
            catch (Exception ex)
            {
                Log("ERREUR  " + ex.Message);
                footer.Text = "Installation interrompue.";
                footer.ForeColor = Theme.Bad;
            }
        }

        private void RemoveUnchecked(string destRoot)
        {
            if (!clientCheck.Checked)
            {
                TryDelete(Path.Combine(destRoot, "autorun", "AP_client.lua"));
                TryDelete(Path.Combine(destRoot, "autorun", "randomizer", "send_to_box.lua"));
                TryDelete(Path.Combine(destRoot, "autorun", "randomizer", "pickup.lua"));
            }
            if (!leonCheck.Checked)
            {
                TryDelete(Path.Combine(destRoot, "autorun", "leon_box.lua"));
            }
            if (!speedCheck.Checked)
            {
                TryDelete(Path.Combine(destRoot, "autorun", "speed_modifier.lua"));
            }
        }

        private void RemoveMod()
        {
            string game = gamePath.Text.Trim();
            if (!HasGameExe(game))
            {
                footer.Text = "Dossier du jeu invalide.";
                footer.ForeColor = Theme.Bad;
                return;
            }
            if (IsGameRunning())
            {
                MessageBox.Show(this, "Ferme RE9 avant de retirer le mod.", "Jeu ouvert",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            DialogResult go = MessageBox.Show(
                this,
                "Retirer les scripts RE9 AP de ce dossier ? REFramework lui-même reste en place.",
                "Retirer le mod",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);
            if (go != DialogResult.Yes)
            {
                return;
            }

            string destRoot = Path.Combine(game, "reframework");
            List<string> files = Payload.AllKnown();
            for (int i = 0; i < files.Count; i++)
            {
                string to = Path.Combine(destRoot, files[i]);
                if (TryDelete(to))
                {
                    Log("Retiré  " + files[i]);
                }
            }
            TryDelete(Path.Combine(destRoot, "data", "re9_ap_session.json"));
            TryDelete(Path.Combine(destRoot, "data", "version_stamp.json"));
            TryDelete(Path.Combine(destRoot, "data", "re9_ap_installed.json"));
            RefreshGameStatus();
            footer.Text = "Scripts retirés. REFramework n'a pas été désinstallé.";
            footer.ForeColor = Theme.Ok;
        }

        private bool TryDelete(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                    return true;
                }
            }
            catch (Exception ex)
            {
                Log("Impossible de supprimer " + path + " : " + ex.Message);
            }
            return false;
        }

        private void LaunchGame()
        {
            if (!HasGameExe(gamePath.Text))
            {
                ShowPage(0);
                footer.Text = "Indique d'abord le dossier du jeu.";
                footer.ForeColor = Theme.Bad;
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo("steam://rungameid/" + SteamLocator.AppId.ToString()));
                footer.Text = "Steam a reçu la demande de lancement.";
                footer.ForeColor = Theme.Ok;
                Log("Lancement Steam app " + SteamLocator.AppId.ToString());
            }
            catch (Exception ex)
            {
                footer.Text = "Steam n'a pas pu être contacté.";
                footer.ForeColor = Theme.Bad;
                Log("ERREUR  " + ex.Message);
            }
        }

        private static bool IsGameRunning()
        {
            return Process.GetProcessesByName("re9").Length > 0;
        }

        private string SessionJson()
        {
            return "{\r\n"
                + "  \"server\": " + JsonMini.Quote(serverBox.Text.Trim()) + ",\r\n"
                + "  \"slot_name\": " + JsonMini.Quote(slotBox.Text.Trim()) + ",\r\n"
                + "  \"password\": " + JsonMini.Quote(passwordBox.Text) + "\r\n"
                + "}\r\n";
        }

        private string DraftPath()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RE9-AP-Wizard");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "draft.json");
        }

        private void LoadDraft()
        {
            try
            {
                string path = DraftPath();
                if (!File.Exists(path))
                {
                    return;
                }
                string json = File.ReadAllText(path);
                gamePath.Text = JsonMini.ReadString(json, "game_path");
                serverBox.Text = JsonMini.ReadString(json, "server");
                slotBox.Text = JsonMini.ReadString(json, "slot_name");
                passwordBox.Text = JsonMini.ReadString(json, "password");
                clientCheck.Checked = JsonMini.ReadBool(json, "install_client", true);
                leonCheck.Checked = JsonMini.ReadBool(json, "install_leon", false);
                speedCheck.Checked = JsonMini.ReadBool(json, "install_speed", false);
            }
            catch (Exception)
            {
            }
        }

        private void SaveDraft()
        {
            try
            {
                string json = "{\r\n"
                    + "  \"game_path\": " + JsonMini.Quote(gamePath.Text.Trim()) + ",\r\n"
                    + "  \"server\": " + JsonMini.Quote(serverBox.Text.Trim()) + ",\r\n"
                    + "  \"slot_name\": " + JsonMini.Quote(slotBox.Text.Trim()) + ",\r\n"
                    + "  \"password\": " + JsonMini.Quote(passwordBox.Text) + ",\r\n"
                    + "  \"install_client\": " + (clientCheck.Checked ? "true" : "false") + ",\r\n"
                    + "  \"install_leon\": " + (leonCheck.Checked ? "true" : "false") + ",\r\n"
                    + "  \"install_speed\": " + (speedCheck.Checked ? "true" : "false") + "\r\n"
                    + "}\r\n";
                File.WriteAllText(DraftPath(), json, Encoding.UTF8);
            }
            catch (Exception)
            {
            }
        }

        private void Log(string line)
        {
            logBox.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "]  " + line + "\r\n");
        }

        private static void OpenUrl(string url)
        {
            Process.Start(new ProcessStartInfo(url));
        }
    }
}
