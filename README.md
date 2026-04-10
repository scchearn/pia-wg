# pia-wg

A simple command-line tool for connecting to [Private Internet Access](https://www.privateinternetaccess.com/) VPN on Linux, using WireGuard and NetworkManager — no PIA app required.

## Why?

The official PIA app works, but it runs a background daemon, manages its own network interfaces, and can conflict with how the rest of your system handles networking. This tool does the same job by talking directly to PIA's API and handing the connection off to NetworkManager, which is already managing your network.

## Requirements

- Linux with NetworkManager
- `wireguard-tools` (`wg` command)
- `curl`
- `jq`
- A PIA account

Install dependencies on Arch/Manjaro:
```sh
sudo pacman -S wireguard-tools curl jq
```

On Ubuntu/Debian:
```sh
sudo apt install wireguard-tools curl jq
```

## Quick start

**1. Download the script and certificate:**

```sh
sudo mkdir -p /usr/local/lib/pia
sudo curl -o /usr/local/lib/pia/pia-wg.sh \
  https://raw.githubusercontent.com/scchearn/pia-wg/main/pia-wg.sh
sudo curl -o /usr/local/lib/pia/ca.rsa.4096.crt \
  https://raw.githubusercontent.com/scchearn/pia-wg/main/ca.rsa.4096.crt
sudo chmod +x /usr/local/lib/pia/pia-wg.sh
sudo ln -sf /usr/local/lib/pia/pia-wg.sh /usr/local/bin/pia-wg
```

**2. Add your credentials:**

```sh
sudo mkdir -p /etc/pia
sudo bash -c 'cat > /etc/pia/credentials <<EOF
PIA_USER=p1234567
PIA_PASS=yourpassword
PREFERRED_REGION=pt
EOF'
sudo chmod 600 /etc/pia/credentials
sudo chown root:root /etc/pia/credentials
```

Replace `p1234567` and `yourpassword` with your PIA login. `PREFERRED_REGION` sets your default server location — see [Regions](#regions) below.

**3. Connect:**

```sh
sudo pia-wg --region pt
```

That's it. Your VPN connection will appear in NetworkManager like any other connection.

---

## Usage

```sh
sudo pia-wg --region <id>        # connect to a specific region
sudo pia-wg --auto               # connect to the lowest latency region
sudo pia-wg --down               # disconnect
sudo pia-wg --list               # list all available regions
sudo pia-wg --latency            # list regions sorted by speed
sudo pia-wg --help               # full usage reference
```

## Regions

Run `sudo pia-wg --list` to see all available regions and their IDs.

To find the fastest server near you:

```sh
sudo pia-wg --latency
```

Set a default in `/etc/pia/credentials` so you don't need to pass `--region` every time:

```
PREFERRED_REGION=pt
```

Or override it on the fly:

```sh
sudo pia-wg --region swiss
```

## Port forwarding

Some regions support port forwarding, which is useful for torrenting or hosting services through the VPN. To see which regions support it:

```sh
sudo pia-wg --list --pf
```

To connect with port forwarding enabled:

```sh
sudo pia-wg --region us_chicago --port-forward
```

The assigned port will be shown after connecting. A keepalive process runs in the background to maintain it — PIA requires a refresh every 15 minutes or the port is released.

Check status at any time:

```sh
sudo pia-wg --pf-status
```

Disconnecting with `--down` automatically stops the keepalive.

## Dedicated IP

If you have a PIA dedicated IP subscription, pass your DIP token instead of a region:

```sh
sudo pia-wg --dip DIP1a2b3c4d5e6f...
```

## How it works

Each time you connect, the tool:

1. Fetches an authentication token from PIA (reused for up to 20 hours)
2. Selects a server for your chosen region
3. Generates a fresh WireGuard key pair and registers it with PIA's API
4. Writes a WireGuard config and imports it into NetworkManager
5. Brings up the connection

The key pair is ephemeral — a new one is generated on every connect. This is how PIA's WireGuard API works.

## IPv6

PIA's WireGuard implementation does not support IPv6. If IPv6 is enabled on your system, `pia-wg` will warn you at connect time, as IPv6 traffic could bypass the VPN tunnel. To disable it:

```sh
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

To make it permanent, add those lines to `/etc/sysctl.d/99-disable-ipv6.conf`.

## License

MIT
