"""Clients for station UIs and bots.

`NetClient` talks to a HostServer over TCP from a background thread.
`LocalLink` wraps an in-process Session with the same interface, so the
station UI can run the police-vs-AI mode without any networking.
"""
from __future__ import annotations

import asyncio
import json
import threading
import time

from ..roles import Role
from .snapshot import PROTOCOL_VERSION, build_snapshot

MAX_LINE = 1 << 20


class NetClient:
    def __init__(self, host: str, port: int, name: str, role: Role | str):
        self.host, self.port, self.name, self.role = host, port, name, Role(role)
        self.latest: dict | None = None
        self.welcome: dict | None = None
        self.error: str | None = None
        self.acks: dict[int, tuple[bool, str]] = {}
        self._seq = 0
        self._loop = asyncio.new_event_loop()
        self._writer: asyncio.StreamWriter | None = None
        self._connected = threading.Event()
        self._closed = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="skyrunner-client")

    def start(self, timeout: float = 5.0) -> "NetClient":
        self._thread.start()
        self._connected.wait(timeout)
        if self.error:
            raise ConnectionError(self.error)
        if not self.welcome:
            raise ConnectionError("No answer from the host.")
        return self

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._main())
        finally:
            self._closed.set()
            self._connected.set()

    async def _main(self) -> None:
        try:
            reader, writer = await asyncio.open_connection(self.host, self.port, limit=MAX_LINE)
        except OSError as e:
            self.error = f"Can't connect to {self.host}:{self.port} ({e})"
            return
        self._writer = writer
        writer.write(_line({"t": "hello", "v": PROTOCOL_VERSION, "name": self.name, "role": self.role.value}))
        await writer.drain()
        while True:
            line = await reader.readline()
            if not line:
                self.error = self.error or "Host closed the connection."
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            kind = msg.get("t")
            if kind == "welcome":
                self.welcome = msg
                self._connected.set()
            elif kind == "error":
                self.error = msg.get("msg", "error")
                self._connected.set()
                break
            elif kind == "snap":
                self.latest = msg
            elif kind == "ack":
                self.acks[msg.get("seq", 0)] = (bool(msg.get("ok")), str(msg.get("msg", "")))
        writer.close()

    def send_command(self, name: str, **args) -> int:
        self._seq += 1
        data = _line({"t": "cmd", "seq": self._seq, "name": name, "args": args})
        if self._writer is not None:
            self._loop.call_soon_threadsafe(self._writer.write, data)
        return self._seq

    def wait_ack(self, seq: int, timeout: float = 3.0) -> tuple[bool, str] | None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if seq in self.acks:
                return self.acks[seq]
            time.sleep(0.01)
        return None

    def snapshot(self) -> dict | None:
        return self.latest

    def tick(self, dt: float) -> None:
        """Remote sessions tick on the host."""

    @property
    def alive(self) -> bool:
        return not self._closed.is_set()

    def close(self) -> None:
        if self._writer is not None:
            self._loop.call_soon_threadsafe(self._writer.close)


class LocalLink:
    """Same interface as NetClient, backed by an in-process Session."""

    def __init__(self, sess, role: Role | str):
        self.sess = sess
        self.role = Role(role)
        self.error = None
        self.last_result: tuple[bool, str] = (True, "")
        self._seq = 0

    def send_command(self, name: str, **args) -> int:
        self.last_result = self.sess.command(self.role, name, **args)
        self._seq += 1
        return self._seq

    def snapshot(self) -> dict:
        self._seq += 1
        return build_snapshot(self.sess, self.role, self._seq)

    def tick(self, dt: float) -> None:
        self.sess.update(dt)

    @property
    def alive(self) -> bool:
        return True

    def close(self) -> None:
        pass


def _line(msg: dict) -> bytes:
    return (json.dumps(msg, separators=(",", ":")) + "\n").encode()
