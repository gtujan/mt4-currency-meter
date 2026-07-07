"""aiohttp bridge server: receives MT4 quote snapshots, recomputes the
currency-strength meter, and broadcasts state to browsers over WebSocket.

Routes:
  POST /tick   - {"ts":.., "quotes": {...}} snapshot from MT4 (or mock_feed.py)
  GET  /ws     - WebSocket; server pushes computed state on every update
  GET  /state  - latest computed state as JSON (debug/polling convenience)
  GET  /       - serves web/index.html

Only dependency: aiohttp. Bind: 127.0.0.1:8010.
"""

import asyncio
import json
import os
import time

from aiohttp import web, WSMsgType

from meter import compute

HOST = os.environ.get("METER_HOST", "127.0.0.1")
PORT = int(os.environ.get("METER_PORT", "8010"))
STALE_AFTER_S = 5
WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web")

latest_quotes: dict = {}
last_tick_time: float = 0.0
last_state: dict = compute({})
websockets: set = set()


def recompute(stale: bool = False) -> dict:
    global last_state
    last_state = compute(latest_quotes, ts=last_tick_time, stale=stale)
    return last_state


async def broadcast(state: dict):
    if not websockets:
        return
    msg = json.dumps(state)
    dead = set()
    for ws in websockets:
        try:
            await ws.send_str(msg)
        except Exception:
            dead.add(ws)
    websockets.difference_update(dead)


async def handle_tick(request: web.Request) -> web.Response:
    global latest_quotes, last_tick_time
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON"}, status=400)

    quotes = body.get("quotes")
    if not isinstance(quotes, dict):
        return web.json_response({"error": "missing 'quotes' object"}, status=400)

    latest_quotes = quotes
    last_tick_time = body.get("ts") or time.time()
    state = recompute(stale=False)
    await broadcast(state)
    return web.json_response({"ok": True})


async def handle_state(request: web.Request) -> web.Response:
    stale = (time.time() - last_tick_time) > STALE_AFTER_S if last_tick_time else True
    if stale != last_state.get("stale"):
        recompute(stale=stale)
    return web.json_response(last_state)


async def handle_ws(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    websockets.add(ws)
    try:
        stale = (time.time() - last_tick_time) > STALE_AFTER_S if last_tick_time else True
        await ws.send_str(json.dumps(recompute(stale=stale)))
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                break
    finally:
        websockets.discard(ws)
    return ws


async def handle_index(request: web.Request) -> web.Response:
    return web.FileResponse(os.path.join(WEB_DIR, "index.html"))


async def stale_watcher(app: web.Application):
    """Background task: mark state stale and push it if no tick for >5s."""
    was_stale = False
    while True:
        await asyncio.sleep(1)
        if not last_tick_time:
            continue
        is_stale = (time.time() - last_tick_time) > STALE_AFTER_S
        if is_stale != was_stale:
            was_stale = is_stale
            state = recompute(stale=is_stale)
            await broadcast(state)


async def start_background_tasks(app: web.Application):
    app["stale_watcher"] = asyncio.create_task(stale_watcher(app))


async def cleanup_background_tasks(app: web.Application):
    app["stale_watcher"].cancel()


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_post("/tick", handle_tick)
    app.router.add_get("/ws", handle_ws)
    app.router.add_get("/state", handle_state)
    app.router.add_get("/", handle_index)
    app.on_startup.append(start_background_tasks)
    app.on_cleanup.append(cleanup_background_tasks)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=HOST, port=PORT)
