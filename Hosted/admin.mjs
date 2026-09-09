#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Set APPLE_CORE_HOSTED_ADMIN_SECRET through a secret manager, never an argument.
import { ORIGIN, TENANT } from "./protocol.mjs";

const [command, tenant] = process.argv.slice(2);
if (!process.env.APPLE_CORE_HOSTED_ADMIN_SECRET || !["invite", "revoke", "usage", "pause", "resume"].includes(command) || command !== "invite" && !TENANT.test(tenant ?? "")) {
  console.error("Usage: node admin.mjs invite | revoke|usage|pause|resume TENANT_ID; requires APPLE_CORE_HOSTED_ADMIN_SECRET");
  process.exit(1);
}
const path = command === "invite" ? "/admin/invitations" : `/admin/tenants/${tenant}${command === "usage" ? "/usage" : ["pause", "resume"].includes(command) ? "/pause" : ""}`;
const response = await fetch(`${ORIGIN}${path}`, {
  method: command === "usage" ? "GET" : command === "revoke" ? "DELETE" : "POST",
  ...(["pause", "resume"].includes(command) ? { body: JSON.stringify({ paused: command === "pause" }) } : {}),
  headers: { authorization: `Bearer ${process.env.APPLE_CORE_HOSTED_ADMIN_SECRET}`, "user-agent": "AppleCoreHostedAdmin/2.0" },
  redirect: "error",
  signal: AbortSignal.timeout(30_000),
});
if (!response.ok) { console.error(`Hosting returned HTTP ${response.status}`); process.exit(1); }
if (command === "invite") console.log((await response.json()).setup_code);
else if (command === "usage") console.log(JSON.stringify(await response.json(), null, 2));
else console.log(command === "revoke" ? "Hosted connection revoked." : `Hosted connection ${command === "pause" ? "paused" : "resumed"}.`);
