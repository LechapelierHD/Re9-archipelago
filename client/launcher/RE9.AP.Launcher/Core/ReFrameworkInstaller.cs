using System;
using System.IO;
using System.Threading.Tasks;

namespace RE9.AP.Launcher.Core
{
    public static class ReFrameworkInstaller
    {
        public const string ReleasesUrl = "https://github.com/praydog/REFramework-nightly/releases";
        public const string BundledName = "Nightly 01313";

        public static string BundledDll
        {
            get { return Path.Combine(AppInfo.AssetsDir, "reframework", "dinput8.dll"); }
        }

        public static Task InstallAsync(string game)
        {
            if (!GameLocator.IsGameFolder(game)) throw new InvalidOperationException(Lang.T("Dossier du jeu invalide."));
            if (GameLocator.IsGameRunning()) throw new InvalidOperationException(Lang.T("Ferme RE Requiem avant d'installer REFramework."));
            if (!File.Exists(BundledDll)) throw new InvalidOperationException(Lang.T("dinput8.dll est absent du lanceur. Mets le lanceur à jour."));
            File.Copy(BundledDll, Path.Combine(game, "dinput8.dll"), true);
            Log.Info("REFramework " + BundledName + " installé (dinput8.dll).");
            return Task.CompletedTask;
        }
    }
}
