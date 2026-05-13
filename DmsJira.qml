import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "AdfBuilder.js" as Adf

PluginComponent {
    id: root

    // ---- Persistent state (survives shell restarts) ----
    PluginGlobalVar {
        id: pinnedKey
        varName: "pinnedKey"
        defaultValue: ""
    }
    PluginGlobalVar {
        id: cachedIssues
        varName: "cachedIssues"
        defaultValue: []
    }
    PluginGlobalVar {
        id: lastPollAt
        varName: "lastPollAt"
        defaultValue: 0
    }
    PluginGlobalVar {
        id: seenCommentIds
        varName: "seenCommentIds"
        defaultValue: []
    }

    // ---- Settings (from DmsJiraSettings.qml) ----
    readonly property string siteUrl: pluginData.siteUrl || ""
    readonly property string email: pluginData.email || ""
    readonly property string tokenSource: pluginData.tokenSource || "file"
    readonly property string tokenPath: pluginData.tokenPath || ""
    readonly property string jql: pluginData.jql ||
        "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    readonly property int pollMinutes: parseInt(pluginData.pollMinutes || "5")
    readonly property bool showKeyOnBar: pluginData.showKeyOnBar ?? true
    readonly property bool branchPrefixByType: pluginData.branchPrefixByType ?? false
    readonly property bool groupByProject: pluginData.groupByProject ?? false
    readonly property bool notifyAssigned: pluginData.notifyAssigned ?? false
    readonly property bool notifyMentioned: pluginData.notifyMentioned ?? false
    readonly property bool demoMode: pluginData.demoMode ?? false

    // Fake-but-plausible data for screenshots / public docs. Shape matches a
    // real Jira REST v3 issue: { key, fields: { summary, status, priority,
    // issuetype, project, updated } } — keep it in sync if the live fields
    // list grows.
    readonly property var demoIssues: [
        {
            key: "ACME-247", fields: {
                summary: "Login redirect loops after SSO token refresh",
                status: { name: "In Progress", statusCategory: { key: "indeterminate" } },
                priority: { name: "High" },
                issuetype: { name: "Bug" },
                project: { key: "ACME", name: "Acme Platform" },
                updated: "2026-05-11T09:12:00.000+0000"
            }
        },
        {
            key: "ACME-260", fields: {
                summary: "Migrate notification pipeline to Kafka",
                status: { name: "In Progress", statusCategory: { key: "indeterminate" } },
                priority: { name: "Medium" },
                issuetype: { name: "Epic" },
                project: { key: "ACME", name: "Acme Platform" },
                updated: "2026-05-10T16:40:00.000+0000"
            }
        },
        {
            key: "ACME-251", fields: {
                summary: "Add pagination to user activity feed",
                status: { name: "To Do", statusCategory: { key: "new" } },
                priority: { name: "Medium" },
                issuetype: { name: "Task" },
                project: { key: "ACME", name: "Acme Platform" },
                updated: "2026-05-08T11:05:00.000+0000"
            }
        },
        {
            key: "WEB-1024", fields: {
                summary: "Checkout: persist cart across anonymous sessions",
                status: { name: "In Progress", statusCategory: { key: "indeterminate" } },
                priority: { name: "Medium" },
                issuetype: { name: "Story" },
                project: { key: "WEB", name: "Web Storefront" },
                updated: "2026-05-10T08:20:00.000+0000"
            }
        },
        {
            key: "WEB-1031", fields: {
                summary: "Footer link colors fail WCAG AA in dark mode",
                status: { name: "To Do", statusCategory: { key: "new" } },
                priority: { name: "Low" },
                issuetype: { name: "Bug" },
                project: { key: "WEB", name: "Web Storefront" },
                updated: "2026-05-07T14:55:00.000+0000"
            }
        },
        {
            key: "MOB-89", fields: {
                summary: "Crash on cold start when system locale is unset",
                status: { name: "In Review", statusCategory: { key: "indeterminate" } },
                priority: { name: "Highest" },
                issuetype: { name: "Task" },
                project: { key: "MOB", name: "Mobile App" },
                updated: "2026-05-11T07:48:00.000+0000"
            }
        },
        {
            key: "MOB-92", fields: {
                summary: "Offline mode for saved articles",
                status: { name: "To Do", statusCategory: { key: "new" } },
                priority: { name: "Medium" },
                issuetype: { name: "Story" },
                project: { key: "MOB", name: "Mobile App" },
                updated: "2026-05-06T10:15:00.000+0000"
            }
        }
    ]

    readonly property var demoTransitions: [
        { id: "11", name: "To Do",       to: { statusCategory: { key: "new" } } },
        { id: "21", name: "In Progress", to: { statusCategory: { key: "indeterminate" } } },
        { id: "31", name: "Done",        to: { statusCategory: { key: "done" } } }
    ]

    readonly property var issues:
        demoMode ? demoIssues : (cachedIssues.value || [])

    // Surface the last refresh error to the popout. Empty when healthy.
    property string lastError: ""

    // Our own Jira accountId, resolved lazily from /myself the first time we
    // need to scan comments for @mentions. Mention nodes in ADF carry the
    // accountId, not the email, so we can't match without it.
    property string _accountId: ""

    // Map a Jira issue type name to a Material Symbol icon.
    function typeIcon(name) {
        switch ((name || "").toLowerCase()) {
            case "bug": return "bug_report"
            case "task": return "task_alt"
            case "story": return "auto_stories"
            case "epic": return "flag"
            case "sub-task":
            case "subtask": return "subdirectory_arrow_right"
            case "improvement": return "upgrade"
            case "new feature": return "add_circle"
            default: return "label"
        }
    }

    // Priority indicator color. Hard-coded hex for high/low so the gradient
    // reads correctly on any theme; theme tokens used for highest/medium.
    function priorityColor(name) {
        switch ((name || "").toLowerCase()) {
            case "highest": return Theme.error
            case "high":    return "#ff7043"
            case "medium":  return Theme.warning
            case "low":     return "#42a5f5"
            case "lowest":  return Theme.surfaceVariantText
            default:        return Theme.surfaceVariantText
        }
    }

    // Status chip color, keyed off Jira's statusCategory ("new",
    // "indeterminate", "done", "undefined").
    function statusColor(categoryKey) {
        switch ((categoryKey || "").toLowerCase()) {
            case "done":          return "#43a047"
            case "indeterminate": return Theme.primary
            case "new":           return Theme.surfaceVariantText
            default:              return Theme.surfaceVariantText
        }
    }

    // Group issues by project key, preserving the order they were first seen
    // in the API response (so most-recently-updated project floats to top).
    readonly property var groupedIssues: {
        const map = {}
        const order = []
        for (let i = 0; i < issues.length; i++) {
            const it = issues[i]
            const proj = (it.fields && it.fields.project && it.fields.project.key) || "?"
            if (!map[proj]) {
                map[proj] = {
                    projectKey: proj,
                    projectName: (it.fields && it.fields.project && it.fields.project.name) || proj,
                    issues: []
                }
                order.push(proj)
            }
            map[proj].issues.push(it)
        }
        return order.map(function (k) { return map[k] })
    }

    // The "active" ticket: pinned if set, else most-recently-updated.
    readonly property var activeIssue: {
        const pin = pinnedKey.value
        if (pin) {
            for (let i = 0; i < issues.length; i++)
                if (issues[i].key === pin) return issues[i]
        }
        return issues.length > 0 ? issues[0] : null
    }

    // ---- HTTP client ----
    JiraClient {
        id: client
        siteUrl: root.siteUrl
        email: root.email
        tokenSource: root.tokenSource
        tokenPath: root.tokenPath
    }

    function refresh() {
        if (root.demoMode) {
            root.lastError = ""
            return
        }
        if (!root.siteUrl || !root.email) {
            root.lastError = "Site URL and email not configured"
            return
        }
        // Snapshot the previous poll's state *before* we overwrite it, so the
        // notification diff compares new-vs-old rather than new-vs-new.
        const prevPollAt = lastPollAt.value || 0
        const prevKeys = {}
        const prevCache = cachedIssues.value || []
        for (let i = 0; i < prevCache.length; i++) prevKeys[prevCache[i].key] = true

        client.search(root.jql, function (err, results) {
            if (err) {
                const msg = (err && err.message) ? err.message : String(err)
                console.warn("[dms-jira] search failed:", msg)
                root.lastError = msg
                return
            }
            root.lastError = ""
            cachedIssues.set(results)
            lastPollAt.set(Date.now())

            // First poll ever (no prior timestamp): just seed state, never
            // notify — otherwise every existing ticket/comment would alert.
            if (prevPollAt <= 0) {
                if (root.notifyMentioned) root._scanComments(results, 0)
                return
            }
            if (root.notifyAssigned) {
                for (let i = 0; i < results.length; i++) {
                    const it = results[i]
                    if (!prevKeys[it.key]) {
                        root.notify("Jira: ticket assigned to you",
                            it.key + " · " + ((it.fields && it.fields.summary) || ""))
                    }
                }
            }
            if (root.notifyMentioned) root._checkMentions(results, prevPollAt)
        })
    }

    // ---- @mention notifications ----
    //
    // For each currently-assigned open ticket, fetch its recent comments and
    // alert on any created since the previous poll whose ADF body mentions us.
    // Gated behind the (off-by-default) "@mentions" toggle because it costs
    // one extra request per open ticket.

    function _checkMentions(issues, sinceMs) {
        if (!issues || issues.length === 0) return
        if (root._accountId) { root._scanComments(issues, sinceMs); return }
        client.myself(function (err, me) {
            if (err) {
                console.warn("[dms-jira] /myself failed:", (err && err.message) || err)
                return
            }
            root._accountId = (me && me.accountId) || ""
            if (root._accountId) root._scanComments(issues, sinceMs)
        })
    }

    function _scanComments(issues, sinceMs) {
        const seeding = !(sinceMs > 0)         // first run: record, don't alert
        const seen = {}
        const known = seenCommentIds.value || []
        for (let i = 0; i < known.length; i++) seen[known[i]] = true

        const fresh = []
        let pending = issues.length
        function done() {
            if (--pending > 0) return
            if (fresh.length === 0) return
            let merged = (seenCommentIds.value || []).concat(fresh)
            if (merged.length > 400) merged = merged.slice(merged.length - 400)
            seenCommentIds.set(merged)
        }

        for (let i = 0; i < issues.length; i++) {
            const issue = issues[i]
            client.getComments(issue.key, function (err, comments) {
                if (err) { done(); return }
                for (let j = 0; j < comments.length; j++) {
                    const c = comments[j]
                    const id = c && c.id ? String(c.id) : ""
                    if (!id || seen[id]) continue
                    seen[id] = true
                    fresh.push(id)
                    if (seeding) continue
                    const createdMs = root._parseJiraDate(c.created || c.updated)
                    if (!isFinite(createdMs) || createdMs < sinceMs) continue
                    if (!root._bodyMentionsMe(c.body)) continue
                    const who = (c.author && c.author.displayName) || "Someone"
                    root.notify("Jira: " + who + " mentioned you",
                        issue.key + " · " + ((issue.fields && issue.fields.summary) || ""))
                }
                done()
            })
        }
    }

    // Jira timestamps use ±HHMM offsets ("2026-05-11T09:12:00.000+0000");
    // normalize to ±HH:MM so Date.parse handles them on every engine.
    function _parseJiraDate(s) {
        if (!s) return NaN
        return Date.parse(String(s).replace(/([+-]\d{2})(\d{2})$/, "$1:$2"))
    }

    // Walk an ADF node tree looking for a mention node targeting our accountId.
    function _bodyMentionsMe(node) {
        if (!node || typeof node !== "object") return false
        if (node.type === "mention" && node.attrs && node.attrs.id === root._accountId)
            return true
        const kids = node.content
        if (Array.isArray(kids)) {
            for (let i = 0; i < kids.length; i++)
                if (root._bodyMentionsMe(kids[i])) return true
        }
        return false
    }

    // Fire a desktop notification. DankMaterialShell is the notification
    // daemon, so a plain libnotify message renders natively; `-a` sets the
    // app name shown on the popup. No-op if `notify-send` isn't installed.
    function notify(summary, body) {
        Quickshell.execDetached(
            ["notify-send", "-a", "Jira Tickets", String(summary), String(body || "")])
    }

    Component.onCompleted: refresh()

    Timer {
        interval: Math.max(1, root.pollMinutes) * 60 * 1000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    // Debounced refresh whenever auth/query inputs change so saving settings
    // doesn't leave the user waiting up to pollMinutes for the next tick.
    Timer {
        id: settingsDebounce
        interval: 500
        repeat: false
        onTriggered: root.refresh()
    }
    onSiteUrlChanged: settingsDebounce.restart()
    onEmailChanged: settingsDebounce.restart()
    onTokenPathChanged: settingsDebounce.restart()
    onJqlChanged: settingsDebounce.restart()

    // Right-click pill → toggle pin on the currently-shown ticket.
    pillRightClickAction: () => {
        if (pinnedKey.value) pinnedKey.set("")
        else if (activeIssue) pinnedKey.set(activeIssue.key)
    }

    readonly property color pillColor: {
        if (issues.length === 0) return Theme.surfaceVariantText
        if (pinnedKey.value) return Theme.primary
        return Theme.surfaceText
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "task_alt"
                size: Theme.iconSizeSmall
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: {
                    if (!root.activeIssue) return root.issues.length.toString()
                    if (!root.showKeyOnBar) return root.issues.length.toString()
                    return root.activeIssue.key + " · " + root.issues.length
                }
                color: root.pillColor
                font.pixelSize: Theme.fontSizeMedium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingS

            DankIcon {
                name: "task_alt"
                size: Theme.iconSizeSmall
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.issues.length.toString()
                color: root.pillColor
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // Row delegate factored out so flat and grouped layouts share it.
    component IssueRow: Rectangle {
        id: row
        required property var issue
        required property real rowWidth

        readonly property var fields: issue.fields || ({})
        readonly property string statusName: (fields.status && fields.status.name) || ""
        readonly property string statusCategoryKey:
            (fields.status && fields.status.statusCategory && fields.status.statusCategory.key) || ""
        readonly property string priorityName: (fields.priority && fields.priority.name) || ""
        readonly property string typeName: (fields.issuetype && fields.issuetype.name) || ""
        readonly property bool isPinned: issue.key === pinnedKey.value

        // Inline action state.
        property bool expanded: false
        property var transitions: []
        property bool transitionsLoading: false
        property string transitionError: ""
        property bool transitionsOpen: false
        property bool composerOpen: false
        property bool composerSending: false
        property string composerError: ""

        function loadTransitionsIfNeeded() {
            if (transitions.length > 0 || transitionsLoading) return
            if (root.demoMode) { row.transitions = root.demoTransitions; return }
            transitionsLoading = true
            transitionError = ""
            client.getTransitions(issue.key, function (err, list) {
                row.transitionsLoading = false
                if (err) { row.transitionError = err.message || String(err); return }
                row.transitions = list
            })
        }

        function applyTransition(t) {
            if (root.demoMode) {
                row.transitionsOpen = false
                row.expanded = false
                return
            }
            client.doTransition(issue.key, t.id, function (err) {
                if (err) {
                    row.transitionError = err.message || String(err)
                    return
                }
                row.transitionsOpen = false
                row.expanded = false
                root.refresh()
            })
        }

        function submitComment(text) {
            if (!text || row.composerSending) return
            if (root.demoMode) {
                row.composerOpen = false
                row.expanded = false
                return
            }
            row.composerSending = true
            row.composerError = ""
            client.addComment(issue.key, text, function (err) {
                row.composerSending = false
                if (err) {
                    row.composerError = err.message || String(err)
                    return
                }
                row.composerOpen = false
                row.expanded = false
                root.refresh()
            })
        }

        width: rowWidth
        height: rowCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: row.expanded
            ? Theme.surfaceContainerHigh
            : (rowMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.04) : "transparent")
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        // Subtle left accent on the pinned row.
        Rectangle {
            visible: row.isPinned
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Theme.spacingS
            anchors.bottomMargin: Theme.spacingS
            width: 3
            radius: width / 2
            color: Theme.primary
        }

        Column {
            id: rowCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingM
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingXS

            Item {
                width: rowCol.width
                height: Math.max(headerLeft.implicitHeight, statusChip.implicitHeight)

                Row {
                    id: headerLeft
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    // Priority dot.
                    Rectangle {
                        width: 8
                        height: 8
                        radius: width / 2
                        color: root.priorityColor(row.priorityName)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Issue type icon.
                    DankIcon {
                        name: root.typeIcon(row.typeName)
                        size: Theme.iconSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: row.issue.key
                        color: row.isPinned ? Theme.primary : Theme.surfaceText
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Status chip, anchored to the right edge.
                Rectangle {
                    id: statusChip
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.statusName.length > 0
                    implicitWidth: statusText.implicitWidth + Theme.spacingM * 2
                    implicitHeight: statusText.implicitHeight + Theme.spacingXS * 2
                    radius: height / 2
                    color: Qt.rgba(
                        statusChip._chip.r,
                        statusChip._chip.g,
                        statusChip._chip.b,
                        0.15)
                    border.color: Qt.rgba(
                        statusChip._chip.r,
                        statusChip._chip.g,
                        statusChip._chip.b,
                        0.45)
                    border.width: 1

                    readonly property color _chip: root.statusColor(row.statusCategoryKey)

                    StyledText {
                        id: statusText
                        anchors.centerIn: parent
                        text: row.statusName
                        color: statusChip._chip
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                    }
                }
            }

            StyledText {
                text: row.fields.summary || ""
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                width: rowCol.width
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            // Expanded action area.
            Loader {
                active: row.expanded
                visible: active
                width: rowCol.width
                sourceComponent: Column {
                    spacing: Theme.spacingS

                    // Top divider.
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Qt.rgba(0, 0, 0, 0.08)
                    }

                    // Action chip bar.
                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS

                        ActionChip {
                            icon: "open_in_new"
                            label: "Open"
                            onTriggered: { root.openIssue(row.issue.key); row.expanded = false }
                        }
                        ActionChip {
                            icon: row.isPinned ? "push_pin" : "keep"
                            label: row.isPinned ? "Unpin" : "Pin"
                            highlighted: row.isPinned
                            onTriggered: {
                                if (row.isPinned) pinnedKey.set("")
                                else pinnedKey.set(row.issue.key)
                            }
                        }
                        ActionChip {
                            icon: "content_copy"
                            label: "Copy key"
                            onTriggered: { root.copyToClipboard(row.issue.key); row.expanded = false }
                        }
                        ActionChip {
                            icon: "alt_route"
                            label: "Copy branch"
                            onTriggered: {
                                root.copyToClipboard(root.branchName(row.issue))
                                row.expanded = false
                            }
                        }
                        ActionChip {
                            icon: "sync_alt"
                            label: "Status"
                            highlighted: row.transitionsOpen
                            onTriggered: {
                                row.transitionsOpen = !row.transitionsOpen
                                if (row.transitionsOpen) row.loadTransitionsIfNeeded()
                            }
                        }
                        ActionChip {
                            icon: "comment"
                            label: "Comment"
                            highlighted: row.composerOpen
                            onTriggered: { row.composerOpen = !row.composerOpen }
                        }
                    }

                    // Transitions list.
                    Column {
                        visible: row.transitionsOpen
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            visible: row.transitionsLoading
                            text: "Loading transitions…"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                        StyledText {
                            visible: row.transitionError.length > 0
                            text: row.transitionError
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }

                        Flow {
                            visible: !row.transitionsLoading
                                && row.transitionError.length === 0
                                && row.transitions.length > 0
                            width: parent.width
                            spacing: Theme.spacingS

                            Repeater {
                                model: row.transitions
                                delegate: TransitionChip {
                                    required property var modelData
                                    transition: modelData
                                    onTriggered: row.applyTransition(modelData)
                                }
                            }
                        }
                    }

                    // Comment composer.
                    Column {
                        visible: row.composerOpen
                        width: parent.width
                        spacing: Theme.spacingXS

                        Rectangle {
                            width: parent.width
                            height: Math.max(60, composerArea.implicitHeight + Theme.spacingS * 2)
                            radius: Theme.cornerRadius
                            color: Theme.surface
                            border.color: composerArea.activeFocus
                                ? Theme.primary
                                : Qt.rgba(0, 0, 0, 0.12)
                            border.width: 1

                            TextArea {
                                id: composerArea
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                placeholderText: "Add a comment…"
                                color: Theme.surfaceText
                                placeholderTextColor: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.WordWrap
                                background: null
                                enabled: !row.composerSending
                            }
                        }

                        StyledText {
                            visible: row.composerError.length > 0
                            text: row.composerError
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }

                        Row {
                            spacing: Theme.spacingS
                            anchors.right: parent.right

                            ActionChip {
                                icon: "close"
                                label: "Cancel"
                                onTriggered: {
                                    composerArea.text = ""
                                    row.composerOpen = false
                                }
                            }
                            ActionChip {
                                icon: row.composerSending ? "hourglass_top" : "send"
                                label: row.composerSending ? "Sending…" : "Send"
                                highlighted: true
                                onTriggered: row.submitComment(composerArea.text)
                            }
                        }
                    }
                }
            }
        }

        // z: -1 keeps this MouseArea behind the action chips so their own
        // MouseAreas capture clicks first when the row is expanded.
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            z: -1
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    row.expanded = !row.expanded
                    if (!row.expanded) {
                        row.transitionsOpen = false
                        row.composerOpen = false
                    }
                } else if (!row.expanded) {
                    root.openIssue(row.issue.key)
                }
            }
        }
    }

    // A pill-shaped clickable chip for the action bar.
    component ActionChip: Rectangle {
        id: chip
        property string icon: ""
        property string label: ""
        property bool highlighted: false
        signal triggered()

        implicitWidth: chipRow.implicitWidth + Theme.spacingM * 2
        implicitHeight: chipRow.implicitHeight + Theme.spacingXS * 2
        radius: height / 2
        color: chip.highlighted
            ? Theme.primary
            : (chipMouse.containsMouse
                ? Qt.rgba(0, 0, 0, 0.06)
                : Theme.surface)
        border.color: chip.highlighted ? Theme.primary : Qt.rgba(0, 0, 0, 0.15)
        border.width: 1

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Theme.spacingXS

            DankIcon {
                visible: chip.icon.length > 0
                name: chip.icon
                size: Theme.iconSizeSmall
                color: chip.highlighted ? Theme.onPrimary : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: chip.label
                color: chip.highlighted ? Theme.onPrimary : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.triggered()
        }
    }

    // A chip showing one available status transition.
    component TransitionChip: Rectangle {
        id: tchip
        property var transition
        signal triggered()

        readonly property color _accent: root.statusColor(
            (transition && transition.to && transition.to.statusCategory
                && transition.to.statusCategory.key) || "")
        readonly property string _label:
            (transition && transition.name) || "—"

        implicitWidth: tchipText.implicitWidth + Theme.spacingM * 2
        implicitHeight: tchipText.implicitHeight + Theme.spacingXS * 2
        radius: height / 2
        color: tchipMouse.containsMouse
            ? Qt.rgba(tchip._accent.r, tchip._accent.g, tchip._accent.b, 0.25)
            : Qt.rgba(tchip._accent.r, tchip._accent.g, tchip._accent.b, 0.12)
        border.color: Qt.rgba(tchip._accent.r, tchip._accent.g, tchip._accent.b, 0.45)
        border.width: 1

        StyledText {
            id: tchipText
            anchors.centerIn: parent
            text: tchip._label
            color: tchip._accent
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
        }

        MouseArea {
            id: tchipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tchip.triggered()
        }
    }

    popoutContent: Component {
        FocusScope {
            id: contentFocusScope
            width: parent ? parent.width : 0
            implicitHeight: mainContent.implicitHeight
            focus: true

            // PluginPopout's Loader looks for these two properties on the
            // loaded content root and assigns the actual close function /
            // popout reference. Forward closePopout to the PopoutComponent
            // so its X button (showCloseButton: true) actually fires.
            property var closePopout: null
            property var parentPopout: null

            PopoutComponent {
                id: mainContent
                width: parent.width
                closePopout: contentFocusScope.closePopout
                headerText: "Jira"
                detailsText: root.issues.length === 0
                    ? (root.siteUrl ? "No assigned tickets" : "Not configured")
                    : root.issues.length + " assigned"
                showCloseButton: true

                Flickable {
                    width: parent.width
                    height: Math.min(540, listCol.implicitHeight)
                    contentHeight: listCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: listCol
                    width: parent.width
                    spacing: Theme.spacingXS

                    // Flat list path.
                    Repeater {
                        model: root.groupByProject ? [] : root.issues
                        delegate: IssueRow {
                            required property var modelData
                            issue: modelData
                            rowWidth: listCol.width
                        }
                    }

                    // Grouped-by-project path.
                    Repeater {
                        model: root.groupByProject ? root.groupedIssues : []
                        delegate: Column {
                            required property var modelData
                            width: listCol.width
                            spacing: Theme.spacingXS
                            topPadding: Theme.spacingS

                            Row {
                                spacing: Theme.spacingS

                                StyledText {
                                    text: modelData.projectName
                                    color: Theme.primary
                                    font.weight: Font.Bold
                                    font.pixelSize: Theme.fontSizeMedium
                                }
                                StyledText {
                                    text: "(" + modelData.issues.length + ")"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Repeater {
                                model: modelData.issues
                                delegate: IssueRow {
                                    required property var modelData
                                    issue: modelData
                                    rowWidth: listCol.width
                                }
                            }
                        }
                    }

                    // Empty / error state.
                    StyledText {
                        visible: root.issues.length === 0
                        width: parent.width
                        text: {
                            if (!root.siteUrl)
                                return "Open Settings → Plugins → Jira Tickets to configure."
                            if (root.lastError)
                                return "Error: " + root.lastError
                            return "No tickets match the current JQL."
                        }
                        color: root.lastError ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }
                }
            }
        }
    }
    popoutWidth: 480
    popoutHeight: 600

    // Copy text to the Wayland clipboard via wl-copy. The text is passed as
    // a single argv arg with `--` so it isn't parsed as an option.
    function copyToClipboard(text) {
        if (!text) return
        Quickshell.execDetached(["wl-copy", "--", String(text)])
    }

    // Open a Jira issue in the user's browser. The siteUrl scheme is checked
    // against https and the key is validated to avoid handing a malformed URL
    // (or arbitrary file:// path) to xdg-open.
    function openIssue(key) {
        const base = (root.siteUrl || "").trim().replace(/\/+$/, "")
        if (!/^https:\/\/[^\s/]+/.test(base)) {
            console.warn("[dms-jira] refusing to open: siteUrl is not https")
            return
        }
        if (!/^[A-Z][A-Z0-9_]{1,9}-[1-9][0-9]{0,9}$/.test(key || "")) {
            console.warn("[dms-jira] refusing to open: invalid key", key)
            return
        }
        Qt.openUrlExternally(base + "/browse/" + key)
    }

    // Format a branch name from issue per DESIGN.md rules.
    function branchName(issue) {
        const slug = (issue.fields.summary || "")
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "")
            .substring(0, 50)
            .replace(/-[^-]*$/, function (m) { return m.length < 8 ? m : "" })
        let name = issue.key + "-" + slug
        if (root.branchPrefixByType) {
            const t = (issue.fields.issuetype && issue.fields.issuetype.name) || ""
            const prefix = t === "Bug" ? "bug"
                : (t === "Task" || t === "Story") ? "feature"
                : "chore"
            name = prefix + "/" + name
        }
        return name
    }
}
