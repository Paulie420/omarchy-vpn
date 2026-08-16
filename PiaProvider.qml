import QtQuick
import Quickshell.Io

// Private Internet Access provider, driven by `piactl`.
//
// The important behaviour here is the LOGGED-OUT LATCH. When PIA's stored auth
// token expires the daemon gets HTTP 401 (ApiUnauthorizedError) from the API,
// retries a few servers, then gives up and sits at Disconnected -- and stops
// logging new 401s. A purely time-windowed check would therefore forget the
// login problem after a few minutes and show a bland "Disconnected", which is
// exactly when you go looking for why it will not connect. Once we have seen
// PIA reject the credentials we keep saying so until a connection succeeds.
//
// Auth happens before protocol selection, which is why an expired token fails
// identically on WireGuard and OpenVPN.

Item {
  id: root
  visible: false

  // ---- configuration -------------------------------------------------
  property string label: "PIA"
  // Identity color for the bar icon and the panel's legend dot. Set by
  // BarWidget from the `color` setting, or from the generated hue ring.
  property color identityColor: "#8ab4f8"
  property bool enabled: true
  property string piactl: "/opt/piavpn/bin/piactl"
  property string daemonLog: "/opt/piavpn/var/daemon.log"

  // ---- observed state ------------------------------------------------
  property bool installed: true
  property string connectionState: "Unknown"
  property string region: ""
  property string protocol: ""
  property string tunnelIp: ""

  // `piactl get pubip` lags the connection. For several seconds after the
  // tunnel comes up it still reports the address you had BEFORE it did --
  // your real one -- while `connectionstate` already says Connected. Gating
  // the panel on `connected` alone is therefore not enough, and it is exactly
  // how this project's own preview screenshot ended up with the author's home
  // IP in it.
  //
  // So: remember any address seen while NOT connected, and refuse to ever
  // present that same address as an exit IP. Worst case the row stays hidden
  // for a poll or two, which is the right way to be wrong.
  property string pubIp: ""
  property string knownRealIp: ""
  readonly property string exitIp:
    (pubIp !== "" && pubIp === knownRealIp) ? "" : pubIp
  property bool busy: false
  property bool loggedOut: false          // the latch
  property real rxBytes: 0
  property real txBytes: 0
  property string ifaceName: ""

  // ---- derived ---------------------------------------------------------
  readonly property bool connected: connectionState === "Connected"
  readonly property bool connecting:
    connectionState === "Connecting" || connectionState === "Reconnecting"
      || connectionState === "DisconnectingToReconnect"

  readonly property string severity: {
    if (!installed) return "off"
    if (loggedOut) return "error"
    if (connected) return "ok"
    if (connecting) return "warn"
    return "off"
  }

  readonly property string stateText: {
    if (!installed) return "Not installed"
    if (loggedOut) return "Logged out"
    if (connected) return "Connected"
    if (connecting) return connectionState
    return "Disconnected"
  }

  readonly property string hintText: loggedOut
    ? "PIA rejected the stored account token (HTTP 401). Log in again with /opt/piavpn/bin/pia-client."
    : ""

  // ---- actions ---------------------------------------------------------
  // Region picking goes through omarchy-menu-select, Quattro's own themed
  // picker, so the panel gets a native keyboard-driven list without this
  // plugin reimplementing one in QML.
  readonly property bool canPickRegion: installed
  function pickRegion() {
    run(["bash", "-lc",
      'opts=$(' + piactl + ' get regions 2>/dev/null | tr "\n" " "); ' +
      '[ -n "$opts" ] || exit 0; ' +
      'sel=$(omarchy-menu-select "PIA region" $opts 2>/dev/null) || exit 0; ' +
      '[ -n "$sel" ] && [ "$sel" != CNCLD ] || exit 0; ' +
      piactl + ' set region "$sel"'])
  }

  function connectVpn() { busy = true; run([piactl, "connect"]) }
  function disconnectVpn() { busy = true; run([piactl, "disconnect"]) }
  function toggle() { connected || connecting ? disconnectVpn() : connectVpn() }
  function run(argv) { actionProc.command = argv; actionProc.running = true }

  function refresh() {
    if (!enabled) return
    stateProc.command = ["bash", "-lc",
      "test -x " + piactl + " || { echo MISSING; exit 0; }; " +
      "printf '%s\\n%s\\n%s\\n%s\\n%s\\n' " +
      "\"$(" + piactl + " get connectionstate 2>/dev/null)\" " +
      "\"$(" + piactl + " get region 2>/dev/null)\" " +
      "\"$(" + piactl + " get protocol 2>/dev/null)\" " +
      "\"$(" + piactl + " get pubip 2>/dev/null)\" " +
      "\"$(" + piactl + " get vpnip 2>/dev/null)\""]
    stateProc.running = true

    // Look for a recent credential rejection, and find PIA's tunnel interface
    // so we can read its byte counters from sysfs.
    authProc.command = ["bash", "-lc",
      "tail -c 131072 " + daemonLog + " 2>/dev/null | grep -c ApiUnauthorizedError || true"]
    authProc.running = true

    // PIA's tunnel interface name varies (pia / wgpia0 / tun0), and it appears
    // and disappears with the connection -- so resolve it and read its counters
    // in one shot every poll rather than binding a watcher to a path that may
    // not exist yet.
    ifaceProc.command = ["bash", "-lc",
      'i=$(ls /sys/class/net 2>/dev/null | grep -E "^(pia|wgpia|tun)" | head -1); ' +
      'if [ -n "$i" ]; then rx=$(cat /sys/class/net/$i/statistics/rx_bytes 2>/dev/null||echo 0); ' +
      'tx=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null||echo 0); else rx=0; tx=0; fi; ' +
      'printf "%s\\n%s\\n%s\\n" "$i" "$rx" "$tx"']
    ifaceProc.running = true
  }

  // ---- processes -------------------------------------------------------
  Process {
    id: stateProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text)
        if (raw.indexOf("MISSING") === 0) { root.installed = false; return }
        root.installed = true
        var l = raw.split("\n")
        root.connectionState = (l[0] || "").trim() || "Unknown"
        root.region = (l[1] || "").trim()
        root.protocol = (l[2] || "").trim()
        root.pubIp = (l[3] || "").trim()
        root.tunnelIp = (l[4] || "").trim()
        // Anything visible while the tunnel is down is, by definition, the
        // address the tunnel is supposed to hide.
        if (root.connectionState !== "Connected" && root.pubIp !== "")
          root.knownRealIp = root.pubIp
        // A genuinely successful connection is the only thing that clears the latch.
        if (root.connectionState === "Connected") root.loggedOut = false
      }
    }
  }

  Process {
    id: authProc
    running: false
    property real seen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = parseFloat(String(text).trim()) || 0
        // Latch on any newly observed rejection; only a real connection clears it.
        if (n > authProc.seen && root.connectionState !== "Connected") root.loggedOut = true
        authProc.seen = n
      }
    }
  }

  Process {
    id: ifaceProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var l = String(text).split("\n")
        root.ifaceName = (l[0] || "").trim()
        root.rxBytes = parseFloat((l[1] || "0").trim()) || 0
        root.txBytes = parseFloat((l[2] || "0").trim()) || 0
      }
    }
  }

  Process {
    id: actionProc
    running: false
    onExited: function () { root.busy = false; root.refresh() }
  }

}
