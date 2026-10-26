using System;
using System.Windows;
using System.Windows.Threading;
using RE9.AP.Launcher.Core;

namespace RE9.AP.Launcher
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            DispatcherUnhandledException += OnUnhandled;
            PatchUpdater.CleanupOldLauncher();
            PatchUpdater.RetireOldDropFolder();
            Log.Info(AppInfo.DisplayName + " " + AppInfo.Version + " démarré.");
            base.OnStartup(e);
        }

        private static void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            Log.Error("Erreur inattendue : " + e.Exception);
            MessageBox.Show(e.Exception.Message, AppInfo.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
        }
    }
}
