#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Set APPLE_CORE_HOSTED_ADMIN_SECRET through a secret manager, never an argument.
import { ORIGIN, TENANT } from "./protocol.mjs";

const [command, tenant] = process.argv.slice(2);
if (!process.env.APPLE_CORE_HOSTED_ADMIN_SECRET || !["invite", "revoke"].includes(command) || command === "revoke" && !TENANT.test(tenant ?? "")) {
  console.error("Usage: node admin.mjs invite | revoke TENANT_ID; requires APPLE_CORE_HOSTED_ADMIN_SECRET");
  process.exit(1);
}
const response = await fetch(`${ORIGIN}${command === "invite" ? "/admin/invitations" : `/admin/tenants/${tenant}`}`, {
  method: command === "invite" ? "POST" : "DELETE",
  headers: { authorization: `Bearer ${process.env.APPLE_CORE_HOSTED_ADMIN_SECRET}`, "user-agent": "AppleCoreHostedAdmin/2.0" },
  redirect: "error",
  signal: AbortSignal.timeout(30_000),
});
if (!response.ok) { console.error(`Hosting returned HTTP ${response.status}`); process.exit(1); }
if (command === "invite") console.log((await response.json()).setup_code);
else console.log("Hosted connection revoked.");
