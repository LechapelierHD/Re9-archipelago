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
    public sealed class RoomProbeResult
    {
        public bool Ok;
        public string Message = "";
        public string Url = "";
        public string Seed = "";
        public string SlotGame = "";
        public int Checked;
        public int Total;
        public string Difficulty = "";
        public string KeyItems = "";
        public List<long> Locations = new List<long>();
        public bool GoalDone;
    }

    // Connexion en « Tracker » pour ne pas occuper le slot.
    public static class RoomProbe
    {
        public static string Normalize(string address)
        {
            string a = (address ?? "").Trim();
            if (a.StartsWith("/connect ", StringComparison.OrdinalIgnoreCase)) a = a.Substring(9).Trim();
            if (a.Length == 0) return a;
            if (!a.Contains("://")) return a;
            return a.TrimEnd('/');
        }

        private static IEnumerable<Uri> Candidates(string address)
        {
            string a = Normalize(address);
            if (a.Contains("://"))
            {
                yield return new Uri(a);
                yield break;
            }
            if (!a.Contains(":")) a += ":38281";
            // ws d'abord (CommonClient) — wss sur localhost → 400 côté MultiServer
            yield return new Uri("ws://" + a);
            yield return new Uri("wss://" + a);
        }

        public static async Task<RoomProbeResult> ProbeAsync(string address, string slot, string password)
        {
            RoomProbeResult result = new RoomProbeResult();
            if (string.IsNullOrWhiteSpace(address))
            {
                result.Message = Lang.T("Indique l'adresse de la room (par exemple archipelago.gg:38281).");
                return result;
            }
            Exception last = null;
            foreach (Uri uri in Candidates(address))
            {
                try
                {
                    return await ProbeUriAsync(uri, slot, password);
                }
                catch (Exception ex)
                {
                    last = ex;
                    Log.Info("Échec sur " + uri + " : " + ex.Message);
                }
            }
            result.Message = Lang.TF("Impossible de joindre la room : {0}. Vérifie l'adresse et le port (une room archipelago.gg change de port quand elle se rendort).",
                last == null ? Lang.T("adresse invalide") : last.Message);
            return result;
        }

        private static async Task<RoomProbeResult> ProbeUriAsync(Uri uri, string slot, string password)
        {
            RoomProbeResult result = new RoomProbeResult { Url = uri.ToString() };
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(12)))
            using (ClientWebSocket ws = new ClientWebSocket())
            {
                await ws.ConnectAsync(uri, cts.Token);
                Log.Info("Room jointe : " + uri);
                bool connectSent = false;
                while (true)
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
                                if (packet.TryGetProperty("seed_name", out seed)) result.Seed = seed.GetString() ?? "";
                                await SendAsync(ws, BuildConnect(slot, password), cts.Token);
                                connectSent = true;
                            }
                            else if (cmd == "ConnectionRefused")
                            {
                                result.Message = Refusal(packet);
                                await CloseAsync(ws);
                                return result;
                            }
                            else if (cmd == "Connected")
                            {
                                Fill(result, packet);
                                if (result.Ok) await ReadGoalAsync(ws, result, packet);
                                await CloseAsync(ws);
                                return result;
                            }
                        }
                    }
                }
            }
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

        private static void Fill(RoomProbeResult result, JsonElement packet)
        {
            int slotId = packet.GetProperty("slot").GetInt32();
            JsonElement info;
            if (packet.TryGetProperty("slot_info", out info))
            {
                JsonElement me;
                if (info.TryGetProperty(slotId.ToString(), out me))
                {
                    JsonElement game;
                    if (me.TryGetProperty("game", out game)) result.SlotGame = game.GetString() ?? "";
                }
            }
            int done = 0;
            foreach (string list in new[] { "checked_locations", "missing_locations" })
            {
                foreach (JsonElement id in packet.GetProperty(list).EnumerateArray())
                {
                    result.Locations.Add(id.GetInt64());
                    if (list == "checked_locations") done++;
                }
            }
            result.Locations.Sort();
            result.Checked = done;
            result.Total = result.Locations.Count;
            JsonElement sd;
            if (packet.TryGetProperty("slot_data", out sd) && sd.ValueKind == JsonValueKind.Object)
            {
                result.Difficulty = Scalar(sd, "difficulty");
                result.KeyItems = Scalar(sd, "key_items");
            }
            if (result.SlotGame.Length > 0 && !string.Equals(result.SlotGame, AppInfo.GameName, StringComparison.OrdinalIgnoreCase))
            {
                result.Message = Lang.TF("Ce slot joue à « {0} », pas à {1}. Vérifie le nom du slot.", result.SlotGame, AppInfo.GameName);
                return;
            }
            result.Ok = true;
            result.Message = Lang.TF("Room trouvée : slot RE Requiem valide, {0} / {1} checks faits.", done, result.Total);
        }

        private static string Scalar(JsonElement obj, string name)
        {
            JsonElement v;
            if (!obj.TryGetProperty(name, out v)) return "";
            return v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : v.ToString();
        }

        // 30 = victoire, lu via la clé serveur _read_client_status_<équipe>_<slot>
        private static async Task ReadGoalAsync(ClientWebSocket ws, RoomProbeResult result, JsonElement connected)
        {
            try
            {
                string key = "_read_client_status_" + connected.GetProperty("team").GetInt32() + "_" + connected.GetProperty("slot").GetInt32();
                object[] get = { new Dictionary<string, object> { { "cmd", "Get" }, { "keys", new[] { key } } } };
                using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(4)))
                {
                    await SendAsync(ws, JsonSerializer.Serialize(get), cts.Token);
                    while (true)
                    {
                        string text = await ReceiveAsync(ws, cts.Token);
                        using (JsonDocument doc = JsonDocument.Parse(text))
                        {
                            foreach (JsonElement packet in doc.RootElement.EnumerateArray())
                            {
                                if (packet.GetProperty("cmd").GetString() != "Retrieved") continue;
                                JsonElement keys, status;
                                if (packet.TryGetProperty("keys", out keys) && keys.TryGetProperty(key, out status)
                                    && status.ValueKind == JsonValueKind.Number)
                                {
                                    result.GoalDone = status.GetInt32() == 30;
                                }
                                if (result.GoalDone)
                                {
                                    result.Message += Lang.T(" ATTENTION : la victoire de ce slot est déjà enregistrée, la partie est terminée. Génère une nouvelle partie pour rejouer.");
                                }
                                return;
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Info("Statut du slot non lu : " + ex.Message);
            }
        }

        private static string Refusal(JsonElement packet)
        {
            List<string> reasons = new List<string>();
            JsonElement errors;
            if (packet.TryGetProperty("errors", out errors))
            {
                foreach (JsonElement e in errors.EnumerateArray())
                {
                    switch (e.GetString())
                    {
                        case "InvalidSlot": reasons.Add(Lang.T("aucun slot à ce nom dans la room (les majuscules comptent)")); break;
                        case "InvalidGame": reasons.Add(Lang.TF("ce slot n'est pas un slot {0}", AppInfo.GameName)); break;
                        case "InvalidPassword": reasons.Add(Lang.T("mot de passe incorrect")); break;
                        case "IncompatibleVersion": reasons.Add(Lang.T("version d'Archipelago incompatible")); break;
                        default: reasons.Add(e.GetString()); break;
                    }
                }
            }
            return Lang.TF("La room a refusé la connexion : {0}.", reasons.Count == 0 ? Lang.T("raison inconnue") : string.Join(", ", reasons));
        }

        private static async Task<string> ReceiveAsync(ClientWebSocket ws, CancellationToken token)
        {
            byte[] buffer = new byte[64 * 1024];
            using (MemoryStream ms = new MemoryStream())
            {
                while (true)
                {
                    WebSocketReceiveResult r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                    if (r.MessageType == WebSocketMessageType.Close) throw new IOException(Lang.T("la room a fermé la connexion"));
                    ms.Write(buffer, 0, r.Count);
                    if (r.EndOfMessage) break;
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        private static Task SendAsync(ClientWebSocket ws, string text, CancellationToken token)
        {
            return ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)), WebSocketMessageType.Text, true, token);
        }

        private static async Task CloseAsync(ClientWebSocket ws)
        {
            try
            {
                using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(2)))
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", cts.Token);
                }
            }
            catch (Exception)
            {
            }
        }
    }
}
