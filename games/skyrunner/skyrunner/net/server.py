"""Listen server: the host runs the only simulation; remote seats send commands
and receive role-filtered snapshots.

Transport: TCP, one JSON object per line. Messages:
  client -> server  {"t":"hello","v":1,"name":"Rosa","role":"copilot"}
                    {"t":"cmd","seq":7,"name":"kick","args":{"count":2}}
  server -> client  {"t":"welcome","role":"copilot","mode":"coop","seed":7}
                    {"t":"error","msg":"..."}
                    {"t":"ack","seq":7,"ok":true,"msg":"ok"}
                    {"t":"snap",...}  (see snapshot.py)

The asyncio loop lives in a background thread. The game's main loop calls
`pump()` (apply queued commands) and `publish()` (send snapshots), so the
Session is only ever touched from one thread.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import queue
import threading
import time

from ..roles import MODE_ROLES, Mode, Role
from .snapshot import PROTOCOL_VERSION, build_snapshot

DEFAULT_PORT = 47800
MAX_LINE = 1 << 20
SNAPSHOT_HZ = 15.0


class _Client:
    def __init__(self, writer: asyncio.StreamWriter, name: str, role: Role):
        self.writer = writer
        self.name = name
        self.role = role


class HostServer:
    def __init__(self, host: str = "0.0.0.0", port: int = DEFAULT_PORT, mode: Mode = Mode.COOP, seed: int = 7):
        self.host, self.port = host, port
        self.mode = Mode(mode)
        self.world_seed = seed
        self.loop = asyncio.new_event_loop()
        self.clients: dict[Role, _Client] = {}
        self.inbox: queue.Queue = queue.Queue()
        self.joins: queue.Queue = queue.Queue()
        self._lock = threading.Lock()
        self._seq = 0
        self._last_pub = 0.0
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="skyrunner-net")
        self._server = None

    # ------------------------------------------------------------ thread side
    def start(self) -> "HostServer":
        self._thread.start()
        self._ready.wait(5)
        return self

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self._server = self.loop.run_until_complete(
            asyncio.start_server(self._handle, self.host, self.port, limit=MAX_LINE))
        self.port = self._server.sockets[0].getsockname()[1]
        self._ready.set()
        self.loop.run_forever()

    def stop(self) -> None:
        def _shutdown():
            for c in list(self.clients.values()):
                c.writer.close()
            if self._server:
                self._server.close()
            self.loop.stop()
        self.loop.call_soon_threadsafe(_shutdown)
        self._thread.join(2)

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        client = None
        try:
            line = await asyncio.wait_for(reader.readline(), 10)
            hello = json.loads(line or b"{}")
            role = Role(hello.get("role", ""))
            name = str(hello.get("name", "player"))[:32]
            err = None
            if hello.get("t") != "hello" or hello.get("v") != PROTOCOL_VERSION:
                err = f"Protocol mismatch (server v{PROTOCOL_VERSION})."
            elif role == Role.PILOT or role not in MODE_ROLES[self.mode]:
                err = f"Role {role.value} isn't open in {self.mode.value} mode."
            else:
                with self._lock:
                    if role in self.clients:
                        err = f"{role.value} is already taken."
                    else:
                        client = self.clients[role] = _Client(writer, name, role)
            if err:
                writer.write(_line({"t": "error", "msg": err}))
                await writer.drain()
                return
            writer.write(_line({"t": "welcome", "role": role.value, "mode": self.mode.value, "seed": self.world_seed}))
            await writer.drain()
            self.joins.put(("join", role, name))
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("t") == "cmd" and isinstance(msg.get("args", {}), dict):
                    args = {str(k)[:32]: v for k, v in list(msg.get("args", {}).items())[:8]}
                    self.inbox.put((role, int(msg.get("seq", 0)), str(msg.get("name", ""))[:32], args))
        except (asyncio.TimeoutError, ValueError, ConnectionError, OSError):
            pass
        finally:
            if client is not None:
                with self._lock:
                    self.clients.pop(client.role, None)
                self.joins.put(("leave", client.role, client.name))
            writer.close()

    def _send(self, role: Role, msg: dict) -> None:
        c = self.clients.get(role)
        if c is None:
            return
        data = _line(msg)

        def _write():
            tr = c.writer.transport
            if tr is not None and not tr.is_closing() and tr.get_write_buffer_size() < (4 << 20):
                c.writer.write(data)
        self.loop.call_soon_threadsafe(_write)

    # ------------------------------------------------------------ game side
    def pump(self, sess) -> None:
        """Apply joins/leaves and queued commands. Call from the game loop."""
        while not self.joins.empty():
            what, role, name = self.joins.get_nowait()
            if what == "join":
                sess.humans[role] = name
                if role == Role.COPILOT:
                    sess.set_copilot("human")
                elif role == Role.CONTROLLER:
                    sess.police.controller = "human"
                sess.say(f"{name} joined as {role.value}.")
                sess.law_say(f"{name} joined as {role.value}.")
            else:
                sess.humans.pop(role, None)
                if role == Role.COPILOT:
                    sess.set_copilot(None)
                elif role == Role.CONTROLLER:
                    sess.police.controller = "ai"
                sess.say(f"{name} ({role.value}) left.")
        while not self.inbox.empty():
            role, seq, name, args = self.inbox.get_nowait()
            ok, msg = sess.command(role, name, **args)
            self._send(role, {"t": "ack", "seq": seq, "ok": ok, "msg": msg})

    def publish(self, sess, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self._last_pub < 1.0 / SNAPSHOT_HZ:
            return
        self._last_pub = now
        self._seq += 1
        with self._lock:
            roles = list(self.clients)
        for role in roles:
            self._send(role, build_snapshot(sess, role, self._seq))


def _line(msg: dict) -> bytes:
    return (json.dumps(msg, separators=(",", ":")) + "\n").encode()


def main() -> None:
    """Dedicated headless server (no pilot seat): police-vs-AI for remote controllers."""
    from ..game import Session

    ap = argparse.ArgumentParser(description="Skyrunner dedicated server (headless)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    sess = Session(mode=Mode.POLICE, seed=args.seed)  # AI runs the desk until a controller joins
    srv = HostServer(args.bind, args.port, Mode.POLICE).start()
    print(f"Skyrunner task-force server on {args.bind}:{srv.port} - connect with "
          f"`python -m skyrunner.station --connect HOST:{srv.port} --role controller`")
    dt = 1 / 30
    try:
        while True:
            t0 = time.monotonic()
            srv.pump(sess)
            sess.update(dt)
            srv.publish(sess)
            time.sleep(max(0.0, dt - (time.monotonic() - t0)))
    except KeyboardInterrupt:
        srv.stop()


if __name__ == "__main__":
    main()
