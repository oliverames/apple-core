# Muse MCP client

Apple Core owns this Muse integration helper at Oliver Ames's direction. It is
source tooling, separate from the Mac application and hosted OAuth server.

`bin/mcp.py` was retrieved from Muse's live `_shared/bin/mcp.py` on September 10,
2026. It preserves the working session-header fix: capture `Mcp-Session-Id`
from the response and resend it on subsequent requests in the same process.
The response parsing and credential handling match the retrieved file.

## Runtime and scope

Run with Python 3.10 or later inside Muse. Muse supplies `dynamic_credentials`
at `/opt/hatch/skills/skill-creator/bin`. That platform module is intentionally
not copied into this repository. It supplies the credential-surrogate exchange
and response reader. Even `--no-auth` currently requires that module to import.

Use a fresh process for each invocation, as Muse's connector wrappers do. The
module-global session is for one endpoint and credential per process. This is
not a reusable multi-server SDK. Session expiry recovery and broader protocol
features are outside this preserved fix.

## Verify

From this directory:

```sh
python3 -m py_compile bin/mcp.py
python3 -m unittest tests.test_mcp_session -v
```

The two tests stub network transport and the Muse platform module. They verify
session capture/resend and a server that omits the session header. No network
or stored credentials are used. CI runs these tests on changes to the repository.

## Install in Muse

Use a checkout of a reviewed Apple Core commit on the Muse VM. Compare this file
with `~/workspace/skills/_shared/bin/mcp.py` first and reconcile any newer local
changes. From the checkout, after review:

```sh
install -m 755 Integrations/Muse/bin/mcp.py "$HOME/workspace/skills/_shared/bin/mcp.py"
```

This copies only the Python client. Leave connector definitions, credentials,
platform modules, and individual skill wrappers intact. The `_shared` directory
is not part of the ames-plugins mirror, so a marketplace update does not install
this helper. Distribution is through this source repository, without a Mac app
version bump or binary release.

For live acceptance, use the existing Apple Core wrapper in a fresh process to
list tools and run `notes_health_check`. Do not print credentials or read note
bodies. Earlier live acceptance and installed Mac build evidence are recorded in
[the OAuth report](../../docs/oauth-connection-id-2026-09-10.md).
