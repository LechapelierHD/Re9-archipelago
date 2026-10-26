using System;
using System.Collections.Generic;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace RE9.AP.Launcher.Core
{
    /// <summary>
    /// Comme le ManifestBuilder RE4R : LocationScouts → foreign vs own.
    /// Foreign = ItemID placeholder dans les scn (ApScenePatcher).
    /// </summary>
    public sealed class ApScoutResult
    {
        public bool Ok;
        public string Message = "";
        public int Slot;
        public string Seed = "";
        public List<long> ForeignLocationIds = new List<long>();
        public int OwnCount;
        public int ForeignCount;
    }

    public static class ApPlacementScout
    {
        public static async Task<ApScoutResult> ScoutForeignAsync(string address, string slot, string password)
        {
            var result = new ApScoutResult();
            Exception last = null;
            foreach (Uri uri in RoomProbeCandidates(address))
            {
                try
                {
                    return await ScoutUriAsync(uri, slot, password);
                }
                catch (Exception ex)
                {
                    last = ex;
                    Log.Info("AP scout échec " + uri + " : " + ex.Message);
                }
            }
            result.Message = Lang.TF("Scout AP impossible : {0}", last == null ? Lang.T("adresse invalide") : last.Message);
            return result;
        }

        private static IEnumerable<Uri> RoomProbeCandidates(string address)
        {
            string a = RoomProbe.Normalize(address);
            if (a.Contains("://"))
            {
                yield return new Uri(a);
                yield break;
            }
            if (!a.Contains(":")) a += ":38281";
            yield return new Uri("wss://" + a);
            yield return new Uri("ws://" + a);
        }

        private static async Task<ApScoutResult> ScoutUriAsync(Uri uri, string slot, string password)
        {
            var result = new ApScoutResult();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(45)))
            using (var ws = new ClientWebSocket())
            {
                await ws.ConnectAsync(uri, cts.Token);
                bool connectSent = false;
                int mySlot = 0;
                var locIds = new List<long>();
                bool scoutsSent = false;
                var foreign = new HashSet<long>();
                var seen = new HashSet<long>();
                int own = 0;
                int expected = 0;

                while (!cts.IsCancellationRequested)
                {
                    string text = await ReceiveAsync(ws, cts.Token);
                    using (JsonDocument doc = JsonDocument.Parse(text))
                    {
                        foreach (JsonElement packet in doc.RootElement.EnumerateArray())
                        {
                            string cmd = packet.GetProperty("cmd").GetString();
                            if (cmd == "RoomInfo" && !connectSent)
                            {
                                JsonElement seed;
                                if (packet.TryGetProperty("seed_name", out seed))
                                    result.Seed = seed.GetString() ?? "";
                                await SendAsync(ws, BuildConnect(slot, password), cts.Token);
                                connectSent = true;
                            }
                            else if (cmd == "ConnectionRefused")
                            {
                                result.Message = "Connexion refusée (scout).";
                                await CloseAsync(ws);
                                return result;
                            }
                            else if (cmd == "Connected")
                            {
                                mySlot = packet.GetProperty("slot").GetInt32();
                                result.Slot = mySlot;
                                foreach (string list in new[] { "checked_locations", "missing_locations" })
                                {
                                    foreach (JsonElement id in packet.GetProperty(list).EnumerateArray())
                                        locIds.Add(id.GetInt64());
                                }
                                expected = locIds.Count;
                                if (expected == 0)
                                {
                                    result.Ok = true;
                                    result.Message = "Aucun emplacement à scouter.";
                                    await CloseAsync(ws);
                                    return result;
                                }
                                object[] scout =
                                {
                                    new Dictionary<string, object>
                                    {
                                        { "cmd", "LocationScouts" },
                                        { "locations", locIds.ToArray() },
                                        { "create_as_hint", 0 },
                                    },
                                };
                                await SendAsync(ws, JsonSerializer.Serialize(scout), cts.Token);
                                scoutsSent = true;
                            }
                            else if (cmd == "LocationInfo" && scoutsSent)
                            {
                                foreach (JsonElement loc in packet.GetProperty("locations").EnumerateArray())
                                {
                                    long locId = loc.GetProperty("location").GetInt64();
                                    if (!seen.Add(locId)) continue;
                                    int player = loc.GetProperty("player").GetInt32();
                                    if (player == mySlot) own++;
                                    else foreign.Add(locId);
                                }
                                if (seen.Count >= expected)
                                {
                                    result.ForeignLocationIds = new List<long>(foreign);
                                    result.ForeignLocationIds.Sort();
                                    result.OwnCount = own;
                                    result.ForeignCount = foreign.Count;
                                    result.Ok = true;
                                    result.Message = Lang.TF(
                                        "Scout OK : {0} pour toi, {1} placeholder (autres joueurs).",
                                        own, foreign.Count);
                                    await CloseAsync(ws);
                                    return result;
                                }
                            }
                        }
                    }
                }
            }
            result.Message = "Timeout scout AP.";
            return result;
        }

        private static string BuildConnect(string slot, string password)
        {
            object[] packet =
            {
                new Dictionary<string, object>
                {
                    { "cmd", "Connect" },
                    { "password", password ?? "" },
                    { "game", AppInfo.GameName },
                    { "name", slot ?? "" },
                    { "uuid", Guid.NewGuid().ToString("N") },
                    { "version", new Dictionary<string, object> { { "major", 0 }, { "minor", 6 }, { "build", 2 }, { "class", "Version" } } },
                    { "items_handling", 0 },
                    { "tags", new[] { "Tracker" } },
                    { "slot_data", true },
                },
            };
            return JsonSerializer.Serialize(packet);
        }

        private static async Task<string> ReceiveAsync(ClientWebSocket ws, CancellationToken token)
        {
            byte[] buffer = new byte[256 * 1024];
            using (var ms = new MemoryStream())
            {
                while (true)
                {
                    WebSocketReceiveResult r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                    if (r.MessageType == WebSocketMessageType.Close)
                        throw new IOException("room fermée");
                    ms.Write(buffer, 0, r.Count);
                    if (r.EndOfMessage) break;
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        private static Task SendAsync(ClientWebSocket ws, string text, CancellationToken token)
        {
            return ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)),
                WebSocketMessageType.Text, true, token);
        }

        private static async Task CloseAsync(ClientWebSocket ws)
        {
            try
            {
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2)))
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", cts.Token);
            }
            catch (Exception) { }
        }
    }
}
