#!/usr/bin/env python3
"""Lab stand-in for the Brev launchable endpoints the course calls (modules 3-4).

  GET /healthz             -> {"status":"ok"}
  GET /api/agent           -> {"agent":{"agent":"openclaw","name":<sandbox>,"dashboardUrl":"/api/agent/launch"}}
                              (503 {"status":"starting"} until the sandbox answers dashboard-url)
  WS  /ws/terminal?cmd=..  -> splits cmd on whitespace and execs it (no shell, quotes kept literally,
                              like current Brev launchables; the course probes this and wraps shell
                              work itself) as this user; frames {"type":"stdout|stderr","data"} then {"type":"exit","code"}
                              client sends {"type":"input","data"}; &stdio=pipe separates stdout/stderr

/cli/gateway is proxied by nginx straight to the OpenClaw gateway (127.0.0.1:18789).
nginx (basic auth) is the only listener on the network; this binds to loopback.
Needs: python3-websockets (Ubuntu 24.04 ships 10.x; legacy API used on purpose).
"""
import asyncio
import json
import os
import pty
import shutil
import subprocess
import time
from http import HTTPStatus
from urllib.parse import parse_qs, urlsplit

from websockets.legacy.server import serve

SANDBOX = os.environ.get("SAIF_SANDBOX", "saif-agent")
LISTEN = int(os.environ.get("SAIF_SHIM_PORT", "8090"))
_cache = {"at": 0.0, "url": None, "err": "not checked yet"}


def _json(status, obj):
    body = json.dumps(obj).encode()
    return status, [("Content-Type", "application/json"), ("Cache-Control", "no-store")], body


def dashboard_url():
    if time.time() - _cache["at"] < 30 and _cache["url"]:
        return _cache["url"], None
    nemoclaw = shutil.which("nemoclaw") or os.path.expanduser("~/.local/bin/nemoclaw")
    try:
        out = subprocess.run([nemoclaw, SANDBOX, "dashboard-url", "--quiet"], capture_output=True,
                             text=True, timeout=25)
        url = next((l.strip() for l in out.stdout.splitlines() if "token=" in l), "")
        if out.returncode == 0 and url:
            _cache.update(at=time.time(), url=url, err=None)
            return url, None
        err = (out.stderr or out.stdout).strip()[-300:] or f"exit {out.returncode}"
    except (OSError, subprocess.TimeoutExpired) as e:
        err = str(e)
    _cache.update(at=time.time(), url=None, err=err)
    return None, err


async def process_request(path, headers):
    p = urlsplit(path).path
    if p == "/healthz":
        return _json(HTTPStatus.OK, {"status": "ok"})
    if p == "/api/agent":
        url, err = await asyncio.get_running_loop().run_in_executor(None, dashboard_url)
        if url:
            # Current launchable contract: a same-origin /api/agent/launch handoff, no token in the URL.
            # The course then reads the gateway token through /ws/terminal and pairs a signed device
            # identity (OpenClaw >= 2026.9 rejects the legacy token-only Control UI login).
            return _json(HTTPStatus.OK, {"agent": {"agent": "openclaw", "name": SANDBOX,
                                                   "dashboardUrl": "/api/agent/launch"}})
        return _json(HTTPStatus.SERVICE_UNAVAILABLE, {"status": "starting", "message": err})
    if p == "/ws/terminal":
        return None  # continue with the WebSocket handshake
    return _json(HTTPStatus.NOT_FOUND, {"error": "not found"})


async def send(ws, **frame):
    try:
        await ws.send(json.dumps(frame))
    except Exception:
        pass


async def terminal(ws, path):
    q = parse_qs(urlsplit(path).query)
    cmd = (q.get("cmd") or [""])[0] or "bash -l"
    # Current launchables split on whitespace and keep quote characters (no shell). The course's
    # gateway-token handoff relies on it: node -e eval(Buffer.from("<b64>","base64").toString())
    argv = cmd.split()
    pipe = (q.get("stdio") or ["pty"])[0] == "pipe"
    env = {**os.environ, "TERM": "xterm-256color"}
    loop = asyncio.get_running_loop()
    if not shutil.which(argv[0], path=env.get("PATH")):
        await send(ws, type="stderr", stream="stderr", data=f"{argv[0]}: command not found\n")
        await send(ws, type="exit", code=127)
        return

    if pipe:
        # One-shot mode (course: sandboxExec, host exec): no stdin, like a real launchable.
        # An open stdin pipe keeps `openshell sandbox exec` waiting forever.
        proc = await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.DEVNULL,
                                                    stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE, env=env,
                                                    start_new_session=True)

        async def pump(stream, name):
            while chunk := await stream.read(4096):
                await send(ws, type=name, stream=name, data=chunk.decode(errors="replace"))

        async def drain_client():
            async for _ in ws:  # ignore input frames; keep the socket serviced
                pass

        drainer = asyncio.ensure_future(drain_client())
        await asyncio.gather(pump(proc.stdout, "stdout"), pump(proc.stderr, "stderr"))
        code = await proc.wait()
        drainer.cancel()
        await send(ws, type="exit", code=code)
        return

    master, slave = pty.openpty()
    proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env,
                            start_new_session=True, close_fds=True)
    os.close(slave)
    out_q = asyncio.Queue()

    def readable():
        try:
            data = os.read(master, 4096)
        except OSError:
            data = b""
        out_q.put_nowait(data)
        if not data:
            loop.remove_reader(master)

    loop.add_reader(master, readable)

    async def feed():
        async for msg in ws:
            try:
                m = json.loads(msg)
            except ValueError:
                m = {"type": "input", "data": msg}
            if m.get("type") == "input":
                os.write(master, str(m.get("data", "")).encode())

    feeder = asyncio.ensure_future(feed())
    try:
        while True:
            data = await out_q.get()
            if not data:
                break
            await send(ws, type="stdout", data=data.decode(errors="replace"))
        code = await loop.run_in_executor(None, proc.wait)
        await send(ws, type="exit", code=code)
    finally:
        feeder.cancel()
        try:
            loop.remove_reader(master)
        except Exception:
            pass
        os.close(master)
        if proc.poll() is None:
            proc.kill()


async def main():
    async with serve(terminal, "127.0.0.1", LISTEN, process_request=process_request, max_size=2**20):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
