# Hosted beta containment verification, September 9, 2026

Author: Oliver Ames

Source 2fb5a90 was committed and pushed after 20 Hosted tests passed and an
independent review accepted the corrected revocation and fixture-build paths.
The owner explicitly approved deployment of the concrete allowances and CPU
limit. Deployment used keep-vars to preserve receiving settings and secrets.

Receiving Worker version: b4f657e6-9922-4cc0-81ab-cd68bfeb882c.
The version API confirms a 50 ms CPU limit, daily allowance 2,000, monthly
allowance 20,000 and global pause false. Existing encrypted secret bindings
remain present. No secret values were printed or replaced.

Direct Apple Core and ChatGPT Work both passed Notes health after deployment.
Quota exhaustion and pause/resume were exercised only in isolated fixtures,
not against the owner's live installation. The private administrator usage
endpoint was not queried because the installation identifier was unavailable
through the bounded verification route. Do not describe that read as passed.

The suite covers invalid and expired invitations, atomic concurrent quotas,
UTC rollovers, pause persistence, administrative authentication, static pause
and grant revocation during suspension. Production bundle inspection excludes
test-only fixture methods. The separate isolated Swift run passed 37 existing
service policy, filesystem and OAuth tests without launching Apple Core.

These are per-installation controls. They are not an aggregate tenant quota or
an enforced dollar billing cap. Rejected traffic, recovery requests, relay
connections and other account usage remain outside the forwarding allowance.
Do not expand invitations until aggregate controls and actual metered usage
are reviewed. Full read-only and onboarding acceptance remains issue 6, while
cost containment and usage visibility remain issue 10.
