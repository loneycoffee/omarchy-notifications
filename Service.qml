import QtQuick
import Quickshell
import Quickshell.Io

// The archive, mounted once for the shell.
//
// Omarchy builds a bar per monitor; the entries, what is unread and the folder
// watch live here so every bar shows the same list. bin/notifs does the work on
// disk: it copies each notification out of Omarchy's history as it lands and
// prunes after 30 days.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  // Host injection.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string ctl: Qt.resolvedUrl("bin/notifs").toString().replace(/^file:\/\//, "")
  readonly property string historyDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"

  property var entries: []
  property double lastSeen: 0
  property bool loaded: false
  property bool pendingSync: false

  readonly property int unread: {
    var count = 0
    for (var i = 0; i < root.entries.length; i++) {
      if (root.entries[i].timestamp > root.lastSeen) count++
      else break
    }
    return count
  }

  // Omarchy's own service owns the daemon and Do Not Disturb.
  readonly property var notificationService: root.shell && typeof root.shell.serviceFor === "function"
    ? root.shell.serviceFor("omarchy.notifications") : null
  readonly property bool doNotDisturb: root.notificationService ? root.notificationService.doNotDisturb : false

  function setDoNotDisturb(value) {
    if (root.notificationService) root.notificationService.setDoNotDisturb(value)
  }

  function run(args) {
    actionProc.command = [root.ctl].concat(args)
    actionProc.running = true
  }

  function markSeen() {
    if (root.entries.length > 0) root.lastSeen = root.entries[0].timestamp
    root.run(["seen"])
  }

  function remove(key) {
    root.entries = root.entries.filter(function(e) { return e.key !== key })
    root.run(["remove", key])
  }

  function clear() {
    root.entries = []
    root.run(["clear"])
  }

  function sync() {
    if (syncProc.running) {
      root.pendingSync = true
      return
    }
    syncProc.running = true
  }

  // Sync, then reload the list.
  Process {
    id: syncProc
    command: [root.ctl, "sync"]
    onRunningChanged: {
      if (running) return
      listProc.running = true
      if (root.pendingSync) {
        root.pendingSync = false
        root.sync()
      }
    }
  }

  Process {
    id: listProc
    command: [root.ctl, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.entries = parsed.entries || []
          root.lastSeen = parsed.lastSeen || 0
        } catch (e) {
          console.warn("notification-center: unreadable archive")
        }
        root.loaded = true
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.warn("notification-center: " + text)
    }
  }

  // Omarchy writes one JSON file per notification into its history folder.
  Process {
    id: watchProc
    command: ["inotifywait", "-m", "-q", "-e", "close_write,moved_to", "--format", "%f", root.historyDir]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).endsWith(".json")) debounce.restart()
      }
    }
    // The folder may not exist before the first notification of a fresh
    // install; try again in a while.
    onRunningChanged: if (!running) rewatch.restart()
  }

  Timer {
    id: debounce
    interval: 300
    onTriggered: root.sync()
  }

  Timer {
    id: rewatch
    interval: 30000
    onTriggered: watchProc.running = true
  }

  // Prune once an hour even when nothing arrives.
  Timer {
    interval: 3600000
    repeat: true
    running: true
    onTriggered: root.sync()
  }

  Component.onCompleted: root.sync()
}
