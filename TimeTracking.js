.pragma library

// Pure helpers for the TimeTracking Online plugin: no QML, no network, so
// they can be unit-tested with Node (see tests/). Minutes are integers,
// dates are "YYYY-MM-DD" strings in local time, timestamps ISO 8601.

// ── Dates ──

function pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

// Local calendar date of a Date as "YYYY-MM-DD".
function isoDate(d) {
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
}

function parseIsoDate(s) {
    const p = s.split("-");
    return new Date(parseInt(p[0], 10), parseInt(p[1], 10) - 1, parseInt(p[2], 10));
}

function addDays(d, n) {
    const r = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    r.setDate(r.getDate() + n);
    return r;
}

// Monday of the week containing d (local time).
function mondayOf(d) {
    const weekday = (d.getDay() + 6) % 7; // Mon = 0
    return addDays(d, -weekday);
}

function isWeekend(d) {
    const day = d.getDay();
    return day === 0 || day === 6;
}

// ── Formatting ──

// 330 -> "5:30", -90 -> "−1:30"
function fmtMinutes(m) {
    if (m === undefined || m === null || isNaN(m))
        return "";
    const sign = m < 0 ? "−" : "";
    const a = Math.abs(Math.round(m));
    return sign + Math.floor(a / 60) + ":" + pad2(a % 60);
}

// 90 -> "+1:30", -90 -> "−1:30", 0 -> "0:00"
function fmtSigned(m) {
    if (m === undefined || m === null || isNaN(m))
        return "–";
    return (m > 0 ? "+" : "") + fmtMinutes(m);
}

// 122 -> "2h 02m", 44 -> "44m"
function fmtDuration(m) {
    m = Math.max(0, Math.round(m));
    if (m < 60)
        return m + "m";
    return Math.floor(m / 60) + "h " + pad2(m % 60) + "m";
}

function fmtClock(d) {
    return d.getHours() + ":" + pad2(d.getMinutes());
}

// 3.5 -> "3.5", 2 -> "2"
function fmtDays(n) {
    if (n === undefined || n === null || isNaN(n))
        return "–";
    return String(Math.round(n * 10) / 10);
}

// "2026-12-21" -> "21.12."
function fmtDay(iso) {
    if (!iso)
        return "";
    const p = iso.split("-");
    return parseInt(p[2], 10) + "." + parseInt(p[1], 10) + ".";
}

// Same day "24.12.", same month "21.–24.12.", else "30.12.–2.1."
function fmtRange(begin, end) {
    if (begin === end)
        return fmtDay(begin);
    if (begin.slice(0, 7) === end.slice(0, 7))
        return parseInt(begin.split("-")[2], 10) + ".–" + fmtDay(end);
    return fmtDay(begin) + "–" + fmtDay(end);
}

// "now" / "tomorrow" / "in 12 days", relative to `today` (a Date).
function relativeDays(iso, today) {
    const t = parseIsoDate(isoDate(today));
    const n = Math.round((parseIsoDate(iso) - t) / 86400000);
    if (n <= 0)
        return "now";
    if (n === 1)
        return "tomorrow";
    return "in " + n + " days";
}

// ── Tracking state ──

// What the user is doing right now, from the open/last working time entry.
// `entry` is `working_time/entries/current` (null when none exists).
// Returns { state, bookingType, since, entryId }:
//   state: "office" | "homeoffice" | "business" | "working" | "break" | "out"
function trackingState(entry, now) {
    if (!entry)
        return { state: "out", bookingType: "", since: "", entryId: null };
    const open = !entry.endingDate;
    if (open) {
        const t = entry.firstBookingType || "";
        let state = "working";
        if (t === "HOMEOFFICE")
            state = "homeoffice";
        else if (t === "COMING" || t === "ON_COMPANY_GROUND")
            state = "office";
        else if (t === "BUSINESS_TRIP" || t === "BUSINESS_DRIVE")
            state = "business";
        return { state: state, bookingType: t, since: entry.beginningDate || "", entryId: entry.id };
    }
    const t = entry.lastBookingType || "";
    const endedToday = !!entry.endingDate && isoDate(new Date(entry.endingDate)) === isoDate(now);
    // A break from yesterday is just "out" today.
    const state = t === "BREAK" && endedToday ? "break" : "out";
    return { state: state, bookingType: t, since: entry.endingDate || "", entryId: entry.id };
}

