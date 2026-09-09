// Test-only entry point. Never referenced by the production Worker configuration.
import { MacRelay } from "../relay.mjs";

export class RelayExpiryFixture extends MacRelay {
  async expireForTest() {
    const invitation = await this.ctx.storage.get("invitation");
    if (!invitation) throw new Error("Missing fixture invitation");
    await this.ctx.storage.put("invitation", { ...invitation, expires: Date.now() - 1000 });
  }

  async setUsageForTest(usage) { await this.ctx.storage.put("usage", usage); }

  async runAlarmForTest() { await super.alarm(); }

  async stateForTest() {
    return {
      invitation: !!(await this.ctx.storage.get("invitation")),
      credential: !!(await this.ctx.storage.get("credential")),
    };
  }
}

export default {
  async fetch(request, env) {
    const { operation, tenant, code, usage, paused } = await request.json();
    const relay = env.FIXTURES.getByName(tenant);
    switch (operation) {
      case "admit": return Response.json(await relay.admit());
      case "usage": return Response.json(await relay.usageStatus());
      case "setUsage": await relay.setUsageForTest(usage); return Response.json(true);
      case "pause": await relay.setPaused(paused); return Response.json(true);
      case "invite": return Response.json(await relay.invite());
      case "expire": await relay.expireForTest(); return Response.json(true);
      case "pair": return Response.json(await relay.pair(code));
      case "state": return Response.json(await relay.stateForTest());
      case "alarm": await relay.runAlarmForTest(); return Response.json(true);
      default: return new Response(null, { status: 400 });
    }
  },
};
