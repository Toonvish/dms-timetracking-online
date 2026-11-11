// Unit tests for TimeTracking.js. Run: node --test tests/
// The file is a QML ".pragma library" script; drop that line and evaluate
// it in a fresh context to get at its functions.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const src = readFileSync(new URL("../TimeTracking.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "");
const ctx = vm.createContext({});
vm.runInContext(src + "\n;globalThis.__api = { isoDate, mondayOf, fmtMinutes, fmtSigned, fmtDuration, fmtDays, fmtRange, relativeDays, trackingState, daySpan, buildWeek, pickOvertimeAccount, groupAbsences, pickVacation, bookingActions };", ctx);
const T = ctx.__api;
// Values created inside the vm context have their own Array/Object
// prototypes; round-trip through JSON before deep comparisons.
const plain = v => JSON.parse(JSON.stringify(v));

test("formatting", () => {
    assert.equal(T.fmtMinutes(330), "5:30");
    assert.equal(T.fmtMinutes(-90), "−1:30");
    assert.equal(T.fmtSigned(90), "+1:30");
    assert.equal(T.fmtSigned(0), "0:00");
    assert.equal(T.fmtSigned(null), "–");
    assert.equal(T.fmtDuration(44), "44m");
    assert.equal(T.fmtDuration(122), "2h 02m");
    assert.equal(T.fmtDays(3.5), "3.5");
    assert.equal(T.fmtDays(2), "2");
    assert.equal(T.fmtRange("2026-12-24", "2026-12-24"), "24.12.");
    assert.equal(T.fmtRange("2026-12-21", "2026-12-24"), "21.–24.12.");
    assert.equal(T.fmtRange("2026-12-30", "2027-01-02"), "30.12.–2.1.");
});

test("relative days and week start", () => {
    const today = new Date(2026, 10, 11, 15, 0); // Wed 11 Nov 2026
    assert.equal(T.relativeDays("2026-11-11", today), "now");
    assert.equal(T.relativeDays("2026-11-12", today), "tomorrow");
    assert.equal(T.relativeDays("2026-12-21", today), "in 40 days");
    assert.equal(T.isoDate(T.mondayOf(today)), "2026-11-09");
    assert.equal(T.isoDate(T.mondayOf(new Date(2026, 10, 15))), "2026-11-09"); // Sunday
});

test("tracking state", () => {
    const now = new Date("2026-11-11T14:00:00Z");
    assert.equal(T.trackingState(null, now).state, "out");
    assert.equal(T.trackingState({ id: 1, beginningDate: "2026-11-11T12:00:00Z", firstBookingType: "HOMEOFFICE" }, now).state, "homeoffice");
    assert.equal(T.trackingState({ id: 1, beginningDate: "2026-11-11T07:00:00Z", firstBookingType: "COMING" }, now).state, "office");
    assert.equal(T.trackingState({ id: 1, endingDate: "2026-11-11T11:00:00Z", lastBookingType: "BREAK" }, now).state, "break");
    // A break that ended yesterday is not a break today.
    assert.equal(T.trackingState({ id: 1, endingDate: "2026-11-09T11:00:00Z", lastBookingType: "BREAK" }, now).state, "out");
    assert.equal(T.trackingState({ id: 1, endingDate: "2026-11-11T13:00:00Z", lastBookingType: "LEAVING" }, now).state, "out");
});

test("breaks are the gaps between entries", () => {
    const entries = [
        { beginningDate: "2026-11-11T11:27:00Z", endingDate: null },
        { beginningDate: "2026-11-11T05:44:00Z", endingDate: "2026-11-11T06:49:00Z", lastBookingType: "BREAK" },
        { beginningDate: "2026-11-11T07:33:00Z", endingDate: "2026-11-11T11:09:00Z", lastBookingType: "BREAK" }
    ];
    const s = T.daySpan(entries, new Date("2026-11-11T14:00:00Z"));
    assert.equal(s.firstStart, "2026-11-11T05:44:00Z");
    assert.equal(s.breakMinutes, 44 + 18);
});

test("a running break counts until now, leaving does not", () => {
    const onBreak = [{ beginningDate: "2026-11-11T07:00:00Z", endingDate: "2026-11-11T11:00:00Z", lastBookingType: "BREAK" }];
    assert.equal(T.daySpan(onBreak, new Date("2026-11-11T11:30:00Z")).breakMinutes, 30);
    const left = [{ beginningDate: "2026-11-11T07:00:00Z", endingDate: "2026-11-11T15:00:00Z", lastBookingType: "LEAVING" }];
    assert.equal(T.daySpan(left, new Date("2026-11-11T18:00:00Z")).breakMinutes, 0);
    assert.deepEqual(plain(T.daySpan([], new Date())), { firstStart: "", breakMinutes: 0 });
});

