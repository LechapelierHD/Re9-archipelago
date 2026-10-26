using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace RE9.AP.Launcher.Core
{
    public static class Hashing
    {
        public static string Sha256File(string path)
        {
            using (FileStream stream = File.OpenRead(path))
            using (SHA256 sha = SHA256.Create())
            {
                return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
            }
        }

        public static string Sha256Bytes(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return Convert.ToHexString(sha.ComputeHash(data)).ToLowerInvariant();
            }
        }

        public static bool EqualsHex(string a, string b)
        {
            if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
            return string.Equals(a.Trim(), b.Trim(), StringComparison.OrdinalIgnoreCase);
        }

        // chemins du manifeste : toujours des /
        public static string ManifestPath(string relative)
        {
            return (relative ?? "").Replace('\\', '/').TrimStart('/');
        }
    }
}
