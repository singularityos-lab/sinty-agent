const ROOM = /^\/v1\/room\/([0-9a-f]{64})$/;
const PUSH = /^\/v1\/push\/([0-9a-f]{64})$/;
const ROLES = ["desktop", "phone"];
const PUSH_GAP_MS = 10000;
const TOKEN = /^[0-9a-fA-F]{32,200}$/;
const ALERTS = {
  confirm: "Sinty AI needs you",
  reply: "Sinty AI has answered",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    let m = url.pathname.match(ROOM);
    if (m) {
      if (request.headers.get("Upgrade") !== "websocket") return new Response("expected a WebSocket\n", { status: 426 });
      if (!ROLES.includes(url.searchParams.get("role"))) return new Response("unknown role\n", { status: 400 });
      return env.ROOMS.get(env.ROOMS.idFromName(m[1])).fetch(request);
    }
    m = url.pathname.match(PUSH);
    if (m && request.method === "POST") return env.ROOMS.get(env.ROOMS.idFromName(m[1])).fetch(request);
    return new Response("not found\n", { status: 404 });
  },
};

export class Room {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/v1/push/")) return this.push(request);
    const role = url.searchParams.get("role");
    const other = role === "desktop" ? "phone" : "desktop";
    const replaced = this.state.getWebSockets(role);
    for (const old of replaced) old.close(4000, "replaced");
    if (replaced.length > 0) {
      for (const peer of this.state.getWebSockets(other)) peer.send("gone");
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.state.acceptWebSocket(server, [role]);
    const peers = this.state.getWebSockets(other);
    if (peers.length > 0) {
      const desktop = role === "desktop" ? server : peers[0];
      desktop.send("peer");
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    if (typeof message === "string") return;
    const role = this.state.getTags(ws)[0];
    const other = role === "desktop" ? "phone" : "desktop";
    for (const peer of this.state.getWebSockets(other)) peer.send(message);
  }

  webSocketClose(ws) {
    this.gone(ws);
  }

  webSocketError(ws) {
    this.gone(ws);
  }

  gone(ws) {
    const role = this.state.getTags(ws)[0];
    const other = role === "desktop" ? "phone" : "desktop";
    for (const peer of this.state.getWebSockets(other)) {
      try {
        peer.send("gone");
      } catch (e) {}
    }
  }

  async push(request) {
    let body;
    try {
      body = await request.json();
    } catch (e) {
      return new Response("bad body\n", { status: 400 });
    }
    const alert = ALERTS[body.kind];
    if (!alert || typeof body.token !== "string" || !TOKEN.test(body.token)) return new Response("bad push\n", { status: 400 });
    if (this.state.getWebSockets("desktop").length === 0) return new Response("no desktop in this room\n", { status: 403 });
    const now = Date.now();
    const last = (await this.state.storage.get("last-push")) || 0;
    if (now - last < PUSH_GAP_MS) return new Response(null, { status: 204 });
    await this.state.storage.put("last-push", now);
    if (!this.env.APNS_KEY) return new Response("push is not configured\n", { status: 503 });
    const r = await apns(this.env, body.token, alert);
    return new Response(null, { status: r.ok ? 204 : 502 });
  }
}

function b64url(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function jwt(env) {
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(head + "." + claims));
  return head + "." + claims + "." + b64url(sig);
}

async function apns(env, token, alert) {
  const host = env.APNS_SANDBOX === "1" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: "bearer " + (await jwt(env)),
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({ aps: { alert: { title: "Sinty AI", body: alert }, sound: "default" } }),
  });
}
