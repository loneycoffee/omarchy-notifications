import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Bar bell and panel for the notification archive, in the same quiet style as
// the Displays panel: a title with Do Not Disturb, a search field, then the
// notifications newest first under the day they arrived, each with its app's
// icon. What arrived since the panel was last opened has an accent bar.
//
// A click opens the picture a notification was about, or focuses the app that
// sent it; it never runs the command the notification came with (that one is
// the sender's choice). Right click on a card removes it; right click on the
// bell toggles Do Not Disturb.
//
// Summon from a keybinding with:  omarchy-shell shell toggle notification-center
Panel {
  id: root

  moduleName: "notification-center"

  property var svc: null
  property string query: ""
  // What counted as new when the panel opened; opening marks everything read.
  property double seenAtOpen: 0

  function bindService() {
    if (root.svc) return
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return
    root.svc = host.serviceFor("notification-center")
  }

  onBarChanged: bindService()

  // The service may mount after the bar, and is rebuilt on plugin hot-reload.
  Timer {
    interval: 250
    repeat: true
    running: !root.svc
    onTriggered: root.bindService()
  }

  readonly property var entries: root.svc ? root.svc.entries : []
  readonly property int unread: root.svc ? root.svc.unread : 0
  readonly property bool dnd: root.svc ? root.svc.doNotDisturb : false

  // Day headers and cards in one flat list, so the ListView can page through
  // a month of notifications without building them all.
  readonly property var rows: {
    var q = root.query.trim().toLowerCase()
    var out = []
    var lastDay = ""
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i]
      if (q !== "" && (e.app + "\n" + e.summary + "\n" + e.body).toLowerCase().indexOf(q) === -1) continue
      var day = root.dayLabel(e.timestamp)
      if (day !== lastDay) {
        out.push({ header: true, label: day, first: out.length === 0 })
        lastDay = day
      }
      out.push({ header: false, entry: e })
    }
    return out
  }

  readonly property color fg: Color.popups.text
  readonly property color dim: Util.alpha(fg, 0.62)
  readonly property color faint: Util.alpha(fg, 0.38)
  // Glass themes make popups see-through; over a white page that leaves the
  // text unreadable, so the panel sits on a near-solid fill.
  readonly property color solidBackground: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.96)
  readonly property string fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
  readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
  readonly property string omarchyBin: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/bin"

  function dayLabel(timestamp) {
    var d = new Date(timestamp)
    var today = new Date()
    today.setHours(0, 0, 0, 0)
    var start = new Date(d.getFullYear(), d.getMonth(), d.getDate())
    var days = Math.round((today - start) / 86400000)
    if (days <= 0) return "TODAY"
    if (days === 1) return "YESTERDAY"
    return Qt.formatDate(d, "ddd d MMM").toUpperCase()
  }

  function iconFor(entry) {
    var icon = String(entry.appIcon || "")
    if (icon.indexOf("file://") === 0) return icon
    if (icon === "" && entry.app) {
      var desktop = DesktopEntries.heuristicLookup(entry.app)
      if (desktop && desktop.icon) icon = desktop.icon
    }
    if (icon === "") return ""
    return root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
  }

  function activate(entry) {
    if (entry.file) {
      // Only ever an absolute image path, checked by bin/notifs, opened as an
      // argument rather than through a shell.
      Quickshell.execDetached(["xdg-open", entry.file])
      root.close()
      return
    }
    // The app name is the sender's to choose and the focus helper matches it as
    // a pattern, so only something shaped like a name gets through.
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(entry.app)) return
    Quickshell.execDetached([root.omarchyBin + "/omarchy-hyprland-focus-app", entry.app])
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened || !root.svc) return
    root.seenAtOpen = root.svc.lastSeen
    root.query = ""
    root.svc.markSeen()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.dnd ? "󰂛" : "󰂚"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.svc) root.svc.setDoNotDisturb(!root.dnd)
      } else {
        root.toggle()
      }
    }
  }

  // Something arrived since the panel was last opened.
  Rectangle {
    visible: root.unread > 0 && !root.opened && !root.dnd
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
    x: button.width / 2 + Style.space(4)
    y: button.height / 2 - Style.space(8)
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(header.implicitHeight + Style.space(14) + list.wantedHeight, Style.space(760))

    Rectangle {
      anchors.fill: parent
      anchors.margins: -panel.padding
      radius: Style.cornerRadius
      color: root.solidBackground
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While searching, the field owns the keys.
      blocked: search.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "/") search.forceActiveFocus()
      }

      Column {
        id: header
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(titleRow.implicitHeight, dndRow.implicitHeight)

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Notifications"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.entries.length > 0
              textFormat: Text.PlainText
              text: String(root.entries.length)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: dndRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Do not disturb"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.dnd
              foreground: root.fg
              onToggled: if (root.svc) root.svc.setDoNotDisturb(!root.dnd)
            }
          }
        }

        Item {
          width: parent.width
          height: search.implicitHeight
          visible: root.entries.length > 0

          TextField {
            id: search
            anchors.left: parent.left
            anchors.right: clearLink.left
            anchors.rightMargin: Style.space(8)
            placeholderText: "Search"
            text: root.query
            foreground: root.fg
            font.family: root.fontFamily
            onTextChanged: root.query = text
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else keyCatcher.forceActiveFocus()
            }
          }

          LinkButton {
            id: clearLink
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Clear all"
            onClicked: if (root.svc) root.svc.clear()
          }
        }
      }

      // Empty state.
      Column {
        visible: root.rows.length === 0
        anchors.top: header.bottom
        anchors.topMargin: Style.space(28)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.dnd ? "󰂛" : "󰂚"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.query !== "" ? "Nothing matches" : "Nothing here"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      ListView {
        id: list

        readonly property real wantedHeight: root.rows.length === 0 ? Style.space(90) : Math.max(contentHeight, Style.space(90))

        anchors.top: header.bottom
        anchors.topMargin: Style.space(14)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: Style.space(6)
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows
        ScrollBar.vertical: ScrollBar { policy: list.contentHeight > list.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

        delegate: Loader {
          required property var modelData
          width: list.width
          sourceComponent: modelData.header ? dayHeader : card

          Component {
            id: dayHeader

            PanelSectionHeader {
              topPadding: modelData.first ? 0 : Style.space(8)
              text: modelData.label
              foreground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Component {
            id: card

            NotificationCard {
              entry: modelData.entry
              unread: modelData.entry.timestamp > root.seenAtOpen
            }
          }
        }
      }
    }
  }

  // A small text button for secondary actions.
  component LinkButton: Button {
    foreground: root.dim
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    verticalPadding: Style.spacing.xxs
    horizontalPadding: Style.spacing.sm
  }

  component NotificationCard: Rectangle {
    id: cardRoot

    property var entry: ({})
    property bool unread: false

    readonly property string icon: root.iconFor(cardRoot.entry)
    readonly property string picture: cardRoot.entry.preview || cardRoot.entry.image || ""

    width: parent ? parent.width : 0
    height: body.implicitHeight + Style.space(20)
    radius: Math.min(Style.cornerRadius, Style.space(8))
    color: cardHover.hovered ? Util.alpha(root.fg, 0.08) : Util.alpha(root.fg, 0.04)
    border.width: Style.normalBorderWidth
    border.color: cardRoot.entry.urgency === 2 ? Util.alpha(Color.urgent, 0.6) : Util.alpha(root.fg, 0.10)

    Behavior on color { ColorAnimation { duration: 120 } }

    HoverHandler { id: cardHover }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.svc.remove(cardRoot.entry.key)
        else root.activate(cardRoot.entry)
      }
    }

    // New since the panel was last opened.
    Rectangle {
      visible: cardRoot.unread
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(1)
      width: Style.space(4)
      radius: width / 2
      color: Color.accent
    }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(10)
      spacing: Style.space(4)

      Item {
        width: parent.width
        height: Math.max(appRow.implicitHeight, removeButton.height)

        Row {
          id: appRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            visible: cardRoot.icon !== ""
            width: Style.space(16)
            height: Style.space(16)
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            source: cardRoot.icon
            asynchronous: true
            smooth: true
            mipmap: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: cardRoot.icon === ""
            textFormat: Text.PlainText
            text: "󰂚"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: cardRoot.entry.app || "Notification"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.right: removeButton.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: Qt.formatTime(new Date(cardRoot.entry.timestamp), "HH:mm")
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: removeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          opacity: cardHover.hovered ? 1 : 0
          iconText: "󰅖"
          fontSize: Style.font.caption
          size: Style.space(18)
          foreground: root.dim
          fontFamily: root.fontFamily
          tooltipText: "Remove"
          onClicked: root.svc.remove(cardRoot.entry.key)
        }
      }

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: cardRoot.entry.summary || ""
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: cardRoot.entry.body || ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        maximumLineCount: 4
        elide: Text.ElideRight
      }

      Image {
        visible: cardRoot.picture !== "" && status !== Image.Error
        width: parent.width
        height: visible ? Math.min(Style.space(150), width * 0.56) : 0
        source: cardRoot.picture
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
      }
    }
  }
}
