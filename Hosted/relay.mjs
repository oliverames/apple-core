// SPDX-License-Identifier: GPL-3.0-or-later
import { DurableObject } from "cloudflare:workers";
import { MAX_RESPONSE, relayPathAllowed, secret, digest, matchesSecret, unbase64 } from "./protocol.mjs";

// One object per installation. Only credential hashes persist; MCP payloads do not.
export class MacRelay extends DurableObject {
  pending = new Map();

  async invite() {
    if (await this.ctx.storage.get("credential")) throw new Error("Already enrolled");
    const code = secret();
    await this.ctx.storage.put("invitation", { hash: await digest(code), expires: Date.now() + 30 * 60 * 1000 });
    await this.ctx.storage.setAlarm(Date.now() + 30 * 60 * 1000);
    return code;
  }

  async pair(code) {
    const invitation = await this.ctx.storage.get("invitation");
    if (!invitation || invitation.expires < Date.now() || !(await matchesSecret(code, invitation.hash))) return null;
    const credential = secret();
    const hash = await digest(credential);
    // Recheck inside the transaction: two simultaneous redemptions must not win.
    return this.ctx.storage.transaction(async txn => {
      const current = await txn.get("invitation");
      if (!current || current.hash !== invitation.hash || current.expires < Date.now()) return null;
      await txn.delete("invitation");
      await txn.put("credential", hash);
      return credential;
    });
  }

  async revoke() {
    await this.ctx.storage.deleteAll();
    for (const socket of this.ctx.getWebSockets()) socket.close(1008, "Connection revoked");
    this.failPending();
  }

  async alarm() {
    const invitation = await this.ctx.storage.get("invitation");
    if (invitation && invitation.expires <= Date.now()) await this.ctx.storage.delete("invitation");
  }

  usageLimits() {
    const day = Number(this.env.HOSTED_DAILY_LIMIT);
    const month = Number(this.env.HOSTED_MONTHLY_LIMIT);
    if (![day, month].every(value => Number.isSafeInteger(value) && value > 0 && value <= 1_000_000)) return null;
    return { day, month };
  }

  currentUsage(stored) {
    const day = new Date().toISOString().slice(0, 10);
    const month = day.slice(0, 7);
    return { day, month, dayCount: stored?.day === day ? stored.dayCount : 0,
      monthCount: stored?.month === month ? stored.monthCount : 0 };
  }

  async usageStatus() {
    return { ...this.currentUsage(await this.ctx.storage.get("usage")),
      limits: this.usageLimits(), paused: !!(await this.ctx.storage.get("paused")) };
  }

  async setPaused(paused) {
    if (typeof paused !== "boolean") throw new Error("Invalid pause state");
    await this.ctx.storage.put("paused", paused);
  }

  async admit() {
    const limits = this.usageLimits();
    if (!limits) return 503;
    return this.ctx.storage.transaction(async txn => {
      if (await txn.get("paused")) return 503;
      const usage = this.currentUsage(await txn.get("usage"));
      if (usage.dayCount >= limits.day || usage.monthCount >= limits.month) return 429;
      usage.dayCount += 1;
      usage.monthCount += 1;
      await txn.put("usage", usage);
      return 200;
    });
  }

  async fetch(request) {
    const credential = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
    if (!(await matchesSecret(credential, await this.ctx.storage.get("credential")))) return new Response(null, { status: 401 });
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
    // Refuse a second active connector instead of distributing personal data
    // across two Macs that accidentally share a configuration.
    if (this.ctx.getWebSockets().length) return new Response("Already connected", { status: 409 });
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async exchange(message) {
    if (!relayPathAllowed(message.method, message.path)) return { status: 400, headers: {}, body: "" };
    const sockets = this.ctx.getWebSockets();
    if (sockets.length !== 1) return { status: 503, headers: {}, body: "" };
    if (this.pending.size >= 4) return { status: 429, headers: {}, body: "" };
    // Keep grant revocation available even while ordinary work is suspended.
    const admission = message.path === "/oauth/revoke" && message.method === "POST" ? 200 : await this.admit();
    if (admission !== 200) return { status: admission, headers: {}, body: "" };
    // Storage admission yields; recheck concurrency before opening another request.
    if (this.pending.size >= 4) return { status: 429, headers: {}, body: "" };
    const id = crypto.randomUUID();
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        try { sockets[0].send(JSON.stringify({ cancel: id })); } catch {}
        resolve({ status: 504, headers: {}, body: "" });
      }, 90_000);
      this.pending.set(id, { resolve, timer, chunks: [], size: 0, status: null, headers: {} });
      try { sockets[0].send(JSON.stringify({ ...message, id })); }
      catch { clearTimeout(timer); this.pending.delete(id); resolve({ status: 503, headers: {}, body: "" }); }
    });
  }

  webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > 128 * 1024) { socket.close(1009, "Invalid frame"); this.failPending(); return; }
    try {
      const frame = JSON.parse(message);
      const pending = this.pending.get(frame.id);
      if (!pending) return;
      if (frame.status !== undefined) {
        if (pending.status !== null || !Number.isInteger(frame.status) || frame.status < 200 || frame.status > 599) throw new Error("Invalid status");
        pending.status = frame.status;
        pending.headers = frame.headers ?? {};
      }
      if (frame.chunk !== undefined) {
        if (typeof frame.chunk !== "string") throw new Error("Invalid chunk");
        const chunk = unbase64(frame.chunk);
        pending.size += chunk.length;
        if (pending.size > MAX_RESPONSE) throw new Error("Response too large");
        pending.chunks.push(frame.chunk);
      }
      if (frame.done === true) {
        if (pending.status === null) throw new Error("Missing status");
        clearTimeout(pending.timer);
        this.pending.delete(frame.id);
        pending.resolve({ status: pending.status, headers: pending.headers, chunks: pending.chunks });
      }
    } catch { socket.close(1008, "Invalid relay response"); this.failPending(); }
  }

  failPending() {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.resolve({ status: 503, headers: {}, body: "" });
    }
    this.pending.clear();
  }

  webSocketClose() { this.failPending(); }
  webSocketError() { this.failPending(); }
}
