using System;
using System.IO;
using System.Text;

namespace RE9.AP.Launcher.Core
{
    public static class Log
    {
        private static readonly object Gate = new object();
        private static readonly StringBuilder Session = new StringBuilder();

        public static event Action<string> Line;

        public static string FilePath
        {
            get { return Path.Combine(AppInfo.LogDir, "launcher.log"); }
        }

        public static string Text
        {
            get { lock (Gate) return Session.ToString(); }
        }

        public static void Info(string message) { Write("INFO", message); }
        public static void Warn(string message) { Write("ATTENTION", message); }
        public static void Error(string message) { Write("ERREUR", message); }

        private static void Write(string level, string message)
        {
            string line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + (level == "INFO" ? "" : level + " : ") + message;
            lock (Gate)
            {
                Session.AppendLine(line);
                try
                {
                    File.AppendAllText(FilePath, DateTime.Now.ToString("yyyy-MM-dd ") + line + Environment.NewLine, new UTF8Encoding(false));
                }
                catch (IOException)
                {
                }
            }
            Action<string> handler = Line;
            if (handler != null) handler(line);
        }
    }
}
