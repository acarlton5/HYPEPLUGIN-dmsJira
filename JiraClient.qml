import QtQuick
import Quickshell
import Quickshell.Io
import "AdfBuilder.js" as Adf

// REST v3 wrapper around Jira Cloud. Auth is HTTP Basic with email + API token.
// All network calls use XMLHttpRequest (available in QML).
//
// Callbacks follow node-style: (err, result). err is null on success.
QtObject {
    id: root

    property string siteUrl: ""
    property string email: ""
    property string tokenSource: "file"
    property string tokenPath: ""

    // Token is read by shelling out — `cat` for the file source, `secret-tool
    // lookup` for libsecret. Qt blocks XHR / FileView reads of file:// by
    // default, and we'd rather not depend on QML_XHR_ALLOW_FILE_READ=1 in the
    // DMS service environment. The result is cached against a key derived
    // from the current token-source config; the cache invalidates whenever
    // that key would change.
    property string _token: ""
    property string _tokenCachedFor: ""
    property string _tokenCacheKeyPending: ""
    property var _pendingTokenCbs: []

    onTokenPathChanged:   { _token = ""; _tokenCachedFor = "" }
    onEmailChanged:       { _token = ""; _tokenCachedFor = "" }
    onTokenSourceChanged: { _token = ""; _tokenCachedFor = "" }

    property var _tokenProcess: Process {
        command: ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                root._token = (this.text || "").trim()
                root._tokenCachedFor = root._tokenCacheKeyPending
                const cbs = root._pendingTokenCbs
                root._pendingTokenCbs = []
                const fromLibsecret =
                    root._tokenCacheKeyPending.indexOf("libsecret:") === 0
                const emptyMsg = fromLibsecret
                    ? "no token in keyring for this email — store one with: " +
                      "secret-tool store --label='dms-jira' service dms-jira account " +
                      ((root.email || "").trim() || "<email>")
                    : "token file is empty or unreadable: " + root.tokenPath
                for (let i = 0; i < cbs.length; i++) {
                    if (!root._token) cbs[i](new Error(emptyMsg))
                    else cbs[i](null, root._token)
                }
            }
        }
    }

    // Issue keys are validated against this pattern before being interpolated
    // into URL paths. Jira keys are <PROJECT>-<N> where PROJECT is uppercase
    // letters / digits / underscores starting with a letter.
    readonly property var _keyRe: /^[A-Z][A-Z0-9_]{1,9}-[1-9][0-9]{0,9}$/

    function _validatedBase() {
        // Require HTTPS to protect the bearer credentials in transit.
        // Strip trailing slashes so we can safely concatenate paths.
        const s = (siteUrl || "").trim().replace(/\/+$/, "")
        if (!/^https:\/\/[^\s/]+/.test(s))
            throw new Error("siteUrl must be https:// — refusing to send credentials over " + (s || "(empty)"))
        return s
    }

    function _validatedEmail() {
        const e = (email || "").trim()
        // Reject any control character — defends against header injection
        // through the Basic auth payload.
        if (/[\x00-\x1f\x7f]/.test(e))
            throw new Error("email contains control characters")
        if (!e) throw new Error("email required")
        return e
    }

    function _validatedKey(key) {
        if (!_keyRe.test(key || ""))
            throw new Error("invalid issue key: " + key)
        return key
    }

    function _readTokenFromFile(cb) {
        if (!tokenPath)
            return cb(new Error("token path not set"))
        if (tokenPath.charAt(0) !== "/")
            return cb(new Error("token path must be absolute: " + tokenPath))
        const cacheKey = "file:" + tokenPath
        if (_token && _tokenCachedFor === cacheKey)
            return cb(null, _token)
        _pendingTokenCbs.push(cb)
        if (!_tokenProcess.running) {
            _tokenCacheKeyPending = cacheKey
            _tokenProcess.command = ["cat", tokenPath]
            _tokenProcess.running = true
        }
    }

    function _readTokenFromLibsecret(cb) {
        const mail = (email || "").trim()
        if (!mail)
            return cb(new Error("email required for libsecret token source"))
        const cacheKey = "libsecret:" + mail
        if (_token && _tokenCachedFor === cacheKey)
            return cb(null, _token)
        _pendingTokenCbs.push(cb)
        if (!_tokenProcess.running) {
            _tokenCacheKeyPending = cacheKey
            _tokenProcess.command = [
                "secret-tool", "lookup",
                "service", "dms-jira",
                "account", mail
            ]
            _tokenProcess.running = true
        }
    }

    function _withToken(cb) {
        const reader = tokenSource === "libsecret"
            ? _readTokenFromLibsecret
            : _readTokenFromFile
        reader(function (err) {
            if (err) return cb(err)
            cb(null, _token)
        })
    }

    function _request(method, path, body, cb) {
        let base, mail
        try { base = _validatedBase(); mail = _validatedEmail() }
        catch (e) { return cb(e) }
        _withToken(function (err, token) {
            if (err) return cb(err)
            const xhr = new XMLHttpRequest()
            xhr.open(method, base + path)
            xhr.setRequestHeader("Accept", "application/json")
            if (body) xhr.setRequestHeader("Content-Type", "application/json")
            xhr.setRequestHeader("Authorization", "Basic " + Qt.btoa(mail + ":" + token))
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                if (xhr.status >= 200 && xhr.status < 300) {
                    try { cb(null, xhr.responseText ? JSON.parse(xhr.responseText) : null) }
                    catch (e) { cb(e) }
                } else {
                    cb(new Error("HTTP " + xhr.status + ": " + xhr.responseText))
                }
            }
            xhr.send(body ? JSON.stringify(body) : null)
        })
    }

    function search(jql, cb) {
        // Jira Cloud's legacy /rest/api/3/search is being removed in favour
        // of /rest/api/3/search/jql which uses token-based pagination.
        const path = "/rest/api/3/search/jql?jql=" + encodeURIComponent(jql) +
            "&fields=summary,status,priority,issuetype,updated,assignee,project" +
            "&maxResults=50"
        _request("GET", path, null, function (err, body) {
            if (err) return cb(err)
            cb(null, (body && body.issues) || [])
        })
    }

    function getTransitions(key, cb) {
        try { key = _validatedKey(key) } catch (e) { return cb(e) }
        _request("GET", "/rest/api/3/issue/" + key + "/transitions", null, function (err, body) {
            if (err) return cb(err)
            cb(null, body.transitions || [])
        })
    }

    function doTransition(key, transitionId, cb) {
        try { key = _validatedKey(key) } catch (e) { return cb(e) }
        if (!/^[0-9]+$/.test(String(transitionId)))
            return cb(new Error("invalid transition id"))
        _request("POST", "/rest/api/3/issue/" + key + "/transitions",
            { transition: { id: String(transitionId) } }, cb)
    }

    function addComment(key, plainText, cb) {
        try { key = _validatedKey(key) } catch (e) { return cb(e) }
        _request("POST", "/rest/api/3/issue/" + key + "/comment",
            { body: Adf.fromPlainText(plainText) }, cb)
    }

    // Current user — used to resolve our own accountId so we can detect
    // @mentions in comment bodies (mention nodes carry accountId, not email).
    function myself(cb) {
        _request("GET", "/rest/api/3/myself", null, cb)
    }

    // Recent comments on an issue, newest first. Capped — we only ever look
    // at comments newer than the previous poll, so a small page is plenty.
    function getComments(key, cb) {
        try { key = _validatedKey(key) } catch (e) { return cb(e) }
        _request("GET", "/rest/api/3/issue/" + key +
            "/comment?orderBy=-created&maxResults=20", null, function (err, body) {
            if (err) return cb(err)
            cb(null, (body && body.comments) || [])
        })
    }
}
