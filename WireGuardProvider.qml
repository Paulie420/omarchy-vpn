import QtQuick
import Quickshell.Io

// WireGuard provider.
//
// Liveness is judged by rx_bytes, NOT by `systemctl is-active`. wg-quick is a
// Type=oneshot unit: it reports active the moment the interface and routes
// exist, WITHOUT ever contacting the peer. A tunnel whose server is down
// therefore reports "active" forever. rx_bytes == 0 means no handshake has ever
// completed.
//
// Everything is read in ONE polled shell call rather than through FileView
// watchers. The first version watched /sys/class/net/<iface>/statistics/* with
// FileView, which is prettier -- but those paths vanish when the tunnel drops,
// the watcher's load fails, and it never re-resolves when the interface comes
// back. The panel then stuck on "Interface missing" forever after the first
// disconnect. A 5s poll is correct through any number of up/down cycles.

Item {
  id: root
  visible: false

  // ---- configuration -------------------------------------------------
  property string label: "WireGuard"
  property string iface: "wg0"
  property bool enabled: true
  // Optional wrapper scripts. Useful when connecting must do more than raise
  // the interface -- e.g. dropping another VPN first and restoring it after.
  // When set, these run instead of `systemctl start/stop wg-quick@<iface>`.
  property string connectCommand: ""
  property string disconnectCommand: ""
  property string reachabilityHost: ""

  readonly property string unit: "wg-quick@" + iface

  // ---- observed state ------------------------------------------------
  property bool unitActive: false
  property bool ifacePresent: false
  property real rxBytes: 0
  property real txBytes: 0
  property string endpoint: ""
  property bool reachable: false
  property bool busy: false
  property double lastRxChange: 0
  property real _lastRx: -1

  // ---- derived ---------------------------------------------------------
  readonly property bool connected: unitActive && ifacePresent && rxBytes > 0
  readonly property int secondsSinceRx: lastRxChange > 0
    ? Math.max(0, Math.floor((Date.now() - lastRxChange) / 1000))
    : -1

  readonly property string severity: {
    if (!unitActive) return "off"
    if (!ifacePresent) return "error"
    if (rxBytes <= 0) return "error"
    if (secondsSinceRx > 240) return "warn"
    return "ok"
  }

  readonly property string stateText: {
    if (!unitActive) return "Disconnected"
    if (!ifacePresent) return "Interface missing"
    if (rxBytes <= 0) return "No handshake"
    if (secondsSinceRx > 240) return "Stale (" + secondsSinceRx + "s)"
    return "Connected"
  }

  readonly property string hintText: {
    if (busy) return "Working…"
    if (severity === "error" && unitActive && ifacePresent)
      return "Sending, receiving nothing. Check the server, the UDP port forward, or this network."
    if (severity === "warn") return "Peer answered before but has gone quiet."
    return ""
  }

  // ---- actions ---------------------------------------------------------
  function connectVpn() {
    busy = true
    runShell(connectCommand !== "" ? connectCommand : "systemctl start " + unit)
  }

  function disconnectVpn() {
    busy = true
    runShell(disconnectCommand !== "" ? disconnectCommand : "systemctl stop " + unit)
  }

  // Toggle on the unit, not on `connected`: a tunnel that is up but has never
  // handshaked still needs stopping, and `connected` is false for it.
  function toggle() { unitActive ? disconnectVpn() : connectVpn() }

  function runShell(cmd) {
    actionProc.command = ["bash", "-lc", cmd]
    actionProc.running = true
  }

  function refresh() {
    if (!enabled || pollProc.running) return
    pollProc.command = ["bash", "-lc",
      'u=$(systemctl is-active ' + unit + ' 2>/dev/null); ' +
      'd=/sys/class/net/' + iface + '/statistics; ' +
      'if [ -d "$d" ]; then p=1; rx=$(cat $d/rx_bytes 2>/dev/null||echo 0); tx=$(cat $d/tx_bytes 2>/dev/null||echo 0); ' +
      'else p=0; rx=0; tx=0; fi; ' +
      'ep=$(wg show ' + iface + ' endpoints 2>/dev/null | awk "{print \\$2}" | head -1); ' +
      (reachabilityHost !== ""
        ? 'ping -c1 -W1 ' + reachabilityHost + ' >/dev/null 2>&1 && r=1 || r=0; '
        : 'r=0; ') +
      'printf "%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n" "$u" "$p" "$rx" "$tx" "$ep" "$r"']
    pollProc.running = true
  }

  // ---- processes -------------------------------------------------------
  Process {
    id: pollProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var l = String(text).split("\n")
        root.unitActive = (l[0] || "").trim() === "active"
        root.ifacePresent = (l[1] || "").trim() === "1"
        var rx = parseFloat((l[2] || "0").trim()) || 0
        root.txBytes = parseFloat((l[3] || "0").trim()) || 0
        root.endpoint = (l[4] || "").trim()
        root.reachable = (l[5] || "").trim() === "1"
        if (rx !== root._lastRx) { root._lastRx = rx; root.lastRxChange = Date.now() }
        root.rxBytes = rx
        if (!root.ifacePresent) { root._lastRx = -1; root.lastRxChange = 0 }
      }
    }
  }

  Process {
    id: actionProc
    running: false
    onExited: function () {
      root.busy = false
      // The wrapper scripts take a moment to settle (PIA disconnect, handshake),
      // so re-read a couple of times rather than once.
      settleTimer.count = 0
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    property int count: 0
    interval: 1200
    repeat: true
    onTriggered: {
      root.refresh()
      count += 1
      if (count >= 5) stop()
    }
  }
}
