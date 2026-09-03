# cml-phoenix

An on-demand Cisco Modeling Labs instance in Azure that is built and
destroyed per session. Reference platform images and lab exports survive on
a persistent data disk and blob storage, so a rebuild costs minutes, not an
afternoon.

- Design: `docs/superpowers/specs/2026-09-02-cml-azure-lab-design.md`
- What you need before the first build: `docs/PREREQUISITES.md`
- How the work is organized for Claude Code: `CLAUDE.md`
- Current state: `docs/STATUS.md`

Built on [CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml)
through a lightly patched fork, pinned as a submodule. Driven from the Mac
with [cml-mcp](https://github.com/xorrkaz/cml-mcp).
