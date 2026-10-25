import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

DesktopPluginComponent {
    id: root

    property bool acceptsKeyboardFocus: true

    widgetWidth: 320
    widgetHeight: 400
    minWidth: 260
    minHeight: 240

    property real bgOpacity: 0.85
    property color cardBg: Theme.withAlpha(Theme.surfaceContainer, bgOpacity)
    property color borderCol: Theme.withAlpha(Theme.outlineVariant, 0.45)
    property real cardRadius: 28

    // Authentic Google Sans fonts
    FontLoader {
        id: fontBold
        source: "./fonts/GoogleSans-Bold.ttf"
    }

    FontLoader {
        id: fontMedium
        source: "./fonts/GoogleSans-Medium.ttf"
    }

    FontLoader {
        id: fontRegular
        source: "./fonts/GoogleSans-Regular.ttf"
    }

    readonly property string sansBold: fontBold.name.length > 0 ? fontBold.name : "Google Sans"
    readonly property string sansMedium: fontMedium.name.length > 0 ? fontMedium.name : "Google Sans Medium"
    readonly property string sansRegular: fontRegular.name.length > 0 ? fontRegular.name : "Google Sans"

    // Active calendar filter ("all" or a calendar UUID)
    property string activeCalendarId: "all"
    property bool showCompleted: false
    property bool isSyncing: false
    property var calendarMap: ({})
    property string defaultCalendarId: ""

    // Models
    ListModel { id: calendarModel }
    ListModel { id: taskModel }

    readonly property int totalCount: taskModel.count
    readonly property int pendingCount: {
        var count = 0;
        for (var i = 0; i < taskModel.count; i++) {
            if (!taskModel.get(i).done)
                count++;
        }
        return count;
    }

    Component.onCompleted: {
        refreshAll();
    }

    function refreshAll() {
        root.isSyncing = true;
        if (!listCalsProc.running)
            listCalsProc.running = true;
        if (!listTasksProc.running)
            listTasksProc.running = true;
    }

    function manualSync() {
        root.isSyncing = true;
        // Trigger background account sync to Google
        Quickshell.execDetached(["dcal", "ipc", "accounts.refresh"]);
        // Fetch fresh local state
        syncDelayedTimer.restart();
    }

    Timer {
        id: syncDelayedTimer
        interval: 600
        onTriggered: {
            if (!listCalsProc.running)
                listCalsProc.running = true;
            if (!listTasksProc.running)
                listTasksProc.running = true;
        }
    }

    // Auto-refresh every 20 seconds
    Timer {
        id: autoRefreshTimer
        interval: 20000
        repeat: true
        running: true
        onTriggered: {
            if (!listTasksProc.running)
                listTasksProc.running = true;
        }
    }

    // List Calendars Process
    Process {
        id: listCalsProc
        command: ["dcal", "ipc", "calendars.list"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var list = JSON.parse(text);
                    if (Array.isArray(list)) {
                        var map = {};
                        var cals = [];
                        var defId = "";

                        for (var i = 0; i < list.length; i++) {
                            var item = list[i];
                            if (item.holdsTasks === true) {
                                map[item.id] = item.name || "Tasks";
                                cals.push({
                                    "id": item.id,
                                    "name": item.name || "Tasks",
                                    "color": item.color || ""
                                });
                                if (!defId || item.name === "General") {
                                    defId = item.id;
                                }
                            }
                        }

                        root.calendarMap = map;
                        root.defaultCalendarId = defId;

                        calendarModel.clear();
                        calendarModel.append({ "id": "all", "name": "All", "color": "" });
                        for (var j = 0; j < cals.length; j++) {
                            calendarModel.append(cals[j]);
                        }
                    }
                } catch (e) {
                    // Ignore JSON errors
                }
            }
        }
    }

    // List Tasks Process
    Process {
        id: listTasksProc
        command: ["dcal", "ipc", "tasks.list", "includeCompleted=" + (root.showCompleted ? "true" : "false")]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                root.isSyncing = false;
                try {
                    var data = JSON.parse(text);
                    if (data && Array.isArray(data.tasks)) {
                        taskModel.clear();
                        var now = new Date();
                        var todayStr = Qt.formatDate(now, "yyyy-MM-dd");
                        var tomorrow = new Date(now.getTime() + 86400000);
                        var tomorrowStr = Qt.formatDate(tomorrow, "yyyy-MM-dd");

                        for (var i = 0; i < data.tasks.length; i++) {
                            var t = data.tasks[i];

                            // Filter by active calendar if not "all"
                            if (root.activeCalendarId !== "all" && t.calendarId !== root.activeCalendarId) {
                                continue;
                            }

                            var isDone = (t.status === "completed" || t.percentComplete === 100);
                            var dueBadge = "";
                            var isOverdue = false;

                            if (t.due) {
                                var dueDate = new Date(t.due);
                                var dueDateStr = Qt.formatDate(dueDate, "yyyy-MM-dd");

                                if (dueDateStr === todayStr) {
                                    dueBadge = "Today";
                                } else if (dueDateStr === tomorrowStr) {
                                    dueBadge = "Tomorrow";
                                } else if (dueDate < now && dueDateStr !== todayStr) {
                                    dueBadge = Qt.formatDate(dueDate, "MMM d");
                                    isOverdue = !isDone;
                                } else {
                                    dueBadge = Qt.formatDate(dueDate, "MMM d");
                                }
                            }

                            // Clean summary display
                            var rawSummary = t.summary || "Task";
                            var cleanTitle = rawSummary;
                            var tagBadge = "";

                            // Extract course prefix like [192.134 Grundzüge...]
                            if (rawSummary.startsWith("[")) {
                                var endBracket = rawSummary.indexOf("]");
                                if (endBracket > 1) {
                                    var course = rawSummary.substring(1, endBracket);
                                    if (course.length > 18) {
                                        course = course.substring(0, 16) + "...";
                                    }
                                    tagBadge = course;
                                    cleanTitle = rawSummary.substring(endBracket + 1).trim();
                                }
                            }

                            var calName = root.calendarMap[t.calendarId] || "";

                            taskModel.append({
                                "id": t.id,
                                "rawSummary": rawSummary,
                                "text": cleanTitle,
                                "tagBadge": tagBadge,
                                "done": isDone,
                                "calendarId": t.calendarId,
                                "calendarName": calName,
                                "due": t.due || "",
                                "dueLabel": dueBadge,
                                "isOverdue": isOverdue,
                                "description": t.description || ""
                            });
                        }
                    }
                } catch (e) {
                    // Ignore JSON errors
                }
            }
        }
    }

    // Toggle Task Complete
    function toggleTask(index) {
        if (index < 0 || index >= taskModel.count)
            return;
        var item = taskModel.get(index);
        var targetState = !item.done;

        // Optimistic UI update
        taskModel.setProperty(index, "done", targetState);

        // Send to dcal
        Quickshell.execDetached(["dcal", "ipc", "tasks.complete", "id=" + item.id, "completed=" + (targetState ? "true" : "false")]);
        Quickshell.execDetached(["dcal", "ipc", "accounts.refresh"]);

        // Sync fresh state after short delay
        syncDelayedTimer.restart();
    }

    // Add Task
    function addTask(text) {
        var trimmed = text ? text.trim() : "";
        if (!trimmed)
            return;

        var targetCal = root.activeCalendarId;
        if (targetCal === "all" || !targetCal) {
            targetCal = root.defaultCalendarId || (calendarModel.count > 1 ? calendarModel.get(1).id : "");
        }

        if (!targetCal)
            return;

        Quickshell.execDetached(["dcal", "ipc", "tasks.create", "calendarId=" + targetCal, "summary=" + trimmed]);
        Quickshell.execDetached(["dcal", "ipc", "accounts.refresh"]);

        // Optimistic add
        taskModel.append({
            "id": "temp_" + Date.now(),
            "rawSummary": trimmed,
            "text": trimmed,
            "tagBadge": "",
            "done": false,
            "calendarId": targetCal,
            "calendarName": root.calendarMap[targetCal] || "Tasks",
            "due": "",
            "dueLabel": "",
            "isOverdue": false,
            "description": ""
        });

        syncDelayedTimer.restart();
    }

    // Delete Task
    function deleteTask(index) {
        if (index < 0 || index >= taskModel.count)
            return;
        var item = taskModel.get(index);
        var taskId = item.id;

        taskModel.remove(index);

        Quickshell.execDetached(["dcal", "ipc", "tasks.delete", "id=" + taskId]);
        Quickshell.execDetached(["dcal", "ipc", "accounts.refresh"]);

        syncDelayedTimer.restart();
    }

    // Outer Pixel Container Card
    Rectangle {
        id: card
        anchors.fill: parent
        radius: root.cardRadius
        color: root.cardBg
        border.color: root.borderCol
        border.width: 1
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            // Header Row (Pixel Material 3 Style)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    width: 32
                    height: 32
                    radius: 16
                    color: Theme.withAlpha(Theme.primary, 0.2)

                    DankIcon {
                        anchors.centerIn: parent
                        name: "task_alt"
                        size: 18
                        color: Theme.primary
                    }
                }

                Text {
                    text: "Tasks"
                    font.family: root.sansBold
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    color: "#ffffff"
                    Layout.fillWidth: true
                }

                // Pending Task Count Badge
                Rectangle {
                    visible: root.pendingCount > 0
                    radius: 12
                    color: Theme.withAlpha(Theme.primary, 0.25)
                    implicitWidth: countText.implicitWidth + 14
                    implicitHeight: 22

                    Text {
                        id: countText
                        anchors.centerIn: parent
                        text: root.pendingCount
                        font.family: root.sansMedium
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        color: "#ffffff"
                    }
                }

                // Sync / Refresh Button (Spins when syncing)
                Rectangle {
                    width: 28
                    height: 28
                    radius: 14
                    color: syncMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                    DankIcon {
                        id: syncIcon
                        anchors.centerIn: parent
                        name: "sync"
                        size: 16
                        color: root.isSyncing ? Theme.primary : "#ffffff"
                        opacity: root.isSyncing ? 1.0 : 0.75
                        rotation: 0

                        RotationAnimation on rotation {
                            running: root.isSyncing
                            loops: Animation.Infinite
                            from: 0
                            to: 360
                            duration: 1000
                        }
                    }

                    MouseArea {
                        id: syncMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.manualSync()
                    }
                }

                // Show/Hide Completed Toggle
                Rectangle {
                    width: 28
                    height: 28
                    radius: 14
                    color: (completedMouse.containsMouse || root.showCompleted) ? Theme.surfaceContainerHighest : "transparent"

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.showCompleted ? "visibility" : "visibility_off"
                        size: 16
                        color: root.showCompleted ? Theme.primary : "#ffffff"
                        opacity: root.showCompleted ? 1.0 : 0.75
                    }

                    MouseArea {
                        id: completedMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.showCompleted = !root.showCompleted;
                            listTasksProc.running = true;
                        }
                    }
                }
            }

            // Task List Filter Chips Row (All, General, Shopping, Submissions)
            Item {
                visible: calendarModel.count > 2
                Layout.fillWidth: true
                height: 28

                ListView {
                    id: chipView
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    model: calendarModel

                    delegate: Rectangle {
                        id: chip
                        height: 26
                        radius: 13
                        readonly property bool isSelected: root.activeCalendarId === model.id
                        color: isSelected ? Theme.primary : Theme.withAlpha(Theme.surfaceContainerHighest, 0.7)
                        border.color: isSelected ? Theme.primary : Theme.withAlpha(Theme.outlineVariant, 0.35)
                        border.width: 1
                        implicitWidth: chipLabel.implicitWidth + 20

                        Text {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: model.name
                            font.family: root.sansMedium
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            color: chip.isSelected ? Theme.onPrimary : "#ffffff"
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activeCalendarId = model.id;
                                listTasksProc.running = true;
                            }
                        }
                    }
                }
            }

            // Input Row (Pixel Pill Quick Add)
            Rectangle {
                Layout.fillWidth: true
                height: 40
                radius: 20
                color: Theme.surfaceContainerHigh
                border.color: inputField.activeFocus ? Theme.primary : Theme.withAlpha(Theme.outlineVariant, 0.35)
                border.width: inputField.activeFocus ? 2 : 1

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 8
                    spacing: 8

                    DankIcon {
                        name: "add"
                        size: 18
                        color: inputField.activeFocus ? Theme.primary : "#ffffff"
                        opacity: inputField.activeFocus ? 1.0 : 0.7
                    }

                    TextInput {
                        id: inputField
                        Layout.fillWidth: true
                        color: "#ffffff"
                        font.family: root.sansRegular
                        font.pixelSize: 13
                        selectByMouse: true
                        clip: true

                        Text {
                            anchors.fill: parent
                            visible: !inputField.text && !inputField.activeFocus
                            text: {
                                if (root.activeCalendarId !== "all" && root.calendarMap[root.activeCalendarId]) {
                                    return "Add to " + root.calendarMap[root.activeCalendarId] + "...";
                                }
                                return "Add a task...";
                            }
                            font.family: root.sansRegular
                            color: Qt.rgba(1, 1, 1, 0.55)
                            font.pixelSize: 13
                        }

                        onAccepted: {
                            root.addTask(inputField.text);
                            inputField.text = "";
                        }
                    }

                    Rectangle {
                        visible: inputField.text.length > 0
                        width: 26
                        height: 26
                        radius: 13
                        color: addBtnMouse.containsMouse ? Theme.primary : Theme.withAlpha(Theme.primary, 0.85)

                        DankIcon {
                            anchors.centerIn: parent
                            name: "arrow_forward"
                            size: 14
                            color: Theme.onPrimary
                        }

                        MouseArea {
                            id: addBtnMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.addTask(inputField.text);
                                inputField.text = "";
                            }
                        }
                    }
                }
            }

            // Task List
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Empty State
                ColumnLayout {
                    anchors.centerIn: parent
                    visible: root.totalCount === 0 && !root.isSyncing
                    spacing: 8

                    DankIcon {
                        Layout.alignment: Qt.AlignHCenter
                        name: "task_alt"
                        size: 36
                        color: Theme.primary
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "All tasks completed!"
                        font.family: root.sansMedium
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "#ffffff"
                    }
                }

                ListView {
                    id: taskListView
                    anchors.fill: parent
                    clip: true
                    spacing: 4
                    model: taskModel

                    delegate: Rectangle {
                        id: taskDelegate
                        width: taskListView.width
                        height: tagRow.visible ? 48 : 38
                        radius: 14
                        color: delegateMouse.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.6) : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 10

                            // Material 3 Circular Checkbox
                            Rectangle {
                                id: checkbox
                                width: 22
                                height: 22
                                radius: 11
                                color: model.done ? Theme.primary : "transparent"
                                border.color: model.done ? Theme.primary : Qt.rgba(1, 1, 1, 0.5)
                                border.width: model.done ? 0 : 2

                                DankIcon {
                                    anchors.centerIn: parent
                                    visible: model.done
                                    name: "check"
                                    size: 14
                                    color: Theme.onPrimary
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleTask(index)
                                }
                            }

                            // Task Text & Meta Details
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: model.text
                                    font.family: root.sansRegular
                                    font.pixelSize: 13
                                    font.strikeout: model.done
                                    color: model.done ? Qt.rgba(1, 1, 1, 0.45) : "#ffffff"
                                    elide: Text.ElideRight

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.toggleTask(index)
                                    }
                                }

                                // Sub-row: Course tag or due date
                                RowLayout {
                                    id: tagRow
                                    visible: model.tagBadge.length > 0 || model.dueLabel.length > 0
                                    spacing: 6

                                    // Course / Category Tag
                                    Rectangle {
                                        visible: model.tagBadge.length > 0
                                        height: 16
                                        radius: 8
                                        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.8)
                                        border.color: Theme.withAlpha(Theme.outlineVariant, 0.25)
                                        border.width: 1
                                        implicitWidth: tagLabel.implicitWidth + 10

                                        Text {
                                            id: tagLabel
                                            anchors.centerIn: parent
                                            text: model.tagBadge
                                            font.family: root.sansMedium
                                            font.pixelSize: 9
                                            font.weight: Font.Medium
                                            color: "#ffffff"
                                            opacity: 0.85
                                        }
                                    }

                                    // Due Date Pill
                                    Rectangle {
                                        visible: model.dueLabel.length > 0
                                        height: 16
                                        radius: 8
                                        color: model.isOverdue ? Theme.errorContainer : Theme.withAlpha(Theme.primary, 0.2)
                                        border.color: model.isOverdue ? Theme.error : Theme.withAlpha(Theme.primary, 0.4)
                                        border.width: 1
                                        implicitWidth: dueLabel.implicitWidth + 10

                                        Text {
                                            id: dueLabel
                                            anchors.centerIn: parent
                                            text: model.dueLabel
                                            font.family: root.sansMedium
                                            font.pixelSize: 9
                                            font.weight: Font.Medium
                                            color: model.isOverdue ? "#ffffff" : Theme.primary
                                        }
                                    }
                                }
                            }

                            // Delete Task Button
                            Rectangle {
                                width: 24
                                height: 24
                                radius: 12
                                opacity: delegateMouse.containsMouse ? 1 : 0
                                color: delMouse.containsMouse ? Theme.errorContainer : "transparent"

                                Behavior on opacity {
                                    NumberAnimation { duration: 150 }
                                }

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "close"
                                    size: 14
                                    color: delMouse.containsMouse ? Theme.onErrorContainer : "#ffffff"
                                }

                                MouseArea {
                                    id: delMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.deleteTask(index)
                                }
                            }
                        }

                        MouseArea {
                            id: delegateMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                        }
                    }
                }
            }
        }
    }
}