// ── Today ──

// First clock-in of the day and minutes spent on breaks: the gaps between
// consecutive entries, plus the running break when the last entry ended as
// one. (The API's day summary lags until the day is assessed.)
function daySpan(entries, now) {
    const sorted = (entries || []).slice().sort((a, b) => new Date(a.beginningDate) - new Date(b.beginningDate));
    let breakMinutes = 0;
    for (let i = 1; i < sorted.length; i++) {
        const prevEnd = sorted[i - 1].endingDate;
        if (prevEnd)
            breakMinutes += Math.max(0, Math.floor((new Date(sorted[i].beginningDate) - new Date(prevEnd)) / 60000));
    }
    const last = sorted[sorted.length - 1];
    if (last && last.endingDate && last.lastBookingType === "BREAK")
        breakMinutes += Math.max(0, Math.floor((now - new Date(last.endingDate)) / 60000));
    return {
        firstStart: sorted.length > 0 ? sorted[0].beginningDate : "",
        breakMinutes: breakMinutes
    };
}

// ── Week ──

// Mon–Sun of the week containing `today`. `days` are the API's daily
// summaries (`working_time/days/user`), which only go up to today: later
// weekdays assume today's target (default 8:00), weekends none. Today's net
// comes from the live endpoint (`liveNet`), as its summary is partial.
function buildWeek(days, today, liveNet) {
    const todayIso = isoDate(today);
    const byDay = {};
    (days || []).forEach(d => byDay[d.day] = d);
    const todayRow = byDay[todayIso];
    const todayTarget = todayRow && todayRow.targetWorkingMinutesNet > 0 ? todayRow.targetWorkingMinutesNet : 480;
    const monday = mondayOf(today);
    const week = [];
    for (let i = 0; i < 7; i++) {
        const d = addDays(monday, i);
        const iso = isoDate(d);
        const row = byDay[iso];
        const future = iso > todayIso;
        let net = row ? row.workingMinutesNet || 0 : 0;
        let target = row ? row.targetWorkingMinutesNet || 0 : 0;
        if (iso === todayIso && liveNet !== null && liveNet !== undefined)
            net = liveNet;
        if (!row && future && !isWeekend(d))
            target = todayTarget;
        week.push({ day: iso, netMinutes: net, targetMinutes: target, today: iso === todayIso, future: future });
    }
    return { week: week, todayTarget: todayTarget };
}

// ── Time account ──

// Pick the overtime account from `time_balances/current/my`: the active
// period whose time type is labelled as overtime, then any active period,
// then the first entry.
function pickOvertimeAccount(balances) {
    balances = balances || [];
    const isOvertime = b => {
        const t = b.timeType || {};
        return [t.labelDe, t.labelEn].some(l => {
            if (!l)
                return false;
            l = l.toLowerCase();
            return l.indexOf("overtime") >= 0 || l.indexOf("berstunden") >= 0;
        });
    };
    const isActive = b => b.activePeriod === true;
    return balances.find(b => isActive(b) && isOvertime(b)) || balances.find(isActive) || balances[0] || null;
}

// ── Absences ──

function exceptionLabel(t) {
    t = t || {};
    return t.customLabelDe || t.internalDescriptionDe || t.customLabelEn || t.internalDescriptionEn || t.internalName || "";
}

function onlyWeekendBetween(endIso, beginIso) {
    let d = addDays(parseIsoDate(endIso), 1);
    const stop = parseIsoDate(beginIso);
    while (d < stop) {
        if (!isWeekend(d))
            return false;
        d = addDays(d, 1);
    }
    return true;
}

