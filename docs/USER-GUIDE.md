# Using the lab

The lab owner has given you an account on a Cisco Modeling Labs server.
You reach it through a browser. There is no VPN and nothing to install.

## What you need

- A Cisco email address that the lab owner has added to the access list.
- A CML password, which the owner gives you offline, never by email.

Your email is both the key to the front door and your CML username, so
you sign in twice with the same address: once to Cloudflare, once to CML.

## Getting in

1. Open **https://lab.rooez.com** in a browser.
2. Cloudflare asks for your email. Enter the Cisco address the owner
   added. If it is not on the list you get a "not authorized" page and
   go no further, so check with the owner first.
3. Cloudflare emails you a one-time code. Open your inbox, copy the
   code, paste it back in the browser. If it does not arrive in a minute,
   look in spam.
4. You land on the CML login page. Sign in with the **same email** as
   the username and the password the owner shared with you.

That is it. The Cloudflare login lasts a day, so a second visit usually
skips straight to CML.

## Once you are in

You see the labs the owner has shared. Open one, start its nodes, and
open a console on any node to work with it. Give the switches and
firewalls a few minutes to boot.

You can start, stop, and use the shared labs. You cannot delete them or
change their wiring, so nobody can break a lab for everyone else. If you
want a lab of your own to take apart, ask the owner.

## When something is off

- **"Not authorized" from Cloudflare.** Your email is not on the access
  list. Ask the owner to add it.
- **The code never arrives.** Check spam, then confirm with the owner
  that they used the right address.
- **CML rejects your login.** The username is your full email, not just
  the part before the @. If that is right, the password may be wrong;
  ask the owner.
- **No labs are listed.** The owner has not shared any with you yet.

## For the lab owner

The two doors are set up separately. `scripts/70-users.sh` creates the
CML accounts from `config/mcp-env/users.csv` and grants every lab to
each non-admin user, and prints the email list for the Cloudflare access
policy. Add those emails to the policy, in the Cloudflare Zero Trust
dashboard, before people try to log in. The connector and the policy are
described in `docs/ACCESS.md`; the user script is ADR 0007.
