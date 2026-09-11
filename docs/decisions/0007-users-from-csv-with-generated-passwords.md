# 0007: CML users from a gitignored CSV, one generated password each

Status: accepted, 2026-09-10. Revised 2026-09-11: the CSV is keyed on
email, and every user is given every lab.

## Context

Every rebuild wipes the controller's users. People need accounts: peers
who want admin rights, and colleagues who just want to open the labs and
try things. The operator needs the passwords afterwards to hand out, and
neither the CSV nor the passwords may be committed.

Two facts settled the shape. A person logs in to CML with the same email
Cloudflare Access checked at the front door, so the email is the CML
username, not a separate handle. And the point of the accounts is to let
people into the labs, so creating a user should also grant the labs, not
leave that as a second manual step.

## Decision

- Input is `config/mcp-env/users.csv`, columns email, fullname, role.
  The email is the CML username and the Access identity. role is admin
  or user. The mcp-env directory already ignores everything, so no
  `.gitignore` edit; `config/users.csv.example` is tracked.
- `scripts/70-users.sh` reads the controller login from `cml.env` and
  hands the CSV to `scripts/lib/users.py`, which creates each missing
  user with a 16 character alphanumeric password from the `secrets`
  module. Users that exist are not touched, so a rerun after every
  build never resets a password someone changed.
- Every non-admin user joins one managed group (`LAB_GROUP`, default
  `lab-users`), and that group holds a permission (`LAB_PERMISSION`,
  default `lab_exec`) on every lab on the controller. So a user sees
  every lab in the kit, and importing a new lab then rerunning grants it
  to everyone. Admins get no grant; CML shows an admin all labs. The
  grant is set on the group object (`PATCH /groups/{id}` with
  `associations`), which is one write for all labs. A member sees the
  shared labs under `GET /labs?show_all=true`, which the web UI uses.
- Passwords go to `config/mcp-env/users-credentials.csv`, mode 0600,
  overwritten only when a run created at least one user. They never
  appear on stdout.
- `scripts/70-users.sh class NAME COUNT DOMAIN` prints rows for a
  synthetic class, name01@domain to nameNN@domain, all plain users, for
  the operator to append to the CSV.
- The script ends by printing every email in the CSV, because the
  Cloudflare Access policy is the other door and is still edited by hand
  (ACCESS.md, "Adding a person"; the end-user walkthrough is
  `docs/USER-GUIDE.md`).

## Consequences

- Handing out credentials is: run the script, open the sheet, send each
  person their line, and add their emails to the Access policy. A
  rebuild means new passwords for everyone, a nuisance for a peer who
  can change theirs in CML, which the script will not reset.
- Everyone with a `user` role shares the same lab objects. If two people
  edit the same running lab they collide; `lab_exec` lets them start,
  stop, and use consoles but not restructure the topology, which keeps
  the collisions mild. Someone who wants a lab to take apart gets their
  own copy, cloned by hand for now. Raising `LAB_PERMISSION` to
  `lab_edit` is possible and makes the collisions worse.
- The CML username caps at 32 characters, which every Cisco CEC address
  fits. A longer address is refused with a clear message rather than a
  raw API error.

## Options considered

1. Static password per row, and a separate manual lab grant. Rejected:
   a secret in the input file, and a second step everyone forgets.
2. A group per class named in the CSV. Rejected as more than this needs.
   One managed group that holds every lab covers "let them all in".
3. Email-keyed CSV, generated passwords, one group with every lab.
   Chosen.
