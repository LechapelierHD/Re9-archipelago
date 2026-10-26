using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace RE9.AP.Launcher.Core
{
    // Les textes français servent de clés ; un texte absent du dictionnaire reste tel quel.
    public static class Lang
    {
        public static readonly string[][] Languages = { new[] { "fr", "Français" }, new[] { "en", "English" } };

        public static event Action Changed;

        public static bool English
        {
            get { return Settings.Current.Language == "en"; }
        }

        public static void Set(string code)
        {
            string lang = code == "en" ? "en" : "fr";
            if (Settings.Current.Language == lang) return;
            Settings.Current.Language = lang;
            Settings.Current.Save();
            Log.Info("Langue du lanceur : " + lang);
            if (Changed != null) Changed();
        }

        public static string T(string fr)
        {
            if (fr == null || !English) return fr;
            string en;
            return En.TryGetValue(fr, out en) ? en : fr;
        }

        public static string TF(string fr, params object[] args)
        {
            return string.Format(T(fr), args);
        }

        private sealed class Original
        {
            public string Text;
            public string Applied;
        }

        private static readonly ConditionalWeakTable<object, Original> Texts = new ConditionalWeakTable<object, Original>();
        private static readonly ConditionalWeakTable<object, Original> Runs = new ConditionalWeakTable<object, Original>();
        private static readonly ConditionalWeakTable<object, Original> Contents = new ConditionalWeakTable<object, Original>();
        private static readonly ConditionalWeakTable<object, Original> Headers = new ConditionalWeakTable<object, Original>();
        private static readonly ConditionalWeakTable<object, Original> Tips = new ConditionalWeakTable<object, Original>();

        private static string Translate(ConditionalWeakTable<object, Original> table, object key, string current)
        {
            Original o;
            if (!table.TryGetValue(key, out o))
            {
                o = new Original { Text = current };
                table.Add(key, o);
            }
            else if (current != o.Applied)
            {
                o.Text = current;
            }
            o.Applied = T(o.Text);
            return o.Applied;
        }

        public static void Apply(DependencyObject root)
        {
            if (root == null) return;
            // Un TextBlock à texte simple n'expose pas son Run ; un texte mixte (liens) n'est jamais une clé
            TextBlock tb = root as TextBlock;
            if (tb != null && !string.IsNullOrEmpty(tb.Text))
            {
                string t = Translate(Texts, tb, tb.Text);
                if (t != tb.Text) tb.Text = t;
            }
            Run run = root as Run;
            if (run != null && !string.IsNullOrEmpty(run.Text))
            {
                string t = Translate(Runs, run, run.Text);
                if (t != run.Text) run.Text = t;
            }
            ContentControl cc = root as ContentControl;
            if (cc != null && !(cc is Window))
            {
                string s = cc.Content as string;
                if (!string.IsNullOrEmpty(s))
                {
                    string t = Translate(Contents, cc, s);
                    if (t != s) cc.Content = t;
                }
                HeaderedContentControl hc = cc as HeaderedContentControl;
                string h = hc != null ? hc.Header as string : null;
                if (!string.IsNullOrEmpty(h))
                {
                    string t = Translate(Headers, hc, h);
                    if (t != h) hc.Header = t;
                }
            }
            FrameworkElement fe = root as FrameworkElement;
            string tip = fe != null ? fe.ToolTip as string : null;
            if (!string.IsNullOrEmpty(tip))
            {
                string t = Translate(Tips, fe, tip);
                if (t != tip) fe.ToolTip = t;
            }
            // Copie : changer le texte d'un Run modifie les enfants de son TextBlock
            List<object> children = new List<object>();
            foreach (object child in LogicalTreeHelper.GetChildren(root)) children.Add(child);
            foreach (object child in children)
            {
                DependencyObject d = child as DependencyObject;
                if (d != null) Apply(d);
            }
        }

        private static readonly Dictionary<string, string> En = new Dictionary<string, string>
        {
            { "MENU", "MENU" },
            { "Accueil", "Home" },
            { "Rejoindre un multimonde", "Join a multiworld" },
            { "Héberger un multimonde", "Host a multiworld" },
            { "État de la configuration", "Setup status" },
            { "Mises à jour", "Updates" },
            { "SESSION EN COURS", "CURRENT SESSION" },
            { "Rechercher des mises à jour", "Check for updates" },
            { "Recherche en cours...", "Checking..." },
            { "Générer un rapport de bug", "Create a bug report" },
            { "Ouvrir le dossier des journaux", "Open the logs folder" },
            { "Propulsé par ", "Powered by " },
            { " et ", " and " },
            { "Mettre à jour", "Update" },
            { "Plus tard", "Later" },
            { "Fermer", "Close" },
            { "Prêt.", "Ready." },
            { "Langue : Français", "Language: English" },
            { "Changer la langue du lanceur (Français / English).", "Change the launcher language (Français / English)." },
            { "Cherche une nouvelle mise à jour du client.", "Looks for a new client update." },
            { "Crée une archive (journaux, état de session, sans mot de passe) à joindre sur Discord.", "Creates an archive (logs, session state, no password) to attach on Discord." },
            { "Session en cours : aucune", "Current session: none" },
            { "Dernière installation : n/d", "Last install: n/a" },
            { "Session en cours : {0} sur {1}", "Current session: {0} on {1}" },
            { "{0} / {1} checks", "{0} / {1} checks" },
            { "progression inconnue", "progress unknown" },
            { "Installée le {0} · {1}", "Installed {0} · {1}" },
            { "n/d", "n/a" },
            { "client {0} · {1} emplacements", "client {0} · {1} locations" },
            { "Rapport de bug créé sur le bureau : {0}", "Bug report created on the desktop: {0}" },
            { "Impossible de créer le rapport : {0}", "Could not create the report: {0}" },

            { "Le client est à jour (version {0}).", "The client is up to date (version {0})." },
            { "Mise à jour disponible : version {0}", "Update available: version {0}" },
            { "   (installée : {0})", "   (installed: {0})" },
            { "Mise à jour du client dans le jeu : version {0}", "Update the client in the game: version {0}" },
            { "   (dans le jeu : {0})", "   (in game: {0})" },
            { "ancienne", "old" },
            { "Le lanceur a une version plus récente du client que celle installée dans le jeu.", "The launcher has a newer client than the one installed in the game." },
            { "Mise à jour vers la version {0}...", "Updating to version {0}..." },
            { "Mise à jour impossible : {0}", "Update failed: {0}" },
            { "Client version {0} installé dans le jeu (ta partie est gardée).", "Client version {0} installed in the game (your game is kept)." },
            { "RE Requiem est lancé. Ferme le jeu avant de mettre à jour.", "RE Requiem is running. Close the game before updating." },
            { "Client mis à jour en version {0}.", "Client updated to version {0}." },
            { " Le lanceur a aussi été mis à jour : il va redémarrer.", " The launcher was updated too: it will restart." },
            { " Installé dans le jeu (ta partie est gardée).", " Installed in the game (your game is kept)." },
            { " Le client n'est pas encore installé dans le jeu : il le sera en rejoignant un multimonde.", " The client is not installed in the game yet: it will be when you join a multiworld." },
            { " apworld mis à jour dans Archipelago.", " apworld updated in Archipelago." },

            { "Lancer RE Requiem", "Launch RE Requiem" },
            { "Vérifier la room", "Check the room" },
            { "Réinstaller le client", "Reinstall the client" },
            { "Mettre à jour les scripts du jeu", "Update the game scripts" },
            { "Jeu introuvable : indique son dossier dans « État de la configuration ».", "Game not found: set its folder in \"Setup status\"." },
            { "Scripts pas encore installés dans le jeu (lanceur : {0}).", "Scripts not installed in the game yet (launcher: {0})." },
            { "Scripts du jeu à jour : {0}.", "Game scripts up to date: {0}." },
            { "Scripts du jeu : {0}, lanceur : {1}.", "Game scripts: {0}, launcher: {1}." },
            { "ancienne version", "old version" },
            { "Scripts du jeu mis à jour (version {0}) : même room, même progression.", "Game scripts updated (version {0}): same room, same progress." },
            { "Le client est installé et connecté à {0}{1}.{2} Lance RE Requiem depuis Steam : le mod se reconnecte tout seul. « Mettre à jour les scripts du jeu » applique les mises à jour du lanceur à cette même partie.", "The client is installed and connected to {0}{1}.{2} Launch RE Requiem from Steam: the mod reconnects by itself. \"Update the game scripts\" applies the launcher's updates to this same game." },
            { "J'ai fini avec ce multimonde", "I'm done with this multiworld" },
            { "Recopie les scripts et données du lanceur dans le jeu (même room, même progression).", "Copies the launcher's scripts and data into the game again (same room, same progress)." },
            { "Bienvenue, survivant.", "Welcome, survivor." },
            { "RAPPEL IMPORTANT : Il s'agit d'une version de Playtest (Bêta). Le mod est activement en cours de développement. Vous risquez de rencontrer des bugs, des désynchronisations ou des plantages. Merci de nous remonter vos retours pour nous aider à stabiliser l'expérience !", "IMPORTANT REMINDER: This is a Playtest (Beta) version. The mod is under active development. You may run into bugs, desyncs or crashes. Please send us your feedback to help us stabilize the experience!" },
            { "Choisis Rejoindre un multimonde ou Héberger un multimonde dans le menu de gauche pour commencer.", "Choose Join a multiworld or Host a multiworld in the menu on the left to get started." },
            { "Les objets reçus arrivent dans le coffre. Connecte-toi en jeu (Insert) avant de ramasser quoi que ce soit.", "Received items arrive in the item box. Connect in game (Insert) before picking anything up." },
            { "Code modifié par l'IA : environ {0} %", "Code modified by AI: about {0}%" },
            { "Crédits", "Credits" },
            { Views.MainWindow.Credits,
                "RE Requiem Archipelago: LechapelierHD\n" +
                "Logo: Aure0re\n\n" +
                "Archipelago: the ArchipelagoMW team\n" +
                "REFramework: praydog\n" +
                "lua-apclientpp: black-sliver, FelicitusNeko, highrow623, NewSoupVi\n" +
                "RE2R AP client (base of the client): Fuzzy\n" +
                "RE4R AP Wizard (model for the launcher)\n" +
                "Modular Chapter Skip (chapter names): MaVeRicK" },
            { "Chaque objet ramassé dans les {0}chapitres devient un check partagé avec les autres joueurs de ton multimonde. Les objets des autres arrivent dans ton coffre.", "Every item picked up in the {0}chapters becomes a check shared with the other players of your multiworld. Their items arrive in your item box." },
            { "Ton multimonde {0} est prêt !", "Your multiworld {0} is ready!" },
            { " Progression : {0} / {1} checks.", " Progress: {0} / {1} checks." },
            { "Le client est installé et connecté à {0}{1}.{2} Lance RE Requiem depuis Steam : le mod se reconnecte tout seul. « Réinstaller le client » applique les mises à jour du lanceur à cette même partie.", "The client is installed and connected to {0}{1}.{2} Launch RE Requiem from Steam: the mod reconnects by itself. \"Reinstall the client\" applies the launcher's updates to this same game." },
            { " (seed {0})", " (seed {0})" },
            { "Steam a reçu la demande de lancement de RE Requiem.", "Steam received the request to launch RE Requiem." },
            { "Steam n'a pas pu être contacté : {0}", "Steam could not be reached: {0}" },
            { "Vérification de la room...", "Checking the room..." },
            { "La room ne répond pas comme prévu.", "The room is not answering as expected." },
            { "Client réinstallé : même room, même progression.", "Client reinstalled: same room, same progress." },
            { "Oublier cette session ? Le client reste installé, mais il ne se connectera plus à cette room.", "Forget this session? The client stays installed, but it will no longer connect to this room." },

            { "Configurer les réglages Archipelago", "Set up your Archipelago options" },
            { "Archipelago appelle ces réglages un YAML : un petit fichier texte qui décrit comment se joue ton RE Requiem (difficulté, objets clés). Chaque joueur d'un multimonde en a un pour son jeu, et ton hôte a besoin du tien avant de pouvoir générer le multimonde.", "Archipelago calls these options a YAML: a small text file describing how your RE Requiem is played (difficulty, key items). Every player in a multiworld has one for their game, and your host needs yours before generating the multiworld." },
            { "Enregistre ou copie ton fichier de réglages et envoie-le à la personne qui héberge le multimonde (généralement sur Discord). Elle générera le multimonde et te renverra l'adresse de la partie. Déjà envoyé ? Continue directement.", "Save or copy your options file and send it to the person hosting the multiworld (usually on Discord). They will generate the multiworld and send you back the game address. Already sent? Just continue." },
            { "À QUOI JOUES-TU", "WHAT ARE YOU PLAYING" },
            { "Nom de slot", "Slot name" },
            { "Ton nom de joueur (16 caractères max.). Tu taperas ce nom exact pour rejoindre : les majuscules comptent.", "Your player name (16 characters max.). You will type this exact name to join: capital letters matter." },
            { "CONTENU INCLUS", "INCLUDED CONTENT" },
            { "Choisis ce que deviennent les objets clés (clés, cartes, fusibles, quartz, briquet, crochet...).", "Choose what happens to key items (keys, cards, fuses, quartz, lighter, hook...)." },
            { "Campagne principale", "Main campaign" },
            { "L'histoire de Grace, randomisée par Archipelago. Chaque objet ramassé devient un check. Les objets clés restent à leur place : impossible de rester bloqué.", "Grace's story, randomized by Archipelago. Every item picked up becomes a check. Key items stay in place: you can't get stuck." },
            { "Objets clés mélangés", "Shuffled key items" },
            { "Les objets clés entrent aussi dans le pool : ils peuvent venir d'autres mondes et arrivent dans le coffre. Plus de checks, plus d'échanges.", "Key items join the pool too: they can come from other worlds and arrive in the item box. More checks, more trading." },
            { "DLC 2027 coming soon", "DLC 2027 coming soon" },
            { "Le scénariste du jeu, Haris Orkin, a confirmé que l'extension se concentrera sur Oswell E. Spencer (l'un des cofondateurs d'Umbrella), afin d'explorer plus en profondeur son histoire et ses agissements dans le prolongement de l'intrigue du jeu.", "The game's writer, Haris Orkin, confirmed that the expansion will focus on Oswell E. Spencer (one of Umbrella's co-founders), to go further into his story and his actions as a continuation of the game's plot." },
            { "Difficulté", "Difficulty" },
            { "Classique", "Classic" },
            { "La difficulté à laquelle tu joues vraiment. Classique et Insanity ajoutent quelques emplacements (pièces, objets placés seulement dans ces modes), donc elle doit correspondre à ta sauvegarde. Ne change pas de difficulté en cours de partie.", "The difficulty you actually play on. Classic and Insanity add a few locations (coins, items only placed in those modes), so it must match your save. Don't change difficulty mid-game." },
            { "OPTIONS", "OPTIONS" },
            { "Drops ennemis", "Enemy drops" },
            { "Chaque ennemi tué ou pot cassé envoie le check suivant, dans l'ordre. Seulement du filler. 0 les coupe.", "Each killed enemy or broken pot sends the next check, in order. Filler only. 0 turns them off." },
            { "Supply Box", "Supply Box" },
            { "Le marchand se débloque après avoir fini le jeu une fois. Désactivé : ses 11 lignes d'achat ne sont pas des checks. Activé : Archipelago choisit l'objet de chaque ligne.", "The merchant unlocks after finishing the game once. Off: its 11 buy lines are not checks. On: Archipelago chooses the item on each line." },
            { "Death Link", "Death Link" },
            { "Désactivé", "Off" },
            { "Activé", "On" },
            { "Quand tu meurs, les autres joueurs qui ont Death Link meurent aussi, et l'inverse.", "When you die, the other players who have Death Link die too, and the other way round." },
            { "Équilibrage de la progression", "Progression balancing" },
            { "Normal", "Normal" },
            { "Extrême", "Extreme" },
            { "Plus c'est haut, plus Archipelago avance les objets importants pour éviter de rester bloqué au début.", "Higher moves important items earlier, so you are less likely to get stuck at the start." },
            { "Accessibilité", "Accessibility" },
            { "Complète", "Full" },
            { "Minimale", "Minimal" },
            { "Complète : tout est accessible. Minimale : seul ce qui mène à la victoire est garanti.", "Full: everything can be reached. Minimal: only what is needed to win is guaranteed." },
            { "{0} checks dans {1} chapitres", "{0} checks in {1} chapters" },
            { "{0} checks, dont {1} objets clés", "{0} checks, including {1} key items" },
            { "Ton slot contient {0} checks.", "Your slot has {0} checks." },
            { "Indique un nom de slot (1 à 16 caractères, sans espace au début).", "Enter a slot name (1 to 16 characters, no leading space)." },
            { "Envoyer ton YAML à l'hôte", "Send your YAML to the host" },
            { "Ton fichier de réglages est prêt. Envoie-le à la personne qui héberge (Discord, mail...). Si c'est toi qui héberges, il est déjà ajouté à la liste de la page « Héberger un multimonde ».", "Your options file is ready. Send it to the host (Discord, email...). If you are hosting, it is already added to the list on the \"Host a multiworld\" page." },
            { "Fichier enregistré", "Saved file" },
            { "Enregistrer sous...", "Save as..." },
            { "Copier le texte", "Copy the text" },
            { "Afficher dans l'explorateur", "Show in Explorer" },
            { "YAML enregistré : {0}", "YAML saved: {0}" },
            { "YAML copié dans le presse-papiers.", "YAML copied to the clipboard." },
            { "Rejoindre la partie", "Join the game" },
            { "L'hôte t'a renvoyé l'adresse de la room (par exemple archipelago.gg:38281). Le lanceur la teste, installe le client dans RE Requiem et enregistre la connexion : le jeu se connectera tout seul.", "The host sent you the room address (for example archipelago.gg:38281). The launcher tests it, installs the client in RE Requiem and saves the connection: the game will connect by itself." },
            { "Adresse de la room", "Room address" },
            { "Une commande « /connect archipelago.gg:38281 » collée telle quelle fonctionne aussi.", "A \"/connect archipelago.gg:38281\" command pasted as is works too." },
            { "Mot de passe", "Password" },
            { "Laisse vide si la room n'en a pas.", "Leave empty if the room has none." },
            { "Tester la connexion", "Test the connection" },
            { "Ouvrir l'état de la configuration", "Open the setup status" },
            { "Le dossier de RE Requiem n'est pas configuré : le lanceur ne pourra pas installer le client.", "The RE Requiem folder is not set: the launcher won't be able to install the client." },
            { "REFramework n'est pas installé dans RE Requiem : sans lui, le client ne se chargera pas. Installe-le depuis l'état de la configuration.", "REFramework is not installed in RE Requiem: without it the client won't load. Install it from the setup status." },
            { "Test de la room...", "Testing the room..." },
            { "Indique l'adresse de la room et le nom de slot.", "Enter the room address and the slot name." },
            { "Configure d'abord le dossier de RE Requiem dans l'état de la configuration.", "Set the RE Requiem folder in the setup status first." },
            { "{0}\n\nInstaller quand même ? Le jeu réessaiera de se connecter tout seul.", "{0}\n\nInstall anyway? The game will retry connecting by itself." },
            { "La victoire de ce slot est déjà enregistrée sur la room : la partie est terminée, le serveur t'a déjà renvoyé tous tes objets et tes checks ne servent plus à rien.\n\nGénère plutôt une nouvelle partie (Héberger un multimonde). Installer quand même ?", "This slot's victory is already recorded on the room: the game is over, the server already sent all your items and your checks no longer matter.\n\nGenerate a new game instead (Host a multiworld). Install anyway?" },
            { "Le client est installé dans RE Requiem et connecté à {0} pour le slot « {1} ».", "The client is installed in RE Requiem and connected to {0} for the slot \"{1}\"." },
            { " {0} / {1} checks déjà faits.", " {0} / {1} checks already done." },
            { "Installation interrompue : {0}", "Installation interrupted: {0}" },
            { "Tout est prêt !", "All set!" },
            { "En jeu", "In game" },
            { "1. Lance RE Requiem depuis Steam (ou le bouton ci-dessous). Le client se connecte tout seul à la room.", "1. Launch RE Requiem from Steam (or the button below). The client connects to the room by itself." },
            { "2. Attends la notification « Connecté » en haut à droite avant de ramasser quoi que ce soit : le client doit connaître la liste de tes checks.", "2. Wait for the \"Connected\" notification at the top right before picking anything up: the client needs to know your check list." },
            { "3. Sur un emplacement Archipelago, l'objet d'origine est remplacé par le check. Les objets reçus arrivent dans le coffre.", "3. On an Archipelago location, the original item is replaced by the check. Received items arrive in the item box." },
            { "4. Touche Insert : fenêtre « Archipelago - Resident Evil Requiem » (connexion, progression par chapitre, messages, victoire).", "4. Insert key: \"Archipelago - Resident Evil Requiem\" window (connection, progress per chapter, messages, victory)." },
            { "Retour", "Back" },
            { "Continuer", "Continue" },
            { "Installer et rejoindre", "Install and join" },
            { "Retour à l'accueil", "Back to home" },

            { "La génération d'un multimonde se fait sur ta propre installation d'Archipelago. Ce guide t'accompagne étape par étape. Ta progression est sauvegardée : tu peux fermer cette fenêtre et revenir quand tu veux.", "Generating a multiworld happens on your own Archipelago install. This guide walks you through it step by step. Your progress is saved: you can close this window and come back any time." },
            { "✓ Terminé", "✓ Done" },
            { "Installer Archipelago 0.6.8", "Install Archipelago 0.6.8" },
            { "Installer l'apworld RE Requiem", "Install the RE Requiem apworld" },
            { "Rassembler les YAML", "Gather the YAMLs" },
            { "Générer le multimonde", "Generate the multiworld" },
            { "Ouvrir la room", "Open the room" },
            { "C'est parti !", "Let's go!" },
            { "Étape {0} sur {1}", "Step {0} of {1}" },
            { "Quitter le guide", "Leave the guide" },
            { "Suivant", "Next" },
            { "Recommencer", "Start over" },
            { "RE Requiem nécessite Archipelago 0.6.8 (0.6.2 minimum). S'il est déjà installé, le lanceur le trouve ci-dessous ; sinon installe-le d'abord (installateur Windows classique), puis reviens ici.", "RE Requiem needs Archipelago 0.6.8 (0.6.2 minimum). If it is already installed, the launcher finds it below; otherwise install it first (regular Windows installer), then come back here." },
            { "Parcourir...", "Browse..." },
            { "Obtenir Archipelago 0.6.8 (page de version)", "Get Archipelago 0.6.8 (release page)" },
            { "Archipelago {0} trouvé dans {1}.", "Archipelago {0} found in {1}." },
            { "ArchipelagoGenerate.exe introuvable dans ce dossier.", "ArchipelagoGenerate.exe not found in this folder." },
            { "L'apworld apprend RE Requiem à Archipelago (objets, emplacements, règles). Le lanceur fournit la version qui correspond à son client : installe-la dans custom_worlds. À refaire après chaque mise à jour du lanceur.", "The apworld teaches RE Requiem to Archipelago (items, locations, rules). The launcher ships the version matching its client: install it in custom_worlds. Redo it after every launcher update." },
            { "Ouvrir custom_worlds", "Open custom_worlds" },
            { "Configure d'abord Archipelago (étape 1).", "Set up Archipelago first (step 1)." },
            { "apworld RE Requiem installé et à jour : {0}", "RE Requiem apworld installed and up to date: {0}" },
            { "Une autre version de l'apworld RE Requiem est installée : mets-la à jour pour qu'elle corresponde au client.", "Another version of the RE Requiem apworld is installed: update it so it matches the client." },
            { "apworld RE Requiem pas encore installé.", "RE Requiem apworld not installed yet." },
            { "Ajoute le YAML de chaque joueur (le tien est déjà là si tu l'as créé dans « Rejoindre »). Les autres jeux du multimonde ont besoin de leur propre apworld dans custom_worlds.", "Add every player's YAML (yours is already there if you made it in \"Join\"). The other games in the multiworld need their own apworld in custom_worlds." },
            { "Ajouter des YAML...", "Add YAMLs..." },
            { "Retirer la sélection", "Remove selected" },
            { "Mes YAML", "My YAMLs" },
            { "{0} YAML, dont {1} pour RE Requiem.", "{0} YAML, {1} for RE Requiem." },
            { "Archipelago mélange les objets de tous les joueurs et produit un fichier AP_xxxx.zip : c'est ta partie. La génération prend de quelques secondes à quelques minutes ; le détail s'affiche dans le journal en bas.", "Archipelago shuffles every player's items and produces an AP_xxxx.zip file: that's your game. Generation takes from a few seconds to a few minutes; details show in the log at the bottom." },
            { "Dernière partie générée : {0}", "Last generated game: {0}" },
            { "Aucune partie générée pour l'instant.", "No game generated yet." },
            { "Ajoute au moins un YAML (étape 3).", "Add at least one YAML (step 3)." },
            { "L'apworld RE Requiem n'est pas à jour : installe-le d'abord (étape 2).", "The RE Requiem apworld is not up to date: install it first (step 2)." },
            { "Génération en cours...", "Generating..." },
            { "Multimonde généré.", "Multiworld generated." },
            { "apworld RE Requiem installé.", "RE Requiem apworld installed." },
            { "Impossible d'installer l'apworld : {0}", "Could not install the apworld: {0}" },
            { "Deux façons d'ouvrir la room :", "Two ways to open the room:" },
            { "Sur archipelago.gg (recommandé)", "On archipelago.gg (recommended)" },
            { "Envoie le .zip sur la page d'upload, puis « Create New Room ». Partage l'adresse affichée (archipelago.gg:xxxxx) aux joueurs. Rien à laisser ouvert sur ton PC.", "Upload the .zip on the upload page, then \"Create New Room\". Share the address shown (archipelago.gg:xxxxx) with the players. Nothing to leave open on your PC." },
            { "Ouvrir la page d'upload", "Open the upload page" },
            { "Afficher le .zip", "Show the .zip" },
            { "Sur ton PC", "On your PC" },
            { "Lance ArchipelagoServer avec la partie. Adresse : localhost:38281 pour toi, ton IP locale ou publique (port 38281 ouvert) pour les autres. La fenêtre du serveur doit rester ouverte pendant toute la partie.", "Run ArchipelagoServer with the game. Address: localhost:38281 for you, your local or public IP (port 38281 open) for the others. The server window must stay open for the whole game." },
            { "Démarrer le serveur local", "Start the local server" },
            { "Serveur local démarré : localhost:38281.", "Local server started: localhost:38281." },
            { "Impossible de démarrer le serveur : {0}", "Could not start the server: {0}" },
            { "La room est ouverte. Envoie son adresse à tous les joueurs. Pour jouer toi-même, va dans « Rejoindre un multimonde » : tes réglages sont déjà remplis, il ne reste que l'adresse.", "The room is open. Send its address to all players. To play yourself, go to \"Join a multiworld\": your options are already filled in, only the address is left." },
            { "Rejoindre ma partie", "Join my game" },

            { "Tout ce dont RE Requiem a besoin pour jouer en Archipelago. Le lanceur ne modifie pas les fichiers .pak du jeu : il ajoute REFramework et les scripts du client.", "Everything RE Requiem needs to play Archipelago. The launcher does not modify the game's .pak files: it adds REFramework and the client scripts." },
            { "Dossier du jeu", "Game folder" },
            { "Détecter (Steam)", "Detect (Steam)" },
            { "Jeu", "Game" },
            { "Ouvrir le dossier", "Open the folder" },
            { "Installer REFramework", "Install REFramework" },
            { "Client Archipelago RE Requiem", "RE Requiem Archipelago client" },
            { "Installer", "Install" },
            { "Retirer", "Remove" },
            { "Connexion enregistrée", "Saved connection" },
            { "Ouvrir les données", "Open the data" },
            { "Anciens scripts (RE9-AP-Client)", "Old scripts (RE9-AP-Client)" },
            { "Désactiver les anciens scripts AP__client.lua et pickup.lua à l'installation (sinon les objets seraient bloqués et injectés en double)", "Disable the old AP__client.lua and pickup.lua scripts when installing (otherwise items would be blocked and injected twice)" },
            { "ARCHIPELAGO (HÔTE SEULEMENT)", "ARCHIPELAGO (HOST ONLY)" },
            { "apworld RE Requiem", "RE Requiem apworld" },
            { "Actualiser", "Refresh" },
            { "{0} trouvé.", "{0} found." },
            { "Indique le dossier qui contient {0}.", "Select the folder that contains {0}." },
            { "En attente du dossier du jeu.", "Waiting for the game folder." },
            { "dinput8.dll présent. Le menu REFramework s'ouvre avec Insert.", "dinput8.dll present. The REFramework menu opens with Insert." },
            { "Absent : le client ne se chargera pas. Le lanceur installe le REFramework inclus (Nightly 01313).", "Missing: the client won't load. The launcher installs the included REFramework (Nightly 01313)." },
            { "dinput8.dll est absent du lanceur. Mets le lanceur à jour.", "dinput8.dll is missing from the launcher. Update the launcher." },
            { "Paquet incomplet : {0}", "Incomplete package: {0}" },
            { "Pas encore installé.", "Not installed yet." },
            { "Installé et à jour ({0} emplacements).", "Installed and up to date ({0} locations)." },
            { "Installé, mais différent de la version du lanceur : mets-le à jour.", "Installed, but different from the launcher's version: update it." },
            { "Aucune room enregistrée : passe par « Rejoindre un multimonde ».", "No room saved: go through \"Join a multiworld\"." },
            { "Aucun ancien script actif.", "No old script active." },
            { "Actifs : {0}. Ils seront désactivés à la prochaine installation.", "Active: {0}. They will be disabled on the next install." },
            { "Archipelago {0} dans {1}", "Archipelago {0} in {1}" },
            { "Non trouvé. Nécessaire seulement pour générer une partie (page « Héberger »).", "Not found. Only needed to generate a game (\"Host\" page)." },
            { "En attente d'Archipelago.", "Waiting for Archipelago." },
            { "Installé et à jour.", "Installed and up to date." },
            { "Absent ou différent : clique sur le bouton pour l'installer dans custom_worlds.", "Missing or different: click the button to install it in custom_worlds." },
            { "RE Requiem (Steam {0}) introuvable. Indique le dossier à la main.", "RE Requiem (Steam {0}) not found. Select the folder by hand." },
            { "Jeu trouvé : {0}", "Game found: {0}" },
            { "Installation de REFramework...", "Installing REFramework..." },
            { "REFramework installé.", "REFramework installed." },
            { "REFramework : {0}", "REFramework: {0}" },
            { "Client installé.", "Client installed." },
            { "Retirer le client Archipelago de RE Requiem ? REFramework et les données de partie restent en place.", "Remove the Archipelago client from RE Requiem? REFramework and game data stay in place." },
            { "Client retiré.", "Client removed." },
            { "Saut de chapitre (optionnel)", "Chapter skip (optional)" },
            { "Installe d'abord le client Archipelago RE Requiem.", "Install the RE Requiem Archipelago client first." },
            { "Absent du paquet : mets le lanceur à jour.", "Not in the package: update the launcher." },
            { "Avec Grace, F sur le point d'enquête du début saute au chapitre choisi et termine les chapitres sautés (checks envoyés ou objets au coffre).", "As Grace, F on the first investigation point jumps to the chosen chapter and completes the skipped chapters (checks sent or items to the box)." },
            { "Installé et à jour. Réglages dans l'onglet « Saut de chapitre » du client en jeu.", "Installed and up to date. Settings in the client's \"Chapter skip\" tab in game." },
            { "Installé (version manuelle, absente du paquet).", "Installed (manual version, not in the package)." },
            { "Saut de chapitre installé. En jeu : Reset Scripts dans REFramework.", "Chapter skip installed. In game: Reset Scripts in REFramework." },
            { "Saut de chapitre installé.", "Chapter skip installed." },
            { "Saut de chapitre retiré. En jeu : Reset Scripts dans REFramework.", "Chapter skip removed. In game: Reset Scripts in REFramework." },
            { "Saut de chapitre retiré.", "Chapter skip removed." },
            { "Saut de chapitre : {0}", "Chapter skip: {0}" },

            { "Indique l'adresse de la room (par exemple archipelago.gg:38281).", "Enter the room address (for example archipelago.gg:38281)." },
            { "Impossible de joindre la room : {0}. Vérifie l'adresse et le port (une room archipelago.gg change de port quand elle se rendort).", "Could not reach the room: {0}. Check the address and port (an archipelago.gg room changes port when it goes back to sleep)." },
            { "adresse invalide", "invalid address" },
            { "Ce slot joue à « {0} », pas à {1}. Vérifie le nom du slot.", "This slot plays \"{0}\", not {1}. Check the slot name." },
            { "Room trouvée : slot RE Requiem valide, {0} / {1} checks faits.", "Room found: valid RE Requiem slot, {0} / {1} checks done." },
            { " ATTENTION : la victoire de ce slot est déjà enregistrée, la partie est terminée. Génère une nouvelle partie pour rejouer.", " WARNING: this slot's victory is already recorded, the game is over. Generate a new game to play again." },
            { "aucun slot à ce nom dans la room (les majuscules comptent)", "no slot with that name in the room (capital letters matter)" },
            { "ce slot n'est pas un slot {0}", "this slot is not a {0} slot" },
            { "mot de passe incorrect", "wrong password" },
            { "version d'Archipelago incompatible", "incompatible Archipelago version" },
            { "La room a refusé la connexion : {0}.", "The room refused the connection: {0}." },
            { "raison inconnue", "unknown reason" },

            { "Dossier du jeu invalide : re9.exe introuvable.", "Invalid game folder: re9.exe not found." },
            { "Pont Python introuvable (assets/bridge/ap_bridge.py).", "Python bridge missing (assets/bridge/ap_bridge.py)." },
            { "Python 3 introuvable. Installe Python puis : py -3 -m pip install websockets",
                "Python 3 not found. Install Python then: py -3 -m pip install websockets" },
            { "Impossible de démarrer ap_bridge.py", "Could not start ap_bridge.py" },
            { "Pont Python Archipelago démarré (WebSocket compressé).", "Archipelago Python bridge started (compressed WebSocket)." },
            { "Pont Python non démarré : {0}", "Python bridge not started: {0}" },
            { "Connexion AP : lua-apclientpp.dll (comme RE2R).", "AP connection: lua-apclientpp.dll (like RE2R)." },
            { "RE Requiem est lancé. Ferme le jeu avant d'installer le client.", "RE Requiem is running. Close the game before installing the client." },
            { "Ferme RE Requiem avant de retirer le client.", "Close RE Requiem before removing the client." },
            { "Dossier du jeu invalide.", "Invalid game folder." },
            { "Ferme RE Requiem avant d'installer REFramework.", "Close RE Requiem before installing REFramework." },
            { "La génération s'est terminée sans produire de fichier AP_*.zip.", "Generation finished without producing an AP_*.zip file." },
            { "La génération a échoué (code {0}). Le détail est dans le journal en bas.", "Generation failed (code {0}). Details are in the log at the bottom." },
            { "Fichier du client manquant dans assets : {0}", "Client file missing in assets: {0}" },
            { "La nightly {0} ne contient pas RE9.zip. Installe REFramework à la main depuis {1}.", "Nightly {0} does not contain RE9.zip. Install REFramework by hand from {1}." },
            { "L'archive ne contenait pas dinput8.dll.", "The archive did not contain dinput8.dll." },
            { "apworld absent du paquet : {0}", "apworld missing from the package: {0}" },
            { "la room a fermé la connexion", "the room closed the connection" },
            { "Dossier d'Archipelago (contient ArchipelagoGenerate.exe)", "Archipelago folder (contains ArchipelagoGenerate.exe)" },
            { "Dossier qui contient re9.exe", "Folder that contains re9.exe" },
            { "dépôt des mises à jour inaccessible [{0}]", "update repository unreachable [{0}]" },
            { "GitHub limite les vérifications pour l'instant, réessaie plus tard [{0}]", "GitHub is limiting checks for now, try again later [{0}]" },
            { "GitHub a répondu {0}", "GitHub answered {0}" },
            { "aucune release avec {0} dans {1}", "no release with {0} in {1}" },
            { "Aucune source de mises à jour (dossier « {0} » introuvable).", "No update source (folder \"{0}\" not found)." },
            { "Fichier de mises à jour introuvable : {0}", "Update file not found: {0}" },
            { "Vérification des mises à jour impossible : {0}", "Could not check for updates: {0}" },
            { "Patch absent du dépôt des mises à jour : {0}", "Patch missing from the update repository: {0}" },
            { "Patch introuvable : {0}", "Patch not found: {0}" },
            { "Ce zip n'est pas un patch du client RE Requiem (patch.json ou scripts absents).", "This zip is not an RE Requiem client patch (patch.json or scripts missing)." },
            { "Patch sans empreinte SHA256 dans la liste : vérification zip ignorée (ancien patch).", "Patch has no SHA256 in the feed: zip verification skipped (legacy patch)." },
            { "Empreinte SHA256 du patch invalide (attendu 64 caractères hex).", "Invalid patch SHA256 (expected 64 hex characters)." },
            { "Patch altéré ou corrompu : SHA256 du zip ne correspond pas (reçu {0}…, attendu {1}…). Rien n'a été installé.", "Patch tampered or corrupt: zip SHA256 mismatch (got {0}…, expected {1}…). Nothing was installed." },
            { "patch.json sans liste « files » : vérification fichier par fichier ignorée (ancien patch).", "patch.json has no \"files\" list: per-file verification skipped (legacy patch)." },
            { "Fichiers du patch altérés ({0}) : {1}. Rien n'a été installé.", "Patch files tampered ({0}): {1}. Nothing was installed." },
            { "Copie altérée vers assets : {0} (SHA256 incorrect). Installation annulée.", "Tampered copy into assets: {0} (bad SHA256). Install cancelled." },
            { "Copie altérée dans le jeu : {0} (SHA256 incorrect). Réessaie l'installation.", "Tampered copy into the game: {0} (bad SHA256). Try installing again." },

            { "Les nouveautés ajoutées par la dernière mise à jour du client.", "What the latest client update added." },
            { "DERNIÈRE MISE À JOUR", "LATEST UPDATE" },            { "Version installée dans le lanceur : {0}", "Version installed in the launcher: {0}" },
            { "Client dans le jeu : non installé", "Client in the game: not installed" },
            { "Client dans le jeu : {0}", "Client in the game: {0}" },
            { "Chargement de la liste des patchs...", "Loading the patch list..." },
            { "Source : {0}", "Source: {0}" },
            { "Installer un patch téléchargé à la main", "Install a manually downloaded patch" },
            { "Dépose le zip du patch (re9ap_patch_X.zip) dans le dossier « Patchs » à côté du lanceur : il est proposé tout de suite, puis rangé dans « installés ».", "Drop the patch zip (re9ap_patch_X.zip) into the \"Patchs\" folder next to the launcher: it is offered right away, then moved to \"installés\"." },
            { "Ouvrir le dossier des patchs", "Open the patches folder" },
            { "Vider les vieux patchs", "Clear old patches" },
            { "Vider les vieux patchs ({0})", "Clear old patches ({0})" },
            { "{0}  ·  {1} vieux patch(s) (installés + cache AppData)", "{0}  ·  {1} old patch(es) (installed + AppData cache)" },
            { "Aucun vieux patch à supprimer.", "No old patches to delete." },
            { "Supprimer {0} zip déjà appliqué(s) ?\n\n• Patchs\\installés (à côté du lanceur)\n• Cache AppData (RE9-AP-Wizard\\patches)\n\nLe client et le mod en jeu restent inchangés.", "Delete {0} already-applied zip(s)?\n\n• Patchs\\installés (next to the launcher)\n• AppData cache (RE9-AP-Wizard\\patches)\n\nThe client and in-game mod stay unchanged." },
            { "{0} vieux patch(s) supprimé(s).", "{0} old patch(es) deleted." },
            { "Aucun fichier n'a pu être supprimé.", "No file could be deleted." },
            { "Patch trouvé dans le dossier des patchs : version {0}", "Patch found in the patches folder: version {0}" },
            { "Liste des patchs indisponible : {0}", "Patch list unavailable: {0}" },
            { "Aucun patch publié pour l'instant.", "No patch published yet." },
            { "Installée", "Installed" },
            { "Nouveau", "New" },
            { "Déjà incluse", "Included" },
            { "Pas de détail pour ce patch.", "No details for this patch." },
        };
    }
}
