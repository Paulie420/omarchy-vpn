import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// VPN bar widget: one icon, one panel, every configured tunnel.
//
// Left click opens the panel. There is deliberately no right-click toggle:
// this machine's WireGuard tunnel carries NFS mounts, and dropping it mid
// transfer hangs rather than fails, so every connect/disconnect is an explicit
// click on a switch inside the panel.

Panel {
  id: root
  moduleName: "paulie420.vpn"
  ipcTarget: "paulie420.vpn"

  // The bar's ModuleSlot sizes itself from the loaded item's implicit size.
  // Panel derives from a plain Item, which has none, so without these two
  // lines the slot collapses to 0x0 and the widget is invisible even though it
  // loaded, registered its IPC target and ran its providers. Every first-party
  // Panel-rooted bar widget declares the same pair.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- config ----------------------------------------------------------
  readonly property int refreshSec: Math.max(2, setting("refreshIntervalSec", 5))
  readonly property var piaCfg: setting("pia", ({ enabled: true, label: "PIA" }))
  readonly property var wgCfg: setting("wireguard", ({
    enabled: true, label: "PiVPN", interface: "pivpn",
    connectCommand: "", disconnectCommand: "", reachabilityHost: ""
  }))

  function cfg(obj, key, fallback) {
    if (!obj) return fallback
    var v = obj[key]
    return (v === undefined || v === null || v === "") ? fallback : v
  }

  // ---- theming ---------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- providers -------------------------------------------------------
  // Each provider is a self-contained component exposing the same interface:
  //   enabled label connected severity stateText hintText busy
  //   rxBytes txBytes  +  connectVpn() disconnectVpn() toggle() refresh()
  // Adding another VPN means dropping in one more file and listing it here.
  readonly property var providers: {
    var out = []
    if (pia.enabled) out.push(pia)
    if (wg.enabled) out.push(wg)
    return out
  }

  PiaProvider {
    id: pia
    enabled: root.cfg(root.piaCfg, "enabled", true) === true
    label: root.cfg(root.piaCfg, "label", "PIA")
  }

  WireGuardProvider {
    id: wg
    enabled: root.cfg(root.wgCfg, "enabled", true) === true
    label: root.cfg(root.wgCfg, "label", "PiVPN")
    iface: root.cfg(root.wgCfg, "interface", "pivpn")
    connectCommand: root.cfg(root.wgCfg, "connectCommand", "")
    disconnectCommand: root.cfg(root.wgCfg, "disconnectCommand", "")
    reachabilityHost: root.cfg(root.wgCfg, "reachabilityHost", "")
  }

  // ---- aggregate state for the bar icon ---------------------------------
  // Worst state wins, so a broken tunnel is never hidden by a healthy one.
  readonly property string worstSeverity: {
    var rank = { "error": 3, "warn": 2, "ok": 1, "off": 0 }
    var worst = "off"
    for (var i = 0; i < providers.length; i++) {
      var s = providers[i].severity
      if (rank[s] > rank[worst]) worst = s
    }
    return worst
  }

  readonly property int connectedCount: {
    var n = 0
    for (var i = 0; i < providers.length; i++) if (providers[i].connected) n++
    return n
  }

  readonly property color iconColor: {
    if (worstSeverity === "error") return Color.urgent
    if (worstSeverity === "warn") return Qt.lighter(Color.urgent, 1.35)
    if (worstSeverity === "ok") return barForeground
    return Qt.darker(barForeground, 1.55)
  }

  readonly property string summaryTooltip: {
    var parts = []
    for (var i = 0; i < providers.length; i++)
      parts.push(providers[i].label + ": " + providers[i].stateText)
    return parts.length ? parts.join("\n") : "No VPN providers enabled"
  }

  function humanBytes(b) {
    if (!b || b <= 0) return "0 B"
    if (b >= 1073741824) return (b / 1073741824).toFixed(2) + " GB"
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB"
    if (b >= 1024) return (b / 1024).toFixed(1) + " KB"
    return Math.round(b) + " B"
  }

  function refreshAll() {
    for (var i = 0; i < providers.length; i++) providers[i].refresh()
  }

  Component.onCompleted: refreshAll()

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAll()
  }

  // ---- bar icon --------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"                 // nf-md-vpn
    foreground: root.iconColor
    useActiveColor: false
    slotSize: Style.bar.statusSlot
    fontSize: Style.bar.iconFont
    tooltipText: root.summaryTooltip
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // ---- panel -----------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) { if (t === "r" || t === "R") root.refreshAll() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          Text {
            text: "VPN"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
            opacity: 0.75
          }

          Repeater {
            model: root.providers

            Column {
              id: section
              required property var modelData
              width: column.width
              spacing: Style.space(4)

              readonly property color accentFor: {
                if (modelData.severity === "error") return Color.urgent
                if (modelData.severity === "warn") return Qt.lighter(Color.urgent, 1.35)
                if (modelData.severity === "ok") return root.foreground
                return root.dim
              }

              // header: name + state + switch
              Item {
                width: parent.width
                height: Math.max(nameCol.implicitHeight, sw.implicitHeight)

                Column {
                  id: nameCol
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    text: section.modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    text: section.modelData.stateText
                    color: section.accentFor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                ToggleSwitch {
                  id: sw
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: section.modelData.connected
                  busy: section.modelData.busy
                  foreground: root.foreground
                  accent: Color.accent
                  onToggled: section.modelData.toggle()
                }
              }

              // hint for a broken tunnel
              Text {
                visible: section.modelData.hintText !== ""
                width: parent.width
                text: section.modelData.hintText
                color: section.accentFor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                opacity: 0.9
              }

              // detail rows
              Repeater {
                model: section.detailRows()

                Item {
                  required property var modelData
                  width: section.width
                  height: rowLabel.implicitHeight

                  Text {
                    id: rowLabel
                    anchors.left: parent.left
                    text: modelData.k
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.right: parent.right
                    text: modelData.v
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              function detailRows() {
                var p = modelData
                var rows = []
                if (p.region !== undefined && p.region) rows.push({ k: "Region", v: p.region })
                if (p.protocol !== undefined && p.protocol) rows.push({ k: "Protocol", v: p.protocol })
                // Address and traffic rows only mean anything while the tunnel
                // is up. While it is down "Public IP" is the user's REAL home
                // address -- shown as if it were a VPN property, and leaked by
                // any screenshot of the panel -- and the rest read as zeros.
                if (p.connected) {
                  if (p.exitIp !== undefined && p.exitIp) rows.push({ k: "Public IP", v: p.exitIp })
                  if (p.tunnelIp !== undefined && p.tunnelIp && p.tunnelIp !== "Unknown")
                    rows.push({ k: "Tunnel IP", v: p.tunnelIp })
                }
                if (p.endpoint !== undefined && p.endpoint) rows.push({ k: "Endpoint", v: p.endpoint })
                if (p.secondsSinceRx !== undefined && p.secondsSinceRx >= 0 && p.connected)
                  rows.push({ k: "Last inbound", v: p.secondsSinceRx + "s ago" })
                // Only meaningful while the tunnel is up -- showing
                // "10.0.0.118 unreachable" on a deliberately disconnected VPN
                // reads as a fault when nothing is wrong.
                if (p.reachabilityHost !== undefined && p.reachabilityHost && p.connected)
                  rows.push({ k: "NAS " + p.reachabilityHost,
                              v: p.reachable ? "reachable" : "unreachable" })
                if (p.connected)
                  rows.push({ k: "Traffic", v: "↑ " + root.humanBytes(p.txBytes)
                                             + "   ↓ " + root.humanBytes(p.rxBytes) })
                return rows
              }

              PanelSeparator {
                width: parent.width
                foreground: root.foreground
                visible: section.modelData !== root.providers[root.providers.length - 1]
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            text: "No VPN providers enabled.\nConfigure them in ~/.config/omarchy/shell.json"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Text {
            text: "r  refresh      esc  close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.7
          }
        }
      }
    }
  }
}
