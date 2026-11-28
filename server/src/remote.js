// Remote control between one account's phones. One Durable Object per
// account holds a WebSocket per signed-in phone that has JARX open. A phone
// sends what it plays whenever that changes; every phone gets the list of
// phones with their songs, and can send play/pause/next/previous to another.
// Hibernating sockets: an idle connection costs nothing, and only changes
// travel (no polling).

const CMDS = ['play', 'pause', 'next', 'prev'];
const str = (s, n) => (typeof s === 'string' ? s.slice(0, n) : '');

/** GET /remote (WebSocket): hand the phone's socket to the account's object. */
export async function connect(req, env, user) {
  if (req.headers.get('upgrade') !== 'websocket') return Response.json({ error: 'websocket_only' }, { status: 426 });
  if (!env.REMOTE) return Response.json({ error: 'not_ready' }, { status: 503 });
  const url = new URL(req.url);
  // One id per sign-in (a phone signing in again gets a new one).
  url.searchParams.set('id', user.token_hash.slice(0, 16));
  url.searchParams.set('name', user.session_device || 'Phone');
  return env.REMOTE.get(env.REMOTE.idFromName(user.id)).fetch(new Request(url, req));
}

// ponytail: a phone signed out by the owner (or a ban) keeps its open socket
// until it reconnects; sessions are checked only when connecting.
export class Remote {
  constructor(ctx) {
    this.ctx = ctx;
  }

  async fetch(req) {
    const q = new URL(req.url).searchParams;
    const [client, server] = Object.values(new WebSocketPair());
    this.join(server, q.get('id'), q.get('name'));
    return new Response(null, { status: 101, webSocket: client });
  }

  join(ws, id, name) {
    for (const old of this.ctx.getWebSockets(id)) old.close(4000, 'replaced');
    this.ctx.acceptWebSocket(ws, [id]);
    ws.serializeAttachment({ id, name: str(name, 60), state: null });
    ws.send(JSON.stringify({ t: 'hello', id }));
    this.broadcast();
  }

  webSocketMessage(ws, raw) {
    if (typeof raw !== 'string' || raw.length > 4000) return;
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    const me = ws.deserializeAttachment();
    if (m.t === 'state' && m.state && typeof m.state === 'object') {
      const s = m.state;
      ws.serializeAttachment({ ...me, state: {
        title: str(s.title, 150), artist: str(s.artist, 150), art: str(s.art, 500), playing: s.playing === true } });
      this.broadcast();
    } else if (m.t === 'cmd' && CMDS.includes(m.cmd) && typeof m.to === 'string' && m.to !== me.id) {
      const msg = JSON.stringify({ t: 'cmd', cmd: m.cmd, from: me.name });
      for (const to of this.ctx.getWebSockets(m.to)) send(to, msg);
    }
  }

  webSocketClose(ws) { this.broadcast(ws); }
  webSocketError(ws) { this.broadcast(ws); }

  /** Every open phone gets the full list (it finds itself by its hello id). */
  broadcast(gone) {
    const open = this.ctx.getWebSockets().filter((ws) => ws !== gone && ws.readyState === 1);
    const msg = JSON.stringify({ t: 'devices', devices: open.map((ws) => ws.deserializeAttachment()) });
    for (const ws of open) send(ws, msg);
  }
}

function send(ws, msg) {
  try { ws.send(msg); } catch { /* closing: its close event updates the list */ }
}
