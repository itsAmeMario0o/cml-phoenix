# Reaching the lab by name, with a trusted certificate

This guide puts a hostname and a valid certificate in front of the CML web
interface, without opening anything in Azure and at no cost. The worked
example is Cloudflare, the DNS provider this lab uses, but the pattern is
any zero trust front door: an agent on the controller dials out to the
provider, the provider terminates TLS with a real certificate and checks
who you are, then forwards the request to the local nginx.

Nothing in the repo needs it. The scripts and cml-mcp reach the controller
through the `cml` SSH forward (ADR 0012), and that does not change. The
front door is a second, browser-only way in.

## When you want it

- The browser warning bothers you. The controller's certificate is
  self-signed and CML regenerates it on a timer, so a real one on the box
  is fiddly. Through the provider you never install one.
- You are on a VPN whose exit addresses change. The NSG allow-list still
  gates SSH and the scripts, but the browser path stops depending on it.
- You want a login before the CML login, and the public IP out of DNS.

If all you want is a name, add a plain A record for the public IP at your
provider, DNS only, no proxy, and stop here. The warning stays. A proxied
record does not work, because the NSG only admits your own addresses.

## What runs where

The connector, `cloudflared`, runs on the controller as a systemd service
from Cloudflare's Debian package. It only dials out, so the NSG and
firewalld do not change. It is not run as a container: CML 2.10 manages
the host's Docker for its own container nodes, and a foreign container
would sit inside CML's housekeeping.

The controller is rebuilt every session, so the connector is reinstalled
after every `scripts/20-up.sh`. The tunnel, its hostname, and the Access
policy live in Cloudflare and survive.

## One-time setup in Cloudflare

You need a Cloudflare zone for the name and a Zero Trust account on the
free plan, on the same login.

### 1. Create the tunnel

Zero Trust dashboard, Networks, Tunnels & Mesh, create a tunnel of type
cloudflared, named for example `cml-lab`. On the install page pick Debian,
64-bit. The command it shows ends in a long token after `service install`.
Copy only the token and store it where nothing tracked can see it:

    umask 077
    printf 'CLOUDFLARE_TUNNEL_TOKEN=%s\n' '<token>' > config/mcp-env/cloudflare-tunnel.env

Everything under `config/mcp-env/` is gitignored. Never paste the token
into a tracked file, a commit message, or a chat.

### 2. Point the tunnel at CML

In the tunnel, open Published application routes (older layouts call it
Public Hostname) and add one:

| Field | Value |
|---|---|
| Subdomain | `lab` |
| Domain | your zone |
| Service type | HTTPS |
| URL | `localhost:443` |

Under Additional application settings, TLS, turn on No TLS Verify; that is
the switch that accepts the self-signed origin. Save. Cloudflare creates
the proxied DNS record. If an A record with that name already exists,
delete it first, or the save fails.

### 3. Put a login in front

Zero Trust, Access controls, Applications, Add an application,
Self-hosted. Name it, set the domain to the same name, and add an Allow
policy whose include rule is the Emails selector with each person's exact
address. One-time PIN to that address is on by default and needs no
identity provider. Save.

## After every CML build: install the connector

Do this after `scripts/20-up.sh` and `scripts/50-tunnels.sh up`, every
time. The sudo password on the host is the persistent root's
`sys_admin_password` output and the token is in
`config/mcp-env/cloudflare-tunnel.env`; both travel over stdin and neither
appears on a command line or in shell history. Run from the repo root:

    IP="$(terraform -chdir=terraform/persistent output -raw public_ip_address)"
    {
      terraform -chdir=terraform/persistent output -raw sys_admin_password; echo
      sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' config/mcp-env/cloudflare-tunnel.env
    } | ssh -p 1122 -i keys/cml-lab -o UserKnownHostsFile=keys/known_hosts sysadmin@"$IP" '
      IFS= read -r PW; IFS= read -r TOKEN
      curl -fsSL -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
      printf "%s\n" "$PW" | sudo -S dpkg -i /tmp/cloudflared.deb
      printf "%s\n" "$PW" | sudo -S cloudflared service install "$TOKEN"
      sleep 10
      printf "%s\n" "$PW" | sudo -S journalctl -u cloudflared --no-pager | grep "Registered tunnel connection"'

It worked when the last command prints four "Registered tunnel connection"
lines. The journal also shows two warnings about ping groups and an ICMP
proxy; ignore them, the tunnel carries HTTPS. The service keeps the token
in `/etc/cloudflared/token`, root only, on the disposable VM.

Then check from the outside:

- The tunnel Overview shows Healthy, and its Connectors list shows
  `cml-controller` as Connected. If the journal says "No ingress rules
  were defined", step 2 was not saved.
- `dig +short lab.<zone>` returns Cloudflare addresses. If it returns the
  lab IP, the old A record is still there.
- The browser gets the Access one-time PIN page, then the CML login, with
  a valid padlock. Node consoles use websockets, which Cloudflare carries.

The certificate is Let's Encrypt for the zone, renewed by Cloudflare.

## Adding a person

Two doors, and both must open. Their email goes into the Access policy of
step 3, as an exact address under the Emails selector. Their CML account
comes from `scripts/70-users.sh` (ADR 0007), which prints the email list
for the policy. A person with a CML account and no policy entry gets
Cloudflare's not-authorized page; one with a policy entry and no CML
account gets nowhere past the CML login. They use the name, never the IP,
because the NSG admits only the operator's addresses. The page to hand
them is https://itsamemario0o.github.io/cml-phoenix/, published from
`docs/index.html`; `docs/USER-GUIDE.md` is the same text.

## Limits and what stays on the IP

- The free plan caps a request at 100 MB, so images go over the IP or
  SCP, never through the name.
- `CML_URL` in `config/mcp-env/cml.env` stays on the IP and `CML_API_BASE`
  on the forward. Access would block cml-mcp at the name.
- SSH on 1122 and Cockpit on 9090 stay on the IP behind the NSG.

## Undo

Delete the Access application and the tunnel in the dashboard, remove the
DNS record it created, and put the plain A record back if you still want
a name. On the host, `sudo cloudflared service uninstall`, or wait for
the next teardown.
