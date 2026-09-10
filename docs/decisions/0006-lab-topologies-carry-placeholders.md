# 0006: Tracked lab topologies carry placeholders, rendered at import

Status: accepted, 2026-09-10

## Context

A CML topology YAML holds each node's day-0 configuration: NX-OS CLI for
the switches, cloud-init for the Ubuntu hosts. Both need a password, and
the source lab this started from had `C1sco12345` written into every
node. This repo never commits a password (CLAUDE.md, ADR 0004), and the
`labs/` folder is tracked so that a topology can be reviewed and reused
across rebuilds.

The kit already renders `config/cml.yml` from a template and gitignored
inputs. Topologies are the same problem one level down.

## Decision

- Files under `labs/` use `__LAB_PASSWORD__` wherever a password goes
  and `__LAB_SSH_PUBKEY__` wherever an authorized key goes. Nothing else
  is templated. One password covers every user in a lab, because the
  lab is disposable and nobody is here to practise account management.
- `scripts/lib/render_lab.py` fills the two placeholders. The password
  comes from the environment, the key from `keys/cml-lab.pub`, the same
  key that opens the CML host. It refuses to run with an empty password
  and refuses to emit a file that still has any `__NAME__` in it.
- `scripts/60-import-lab.sh` reads `config/mcp-env/labs.env` for the
  password and `cml.env` for the controller, renders into
  `exports/.rendered/` with mode 0600, and posts the result to
  `/api/v0/import`. The rendered copy is gitignored with the rest of
  `exports/` and stays around for a manual import through the UI.
- A unittest walks every file in `labs/` and fails on a known default
  password, on a password line without the placeholder, or on a
  topology that does not render.

## Consequences

- Importing a lab is one command after a build. cml-mcp still drives the
  lab once it exists. It just never has to carry the password through a
  chat session.
- The rendered file on disk holds the password in clear text, like
  `cml.env` does today. Same directory conventions, same exposure.
- A second lab that needs a value the two placeholders do not cover
  extends the renderer rather than inventing a new mechanism.

## Options considered

1. Commit the topology with a well-known lab password and call it
   non-secret. Rejected. It is still a credential on a box that can be
   reached through the front door, and the rule has no exceptions.
2. Substitute at import time through cml-mcp, passing the password as a
   tool argument. Rejected. The value would pass through the chat
   transcript, which is exactly what ADR 0004 and the mcp-env directory
   were built to avoid.
3. Placeholders plus a small renderer that reuses the existing gitignored
   directories. Chosen.
