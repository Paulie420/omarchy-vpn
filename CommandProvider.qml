import QtQuick
import Quickshell.Io

// Generic CLI provider. Drives any VPN that has a command line, entirely from
// shell.json, with no QML to write:
//
//   { "label": "Mullvad",
//     "statusCommand":     "mullvad status",
//     "connectedWhen":     "Connected",
//     "connectCommand":    "mullvad connect",
//     "disconnectCommand": "mullvad disconnect",
//     "interface":         "wg0-mullvad" }
//
// `interface` is optional but worth setting. With it, this provider also reads
// rx_bytes/tx_bytes from sysfs, which gives live traffic counters AND catches
// the case every VPN tool gets wrong: the CLI cheerfully reporting "connected"
// while the tunnel carries nothing. Bytes in is the only honest proof.
//
// Everything is read in one polled shell call. Do not be tempted to swap this
// for FileView watchers on /sys/class/net/... -- those paths disappear when a
// tunnel drops and the watcher never re-resolves.

Item {
  id: root
  visible: false

  // ---- configuration -------------------------------------------------
  property string label: "VPN"
  property bool enabled: true
  property string statusCommand: ""
  property string connectedWhen: "connected"   // matched case-insensitively
  property string connectCommand: ""
  property string disconnectCommand: ""
  property string iface: ""                    // optional
  property string reachabilityHost: ""
  // Optional: pull one extra line out of the status output for the panel,
  // e.g. { "label": "Server", "match": "Relay: (.*)" }
  property var detail: null
  // Optional server/region picking. `regionListCommand` must print one option
  // per line; `regionSetCommand` gets {} replaced with the chosen value.
  property string regionListCommand: ""
  property string regionSetCommand: ""

  // ---- observed state ------------------------------------------------
  property bool cliPresent: true
  property bool statusConnected: false
  property string statusLine: ""
  property string detailValue: ""
  property bool ifacePresent: false
  property real rxBytes: 0
  property real txBytes: 0
  property bool reachable: false
  property bool busy: false
  property double lastRxChange: 0
  property real _lastRx: -1

  // ---- derived ---------------------------------------------------------
  // Without an interface we can only believe the CLI. With one, bytes decide.
  readonly property bool connected: iface !== ""
    ? (statusConnected && ifacePresent && rxBytes > 0)
    : statusConnected

  readonly property int secondsSinceRx: lastRxChange > 0
    ? Math.max(0, Math.floor((Date.now() - lastRxChange) / 1000))
    : -1

  readonly property string severity: {
    if (!cliPresent) return "off"
    if (!statusConnected) return "off"
    if (iface === "") return "ok"
    if (!ifacePresent) return "error"
    if (rxBytes <= 0) return "error"
    if (secondsSinceRx > 240) return "warn"
    return "ok"
  }

  readonly property string stateText: {
    if (!cliPresent) return "Not installed"
    if (!statusConnected) return "Disconnected"
    if (iface === "") return "Connected"
    if (!ifacePresent) return "Interface missing"
    if (rxBytes <= 0) return "No handshake"
    if (secondsSinceRx > 240) return "Stale (" + secondsSinceRx + "s)"
    return "Connected"
  }

  readonly property string hintText: {
    if (busy) return "Working…"
    if (severity === "error" && statusConnected)
      return "The VPN reports connected but nothing is coming back. Check the server or this network."
    if (severity === "warn") return "Was carrying traffic, has gone quiet."
    return ""
  }

  // ---- actions ---------------------------------------------------------
  function connectVpn() { if (connectCommand !== "") { busy = true; runShell(connectCommand) } }
  function disconnectVpn() { if (disconnectCommand !== "") { busy = true; runShell(disconnectCommand) } }
  function toggle() { statusConnected ? disconnectVpn() : connectVpn() }

  readonly property bool canPickRegion: regionListCommand !== "" && regionSetCommand !== ""
  function pickRegion() {
    if (!canPickRegion) return
    var setCmd = String(regionSetCommand).split("{}").join('"$sel"')
    runShell('opts=$(' + regionListCommand + ' 2>/dev/null | tr "\n" " "); ' +
             '[ -n "$opts" ] || exit 0; ' +
             'sel=$(omarchy-menu-select "' + label + ' server" $opts 2>/dev/null) || exit 0; ' +
             '[ -n "$sel" ] && [ "$sel" != CNCLD ] || exit 0; ' + setCmd)
  }

  function runShell(cmd) {
    actionProc.command = ["bash", "-lc", cmd]
    actionProc.running = true
  }

  function refresh() {
    if (!enabled || statusCommand === "" || pollProc.running) return
    var script =
      'out=$(' + statusCommand + ' 2>/dev/null); ' +
      'printf "%s\\n" "$out" | head -1 > /dev/null; '
    if (iface !== "") {
      script +=
        'd=/sys/class/net/' + iface + '/statistics; ' +
        'if [ -d "$d" ]; then p=1; rx=$(cat $d/rx_bytes 2>/dev/null||echo 0); ' +
        'tx=$(cat $d/tx_bytes 2>/dev/null||echo 0); else p=0; rx=0; tx=0; fi; '
    } else {
      script += 'p=0; rx=0; tx=0; '
    }
    script += (reachabilityHost !== ""
      ? 'ping -c1 -W1 ' + reachabilityHost + ' >/dev/null 2>&1 && r=1 || r=0; '
      : 'r=0; ')
    // Marker keeps the multi-line status output separate from the scalars.
    script += 'printf "%s\\n%s\\n%s\\n%s\\n---OMVPN---\\n%s\\n" "$p" "$rx" "$tx" "$r" "$out"'

    pollProc.command = ["bash", "-lc", script]
    pollProc.running = true
  }

  // ---- processes -------------------------------------------------------
  Process {
    id: pollProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text)
        var parts = raw.split("---OMVPN---\n")
        var head = (parts[0] || "").split("\n")
        var out = parts.length > 1 ? parts[1] : ""

        root.ifacePresent = (head[0] || "").trim() === "1"
        var rx = parseFloat((head[1] || "0").trim()) || 0
        root.txBytes = parseFloat((head[2] || "0").trim()) || 0
        root.reachable = (head[3] || "").trim() === "1"

        root.cliPresent = out.trim() !== ""
        root.statusConnected =
          out.toLowerCase().indexOf(String(root.connectedWhen).toLowerCase()) !== -1
        root.statusLine = out.split("\n")[0].trim()

        if (root.detail && root.detail.match) {
          try {
            var m = out.match(new RegExp(root.detail.match))
            root.detailValue = m ? (m[1] || m[0]).trim() : ""
          } catch (e) { root.detailValue = "" }
        }

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
      settleTimer.count = 0
      settleTimer.restart()
    }
  }

  // VPN CLIs return before the tunnel is actually up, so re-read a few times.
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
