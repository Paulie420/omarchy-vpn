# Omarchy VPN

Multi-provider VPN status and control for the [Omarchy](https://omarchy.org/) bar.

One icon, one panel, every tunnel. Each provider gets its own section showing
connection state, region/endpoint, live traffic counters and an on/off switch.
Ships with **PIA** (Private Internet Access) and **WireGuard** providers.

![The VPN panel](preview.png)

## Why a separate widget

A VPN is not a network *connection* — it is a policy layered over one, so it
does not belong inside the Wi-Fi panel. Omarchy agrees: the built-in
`omarchy.tailscale` is a separate bar widget too.

## What it gets right

Two failure modes drove the design, both learned the hard way:

**WireGuard liveness is judged by `rx_bytes`, never `systemctl is-active`.**
`wg-quick` is a `Type=oneshot` unit — it reports *active* the moment the
interface and routes exist, **without ever contacting the peer**. A tunnel whose
server is powered off therefore reports "active" forever. This widget reads
`/sys/class/net/<iface>/statistics/rx_bytes`: zero means no handshake has ever
completed, and the icon goes red instead of green.

**An expired PIA login is latched, not sampled.** When PIA's stored token
expires the daemon gets HTTP 401 (`ApiUnauthorizedError`), retries a few
servers, gives up, and then sits at `Disconnected` — and stops logging new
401s. A time-windowed check forgets the login problem after a few minutes and
shows a bland "Disconnected", which is exactly when you go looking for why it
will not connect. Once a rejection has been seen the panel keeps saying
**LOGGED OUT** until a connection genuinely succeeds.

The bar icon shows **worst-case severity** across all providers, so one broken
tunnel is never hidden behind a healthy one.

| Colour | Meaning |
|---|---|
| green | connected and carrying traffic |
| yellow | answered before, now gone quiet (>240s) |
| red | up but no handshake, or PIA logged out |
| dim | deliberately off |

## Requirements

- Omarchy **Quattro** (4.x) with `omarchy-shell`
- A Nerd Font for the bar glyph (Omarchy ships one)
- **WireGuard provider:** `wireguard-tools`, and permission to start/stop the
  unit. Either a polkit rule for `wg-quick@<iface>.service`, or point
  `connectCommand`/`disconnectCommand` at your own wrapper scripts.
- **PIA provider:** the official PIA client (`/opt/piavpn/bin/piactl`). The
  provider is hidden automatically when it is not installed.

No other dependencies. Nothing is installed, and no configuration is written.

## Install

```bash
omarchy plugin add https://github.com/paulie420/omarchy-vpn.git --enable
omarchy bar move paulie420.vpn --section right
```

## Remove

```bash
omarchy plugin remove paulie420.vpn
```

That deletes the plugin folder. If you added a `paulie420.vpn` block to
`~/.config/omarchy/shell.json`, delete that entry too — the plugin never
edits your configuration itself.

## Configure

All settings live in this widget's entry in `~/.config/omarchy/shell.json`.
Everything is optional; the defaults assume a PIA install and a WireGuard
interface named `pivpn`.

```jsonc
{
  "id": "paulie420.vpn",
  "refreshIntervalSec": 5,

  "pia": {
    "enabled": true,
    "label": "PIA"
  },

  "wireguard": {
    "enabled": true,
    "label": "PiVPN",
    "interface": "pivpn",

    // Optional. When set, these run instead of `systemctl start/stop
    // wg-quick@<interface>`. Useful when connecting has to do more than raise
    // the interface -- e.g. dropping another VPN first and restoring it after.
    "connectCommand": "",
    "disconnectCommand": "",

    // Optional. A host behind the tunnel; the panel reports whether it is
    // reachable while connected.
    "reachabilityHost": ""
  }
}
```

> **Note:** `omarchy plugin disable` followed by `enable` rewrites this entry
> back to a bare `{"id": "paulie420.vpn"}`, discarding the settings above.
> Re-add them afterwards.

## Adding another VPN

Providers are self-contained QML components exposing one interface:

```
enabled  label  connected  severity  stateText  hintText  busy  rxBytes  txBytes
connectVpn()  disconnectVpn()  toggle()  refresh()
```

`severity` is one of `ok` / `warn` / `error` / `off`. To add a provider, drop a
new `*Provider.qml` beside the others implementing that interface, then declare
it in `BarWidget.qml` alongside `PiaProvider` and `WireGuardProvider` and add it
to the `providers` list.

Providers poll rather than watch files. That is deliberate: an earlier version
used `FileView` on `/sys/class/net/<iface>/statistics/*`, and those paths vanish
when a tunnel drops, so the watcher's load failed and never re-resolved when the
interface came back — the panel stuck on "Interface missing" after the first
disconnect. A short poll is correct across any number of up/down cycles.

## Development

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml PiaProvider.qml WireGuardProvider.qml
omarchy-shell shell rescanPlugins
```

## Privacy

Address and traffic rows are hidden while a provider is disconnected — with the
tunnel down, "Public IP" is your **real** address, and showing it as though it
were a VPN property leaks it into any screenshot of the panel.

The plugin makes no network requests of its own. It only runs local commands
(`systemctl`, `wg`, `piactl`, `ping`) and reads local files.

## Licence

MIT — see [LICENSE](LICENSE). Use it, change it, ship it, however you like.