// Merge per-day absence entries (`working_time_exceptions/slimmed/my`) into
// ranges: same type, overlapping or only a weekend between. Rejected and
// cancelled entries are dropped. Sorted by begin date.
function groupAbsences(entries) {
    const kind = e => (e.exceptionType && e.exceptionType.internalName) || "";
    const items = (entries || []).filter(e => {
        const s = (e.approvalState || "").toUpperCase();
        return !(s.indexOf("REJECT") >= 0 || s.indexOf("CANCEL") >= 0 || s.indexOf("DECLIN") >= 0);
    }).sort((a, b) => kind(a) < kind(b) ? -1 : kind(a) > kind(b) ? 1 : (a.begin < b.begin ? -1 : a.begin > b.begin ? 1 : 0));

    const ranges = [];
    items.forEach(e => {
        const dt = e.durationType;
        const days = (!dt || dt === "FULL_DAY" || dt === "HALF_DAY") ? (e.affected || 0) / 100 : 0;
        const last = ranges[ranges.length - 1];
        if (last && last.kind === kind(e) && (e.begin <= last.end || onlyWeekendBetween(last.end, e.begin))) {
            if (e.end > last.end)
                last.end = e.end;
            last.days += days;
            return;
        }
        const t = e.exceptionType || {};
        ranges.push({
            kind: kind(e),
            label: exceptionLabel(t),
            color: t.customColor || t.defaultColor || "",
            begin: e.begin,
            end: e.end,
            days: days,
            approvalState: e.approvalState || ""
        });
    });
    ranges.sort((a, b) => a.begin < b.begin ? -1 : a.begin > b.begin ? 1 : (a.kind < b.kind ? -1 : 1));
    return ranges;
}

// The vacation account from `absence_balances/my/all`, falling back to the
// first balance when none is of type VACATION.
function pickVacation(balances) {
    balances = balances || [];
    const b = balances.find(x => x.exceptionType && x.exceptionType.internalName === "VACATION") || balances[0];
    if (!b)
        return null;
    return {
        year: b.periodYear,
        label: exceptionLabel(b.exceptionType),
        remainingLastYear: b.endBalanceLastPeriod || 0,
        entitlement: b.startBalanceCurrentPeriod || 0,
        adjustment: b.adjustBalanceCurrentPeriod || 0,
        consumed: b.consumedBalanceCurrentPeriod || 0,
        pending: b.pendingBalanceCurrentPeriod || 0,
        planned: b.plannedBalanceCurrentPeriod || 0,
        available: b.availableBalanceCurrentPeriod || 0
    };
}

// ── Bookings ──

const BOOKING_LABELS = {
    "COMING": { label: "Start (office)", icon: "login" },
    "HOMEOFFICE": { label: "Start homeoffice", icon: "home_work" },
    "BUSINESS_TRIP": { label: "Business trip", icon: "flight_takeoff" },
    "BUSINESS_DRIVE": { label: "Business drive", icon: "directions_car" },
    "ON_COMPANY_GROUND": { label: "On company ground", icon: "apartment" },
    "BREAK": { label: "Break", icon: "coffee" },
    "LEAVING": { label: "Leave", icon: "logout" }
};

// Buttons for the bookings the API currently allows
// (`working_time/booking_types/currently_allowed/my`). While an entry is
// open only ending bookings are offered, otherwise only beginning ones.
// The primary action: Leave while working, else the type the user started
// with last (`preferredStart`), else the first.
function bookingActions(allowed, hasOpenEntry, preferredStart) {
    const wanted = hasOpenEntry ? "ENDING" : "BEGINNING";
    const actions = (allowed || []).filter(a => a.bookingDirection === wanted).map(a => {
        const known = BOOKING_LABELS[a.bookingType];
        return {
            bookingType: a.bookingType,
            direction: a.bookingDirection,
            label: a.nameEnglish || (known ? known.label : a.bookingType.replace(/_/g, " ").toLowerCase()),
            icon: known ? known.icon : (wanted === "ENDING" ? "logout" : "login"),
            primary: false
        };
    });
    let primary = actions.find(a => a.bookingType === (hasOpenEntry ? "LEAVING" : preferredStart)) || actions[0];
    if (primary)
        primary.primary = true;
    // Primary first, the rest in API order.
    return actions.filter(a => a.primary).concat(actions.filter(a => !a.primary));
}
