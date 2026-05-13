import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// All setting widgets are declared as DIRECT children of PluginSettings.
// DMS's PluginSettings only iterates its direct `content` list to call
// loadValue() when `pluginService` becomes available; widgets nested in
// containers (Column, StyledRect, etc.) silently keep their defaultValue
// and never reflect the persisted settings. Use plain StyledText nodes as
// section headers in place of grouping rectangles.

PluginSettings {
    id: root
    pluginId: "dmsJira"

    // ---- Connection ----

    StyledText {
        text: "Connection"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingS
    }

    StringSetting {
        settingKey: "siteUrl"
        label: "Site URL"
        description: "e.g. https://your-org.atlassian.net"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "email"
        label: "Email"
        description: "Email on your Atlassian account (top-right of id.atlassian.com)"
        defaultValue: ""
    }

    SelectionSetting {
        id: tokenSourceSetting
        settingKey: "tokenSource"
        label: "Token source"
        description: "Where the plugin reads the API token from."
        options: [
            { label: "File", value: "file" },
            { label: "libsecret (secret-tool)", value: "libsecret" }
        ]
        defaultValue: "file"
    }

    StringSetting {
        settingKey: "tokenPath"
        label: "Token file path"
        description: "Path to a 0600 file containing the API token. Used when token source is File."
        defaultValue: ""
        // Visibility binds to the SelectionSetting's `value` property
        // directly (the `pluginData` injection isn't exposed inside
        // PluginSettings, so a binding via `pluginData.tokenSource`
        // would stay stuck at the first evaluation).
        visible: tokenSourceSetting.value === "file"
    }

    // ---- Query ----

    StyledText {
        text: "Query"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    StringSetting {
        settingKey: "jql"
        label: "JQL"
        description: "Default: your open assigned tickets."
        defaultValue: "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    }

    SelectionSetting {
        settingKey: "pollMinutes"
        label: "Poll interval"
        description: "How often to refresh the ticket list."
        options: [
            { label: "1 minute",   value: "1" },
            { label: "2 minutes",  value: "2" },
            { label: "5 minutes",  value: "5" },
            { label: "10 minutes", value: "10" },
            { label: "15 minutes", value: "15" },
            { label: "30 minutes", value: "30" },
            { label: "60 minutes", value: "60" }
        ]
        defaultValue: "5"
    }

    // ---- Display ----

    StyledText {
        text: "Display"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "showKeyOnBar"
        label: "Show active ticket key on bar"
        description: "If off, only the count is shown."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "branchPrefixByType"
        label: "Prefix branch name with issue type"
        description: "Adds feature/ / bug/ / chore/ when copying branch names."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "groupByProject"
        label: "Group by project"
        description: "Group tickets in the popout by their Jira project."
        defaultValue: false
    }

    // ---- Notifications ----

    StyledText {
        text: "Notifications"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "notifyAssigned"
        label: "New assignment"
        description: "Notify when a ticket is newly assigned to you."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notifyMentioned"
        label: "@mentions"
        description: "Notify on new comments on your open tickets that mention you."
        defaultValue: false
    }

    // ---- Demo ----

    StyledText {
        text: "Demo"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "demoMode"
        label: "Demo mode"
        description: "Replaces live tickets with fake-but-plausible ones across three made-up projects. Skips the Jira API entirely — safe for screenshots."
        defaultValue: false
    }
}

