import QtQuick
import Quickshell.Io
import "TimeTracking.js" as TT

// Client for the TimeTracking Online REST API
// (https://demo.timetracking-online.com/api/docs/index.html).
//
// Auth: password grant on `auth/authorize`, then refresh-token grant. Tokens
// are kept in the plugin's DMS state; the password is read from the system
// keyring (secret-tool) only when a fresh login is needed.
//
// Data is split in two refresh groups:
//   refreshFast(): live minutes, current entry, allowed bookings (cheap; the
//                  bar polls it every minute)
//   refreshSlow(): week, month, time account, vacation, absences, today's
//                  entries, birthdays (on panel open and every 10 minutes)
Item {
    id: client

    property string apiUrl: ""
    property string username: ""
    property var pluginService: null
    property string pluginId: ""

    readonly property string keyringService: "dms-timetracking-online"
    readonly property bool configured: apiUrl.trim() !== "" && username.trim() !== ""

    // ── Data (raw API shapes) ──
    property var live: null           // { workingMinutesNet, overTimeMinutes }
    property var current: null        // current/last working time entry, or null
    property var allowed: []          // currently allowed booking types
    property var days: []             // daily summaries, Monday..today
    property var month: null          // working_time/months/my
    property var timeBalances: []     // time_balances/current/my
    property var absenceBalances: []  // absence_balances/my/all
    property var absences: []         // working_time_exceptions/slimmed/my
    property var todayEntries: []     // working_time/entries for today
    property var birthdays: []        // names of colleagues with birthday today
    property bool fastLoaded: false
    property bool slowLoaded: false
    property bool busy: false         // a booking is in flight
    property string error: ""

    signal booked(string label)
    signal bookingFailed(string message)

    // ── Auth ──
    property var _auth: null          // { apiUrl, username, accessToken, refreshToken, expiresAt (ms) }
    property string _password: ""
    property var _authWaiters: []
    property bool _authBusy: false
    property bool _authLoaded: false

    onApiUrlChanged: _resetSession()
    onUsernameChanged: _resetSession()

    // The saved token is read lazily: DMS hands the plugin its state and
    // settings only after creation.
    function _loadSavedAuth() {
        if (_authLoaded || !pluginService)
            return;
        _authLoaded = true;
        const saved = pluginService.loadPluginState(pluginId, "auth", null);
        if (saved && saved.apiUrl === apiUrl && saved.username === username)
            _auth = saved;
    }

    // Call after the password in the keyring changed.
    function forgetCredentials() {
        _password = "";
        _auth = null;
        _saveAuth();
    }

    function _resetSession() {
        _password = "";
        _auth = null;
        _authLoaded = false;
        fastLoaded = false;
        slowLoaded = false;
    }

    function _saveAuth() {
        if (pluginService)
            pluginService.savePluginState(pluginId, "auth", _auth);
    }

    function _url(path) {
        return apiUrl.trim().replace(/\/+$/, "") + "/" + path;
    }

    // Raw request; cb(status, json). status 0 = network failure.
    function _xhr(method, path, body, token, cb) {
        const x = new XMLHttpRequest();
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE)
                return;
            let data = null;
            try {
                data = x.responseText ? JSON.parse(x.responseText) : null;
            } catch (e) {
                data = null;
            }
            cb(x.status, data);
        };
        x.open(method, _url(path));
        x.setRequestHeader("Accept", "application/json");
        if (body !== null && body !== undefined)
            x.setRequestHeader("Content-Type", "application/json");
        if (token)
            x.setRequestHeader("Authorization", "Bearer " + token);
        x.send(body !== null && body !== undefined ? JSON.stringify(body) : null);
    }

    function _describe(status, data) {
        if (status === 0)
            return "Cannot reach " + apiUrl;
        const msg = data && data.message ? data.message : "";
        return "HTTP " + status + (msg ? ": " + msg : "");
    }

    function _authValid() {
        return _auth && _auth.accessToken && _auth.expiresAt - 60000 > Date.now();
    }

    // cb(errorString | "")
    function _ensureAuth(cb) {
        _loadSavedAuth();
        if (_authValid()) {
            cb("");
            return;
        }
        _authWaiters.push(cb);
        if (_authBusy)
            return;
        _authBusy = true;
        if (_auth && _auth.refreshToken)
            _grant({
                "grant_type": "refresh_token",
                "refresh_token": _auth.refreshToken
            }, err => err ? _passwordLogin() : _authDone(""));
        else
            _passwordLogin();
    }

    function _passwordLogin() {
        if (_password !== "") {
            _grant({
                "grant_type": "password",
                "username": username.trim(),
                "password": _password
            }, err => {
                if (err)
                    _password = ""; // look it up again next time; it may have changed
                _authDone(err);
            });
            return;
        }
        lookupProc.command = ["secret-tool", "lookup", "service", keyringService, "account", username.trim()];
        lookupProc.running = true;
        lookupWatchdog.restart();
    }

    function _grant(body, cb) {
        _xhr("POST", "auth/authorize", body, "", (status, data) => {
            if (status >= 200 && status < 300 && data && data.access_token) {
                const expiresAt = Date.parse(data.expires_at) || (Date.now() + (data.expires_in || 300) * 1000);
                _auth = {
                    "apiUrl": apiUrl,
                    "username": username,
                    "accessToken": data.access_token,
                    "refreshToken": data.refresh_token || "",
                    "expiresAt": expiresAt
                };
                _saveAuth();
                cb("");
            } else {
                cb(status === 400 || status === 401 ? "Login failed: check username and password" : "Login failed: " + _describe(status, data));
            }
        });
    }

    function _authDone(err) {
        _authBusy = false;
        const waiters = _authWaiters;
        _authWaiters = [];
        waiters.forEach(w => w(err));
    }

    Process {
        id: lookupProc
        // secret-tool prints nothing (and exits 1) when no item matches.
        stdout: StdioCollector {
            onStreamFinished: {
                if (!lookupWatchdog.running)
                    return; // already timed out
                lookupWatchdog.stop();
                const pw = text.replace(/\n$/, "");
                if (pw === "") {
                    client._authDone("No password in the keyring for " + client.username.trim() + ": set it in the plugin settings");
                    return;
                }
                client._password = pw;
                client._passwordLogin();
            }
        }
    }

    // A missing secret-tool never reports back; don't leave callers hanging.
    Timer {
        id: lookupWatchdog
        interval: 10000
        onTriggered: client._authDone("Could not read the password: is secret-tool (libsecret) installed and the keyring unlocked?")
    }

    // Authenticated request; cb(error, data, status). One retry after a 401
    // with a fresh login.
    function request(method, path, body, cb, _retried) {
        _ensureAuth(err => {
            if (err) {
                cb(err, null, 0);
                return;
            }
            _xhr(method, path, body, _auth.accessToken, (status, data) => {
                if (status === 401 && !_retried) {
                    _auth = Object.assign({}, _auth, {
                        "expiresAt": 0
                    });
                    request(method, path, body, cb, true);
                    return;
                }
                if (status >= 200 && status < 300)
                    cb("", data, status);
                else
                    cb(_describe(status, data), data, status);
            });
        });
    }

    // Run several GETs in parallel; done(firstError) once all finished.
    function _batch(jobs, done) {
        let pending = jobs.length;
        let firstError = "";
        jobs.forEach(job => {
            request("GET", job.path, null, (err, data, status) => {
                if (err && !(job.optional || (job.allowStatus || []).indexOf(status) >= 0))
                    firstError = firstError || err;
                job.apply(err ? null : data, status);
                if (--pending === 0)
                    done(firstError);
            });
        });
    }

    function refreshFast() {
        if (!configured)
            return;
        const now = new Date().toISOString();
        _batch([
            {
                "path": "working_time/days/user/live?pendingWorkingTimeEnd=" + encodeURIComponent(now),
                "apply": d => client.live = d
            },
            {
                // No entry yet (new user) answers with an error status.
                "path": "working_time/entries/current",
                "optional": true,
                "apply": d => client.current = d
            },
            {
                "path": "working_time/booking_types/currently_allowed/my",
                "optional": true,
                "apply": d => client.allowed = d || []
            }
        ], err => {
            client.error = err;
            client.fastLoaded = err === "";
        });
    }

    function refreshSlow() {
        if (!configured)
            return;
        const today = new Date();
        const t = TT.isoDate(today);
        const monday = TT.isoDate(TT.mondayOf(today));
        const until = TT.isoDate(new Date(today.getFullYear(), today.getMonth(), today.getDate() + 120));
        _batch([
            {
                "path": "working_time/days/user?from=" + monday + "&to=" + t,
                "optional": true,
                "apply": d => client.days = d || []
            },
            {
                "path": "working_time/months/my?yearMonth=" + t.slice(0, 7),
                "optional": true,
                "apply": d => client.month = d
            },
            {
                "path": "time_balances/current/my",
                "optional": true,
                "apply": d => client.timeBalances = d || []
            },
            {
                "path": "absence_balances/my/all?periodYear=" + today.getFullYear(),
                "optional": true,
                "apply": d => client.absenceBalances = d || []
            },
            {
                "path": "working_time_exceptions/slimmed/my?source=ABSENCE_CALENDAR&fromDate=" + t + "&toDate=" + until,
                "optional": true,
                "apply": d => client.absences = d || []
            },
            {
                "path": "working_time/entries?fromBalanceDate=" + t + "&toBalanceDate=" + t,
                "optional": true,
                "apply": d => client.todayEntries = d || []
            },
            {
                "path": "users/attendance",
                "optional": true,
                "apply": d => client.birthdays = (d || []).filter(u => u.hasBirthday).map(u => u.firstName + " " + u.lastName)
            }
        ], err => {
            client.slowLoaded = true;
        });
    }

    // Book `bookingType` now: a beginning booking starts a new entry, an
    // ending one completes the open entry.
    function book(action) {
        if (busy)
            return;
        busy = true;
        const now = new Date().toISOString();
        const finish = (err, data) => {
            busy = false;
            if (err)
                bookingFailed(err);
            else
                booked(action.label);
            settleTimer.restart();
        };
        if (action.direction === "BEGINNING") {
            request("POST", "working_time/entries/my", {
                "beginningDate": now,
                "firstBookingType": action.bookingType
            }, finish);
        } else {
            if (!current || current.endingDate) {
                finish("No open time entry to end");
                return;
            }
            request("PUT", "working_time/entries/complete/" + current.id + "/my?adoptWorkingTime=false", {
                "id": String(current.id),
                "lastBookingType": action.bookingType,
                "endingDate": now
            }, finish);
        }
    }

    // Let the booking settle on the server, then re-read everything.
    Timer {
        id: settleTimer
        interval: 1000
        onTriggered: {
            client.refreshFast();
            client.refreshSlow();
        }
    }
}
