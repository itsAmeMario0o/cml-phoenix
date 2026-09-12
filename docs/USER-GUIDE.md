# Using the lab

Welcome. You have been given an account on a Cisco Modeling Labs server
that runs on demand. You reach it entirely through your browser, with no
VPN to connect and nothing to install.

## What you need

- A Cisco email address that the lab owner has added to the access list.
- A CML password, which the owner will share with you directly rather
  than by email.

Your email serves as both the key to the front door and your CML
username, so you will sign in twice with the same address: first to
Cloudflare, then to CML.

## Getting in

1. Open **https://lab.rooez.com** in your browser.
2. Cloudflare will ask for your email. Enter the Cisco address the owner
   added. If the address is not on the list, you will see a "not
   authorized" page and cannot continue, so confirm with the owner first
   if you are unsure.
3. Cloudflare then emails you a one-time code. Copy it from your inbox and
   paste it back into the browser. If it does not arrive within a minute,
   please check your spam folder.
4. You will arrive at the CML login page. Sign in using that **same
   email** as your username, along with the password the owner shared
   with you.

That completes sign-in. The Cloudflare session lasts about a day, so a
return visit usually takes you straight to CML.

## Once you are in

You will see the labs the owner has shared with you. Open one, start its
nodes, and open a console on any node to begin working. Allow the switches
and firewalls a few minutes to finish booting before you expect them to
respond.

You can start, stop, and use the shared labs, though you cannot delete
them or change their wiring, which keeps any single lab safe for everyone
who shares it. If you would like a lab of your own to modify freely,
please ask the owner.

## When something is off

- **"Not authorized" from Cloudflare.** Your email is not yet on the
  access list. Ask the owner to add it.
- **The code never arrives.** Check your spam folder, then confirm with
  the owner that they used the correct address.
- **CML rejects your login.** Your username is your full email address,
  not just the portion before the @. If that is correct, the password may
  be wrong, so check with the owner.
- **No labs are listed.** The owner has not shared any with you yet.

## For the lab owner

The two doors are configured separately. `scripts/70-users.sh` creates the
CML accounts from `config/mcp-env/users.csv`, grants every lab to each
non-admin user, and prints the list of emails for the Cloudflare access
policy. Add those emails to the policy in the Cloudflare Zero Trust
dashboard before anyone attempts to log in. The connector and the policy
are documented in `docs/ACCESS.md`, and the user script is covered by
ADR 0007.
