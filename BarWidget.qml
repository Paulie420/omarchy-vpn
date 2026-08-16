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

  // `wireguard` accepts either one object or a list of them, so several
  // WireGuard-based VPNs (a homelab tunnel, Mullvad, NordLynx, Proton...) can
  // sit side by side in the same panel. A single object is wrapped into a
  // one-item list so both spellings behave identically.
  // Any VPN with a CLI, configured entirely from shell.json. See the README
  // cookbook for ready-made entries (Mullvad, Proton, IVPN, Mozilla, AirVPN,
  // NordVPN, Windscribe, FortiVPN...).
  readonly property var customConfigs: {
    var c = setting("custom", undefined)
    if (c === undefined || c === null) return []
    return (c instanceof Array) ? c : [c]
  }

  readonly property var wgConfigs: {
    var c = setting("wireguard", undefined)
    if (c === undefined || c === null)
      return [({ enabled: true, label: "WireGuard", interface: "wg0" })]
    return (c instanceof Array) ? c : [c]
  }

  function cfg(obj, key, fallback) {
    if (!obj) return fallback
    var v = obj[key]
    return (v === undefined || v === null || v === "") ? fallback : v
  }

  // ---- theming ---------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color warnColor: Qt.lighter(Color.urgent, 1.35)

  // ---- per-VPN identity colors -----------------------------------------
  // A theme only guarantees foreground/accent/urgent/muted, which is not
  // enough to tell two live tunnels apart, so identity hues are generated
  // here instead of pulled from the palette.
  //
  // Red is deliberately absent from the ring: it belongs to the error state.
  // A VPN whose identity color was red would be indistinguishable from a VPN
  // that is failing, which is exactly the confusion this widget exists to
  // stop. The ring also skips the yellow the "gone quiet" state uses.
  readonly property var identityHues: [205, 145, 275, 172, 320, 42]

  // The bar sits on wallpaper as often as on a solid color, and `barForeground`
  // flips when it does, so lightness is picked against the foreground rather
  // than assuming a dark bar.
  readonly property bool onLightBar: barForeground.hslLightness < 0.5

  // `spec` is the optional per-VPN "color" setting: a hex string, or one of
  // the theme role names. Anything else falls through to the generated hue.
  function identityColor(spec, index) {
    if (spec) {
      var s = String(spec).toLowerCase()
      if (s === "accent") return Color.accent
      if (s === "urgent") return Color.urgent
      if (s === "foreground") return barForeground
      if (s === "muted") return Color.muted
      if (s.charAt(0) === "#") return spec
    }
    var h = identityHues[index % identityHues.length] / 360
    return onLightBar ? Qt.hsla(h, 0.75, 0.36, 1) : Qt.hsla(h, 0.62, 0.66, 1)
  }

  // ---- providers -------------------------------------------------------
  // Each provider is a self-contained component exposing the same interface:
  //   enabled label connected severity stateText hintText busy
  //   rxBytes txBytes  +  connectVpn() disconnectVpn() toggle() refresh()
  // Adding another VPN means dropping in one more file and listing it here.
  // Bumped whenever the WireGuard instantiator adds or removes an object, so
  // `providers` re-evaluates: reading wgHost.count alone is not a binding
  // dependency strong enough to catch model edits.
  property int providersRevision: 0

  readonly property var providers: {
    providersRevision
    var out = []
    if (pia.enabled) out.push(pia)
    for (var i = 0; i < wgHost.count; i++) {
      var o = wgHost.objectAt(i)
      if (o && o.enabled) out.push(o)
    }
    for (var j = 0; j < cmdHost.count; j++) {
      var c = cmdHost.objectAt(j)
      if (c && c.enabled) out.push(c)
    }
    return out
  }

  // Identity indices are assigned by config position, not by position in the
  // `providers` list, so a VPN keeps its color when another one is disabled.
  PiaProvider {
    id: pia
    enabled: root.cfg(root.piaCfg, "enabled", true) === true
    label: root.cfg(root.piaCfg, "label", "PIA")
    identityColor: root.identityColor(root.cfg(root.piaCfg, "color", ""), 0)
  }

  Instantiator {
    id: wgHost
    model: root.wgConfigs
    onObjectAdded: root.providersRevision++
    onObjectRemoved: root.providersRevision++

    delegate: WireGuardProvider {
      required property var modelData
      required property int index
      enabled: modelData ? modelData.enabled !== false : true
      label: root.cfg(modelData, "label", "WireGuard")
      identityColor: root.identityColor(root.cfg(modelData, "color", ""), 1 + index)
      iface: root.cfg(modelData, "interface", "wg0")
      connectCommand: root.cfg(modelData, "connectCommand", "")
      disconnectCommand: root.cfg(modelData, "disconnectCommand", "")
      reachabilityHost: root.cfg(modelData, "reachabilityHost", "")
    }
  }

  Instantiator {
    id: cmdHost
    model: root.customConfigs
    onObjectAdded: root.providersRevision++
    onObjectRemoved: root.providersRevision++

    delegate: CommandProvider {
      required property var modelData
      required property int index
      enabled: modelData ? modelData.enabled !== false : true
      label: root.cfg(modelData, "label", "VPN")
      identityColor: root.identityColor(root.cfg(modelData, "color", ""),
                                        1 + root.wgConfigs.length + index)
      statusCommand: root.cfg(modelData, "statusCommand", "")
      connectedWhen: root.cfg(modelData, "connectedWhen", "connected")
      connectCommand: root.cfg(modelData, "connectCommand", "")
      disconnectCommand: root.cfg(modelData, "disconnectCommand", "")
      iface: root.cfg(modelData, "interface", "")
      reachabilityHost: root.cfg(modelData, "reachabilityHost", "")
      regionListCommand: root.cfg(modelData, "regionListCommand", "")
      regionSetCommand: root.cfg(modelData, "regionSetCommand", "")
      detail: modelData ? (modelData.detail || null) : null
    }
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

  // A provider's color says *what* it is; severity still overrides it, because
  // knowing a tunnel is broken matters more than knowing which one it is.
  function providerColor(p) {
    if (p.severity === "error") return Color.urgent
    if (p.severity === "warn") return warnColor
    return p.identityColor
  }

  // One band per VPN that is actually doing something. One live tunnel paints
  // the glyph a single solid color; two paint it in halves, so "which VPN am I
  // on" is answerable without opening the panel. A tunnel that is off
  // contributes nothing, so the common case stays a plain glyph.
  readonly property var iconBands: {
    var out = []
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].severity === "off") continue
      out.push({ c: providerColor(providers[i]) })
    }
    if (out.length === 0) out.push({ c: Qt.darker(barForeground, 1.55) })
    return out
  }

  readonly property color iconColor: iconBands[0].c

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

    // Painting the glyph ourselves is the only way to give it more than one
    // color. Each band clips a full-size glyph and shifts it back into place,
    // so the bands line up into one continuous icon rather than several small
    // ones. With a single band this renders identically to BarIconButton's own
    // OpticalGlyph, which is what it re-uses.
    iconComponent: Component {
      Item {
        id: canvas
        readonly property var bands: root.iconBands

        Repeater {
          model: canvas.bands

          Item {
            required property var modelData
            required property int index
            width: canvas.width / canvas.bands.length
            height: canvas.height
            x: index * width
            clip: canvas.bands.length > 1

            OpticalGlyph {
              x: -parent.x
              width: canvas.width
              height: canvas.height
              text: button.text
              fontFamily: root.fontFamily
              fontSize: Style.bar.iconFont
              color: parent.modelData.c
            }
          }
        }
      }
    }
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
                if (modelData.severity === "warn") return root.warnColor
                if (modelData.severity === "ok") return root.foreground
                return root.dim
              }

              // header: name + state + switch
              Item {
                width: parent.width
                height: Math.max(nameRow.implicitHeight, sw.implicitHeight)

                Row {
                  id: nameRow
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(7)

                  // The legend for the bar icon. Always present, so the colour
                  // to VPN mapping can be learned, but dimmed while the tunnel
                  // is down so the live one is the one that stands out.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: section.modelData.identityColor
                    opacity: section.modelData.severity === "off" ? 0.3 : 1.0
                  }

                  Column {
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
                // "<host> unreachable" on a deliberately disconnected VPN
                // reads as a fault when nothing is wrong.
                if (p.reachabilityHost !== undefined && p.reachabilityHost && p.connected)
                  rows.push({ k: "NAS " + p.reachabilityHost,
                              v: p.reachable ? "reachable" : "unreachable" })
                if (p.connected)
                  rows.push({ k: "Traffic", v: "↑ " + root.humanBytes(p.txBytes)
                                             + "   ↓ " + root.humanBytes(p.rxBytes) })
                return rows
              }

              // Region / server picker. Uses omarchy-menu-select so the list is
              // Quattro's own themed picker rather than a bespoke QML list.
              Item {
                visible: section.modelData.canPickRegion === true
                width: parent.width
                height: visible ? pickLabel.implicitHeight + Style.space(6) : 0

                Rectangle {
                  anchors.fill: parent
                  color: pickMouse.containsMouse ? root.hoverFill : "transparent"
                  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                }

                Text {
                  id: pickLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Change server…"
                  color: pickMouse.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: pickMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { section.modelData.pickRegion(); root.close() }
                }
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
