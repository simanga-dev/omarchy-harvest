import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.Panel {
  id: root
  moduleName: "simanga.harvest"
  ipcTarget: "simanga.harvest"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property bool configured: false
  property bool backgroundSync: false
  property bool setup: false
  property bool busy: false
  property bool fresh: false
  property string errorKey: ""
  property string requestAction: ""
  property string input: ""
  property var snapshot: null
  property var projects: []
  property int projectIndex: -1
  property int taskIndex: -1
  readonly property var tasks: projectIndex >= 0 && projectIndex < projects.length ? projects[projectIndex].tasks : []
  readonly property bool tracking: snapshot !== null && snapshot.running.length > 0
  // Each mutation re-checks the live Harvest state in the bridge. A stale
  // display should not silently disable controls when background sync is off.
  readonly property bool canChange: configured && !busy && snapshot !== null
  readonly property real openPanelIndicatorWidth: button.width
  property double now: Date.now()

  // Theme tokens, taken from the bar like the stock panels do.
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var current: tracking ? snapshot.running[0] : null
  readonly property bool showSetup: !configured || setup
  readonly property bool canStart: canChange && !tracking && projectIndex >= 0 && taskIndex >= 0
  // Connection state drives a coloured dot instead of status lines that
  // appear and disappear and shove the layout around.
  readonly property string connection: !configured ? "off"
    : (errorKey !== "" ? "error" : (snapshot === null ? "connecting" : (fresh ? "ok" : "stale")))
  readonly property color connectionColor: connection === "ok" ? Commons.Color.accent
    : ((connection === "connecting" || connection === "stale") ? Commons.Color.muted : urgent)
  readonly property string connectionIcon: connection === "ok" ? "󰅠"
    : ((connection === "connecting" || connection === "stale") ? "󰅟" : "󰅤")
  readonly property string shortErrorKey: {
    var e = errorKey.replace("error.", "")
    if (e === "auth" || e === "credentials" || e === "permissions") return "short.credentials"
    if (e === "network" || e === "timeout") return "short.offline"
    if (e === "rate") return "short.rate"
    return "short.failed"
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function request(payload) {
    if (busy) return
    busy = true
    errorKey = ""
    input = JSON.stringify(payload) + "\n"
    requestAction = payload.action
    worker.running = true
  }
  function refresh() {
    request({action: "refresh", projects: true})
  }
  function startTimer(notes) {
    if (canStart) request({action: "start", project_id: projects[projectIndex].id, task_id: tasks[taskIndex].id, notes: notes})
  }
  function stopTimer() {
    if (canChange && tracking) request({action: "stop", id: current.id})
  }
  function receive(line) {
    var result
    try { result = JSON.parse(line) } catch (_) { errorKey = "error.response"; fresh = false; return }
    if (!result.ok) {
      var errors = ["auth", "credentials", "permissions", "network", "timeout", "rate", "rejected", "running", "invalid", "response"]
      errorKey = "error." + (errors.indexOf(result.error) >= 0 ? result.error : "response")
      fresh = false
      return
    }
    configured = result.configured === true
    backgroundSync = result.sync === true
    if (requestAction === "configure") setup = false
    if (result.data) {
      snapshot = result.data
      fresh = true
      if (result.data.projects) {
        var oldProject = projectIndex >= 0 && projectIndex < projects.length ? projects[projectIndex].id : -1
        var oldTask = taskIndex >= 0 && taskIndex < tasks.length ? tasks[taskIndex].id : -1
        projects = result.data.projects
        projectIndex = projects.length ? 0 : -1
        for (var i = 0; i < projects.length; i++) if (projects[i].id === oldProject) projectIndex = i
        taskIndex = tasks.length ? 0 : -1
        for (var j = 0; j < tasks.length; j++) if (tasks[j].id === oldTask) taskIndex = j
      }
    }
    if (result.changed) fresh = false
  }
  function elapsed(hours, running, date) {
    var delta = snapshot && running && date === snapshot.date ? Math.max(0, (now / 1000 - snapshot.synced_at) / 3600) : 0
    // Never project more than one polling interval when disconnected.
    return Commons.I18n.formatNumber(hours + Math.min(delta, 1 / 60), 2)
  }
  onOpenedChanged: if (opened && configured && !busy) refresh()
  Component.onCompleted: request({action: "status"})

  ShellIpc {
    target: "simanga.harvest"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return JSON.stringify({configured: root.configured, busy: root.busy,
        error: root.errorKey, opened: root.opened, backgroundSync: root.backgroundSync,
        fresh: root.fresh, canChange: root.canChange, tracking: root.tracking,
        projectCount: root.projects.length, taskCount: root.tasks.length,
        projectIndex: root.projectIndex, taskIndex: root.taskIndex})
    }
  }

  Process {
    id: worker
    command: ["python3", decodeURIComponent(Qt.resolvedUrl("harvest.py").toString().replace(/^(file|qs):\/\//, ""))]
    stdinEnabled: true
    onStarted: { write(root.input); root.input = ""; }
    stdout: SplitParser { onRead: line => root.receive(line) }
    onExited: function(code) {
      root.busy = false
      if (code !== 0) { root.errorKey = "error.response"; root.fresh = false; return }
      if (!root.errorKey && root.configured &&
          (root.requestAction === "configure" || root.requestAction === "start" ||
           root.requestAction === "stop" || root.requestAction === "resume" ||
           (root.requestAction === "status" && root.backgroundSync)))
        Qt.callLater(root.refresh)
    }
  }
  Timer {
    interval: 60000
    repeat: true
    running: root.configured && root.backgroundSync
    onTriggered: if (!root.busy) root.refresh()
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.tracking || root.opened
    onTriggered: {
      root.now = Date.now()
      if (root.snapshot && root.now / 1000 - root.snapshot.synced_at >= 90) root.fresh = false
    }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.bar && root.bar.vertical ? "󱎫" :
      (root.tracking ? "󱎫 " + root.elapsed(root.snapshot.running[0].hours, true, root.snapshot.running[0].date) : "󱎫 Harvest")
    active: root.tracking
    tooltipText: strings.t("open")
    onPressed: root.toggle()
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: fittedContentWidth(Style.space(400))
    contentHeight: fittedContentHeight(body.implicitHeight, Style.space(760))
    focusTarget: body

    Flickable {
      id: body
      width: parent.width
      height: parent.height
      implicitHeight: column.implicitHeight
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      Keys.onEscapePressed: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ── Hero: current timer, quick actions, on/off switch ──────────────
        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight
          // The hero's components resolve `root` to PanelHero, so they reach
          // panel state through here.
          readonly property bool tracking: root.tracking
          readonly property bool configured: root.configured
          readonly property bool showSetup: root.showSetup
          readonly property bool busy: root.busy
          readonly property color connectionColor: root.connectionColor
          readonly property string connectionIcon: root.connectionIcon
          readonly property bool switchEnabled: root.tracking ? root.canChange : root.canStart
          function refresh() { root.refresh() }
          function editCredentials() { root.setup = true }
          function toggleTimer() { if (root.tracking) root.stopTimer(); else root.startTimer(notes.text) }

          Ui.PanelHero {
            id: hero
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.current ? root.current.project : strings.t("title")
            meta: root.errorKey !== "" ? strings.t(root.shortErrorKey)
              : (root.showSetup ? strings.t("notConnected")
              : (root.current ? root.current.task : strings.t("idle")))
            iconOpacity: root.tracking ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󱎫"
                color: hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display

                // Connection badge: cloud-check = synced, cloud = connecting
                // or stale, cloud-off = error or not connected.
                Rectangle {
                  width: badge.implicitWidth + Style.space(2)
                  height: width
                  radius: width / 2
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.rightMargin: -Style.space(5)
                  anchors.bottomMargin: -Style.space(2)
                  color: Commons.Color.background
                  Text {
                    id: badge
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: header.connectionIcon
                    color: header.connectionColor
                    font.family: hero.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(6)
                visible: header.configured
                Ui.PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !header.showSetup
                  iconText: "󰑐"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  enabled: !header.busy
                  onClicked: header.refresh()
                }
                Ui.PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !header.showSetup
                  iconText: "󰌋"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  enabled: !header.busy
                  onClicked: header.editCredentials()
                }
                Ui.ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !header.showSetup
                  checked: header.tracking
                  busy: header.busy
                  enabled: header.switchEnabled
                  opacity: enabled ? 1 : 0.5
                  foreground: hero.foreground
                  onToggled: header.toggleTimer()
                }
              }
            }
          }
        }

        // ── Connect / change credentials ────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.showSetup

          Ui.PanelSeparator { foreground: root.foreground }
          Ui.PanelSectionHeader { text: strings.t("setup"); foreground: root.foreground; fontFamily: root.fontFamily }
          // The full error is only shown here, where it says what to fix.
          StatusText {
            text: root.errorKey ? strings.t(root.errorKey) : strings.t("setupHelp")
            color: root.errorKey ? root.urgent : root.dim
          }
          Ui.TextField { id: account; width: parent.width; foreground: root.foreground; placeholderText: strings.t("account"); maximumLength: 16; inputMethodHints: Qt.ImhDigitsOnly }
          Ui.TextField { id: token; width: parent.width; foreground: root.foreground; placeholderText: strings.t("token"); password: true; maximumLength: 1024 }
          Ui.Button {
            text: strings.t("connect"); focusable: true; bordered: true
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.busy && account.text.length > 0 && token.text.length > 0
            onClicked: {
              root.request({action: "configure", account_id: account.text.trim(), token: token.text.trim(), sync: root.backgroundSync})
              token.text = ""
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Ui.Button {
              text: strings.t("developer"); focusable: true; bordered: true
              width: root.configured ? (parent.width - parent.spacing) / 2 : parent.width
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: Qt.openUrlExternally("https://id.getharvest.com/developers")
            }
            Ui.Button {
              text: strings.t("cancel"); visible: root.configured; focusable: true; bordered: true
              width: (parent.width - parent.spacing) / 2
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: { token.text = ""; root.setup = false }
            }
          }
        }

        // ── Connected view ──────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: !root.showSetup

          GridLayout {
            width: parent.width
            columns: 4
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: strings.t("stat.today") }
            InfoValue {
              text: root.snapshot ? strings.t("hours").arg(root.elapsed(root.snapshot.hours,
                root.current !== null && root.current.date === root.snapshot.date, root.snapshot.date)) : "--"
            }
            InfoLabel { text: strings.t("stat.entries") }
            InfoValue { text: root.snapshot ? Commons.I18n.formatNumber(root.snapshot.entries.length, 0) : "--" }

            InfoLabel { text: strings.t("stat.status") }
            InfoValue {
              text: root.connectionIcon
              color: root.connectionColor
            }
            InfoLabel { text: strings.t("stat.sync") }
            InfoValue { text: root.backgroundSync ? strings.t("sync.auto") : strings.t("sync.manual") }
          }

          Ui.PanelSeparator { foreground: root.foreground }

          // New timer
          Ui.PanelSectionHeader {
            text: root.tracking ? strings.t("section.running") : strings.t("section.start")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Ui.Dropdown {
            id: projectPicker
            width: parent.width
            showLabel: false
            fontFamily: root.fontFamily
            options: root.projects.map(function(p, i) { return {value: String(i), label: p.name} })
            value: root.projectIndex >= 0 ? String(root.projectIndex) : ""
            enabled: !root.busy && !root.tracking
            onChanged: function(value) {
              root.projectIndex = Number(value)
              root.taskIndex = root.tasks.length ? 0 : -1
            }
          }
          Ui.Dropdown {
            id: taskPicker
            width: parent.width
            showLabel: false
            fontFamily: root.fontFamily
            options: root.tasks.map(function(t, i) { return {value: String(i), label: t.name} })
            value: root.taskIndex >= 0 ? String(root.taskIndex) : ""
            enabled: !root.busy && !root.tracking
            onChanged: function(value) { root.taskIndex = Number(value) }
          }
          Ui.TextField {
            id: notes
            width: parent.width
            visible: !root.tracking
            foreground: root.foreground
            placeholderText: strings.t("notes")
            maximumLength: 1000
            onAccepted: root.startTimer(notes.text)
          }
          Ui.Button {
            text: root.tracking ? strings.t("stop") : strings.t("start")
            iconText: root.tracking ? "󰓛" : "󰐊"
            focusable: true
            bordered: true
            width: parent.width
            foreground: root.tracking ? root.urgent : root.foreground
            accent: root.tracking ? root.urgent : Commons.Color.accent
            fontFamily: root.fontFamily
            enabled: root.tracking ? root.canChange : root.canStart
            onClicked: root.tracking ? root.stopTimer() : root.startTimer(notes.text)
          }
          StatusText { visible: root.snapshot !== null && root.projects.length === 0; text: strings.t("noProjects") }

          Ui.PanelSeparator { foreground: root.foreground }

          // Today's entries
          Ui.PanelSectionHeader { text: strings.t("section.entries"); foreground: root.foreground; fontFamily: root.fontFamily }
          StatusText { visible: root.snapshot !== null && root.snapshot.entries.length === 0; text: strings.t("empty") }
          Column {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.snapshot ? root.snapshot.entries : []
              EntryRow {
                required property var modelData
                width: parent.width
                entry: modelData
              }
            }
          }

          Ui.PanelSeparator { foreground: root.foreground }

          // Background sync, in the style of the Wi-Fi band row.
          Item {
            width: parent.width
            implicitHeight: Math.max(syncLabel.implicitHeight, syncSwitch.implicitHeight)
            Ui.PanelSectionHeader {
              id: syncLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("backgroundSync")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Ui.ToggleSwitch {
              id: syncSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              trackHeight: 16
              cursorPad: Style.space(3)
              checked: root.backgroundSync
              busy: root.busy
              foreground: root.foreground
              onToggled: root.request({action: "sync", enabled: !root.backgroundSync})
            }
          }
        }
      }
    }
  }

  component StatusText: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  // One time entry, laid out like a network row: glyph, two lines, trailing
  // hours and an inline resume action.
  component EntryRow: Ui.CursorSurface {
    id: row
    property var entry: ({})
    readonly property bool running: entry.running === true
    foreground: root.foreground
    current: running
    hasCursor: rowMouse.containsMouse && !running
    implicitHeight: Math.max(texts.implicitHeight, resumeButton.implicitHeight) + Style.space(14)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: row.running ? "󱎫" : "󰔟"
      color: row.running ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: texts
      anchors.left: glyph.right
      anchors.leftMargin: Style.space(12)
      anchors.right: trailing.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.entry.project || ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: (row.entry.task || "") + (row.entry.notes ? " · " + row.entry.notes : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    Row {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: strings.t("hours").arg(root.elapsed(row.entry.hours || 0, row.running, row.entry.date))
        color: row.running ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Ui.PanelActionButton {
        id: resumeButton
        anchors.verticalCenter: parent.verticalCenter
        visible: !row.running
        iconText: "󰐊"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.canChange && !root.tracking
        onClicked: root.request({action: "resume", id: row.entry.id})
      }
    }
  }
}
