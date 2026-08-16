# Omarchy VPN

A VPN widget for the Omarchy Quattro bar. One icon, one panel, all your tunnels.

![The VPN panel](preview.png)

I run a homelab behind a WireGuard tunnel and PIA for everything else, and I got
tired of squinting at two separate indicators that both lied to me. So: one icon.
Click it, see every tunnel, flip whichever one you need.

Ships with PIA and WireGuard providers. Mullvad, Nord and Proton all run
WireGuard under the hood, so they work too, no code required. Jump to
[Adding your VPN](#adding-your-vpn).

## Why not just cram it into the wifi menu

Because a VPN isn't a network connection, it's a policy sitting on top of one.
Omarchy already agrees with me here, the built-in Tailscale widget is its own
thing too.

## The thing that actually matters

Here's the bug that made me write this.

`wg-quick` is a `Type=oneshot` systemd unit. It flips to "active" the second the
interface exists and the routes get added. It never talks to the peer. Not once.

So if your VPN server is powered off, `systemctl is-active wg-quick@whatever`
says **active**. Forever. Cheerfully. While absolutely nothing goes through the
tunnel. My old status script believed it, and I burned an entire afternoon at a
beach house debugging my laptop, my wifi, and eventually my own sanity, before
discovering the VM running PiVPN had simply been powered off the whole time.

My bar was green for all of it.

This widget reads `rx_bytes` off the interface instead. Zero bytes in means no
handshake ever happened, so the icon goes red. Bytes flowing means you're
actually connected. Groundbreaking, I know.

PIA gets the same treatment for a different reason. When your PIA token expires
the daemon takes a 401, retries a few servers, gives up, and parks at
"Disconnected". Then it stops logging 401s. Check five minutes later and there's
no evidence anything is wrong, and "Disconnected" looks exactly like "you turned
it off". This widget latches it. Once PIA rejects your login it keeps yelling
**LOGGED OUT** until a connection actually succeeds.

The icon always shows the worst state across all your tunnels, so a broken one
can't hide behind a working one.

| Colour | What it means |
|---|---|
| green | connected, bytes moving |
| yellow | was fine, gone quiet (nothing in for 4 min) |
| red | up but no handshake, or PIA is logged out |
| dim | off, on purpose |

## What you need

* Omarchy Quattro (4.x) with `omarchy-shell`
* A Nerd Font for the icon (Omarchy ships one)
* For WireGuard: `wireguard-tools`, plus permission to start and stop the unit.
  Either add a polkit rule for `wg-quick@<iface>.service`, or point
  `connectCommand` / `disconnectCommand` at your own scripts.
* For PIA: the official client (`/opt/piavpn/bin/piactl`). Not installed? The
  PIA section just doesn't show up.

Nothing else. It doesn't install anything, and it never writes to your config.

## Install

```bash
omarchy plugin add https://github.com/Paulie420/omarchy-vpn.git --enable
omarchy bar move paulie420.vpn --section right
```

## Uninstall

```bash
omarchy plugin remove paulie420.vpn
```

That deletes the folder. If you added a `paulie420.vpn` block to your
`shell.json`, delete that too. The plugin won't touch your config, which also
means it can't clean up after itself.

## Config

Everything lives in this widget's entry in `~/.config/omarchy/shell.json`, and
all of it is optional.

```jsonc
{
  "id": "paulie420.vpn",
  "refreshIntervalSec": 5,

  "pia": { "enabled": true, "label": "PIA" },

  // one object, or a list of them
  "wireguard": [{
    "enabled": true,
    "label": "Homelab",
    "interface": "wg0",

    // Leave these empty and it runs systemctl start/stop wg-quick@<interface>.
    // Set them if your VPN has its own CLI, or if connecting needs to do more
    // than raise the interface. Mine drops PIA first and puts it back after.
    "connectCommand": "",
    "disconnectCommand": "",

    // Optional. Something living behind the tunnel. The panel tells you whether
    // it's reachable while you're connected. Mine points at the NAS.
    "reachabilityHost": ""
  }]
}
```

Heads up: `omarchy plugin disable` followed by `enable` resets this entry to a
bare `{"id": "paulie420.vpn"}`. Not my doing, but it will eat your settings, so
keep a copy somewhere.

## Adding your VPN

### Most of them need zero code

Mullvad, NordVPN and Proton are all WireGuard underneath. Point the WireGuard
provider at the right interface, hand it the vendor's CLI, done. And since
`wireguard` takes a list, stack as many as you want:

```jsonc
"wireguard": [
  { "label": "Homelab", "interface": "wg0", "reachabilityHost": "192.168.1.10" },

  { "label": "Mullvad", "interface": "wg0-mullvad",
    "connectCommand": "mullvad connect",
    "disconnectCommand": "mullvad disconnect" }
]
```

Starting points below, but **go check the interface name yourself**. Vendors
love renaming these between releases.

| VPN | Interface (usually) | Connect | Disconnect |
|---|---|---|---|
| Mullvad | `wg0-mullvad` | `mullvad connect` | `mullvad disconnect` |
| NordVPN (NordLynx) | `nordlynx` | `nordvpn connect` | `nordvpn disconnect` |
| Proton | `proton0` | `protonvpn-cli connect` | `protonvpn-cli disconnect` |
| plain `wg-quick` | `wg0` | *(leave blank, it uses systemctl)* | |

To find yours, connect the VPN however you normally do, then:

```bash
ip -br link      # your new interface shows up while connected
wg show          # anything WireGuard-based lists itself here
```

Whatever appears is your `interface`.

### When you actually have to write code

Only if your VPN isn't WireGuard-based, or it knows things the generic provider
can't see. That's why PIA has its own file. It reports a region, a protocol, and
that expired-login state that otherwise looks identical to "switched off".

A provider is one QML file with this shape:

```
Properties  enabled  label  connected  busy  rxBytes  txBytes
            severity   "ok" | "warn" | "error" | "off"
            stateText  short line, like "Connected"
            hintText   optional, shown when something's broken

Functions   connectVpn()  disconnectVpn()  toggle()  refresh()
```

Drop `MyVpnProvider.qml` next to the others, declare it in `BarWidget.qml`
beside `PiaProvider`, add it to the `providers` list. That's the whole job.

### Or just have an AI write it

Honestly, great job to hand off. The contract is tiny and there are two working
examples sitting right there. Paste this at your assistant of choice:

> I'm writing a provider for the Omarchy `paulie420.vpn` bar widget.
> Read `WireGuardProvider.qml` and `PiaProvider.qml` in this repo first, they
> define the interface I need to implement.
>
> Write `<Name>Provider.qml` for **<your VPN>**. It connects with
> `<connect command>`, disconnects with `<disconnect command>`, and I can check
> status using `<status command>`, which prints `<paste the real output>`.
>
> Rules:
> - Root is `Item { visible: false }`, imports `QtQuick` and `Quickshell.Io`.
> - Get all state in ONE `Process` per `refresh()`, using
>   `stdout: StdioCollector { waitForEnd: true; onStreamFinished: ... }`.
> - Do NOT use `FileView` on `/sys/class/net/...`. Those paths vanish when the
>   tunnel drops and the watcher never recovers.
> - Expose exactly: enabled, label, connected, busy, rxBytes, txBytes,
>   severity, stateText, hintText, and
>   connectVpn/disconnectVpn/toggle/refresh.
> - `severity` must be "error" when the VPN claims it's up but nothing is
>   coming through. Never trust systemd's "active" as proof of a live tunnel.
>
> Then show me the `shell.json` entry to add.

That last rule is the entire reason this widget exists, so don't let it skip it.

Check whatever it hands you before trusting it:

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" <Name>Provider.qml
omarchy-shell shell rescanPlugins
qs log -p "$OMARCHY_PATH/shell" --tail 100   # QML only complains at load time
```

**Got one working? Send a PR.** I'd love to ship more providers, and I only own
the two VPNs I actually pay for.

## Privacy

Address and traffic rows stay hidden while a tunnel is down. With the VPN off,
"Public IP" is your real address, and there's no reason to paint that on your
screen where it'll land in the first screenshot you post. Ask me how I know.

The plugin makes no network calls of its own. It shells out to `systemctl`,
`wg`, `piactl` and `ping`, and reads local files. That's the entire attack
surface.

## Who made this

I'm paulie420. I run a homelab, a BBS, and [techheart.life](https://techheart.life),
and I put the builds and the debugging up on YouTube at
**[@techheart6090](https://youtube.com/@techheart6090)**.

If you want to watch the kind of afternoon that produces a widget like this,
that's where it lives. Come hang out.

## Licence

MIT, see [LICENSE](LICENSE). Take it, fork it, ship it, sell it, whatever.
