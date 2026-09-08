# Reaching the lab by name, with a trusted certificate

How to put a name and a valid certificate in front of the CML web UI
without opening anything in Azure and without paying. The worked example
is Cloudflare, because that is the DNS provider this lab uses, but the
shape is any zero trust front door: an agent on the controller dials out
to the provider, the provider terminates TLS with a real certificate and
asks who you are, then forwards to the local nginx.

Nothing in this repo needs any of this. The scripts, cml-mcp, the smoke
test, and Terraform's readiness check all talk to the persistent public IP
over 443 with certificate checks off, and they keep doing so after this
procedure. What you get here is a second way in, for a browser.

## When you want it

- The browser warning bothers you. The controller serves a self-signed
  certificate and CML regenerates it on a timer, so installing a real one
  on the box is fiddly. Going through the provider means you never have
  to.
- You are on a VPN whose exit addresses change. The NSG allow-list is
  still needed for SSH and for the scripts, but the browser path no
  longer depends on it. See LESSONS-LEARNED, "SSH to the host times out".
- You want a login before the CML login, and the public IP out of DNS.

If all you want is a name and none of the above, add a plain A record for
the public IP at your provider, DNS only, no proxy, and stop here. The
warning stays, and a proxied record does not work, because the NSG only
admits your own addresses.

## What runs where

The Cloudflare connector, `cloudflared`, runs on the controller as a
systemd service from Cloudflare's Debian package. It only ever dials
out, so nothing changes in the NSG or in firewalld. It does not run as a
container, even though Cloudflare offers one and the host has Docker. CML
2.10 installs that Docker for its own container-based lab nodes and
manages the daemon through its docker shim, so a foreign container would
be living inside CML's housekeeping. A systemd unit has nothing to do
with any of that.

The controller is rebuilt every session, so the connector is reinstalled
after each build. The tunnel itself, its hostname, and the Access policy
live in Cloudflare and survive. The reinstall is three commands and the
same token. Automating it as a post-build step is on the roadmap.

## Procedure, by hand

You need a Cloudflare zone for the name and a Zero Trust account on the
free plan. Both are attached to the same Cloudflare login.

### 1. Create the tunnel

In the Zero Trust dashboard go to Networks, then Tunnels & Mesh, and
create a tunnel of type cloudflared named, for example, `cml-lab`.
Cloudflare renames these menus now and then; in September 2026 the
tunnel page has tabs Overview, CIDR routes, Hostname routes, Published
application routes, and Live logs. On the install
page pick Debian, 64-bit. The command it shows ends in a long token after
`service install`. Copy only the token.

Store it on the Mac where nothing tracked can see it:

    umask 077
    printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\n' '<token>' > config/mcp-env/cloudflare-tunnel.env

Everything under `config/mcp-env/` is gitignored. Never paste the token
into a tracked file, a commit message, or a chat.

### 2. Point the tunnel at CML

Still in the tunnel, open the Published application routes tab, which
older layouts called Public Hostname, and add one:

| Field | Value |
|---|---|
| Subdomain | `lab` |
| Domain | your zone |
| Service type | HTTPS |
| URL | `localhost:443` |

Under Additional application settings, TLS, turn on No TLS Verify. The
origin certificate is self-signed and this is the switch that accepts it.
Save. Cloudflare creates the DNS record for you, proxied. If an A record
with that name already exists, delete it first, or the save fails.

### 3. Put a login in front

Zero Trust, Access controls, Applications, Add an application,
Self-hosted. Name
it, set the domain to the same name, and add an Allow policy whose
include rule is your email address. One-time PIN to that address is on by
default and needs no identity provider. Save.

### 4. Install the connector on the controller

Open a shell on the host. When sudo asks for a password, it wants the
sysadmin password from the persistent root. Print that one only at the
prompt.

    ssh -p 1122 -i keys/cml-lab sysadmin@<public ip>

On the host, read the token into the shell without echoing it, then
install:

    read -rs CLOUDFLARE_TUNNEL_TOKEN
    curl -fsSL -o /tmp/cloudflared.deb \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i /tmp/cloudflared.deb
    sudo cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"
    systemctl is-active cloudflared

The service keeps the token in `/etc/cloudflared/token`, root only. That
is on the disposable VM, which is gone at teardown, so it is fine. The
journal shows two warnings about ping groups and an ICMP proxy at
start. Ignore them; the tunnel carries HTTPS, not ping. The line to
look for is "Registered tunnel connection", four times.

### 5. Verify

- The tunnel Overview shows Healthy, and its Connectors list shows
  `cml-controller` as Connected with the lab's public IP as origin. If the
  journal says "No ingress rules were defined", step 2 was not saved.
- `dig +short lab.<zone>` returns Cloudflare addresses. If it returns the
  lab IP, the old A record is still there.
- The browser gets the Access one-time PIN page, then the CML login, with
  a valid padlock and no warning.
- Open a node console once a lab is running. Consoles use websockets and
  Cloudflare carries them.

Walked once on 2026-09-05 for `lab.rooez.com`. The certificate Cloudflare
serves is Let's Encrypt for the zone, renewed by Cloudflare, nothing to
do. A policy that says "Emails ending in gmail.com" admits every Gmail
user; use the Emails selector with exact addresses for shared domains.

## Adding a person

Two doors, and both must open. Their email goes into the Access policy,
as an exact address under the Emails selector, so Cloudflare lets them
through to the login page. Their CML account is created separately in
the CML web UI or through cml-mcp. A person with a CML account and no
policy entry gets Cloudflare's not-authorized page and never sees CML.
A person with a policy entry and no CML account sees the CML login and
gets nowhere. And they must use the name, never the IP; the NSG admits
only the operator's own addresses. Access sessions last 24 hours by
default, so a second visit shows no prompt.

## After a rebuild

The tunnel shows Down while the VM is gone. After `scripts/20-up.sh`,
repeat step 4 with the same token. Nothing in Cloudflare changes.

## Limits and what stays on the IP

- The free plan caps a request at 100 MB, and a reference platform image
  is several times that. Upload images over the IP or with SCP. The name
  is for driving the lab, not for feeding it.
- Keep `config/mcp-env/cml.env` pointing at the IP. Access would block
  cml-mcp at the name unless it carried a service token, and there is no
  reason to route it that way.
- SSH on 1122 and Cockpit on 9090 stay on the IP behind the NSG. Cockpit
  can be published as a second hostname later if you want it behind
  Access too.
- The NSG allow-list still gates SSH and the scripts. Only the browser
  stops caring about it.

## Undo

Delete the Access application and the tunnel in the dashboard, remove the
DNS record it created, and put the plain A record back if you still want
a name. On the host, `sudo cloudflared service uninstall`, or wait for
the next teardown.
