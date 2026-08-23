import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "io.github.dretureta.rclone"
  ipcTarget: "io.github.dretureta.rclone"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string stateCommand: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/io.github.dretureta.rclone/state.sh"

  property var state: ({ mounts: [], total: 0, ok: 0, problems: 0, errors: 0, vfsBytes: -1 })
  property bool refreshing: false

  readonly property var mounts: state && Array.isArray(state.mounts) ? state.mounts : []
  readonly property int problems: Number(state.problems || 0)
  readonly property int errorCount: Number(state.errors || 0)
  readonly property color statusColor: problems > 0 ? urgent : foreground
  readonly property real speed: Number(state.speed || 0)
  readonly property int queued: Number(state.queued || 0)
  readonly property string barText: {
    if (mounts.length === 0) return "󰅤"
    if (problems > 0) return "󰅤 " + problems
    if (speed > 0) return "󰅧 " + formatRate(speed)
    return "󰅟 " + mounts.length
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function parseState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && typeof parsed === "object") state = parsed
    } catch (e) {
      console.warn("io.github.dretureta.rclone: invalid state output", e)
    }
  }

  function refresh() {
    if (stateProcess.running) return
    refreshing = true
    stateProcess.running = true
  }

  // Actions are one-shot subprocesses; the next tick reports what happened.
  function runAction(action, path) {
    Quickshell.execDetached([root.stateCommand, action, path])
    Qt.callLater(function() { actionSettle.restart() })
  }

  function openPath(path) {
    Quickshell.execDetached(["xdg-open", path])
    root.close()
  }

  function formatBytes(value) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return "—"
    var units = ["B", "K", "M", "G", "T", "P"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + units[i]
  }

  function formatRate(value) {
    return formatBytes(value) + "/s"
  }

  function statusGlyph(status) {
    if (status === "ok") return "󰅠"
    if (status === "stale") return "󰀦"
    if (status === "mounting") return "󰔟"
    return "󰅤"
  }

  function statusColorFor(status) {
    if (status === "ok") return root.foreground
    if (status === "mounting") return root.dim
    return root.urgent
  }

  function statusLabel(mount) {
    if (mount.status === "ok") return "Mounted"
    if (mount.status === "stale") return "Stale endpoint"
    if (mount.status === "mounting") return "Mounting"
    return "Not mounted"
  }

  function usageText(mount) {
    if (!mount.total) return ""
    return formatBytes(mount.used) + " / " + formatBytes(mount.total)
  }

  function heroDetail() {
    if (mounts.length === 0) return "No mounts"
    if (problems > 0) return problems + " of " + mounts.length + " down"
    return mounts.length + " mounted"
  }

  onOpenedChanged: if (opened) {
    refresh()
    if (mountFlick) mountFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: stateProcess
    command: [root.stateCommand]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }

    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) console.warn("io.github.dretureta.rclone: state command exited", exitCode)
    }
  }

  // Mounting takes a moment; re-read once the dust settles instead of showing
  // the pre-action state until the next tick.
  Timer {
    id: actionSettle
    interval: 1500
    onTriggered: root.refresh()
  }

  // Fast only while the panel is open, because that is the only place a moving
  // number is worth 200ms of shell every two seconds. Keying this off "is
  // something transferring" was the first attempt and it never went quiet: a
  // mount with an indexer walking it trickles files all day, so the fast tier
  // would have been permanent. Closed, the bar just shows a rate, and the idle
  // tier still has to be brisk enough to notice a mount dying.
  Timer {
    interval: (root.opened
      ? Math.max(1, Number(root.setting("activeIntervalSec", 2)))
      : Math.max(5, Number(root.setting("refreshIntervalSec", 15)))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.problems > 0
    activeColor: root.statusColor
    fontSize: Style.font.bodySmall
    horizontalMargin: 3.5

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          mountFlick.contentY = Math.max(0, Math.min(
            mountFlick.contentY + dy * Style.space(58),
            Math.max(0, mountFlick.contentHeight - mountFlick.height)
          ))
        }
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }

      Flickable {
        id: mountFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: mountFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Rclone"
            meta: root.problems > 0 ? "ATTENTION NEEDED" : "MOUNTS"
            detail: root.heroDetail()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.problems > 0 ? "󰅤" : "󰅟"
                color: root.statusColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.mounts.length === 0
            width: parent.width
            text: "No rclone mounts found"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
          }

          Column {
            visible: root.mounts.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "MOUNTS  ·  " + root.mounts.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.mounts

              MountRow {
                width: parent ? parent.width : 0
                mount: modelData
                rowIndex: index
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Item {
            width: parent.width
            implicitHeight: footerText.implicitHeight

            Text {
              id: footerText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var parts = ["VFS cache " + root.formatBytes(root.state.vfsBytes)]
                if (root.queued > 0) parts.push(root.queued + " waiting to upload")
                if (root.errorCount > 0) parts.push(root.errorCount + " errors today")
                return parts.join("  ·  ")
              }
              color: root.errorCount > 0 ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

          }
        }
      }
    }
  }

  component MountRow: Column {
    id: mountRow
    property var mount: ({})
    property int rowIndex: 0

    readonly property string status: String(mountRow.mount.status || "down")
    spacing: Style.space(8)

    PanelSeparator {
      visible: mountRow.rowIndex > 0
      foreground: root.foreground
      strength: 0.07
    }

    Item {
      width: mountRow.width
      implicitHeight: Math.max(mountGlyph.implicitHeight, mountLabels.implicitHeight, mountActions.implicitHeight)

      Text {
        id: mountGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.statusGlyph(mountRow.status)
        color: root.statusColorFor(mountRow.status)
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
      }

      Column {
        id: mountLabels
        anchors.left: mountGlyph.right
        anchors.leftMargin: Style.space(10)
        anchors.right: mountActions.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: String(mountRow.mount.remote || mountRow.mount.path || "rclone")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: {
            var parts = mountRow.status === "ok" ? [] : [root.statusLabel(mountRow.mount)]
            var usage = root.usageText(mountRow.mount)
            if (usage) parts.push(usage)
            if (mountRow.mount.cacheBytes !== null && mountRow.mount.cacheBytes !== undefined)
              parts.push("cache " + root.formatBytes(mountRow.mount.cacheBytes))
            if (Number(mountRow.mount.queued || 0) > 0) parts.push(mountRow.mount.queued + " queued")
            if (Number(mountRow.mount.errors || 0) > 0) parts.push(mountRow.mount.errors + " err")
            return parts.join("  ·  ")
          }
          color: mountRow.status === "ok" ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // Why it is broken, in the row itself. Without this the panel said
        // "Not mounted" and nothing else, while the log had the actual reason.
        Text {
          visible: text !== ""
          width: parent.width
          text: mountRow.status === "ok" ? "" : String(mountRow.mount.lastError || "")
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          width: parent.width
          text: {
            var moving = mountRow.mount.transferring || []
            if (moving.length === 0) return ""
            var head = moving[0]
            var line = "↑ " + String(head.name || "").split("/").pop()
              + "  " + Math.round(Number(head.percentage || 0)) + "%"
            if (Number(head.speed || 0) > 0) line += "  ·  " + root.formatRate(head.speed)
            if (moving.length > 1) line += "  (+" + (moving.length - 1) + ")"
            return line
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: String(mountRow.mount.path || "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          opacity: 0.7
          elide: Text.ElideLeft
        }
      }

      Row {
        id: mountActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          visible: mountRow.status === "ok"
          iconText: "󰝰"
          tooltipText: "Open in file manager"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openPath(String(mountRow.mount.path || ""))
        }

        PanelActionButton {
          visible: mountRow.status === "ok" && mountRow.mount.hasRc === true
          iconText: "󰑐"
          tooltipText: "Refresh dir cache"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction("refresh", String(mountRow.mount.path || ""))
        }

        PanelActionButton {
          visible: Number(mountRow.mount.queued || 0) > 0
          iconText: "󰅧"
          tooltipText: "Upload queued files now"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction("flush", String(mountRow.mount.path || ""))
        }

        PanelActionButton {
          visible: mountRow.status === "ok"
          iconText: "󰅤"
          tooltipText: "Unmount"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.runAction("unmount", String(mountRow.mount.path || ""))
        }

        PanelActionButton {
          visible: mountRow.status !== "ok" && mountRow.mount.canRemount === true
          iconText: "󰑓"
          tooltipText: "Remount"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction("remount", String(mountRow.mount.path || ""))
        }
      }
    }
  }
}
