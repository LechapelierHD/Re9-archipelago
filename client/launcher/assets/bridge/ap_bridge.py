"""
Pont Archipelago pour Resident Evil Requiem (RE9).

Jeu (REFramework/Lua)  ← JSONL →  ap_bridge.py  ← WebSocket compressé →  serveur AP

Utilise la lib officielle `websockets` (permessage-deflate), conforme au network protocol.
Le Lua lit/écrit sous reframework/data/ArchipelagoRE9/ (chemins relatifs REF uniquement).

Dépendance : pip install websockets
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from typing import Any

try:
    import websockets
    from websockets.extensions.permessage_deflate import ClientPerMessageDeflateFactory
except ImportError:
    print("[ap_bridge] Installe websockets : py -3 -m pip install websockets", file=sys.stderr)
    sys.exit(1)

GAME_NAME = "Resident Evil Requiem"
CLIENT_VERSION = {"major": 0, "minor": 6, "build": 2, "class": "Version"}
ITEMS_HANDLING = 0b111
DEFAULT_TAGS = ["AP", "Python"]
DATA_SUBDIR = os.path.join("reframework", "data", "ArchipelagoRE9")
HEARTBEAT_S = 0.5
CMD_POLL_S = 0.1
CONNECT_OPEN_TIMEOUT_S = 4.0
RECONNECT_WAIT_S = 1.0
NO_SESSION_WAIT_S = 0.5

SLOT_SCALARS = (
    "apworld_version", "goal", "difficulty", "key_items", "flag_items",
    "enemy_drops", "death_link", "chapter_keys", "check_count",
)

# ClientStatus Archipelago
STATUS_GOAL = 30


def data_dir(game_dir: str) -> str:
    return os.path.join(game_dir, DATA_SUBDIR)


def paths(game_dir: str) -> dict[str, str]:
    d = data_dir(game_dir)
    return {
        "dir": d,
        "connection": os.path.join(d, "ap_connection.json"),
        "inbox": os.path.join(d, "bridge_inbox.jsonl"),
        "cmd": os.path.join(d, "bridge_cmd.jsonl"),
        "status": os.path.join(d, "bridge_status.json"),
        "cmd_ofs": os.path.join(d, "bridge_cmd_offset.json"),
    }


def ensure_files(p: dict[str, str]) -> None:
    os.makedirs(p["dir"], exist_ok=True)
    for key in ("inbox", "cmd"):
        if not os.path.exists(p[key]):
            open(p[key], "a", encoding="utf-8").close()
    if not os.path.exists(p["cmd_ofs"]):
        with open(p["cmd_ofs"], "w", encoding="utf-8") as f:
            json.dump({"lines_read": 0}, f)


def write_status(p: dict[str, str], **fields: Any) -> None:
    payload = {
        "alive": True,
        "pid": os.getpid(),
        "ts": time.time(),
        "backend": "python-websockets",
        "compression": "permessage-deflate",
        **fields,
    }
    tmp = p["status"] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    os.replace(tmp, p["status"])


def post(p: dict[str, str], kind: str, payload: str = "") -> None:
    line = f"{kind}|{payload or ''}\n"
    with open(p["inbox"], "a", encoding="utf-8") as f:
        f.write(line)


def load_connection(p: dict[str, str]) -> tuple[str, str, str] | None:
    if not os.path.exists(p["connection"]):
        return None
    try:
        with open(p["connection"], encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    server = str(data.get("server_address") or data.get("server") or "").strip()
    slot = str(data.get("slot_name") or data.get("slot") or "").strip()
    password = str(data.get("password") or "")
    if not server or not slot:
        return None
    return server, slot, password


def parse_server(server: str) -> list[str]:
    """URI à essayer — même ordre que CommonClient AP : ws puis wss.

    Localhost : ws only (évite le timeout TLS wss qui rallonge la connexion).
    wss-first sur un MultiServer local (ws only) envoie un ClientHello TLS :
    le serveur log « connection rejected (400 Bad Request) ».
    """
    s = server.strip()
    if s.startswith("ws://") or s.startswith("wss://"):
        return [s]
    if s.startswith("archipelago://"):
        hostport = s[len("archipelago://"):].split("/")[0]
    elif "://" in s:
        hostport = s.split("://", 1)[1].split("/")[0]
    else:
        hostport = s.split("/")[0]
    host = hostport.split(":")[0].lower()
    if host in ("localhost", "127.0.0.1", "::1"):
        return [f"ws://{hostport}"]
    return [f"ws://{hostport}", f"wss://{hostport}"]


def num(v: Any) -> str:
    try:
        return f"{int(v)}"
    except (TypeError, ValueError):
        return "0"


def slot_data_text(sd: Any) -> str:
    if not isinstance(sd, dict):
        return ""
    parts: list[str] = []
    for k in SLOT_SCALARS:
        v = sd.get(k)
        if isinstance(v, bool):
            parts.append(f"S\t{k}\t{str(v).lower()}")
        elif isinstance(v, (int, float)):
            parts.append(f"S\t{k}\t{v}")
        elif isinstance(v, str):
            parts.append(f"S\t{k}\t{v}")
    locs = sd.get("locations")
    if isinstance(locs, list):
        for loc in locs:
            try:
                parts.append(f"L\t{int(loc)}")
            except (TypeError, ValueError):
                pass
    items = sd.get("items")
    if isinstance(items, dict):
        for code, v in items.items():
            if isinstance(v, (list, tuple)) and len(v) >= 1:
                gid = v[0]
                count = v[1] if len(v) >= 2 else 1
                parts.append(f"I\t{code}\t{gid}\t{num(count)}")
            elif isinstance(v, dict) and "id" in v:
                parts.append(f"I\t{code}\t{v.get('id')}\t{num(v.get('count', 1))}")
    return "\n".join(parts)


def dump_ids(values: Any) -> str:
    if not isinstance(values, list):
        return ""
    out = []
    for v in values:
        try:
            out.append(f"{int(v)},")
        except (TypeError, ValueError):
            pass
    return "".join(out)


def flatten_printjson(data: Any) -> str:
    if not isinstance(data, list):
        return str(data or "")
    bits = []
    for row in data:
        if isinstance(row, dict):
            bits.append(str(row.get("text") or ""))
        else:
            bits.append(str(row))
    return "".join(bits)


class Bridge:
    def __init__(self, game_dir: str):
        self.p = paths(game_dir)
        ensure_files(self.p)
        self.ws = None
        self.state = "idle"
        self.slot = ""
        self.player_number = None
        self.seed = ""
        self._cmd_read = 0
        self._load_cmd_offset()

    def _load_cmd_offset(self) -> None:
        try:
            with open(self.p["cmd_ofs"], encoding="utf-8") as f:
                self._cmd_read = int(json.load(f).get("lines_read", 0))
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            self._cmd_read = 0

    def _save_cmd_offset(self) -> None:
        with open(self.p["cmd_ofs"], "w", encoding="utf-8") as f:
            json.dump({"lines_read": self._cmd_read}, f)

    def set_state(self, state: str, detail: str = "") -> None:
        self.state = state
        write_status(self.p, state=state, detail=detail, slot=self.slot, player=self.player_number, seed=self.seed)

    async def run(self) -> None:
        self.set_state("waiting", "attente ap_connection.json")
        print(f"[ap_bridge] data = {self.p['dir']}")
        while True:
            conn = load_connection(self.p)
            if not conn:
                self.set_state("waiting", "pas de session (serveur/slot)")
                await asyncio.sleep(NO_SESSION_WAIT_S)
                continue
            server, slot, password = conn
            self.slot = slot
            ok = await self._session(server, slot, password)
            if not ok:
                await asyncio.sleep(RECONNECT_WAIT_S)

    async def _session(self, server: str, slot: str, password: str) -> bool:
        uris = parse_server(server)
        last_err = ""
        for uri in uris:
            try:
                print(f"[ap_bridge] Connexion {uri} ...")
                self.set_state("connecting", uri)
                post(self.p, "socket", "")
                factory = ClientPerMessageDeflateFactory()
                async with websockets.connect(
                    uri,
                    extensions=[factory],
                    max_size=8 * 1024 * 1024,
                    open_timeout=CONNECT_OPEN_TIMEOUT_S,
                    ping_interval=20,
                    ping_timeout=20,
                ) as ws:
                    self.ws = ws
                    ext = getattr(ws, "extensions", None) or getattr(getattr(ws, "protocol", None), "extensions", [])
                    print(f"[ap_bridge] extensions={ext}")
                    return await self._handshake_and_loop(ws, slot, password)
            except Exception as e:
                last_err = str(e)
                print(f"[ap_bridge] échec {uri}: {e}")
                # pas de post(error) ici : fallback URI attendu (ws↔wss)
        post(self.p, "disconnected", "")
        post(self.p, "error", last_err or "connexion impossible")
        self.set_state("error", last_err or "connexion impossible")
        return False

    async def _handshake_and_loop(self, ws, slot: str, password: str) -> bool:
        # RoomInfo (liste de commandes)
        raw = await ws.recv()
        packets = json.loads(raw)
        if not isinstance(packets, list):
            packets = [packets]
        for pkt in packets:
            if pkt.get("cmd") == "RoomInfo":
                self.seed = str(pkt.get("seed_name") or "")
                post(self.p, "roominfo", "")
                break

        tags = list(DEFAULT_TAGS)
        connect = [{
            "cmd": "Connect",
            "password": password or "",
            "game": GAME_NAME,
            "name": slot,
            "uuid": f"re9_ap_bridge_{os.getpid()}",
            "version": CLIENT_VERSION,
            "items_handling": ITEMS_HANDLING,
            "tags": tags,
            "slot_data": True,
        }]
        await ws.send(json.dumps(connect))

        # Peut recevoir plusieurs paquets avant Connected
        while True:
            raw = await ws.recv()
            packets = json.loads(raw)
            if not isinstance(packets, list):
                packets = [packets]
            refused = False
            connected = False
            for pkt in packets:
                cmd = pkt.get("cmd")
                if cmd == "ConnectionRefused":
                    reasons = pkt.get("errors") or pkt.get("reasons") or ["refused"]
                    if isinstance(reasons, list):
                        text = " ".join(str(r) for r in reasons)
                    else:
                        text = str(reasons)
                    post(self.p, "refused", text)
                    self.set_state("refused", text)
                    refused = True
                elif cmd == "Connected":
                    self._on_connected(pkt)
                    connected = True
                else:
                    self._dispatch(pkt)
            if refused:
                return False
            if connected:
                break

        self.set_state("connected", "slot ok")
        await asyncio.gather(
            self._listen(ws),
            self._poll_cmds(ws),
            self._heartbeat(),
        )
        return True

    def _on_connected(self, pkt: dict) -> None:
        self.player_number = pkt.get("slot")
        missing = pkt.get("missing_locations") or []
        checked = pkt.get("checked_locations") or []
        miss = dump_ids(missing)
        done = dump_ids(checked)
        post(self.p, "slotlocs", miss + done)
        post(self.p, "slotchecked", done)
        sd = pkt.get("slot_data") or {}
        post(self.p, "slotdata", slot_data_text(sd))
        post(self.p, "connected", "")
        # Items déjà en file : souvent dans le même batch ; sinon ReceivedItems suit
        print(f"[ap_bridge] Connected slot={self.player_number} seed={self.seed}")

    async def _listen(self, ws) -> None:
        try:
            async for message in ws:
                packets = json.loads(message)
                if not isinstance(packets, list):
                    packets = [packets]
                for pkt in packets:
                    self._dispatch(pkt)
        except Exception as e:
            post(self.p, "error", str(e))
            post(self.p, "disconnected", "")
            self.set_state("disconnected", str(e))
            raise

    def _dispatch(self, pkt: dict) -> None:
        cmd = pkt.get("cmd")
        if cmd == "ReceivedItems":
            start = int(pkt.get("index") or 0)
            for offset, it in enumerate(pkt.get("items") or []):
                idx = start + offset
                post(
                    self.p,
                    "item",
                    f"{idx},{num(it.get('item'))},{num(it.get('location'))},{num(it.get('player'))},{num(it.get('flags'))}",
                )
        elif cmd == "LocationInfo":
            for it in pkt.get("locations") or []:
                post(
                    self.p,
                    "scout",
                    f"{num(it.get('location'))},{num(it.get('item'))},{num(it.get('player'))},{num(it.get('flags'))}",
                )
        elif cmd == "RoomUpdate":
            checked = pkt.get("checked_locations")
            if checked:
                post(self.p, "checked", dump_ids(checked))
        elif cmd == "PrintJSON":
            text = flatten_printjson(pkt.get("data"))
            if text:
                kind = str(pkt.get("type") or "")
                receiving = num(pkt.get("receiving")) if pkt.get("receiving") is not None else ""
                post(self.p, "print", f"{kind}\t{receiving}\t{text}")
        elif cmd == "Bounced":
            tags = pkt.get("tags") or []
            tag_s = "".join(f"{t}," for t in tags) if isinstance(tags, list) else ""
            data = pkt.get("data") or {}
            if not isinstance(data, dict):
                data = {}
            source = str(data.get("source") or "").replace("\t", " ").replace("\n", " ")
            cause = str(data.get("cause") or "").replace("\t", " ").replace("\n", " ")
            t = float(data.get("time") or 0)
            post(self.p, "bounce", f"{tag_s}\t{t:.3f}\t{source}\t{cause}")
        elif cmd == "Connected":
            self._on_connected(pkt)
        elif cmd == "ConnectionRefused":
            reasons = pkt.get("errors") or ["refused"]
            text = " ".join(str(r) for r in reasons) if isinstance(reasons, list) else str(reasons)
            post(self.p, "refused", text)

    async def _poll_cmds(self, ws) -> None:
        while True:
            try:
                with open(self.p["cmd"], encoding="utf-8") as f:
                    lines = f.readlines()
            except OSError:
                lines = []
            new = lines[self._cmd_read:]
            if new:
                for line in new:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        cmd = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    await self._handle_cmd(ws, cmd)
                self._cmd_read = len(lines)
                self._save_cmd_offset()
            await asyncio.sleep(CMD_POLL_S)

    async def _handle_cmd(self, ws, cmd: dict) -> None:
        name = cmd.get("cmd")
        if name == "LocationChecks":
            locs = cmd.get("locations") or []
            if locs:
                await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": [int(x) for x in locs]}]))
                print(f"[ap_bridge] LocationChecks x{len(locs)}")
        elif name == "LocationScouts":
            locs = cmd.get("locations") or []
            create = int(cmd.get("create_as_hint") or 0)
            if locs:
                await ws.send(json.dumps([{
                    "cmd": "LocationScouts",
                    "locations": [int(x) for x in locs],
                    "create_as_hint": create,
                }]))
        elif name == "StatusUpdate":
            status = int(cmd.get("status") or STATUS_GOAL)
            await ws.send(json.dumps([{"cmd": "StatusUpdate", "status": status}]))
        elif name == "Bounce":
            pkt = {
                "cmd": "Bounce",
                "data": cmd.get("data") or {},
            }
            if cmd.get("slots"):
                pkt["slots"] = [int(x) for x in cmd["slots"]]
            if cmd.get("tags"):
                pkt["tags"] = cmd["tags"]
            elif not cmd.get("slots"):
                pkt["tags"] = ["DeathLink"]
            await ws.send(json.dumps([pkt]))
        elif name == "Say":
            text = str(cmd.get("text") or "")
            if text:
                await ws.send(json.dumps([{"cmd": "Say", "text": text}]))
        elif name == "ConnectUpdate":
            pkt: dict[str, Any] = {"cmd": "ConnectUpdate"}
            if "tags" in cmd:
                pkt["tags"] = cmd["tags"]
            if "items_handling" in cmd:
                pkt["items_handling"] = int(cmd["items_handling"])
            await ws.send(json.dumps([pkt]))
        elif name == "Disconnect":
            await ws.close()

    async def _heartbeat(self) -> None:
        while True:
            write_status(
                self.p,
                state=self.state,
                slot=self.slot,
                player=self.player_number,
                seed=self.seed,
            )
            await asyncio.sleep(HEARTBEAT_S)


def main() -> None:
    parser = argparse.ArgumentParser(description="Pont Archipelago RE9 (WebSocket compressé)")
    parser.add_argument("--game-dir", required=True, help="Dossier contenant re9.exe")
    args = parser.parse_args()
    game_dir = os.path.abspath(args.game_dir)
    if not os.path.isdir(game_dir):
        print(f"[ap_bridge] game-dir invalide : {game_dir}", file=sys.stderr)
        sys.exit(1)

    bridge = Bridge(game_dir)
    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        write_status(bridge.p, alive=False, state="stopped")
        print("\n[ap_bridge] arrêt")


if __name__ == "__main__":
    main()