test("week fills future weekdays with today's target and uses live net for today", () => {
    const days = [
        { day: "2026-11-09", workingMinutesNet: 540, targetWorkingMinutesNet: 480 },
        { day: "2026-11-10", workingMinutesNet: 544, targetWorkingMinutesNet: 480 },
        { day: "2026-11-11", workingMinutesNet: 281, targetWorkingMinutesNet: 480 }
    ];
    const { week, todayTarget } = T.buildWeek(days, new Date(2026, 10, 11, 15, 0), 332);
    assert.equal(todayTarget, 480);
    assert.deepEqual(plain(week.map(d => d.netMinutes)), [540, 544, 332, 0, 0, 0, 0]);
    assert.deepEqual(plain(week.map(d => d.targetMinutes)), [480, 480, 480, 480, 480, 0, 0]);
    assert.equal(week[2].today, true);
    assert.equal(week[3].future, true);
});

test("overtime account selection", () => {
    const b = (labelDe, labelEn, active, end) => ({ timeType: { labelDe, labelEn }, activePeriod: active, endBalancePeriod: end });
    assert.equal(T.pickOvertimeAccount([b("Gleitzeit", null, true, 1), b("Überstunden", null, true, 2)]).endBalancePeriod, 2);
    assert.equal(T.pickOvertimeAccount([b(null, "Overtime", true, 3)]).endBalancePeriod, 3);
    assert.equal(T.pickOvertimeAccount([b("Gleitzeit", null, false, 1), b("Andere", null, true, 4)]).endBalancePeriod, 4);
    assert.equal(T.pickOvertimeAccount([b("Gleitzeit", null, false, 5)]).endBalancePeriod, 5);
    assert.equal(T.pickOvertimeAccount([]), null);
});

const absence = (kind, begin, affected, state) => ({
    begin, end: begin, affected,
    durationType: affected < 100 ? "HALF_DAY" : "FULL_DAY",
    approvalState: state || "APPROVED",
    exceptionType: { internalName: kind, internalDescriptionDe: kind.toLowerCase(), customColor: "#8e44ad" }
});

test("consecutive absence days merge into one range", () => {
    const r = T.groupAbsences([
        absence("VACATION", "2026-12-23", 100),
        absence("VACATION", "2026-12-21", 100),
        absence("VACATION", "2026-12-22", 100),
        absence("VACATION", "2026-12-24", 50)
    ]);
    assert.equal(r.length, 1);
    assert.equal(r[0].begin, "2026-12-21");
    assert.equal(r[0].end, "2026-12-24");
    assert.equal(r[0].days, 3.5);
    assert.equal(r[0].color, "#8e44ad");
});

test("a weekend gap merges, a weekday gap splits", () => {
    const r = T.groupAbsences([
        absence("VACATION", "2026-12-04", 100), // Fri
        absence("VACATION", "2026-12-07", 100), // Mon
        absence("VACATION", "2026-12-09", 100)  // Wed (Tue is a workday)
    ]);
    assert.equal(r.length, 2);
    assert.equal(r[0].days, 2);
    assert.equal(r[1].begin, "2026-12-09");
});

test("types stay separate and rejected entries drop", () => {
    const r = T.groupAbsences([
        absence("VACATION", "2026-12-24", 50),
        absence("CUSTOMER_DEFINED_51", "2026-12-24", 50),
        absence("VACATION", "2026-12-28", 100, "REJECTED")
    ]);
    assert.equal(r.length, 2);
    assert.ok(r.every(x => x.days === 0.5));
});

test("vacation balance", () => {
    const v = T.pickVacation([
        { periodYear: 2026, exceptionType: { internalName: "TRIP_TO_DOCTOR" } },
        { periodYear: 2026, exceptionType: { internalName: "VACATION", internalDescriptionDe: "Urlaub" }, endBalanceLastPeriod: 2, startBalanceCurrentPeriod: 29, adjustBalanceCurrentPeriod: 1, consumedBalanceCurrentPeriod: 32, availableBalanceCurrentPeriod: 0 }
    ]);
    assert.equal(v.label, "Urlaub");
    assert.equal(v.entitlement, 29);
    assert.equal(v.available, 0);
    assert.equal(T.pickVacation([]), null);
});

test("booking actions follow the open entry and the API's allowed list", () => {
    const allowed = [
        { bookingType: "LEAVING", bookingDirection: "ENDING" },
        { bookingType: "BUSINESS_TRIP", bookingDirection: "BEGINNING" },
        { bookingType: "BREAK", bookingDirection: "ENDING" }
    ];
    const working = T.bookingActions(allowed, true, "HOMEOFFICE");
    assert.deepEqual(plain(working.map(a => a.bookingType)), ["LEAVING", "BREAK"]);
    assert.equal(working[0].primary, true);

    const out = T.bookingActions([
        { bookingType: "COMING", bookingDirection: "BEGINNING" },
        { bookingType: "HOMEOFFICE", bookingDirection: "BEGINNING" },
        { bookingType: "CUSTOM_TYPE_1", bookingDirection: "BEGINNING", nameEnglish: "Field work" },
        { bookingType: "BREAK", bookingDirection: "ENDING" }
    ], false, "HOMEOFFICE");
    assert.deepEqual(plain(out.map(a => a.bookingType)), ["HOMEOFFICE", "COMING", "CUSTOM_TYPE_1"]);
    assert.equal(out[2].label, "Field work");
    assert.equal(T.bookingActions([], false, "").length, 0);
});
