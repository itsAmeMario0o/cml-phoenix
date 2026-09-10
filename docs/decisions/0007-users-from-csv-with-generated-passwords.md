# 0007: CML users from a gitignored CSV, one generated password each

Status: accepted, 2026-09-10

## Context

Every rebuild wipes the controller's users. Two kinds of people need
accounts: peers who work on the kit with me and want admin rights, and
students in a class of about ten who need plain accounts in one group.
Either way the operator needs the passwords afterwards to hand out, and
neither the CSV nor the passwords may be committed.

The 2026-09-08 decision (roadmap item 6) had a static temporary
password in the CSV. Writing the script changed that: generating the
password keeps the input file free of secrets, and the output sheet is
what gets handed out anyway.

## Decision

- Input is `config/mcp-env/users.csv`, columns username, email,
  fullname, role, group. The directory already ignores everything, so
  no `.gitignore` edit. `config/users.csv.example` is tracked.
- `scripts/70-users.sh` reads the controller login from `cml.env` and
  hands both files to `scripts/lib/users.py`, which creates missing
  groups, then missing users, each with a 16 character alphanumeric
  password from the `secrets` module. Users that exist are not touched,
  so the script is safe to rerun after every build and never resets a
  password someone has changed.
- Passwords go to `config/mcp-env/users-credentials.csv`, mode 0600,
  overwritten only when a run created at least one user. They never
  appear on stdout.
- `scripts/70-users.sh class NAME COUNT [DOMAIN]` prints rows for a
  class, name01 to nameNN, plain users in a group named after the
  class. The operator appends them to the CSV.
- The script ends by printing every email in the CSV, because the
  Cloudflare Access policy is the other door and is still edited by
  hand (ACCESS.md, "Adding a person").

## Consequences

- Handing out credentials is: run the script, open the sheet, send each
  person their line. A rebuild means new passwords for everyone, which
  is a feature for a class and a nuisance for a peer. Peers can change
  theirs in CML, and the script will not reset it.
- Lab permissions are not in the CSV. A group or user with rights on
  a lab is set in the UI or with a PATCH on the lab's associations
  after the lab exists; the cml-mcp tool for it is broken in 0.31.2
  (LESSONS-LEARNED).
- A row without an email creates a working CML account that cannot get
  past the Access login. The script warns rather than refuses, since a
  class may be run on the IP inside the allow-list.

## Options considered

1. Static password per row in the CSV, as first decided. Rejected once
   the script existed: it puts a secret in the input file for no gain.
2. One shared class password. Rejected. It stops nobody from logging in
   as someone else and makes the sheet pointless.
3. Generated per user, written to a private sheet. Chosen.
