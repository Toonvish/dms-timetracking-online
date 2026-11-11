import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "TimeTracking.js" as TT

// TimeTracking Online for DMS. The bar shows today's net working time; the
// panel shows progress toward today's target, overtime, this week, vacation
// and upcoming absences, plus the bookings the API currently allows.
PluginComponent {
    id: root

    // ── Settings ──
    readonly property int intervalSec: Math.max(30, pluginData.interval || 60)
    readonly property bool showWeek: pluginData.showWeek ?? false
    readonly property var passwordChangedAt: pluginData.passwordChangedAt ?? 0
    onPasswordChangedAtChanged: {
        api.forgetCredentials();
        api.refreshFast();
        api.refreshSlow();
    }

    TimeTrackingClient {
        id: api
        apiUrl: root.pluginData.apiUrl || ""
        username: root.pluginData.username || ""
        pluginService: root.pluginService
        pluginId: root.pluginId
        onBooked: label => ToastService.showInfo("TimeTracking: " + label)
        onBookingFailed: message => ToastService.showError("TimeTracking: booking failed", message)
    }

    // Clock for "done at", running breaks and day changes.
    property date now: new Date()
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    Timer {
        interval: root.intervalSec * 1000
        running: api.configured
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.now = new Date();
            api.refreshFast();
        }
    }

    Timer {
        interval: 10 * 60 * 1000
        running: api.configured
        repeat: true
        triggeredOnStart: true
        onTriggered: api.refreshSlow()
    }

    // ── Derived state ──
    readonly property bool hasData: api.fastLoaded && api.live !== null
    readonly property var tracking: TT.trackingState(api.current, now)
    readonly property string workState: hasData ? tracking.state : "unknown"
    readonly property bool hasOpenEntry: !!api.current && !api.current.endingDate
    readonly property int netMinutes: api.live?.workingMinutesNet ?? 0
    readonly property int overtimeMinutes: api.live?.overTimeMinutes ?? 0

    readonly property var weekData: TT.buildWeek(api.days, now, hasData ? netMinutes : null)
    readonly property var week: api.days.length > 0 ? weekData.week : []
    readonly property int todayTarget: weekData.todayTarget
    readonly property int weekMinutes: weekData.week.filter(d => !d.future).reduce((sum, d) => sum + d.netMinutes, 0)
    readonly property int weekTarget: weekData.week.reduce((sum, d) => sum + d.targetMinutes, 0)
    readonly property real weekMax: Math.max(600, ...week.map(d => Math.max(d.netMinutes, d.targetMinutes)))

    readonly property real todayProgress: todayTarget > 0 ? netMinutes / todayTarget : 0
    readonly property int remainingMinutes: todayTarget - netMinutes
    readonly property var span: TT.daySpan(api.todayEntries, now)

    readonly property var account: TT.pickOvertimeAccount(api.timeBalances)
    // The account covers assessed days only; add today's live overtime once.
    readonly property var overtimeTotal: account && account.endBalancePeriod !== undefined && account.endBalancePeriod !== null ? Math.round(account.endBalancePeriod) + overtimeMinutes : null
    readonly property var vacation: TT.pickVacation(api.absenceBalances)
    readonly property real vacationTotal: vacation ? vacation.entitlement + vacation.remainingLastYear + vacation.adjustment : 0
    readonly property var upcoming: TT.groupAbsences(api.absences).filter(r => r.end >= TT.isoDate(now)).slice(0, 3)

    readonly property string preferredStart: api.current?.firstBookingType ?? ""
    readonly property var actions: hasData ? TT.bookingActions(api.allowed, hasOpenEntry, preferredStart) : []

    readonly property var dayNames: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    readonly property var monthNames: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    readonly property var stateInfo: ({
            "office": {
                "icon": "work",
                "color": Theme.success,
                "label": "Office"
            },
            "homeoffice": {
                "icon": "home_work",
                "color": Theme.primary,
                "label": "Homeoffice"
            },
            "business": {
                "icon": "directions_car",
                "color": Theme.secondary,
                "label": "Business trip"
            },
            "working": {
                "icon": "work",
                "color": Theme.success,
                "label": "Working"
            },
            "break": {
                "icon": "coffee",
                "color": Theme.warning,
                "label": "On break"
            },
            "out": {
                "icon": "logout",
                "color": Theme.surfaceVariantText,
                "label": "Not tracking"
            },
            "unknown": {
                "icon": "schedule",
                "color": Theme.surfaceVariantText,
                "label": ""
            }
        })
    readonly property var info: stateInfo[workState] || stateInfo["unknown"]
    readonly property bool isWorking: hasOpenEntry && workState !== "unknown"

    readonly property string barText: {
        if (!api.configured)
            return "Set up";
        if (!hasData)
            return "--:--";
        let t = TT.fmtMinutes(netMinutes);
        if (showWeek)
            t += " · " + TT.fmtMinutes(weekMinutes);
        return t;
    }

    readonly property string subtitle: {
        if (!api.configured)
            return "Not configured";
        if (!hasData)
            return api.error !== "" ? "Offline" : "Loading…";
        const since = tracking.since;
        if (since === "")
            return info.label;
        const at = TT.fmtClock(new Date(since));
        if (workState === "out")
            return TT.isoDate(new Date(since)) === TT.isoDate(now) ? info.label + " · left at " + at : info.label;
        return info.label + " · since " + at;
    }

    function signColor(m) {
        if (m > 0)
            return Theme.success;
        if (m < 0)
            return Theme.warning;
        return Theme.surfaceText;
    }

    // ── Bar pills ──
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: root.info.icon
                size: root.iconSize
                color: root.info.color
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.barText
                font.pixelSize: root.textSize
                color: root.info.color
                anchors.verticalCenter: parent.verticalCenter
            }

            DIcon {
                visible: api.birthdays.length > 0
                name: "cake"
                size: root.iconSize
                color: Theme.tertiary
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DIcon {
                name: root.info.icon
                size: root.iconSize
                color: root.info.color
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.hasData ? TT.fmtMinutes(root.netMinutes) : "--"
                font.pixelSize: root.textSize
                color: root.info.color
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Panel building blocks ──

    component Card: StyledRect {
        id: card
        default property alias content: cardBody.data
        property real padding: Theme.spacingM
        height: cardBody.implicitHeight + padding * 2
        color: Theme.surfaceContainerHigh

        Column {
            id: cardBody
            x: card.padding
            y: card.padding
            width: card.width - card.padding * 2
            spacing: Theme.spacingS
        }
    }

    component CardTitle: Item {
        id: ct
        property string title: ""
        property string note: ""
        width: parent ? parent.width : 0
        height: titleLabel.implicitHeight

        StyledText {
            id: titleLabel
            text: ct.title
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }
        StyledText {
            anchors.right: parent.right
            anchors.baseline: titleLabel.baseline
            text: ct.note
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    component ActionButton: StyledRect {
        id: btn
        property string label: ""
        property string icon: ""
        property bool primary: false
        signal activated
        height: 44
        radius: 22
        opacity: api.busy ? 0.5 : 1
        color: primary ? Theme.primary : Theme.surfaceVariant

        Rectangle {
            anchors.fill: parent
            radius: btn.radius
            color: btn.primary ? Theme.primaryText : Theme.surfaceText
            opacity: btnArea.pressed ? 0.16 : (btnArea.containsMouse ? 0.08 : 0)
        }

        Row {
            anchors.centerIn: parent
            spacing: Theme.spacingS

            DIcon {
                name: btn.icon
                size: Theme.iconSize - 4
                color: btn.primary ? Theme.primaryText : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: btn.label
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: btn.primary ? Theme.primaryText : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: !api.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
    }

    // ── Panel ──
    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Work Time"
            detailsText: root.subtitle

            Component.onCompleted: {
                root.now = new Date();
                api.refreshFast();
                api.refreshSlow();
            }

            Column {
                id: body
                width: parent.width - Theme.spacingM * 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingL

                // --- Setup / error notice ---
                StyledRect {
                    readonly property string message: !api.configured ? "Set your API URL, username and password in Settings → Plugins → TimeTracking Online." : api.error
                    visible: message !== ""
                    width: body.width
                    height: noticeText.implicitHeight + Theme.spacingM * 2
                    color: Theme.surfaceContainerHigh

                    StyledText {
                        id: noticeText
                        x: Theme.spacingM
                        width: parent.width - Theme.spacingM * 2
                        anchors.verticalCenter: parent.verticalCenter
                        wrapMode: Text.WordWrap
                        text: parent.message
                        font.pixelSize: Theme.fontSizeMedium
                        color: api.configured ? Theme.warning : Theme.surfaceText
                    }
                }

                // --- Birthday notice ---
                StyledRect {
                    visible: api.birthdays.length > 0
                    width: body.width
                    height: bdayText.implicitHeight + Theme.spacingS * 2
                    color: Theme.surfaceContainerHigh

                    DIcon {
                        id: bdayIcon
                        x: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: "cake"
                        size: Theme.iconSize - 4
                        color: Theme.tertiary
                    }
                    StyledText {
                        id: bdayText
                        anchors.left: bdayIcon.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        wrapMode: Text.WordWrap
                        text: "Birthday today: " + api.birthdays.join(", ")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.tertiary
                    }
                }

                // --- Today: progress ring toward the daily target ---
                Card {
                    visible: root.hasData
                    width: body.width
                    padding: Theme.spacingS

                    Row {
                        id: todayRow
                        width: parent.width
                        spacing: Theme.spacingM

                        Canvas {
                            id: ring
                            width: 100
                            height: 100
                            anchors.verticalCenter: parent.verticalCenter
                            renderStrategy: Canvas.Cooperative

                            property real progress: root.todayProgress
                            onProgressChanged: requestPaint()

                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                const cx = width / 2, cy = height / 2, r = 38, lw = 8;
                                const start = -Math.PI / 2;

                                ctx.beginPath();
                                ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                                ctx.lineWidth = lw;
                                ctx.strokeStyle = progress >= 1 ? Theme.primary : Theme.surfaceVariant;
                                ctx.stroke();

                                if (progress > 0 && progress < 1) {
                                    ctx.beginPath();
                                    ctx.arc(cx, cy, r, start, start + 2 * Math.PI * progress);
                                    ctx.lineWidth = lw;
                                    ctx.strokeStyle = Theme.primary;
                                    ctx.lineCap = "round";
                                    ctx.stroke();
                                }
                                // Overtime laps the ring in green.
                                if (progress > 1) {
                                    ctx.beginPath();
                                    ctx.arc(cx, cy, r, start, start + 2 * Math.PI * Math.min(progress - 1, 1));
                                    ctx.lineWidth = lw;
                                    ctx.strokeStyle = Theme.success;
                                    ctx.lineCap = "round";
                                    ctx.stroke();
                                }
                            }

                            Column {
                                anchors.centerIn: parent

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: TT.fmtMinutes(root.netMinutes)
                                    font.pixelSize: Theme.fontSizeXLarge
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "of " + TT.fmtMinutes(root.todayTarget)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        Column {
                            width: Math.max(0, todayRow.width - ring.width - todayRow.spacing)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            StyledText {
                                text: "Today"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }
                            StyledText {
                                text: root.remainingMinutes > 0 ? Math.round(root.todayProgress * 100) + "% of target" : (root.remainingMinutes < 0 ? TT.fmtMinutes(-root.remainingMinutes) + " over target" : "Target reached")
                                font.pixelSize: Theme.fontSizeMedium
                                color: root.remainingMinutes > 0 ? Theme.primary : Theme.success
                            }
                            StyledText {
                                visible: root.remainingMinutes > 0 && root.workState !== "out"
                                text: TT.fmtMinutes(root.remainingMinutes) + " left" + (root.isWorking ? " · done " + TT.fmtClock(new Date(root.now.getTime() + root.remainingMinutes * 60000)) : "")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                            }
                            StyledText {
                                visible: root.span.firstStart !== ""
                                text: "Started " + (root.span.firstStart ? TT.fmtClock(new Date(root.span.firstStart)) : "") + (root.span.breakMinutes > 0 ? " · " + TT.fmtDuration(root.span.breakMinutes) + " break" : "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                            StyledText {
                                visible: root.week.length > 0
                                text: "Week " + TT.fmtMinutes(root.weekMinutes) + (root.weekTarget > 0 ? " of " + TT.fmtMinutes(root.weekTarget) : "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                // --- Overtime: today / month / balance ---
                Card {
                    visible: root.hasData
                    width: body.width

                    CardTitle {
                        title: "Overtime"
                    }

                    Row {
                        id: otRow
                        width: parent.width
                        topPadding: Theme.spacingXS

                        Repeater {
                            model: [
                                {
                                    "label": "Today",
                                    "value": TT.fmtSigned(root.overtimeMinutes),
                                    "color": root.signColor(root.overtimeMinutes),
                                    "sub": root.workState === "out" ? "final" : "live"
                                },
                                {
                                    "label": api.month ? root.monthNames[parseInt(api.month.yearMonth.slice(5)) - 1] : "Month",
                                    "value": api.month ? TT.fmtSigned(api.month.overTimeMinutes) : "–",
                                    "color": Theme.surfaceText,
                                    "sub": api.month ? TT.fmtMinutes(api.month.workingMinutesNet) + " / " + TT.fmtMinutes(api.month.targetWorkingMinutesNet) : ""
                                },
                                {
                                    "label": "Balance",
                                    "value": TT.fmtSigned(root.overtimeTotal),
                                    "color": Theme.primary,
                                    "sub": root.account && root.account.lastPeriodEndBalance !== undefined && root.account.lastPeriodEndBalance !== null ? TT.fmtSigned(Math.round(root.account.lastPeriodEndBalance)) + " carried" : ""
                                }
                            ]

                            Column {
                                id: otCol
                                required property var modelData
                                width: otRow.width / 3
                                spacing: Theme.spacingXS

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: otCol.modelData.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: otCol.modelData.value
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: otCol.modelData.color
                                }
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: otCol.modelData.sub
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                // --- This week: daily bars, a tick at the daily target ---
                Card {
                    width: body.width
                    visible: root.hasData && root.week.length > 0

                    CardTitle {
                        title: "This Week"
                        note: "tick = target"
                    }

                    Row {
                        id: weekRow
                        width: parent.width
                        height: 86
                        spacing: 6
                        readonly property real plotH: 66
                        readonly property real colW: (width - spacing * 6) / 7

                        Repeater {
                            model: root.week

                            Item {
                                id: dayCol
                                required property var modelData
                                readonly property bool today: modelData.today === true
                                readonly property bool hasNet: modelData.netMinutes > 0
                                width: weekRow.colW
                                height: weekRow.height

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: bar.top
                                    anchors.bottomMargin: 2
                                    visible: dayCol.hasNet
                                    text: TT.fmtMinutes(dayCol.modelData.netMinutes)
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: dayCol.today ? Theme.primary : Theme.surfaceVariantText
                                }

                                Rectangle {
                                    id: bar
                                    anchors.bottom: parent.bottom
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Math.max(parent.width - 4, 4)
                                    height: dayCol.hasNet ? Math.max(dayCol.modelData.netMinutes / root.weekMax * weekRow.plotH, 3) : 0
                                    radius: 3
                                    color: dayCol.today ? Theme.primary : Theme.surfaceVariant
                                }

                                // Daily target tick (past and current workdays).
                                Rectangle {
                                    visible: dayCol.modelData.targetMinutes > 0 && !dayCol.modelData.future
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: bar.width + 4
                                    height: 2
                                    radius: 1
                                    y: dayCol.height - dayCol.modelData.targetMinutes / root.weekMax * weekRow.plotH - 1
                                    color: Theme.surfaceText
                                    opacity: 0.5
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: weekRow.spacing

                        Repeater {
                            model: root.week

                            StyledText {
                                required property var modelData
                                required property int index
                                width: weekRow.colW
                                horizontalAlignment: Text.AlignHCenter
                                text: root.dayNames[index]
                                font.pixelSize: 11
                                color: modelData.today ? Theme.primary : Theme.surfaceVariantText
                            }
                        }
                    }
                }

                // --- Vacation + upcoming absences ---
                Card {
                    id: vacCard
                    width: body.width
                    visible: root.hasData && (root.vacation !== null || api.slowLoaded)

                    CardTitle {
                        visible: root.vacation !== null
                        title: root.vacation ? (root.vacation.label || "Vacation") + " " + root.vacation.year : ""
                        note: root.vacation ? TT.fmtDays(root.vacation.available) + " days left" : ""
                    }

                    Item {
                        visible: root.vacation !== null
                        width: parent.width
                        height: usedLabel.implicitHeight

                        StyledText {
                            id: usedLabel
                            text: root.vacation ? TT.fmtDays(root.vacation.consumed) + " of " + TT.fmtDays(root.vacationTotal) + " used" : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }
                        StyledText {
                            anchors.right: parent.right
                            text: {
                                const v = root.vacation;
                                if (!v)
                                    return "";
                                let s = TT.fmtDays(v.entitlement);
                                if (v.remainingLastYear)
                                    s += " + " + TT.fmtDays(v.remainingLastYear) + " carried";
                                if (v.adjustment)
                                    s += (v.adjustment > 0 ? " + " : " − ") + TT.fmtDays(Math.abs(v.adjustment));
                                return s;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Rectangle {
                        visible: root.vacation !== null
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Theme.surfaceVariant

                        Rectangle {
                            width: root.vacationTotal > 0 ? parent.width * Math.min(1, root.vacation.consumed / root.vacationTotal) : 0
                            height: parent.height
                            radius: 3
                            color: Theme.primary
                        }
                    }

                    StyledText {
                        readonly property var v: root.vacation
                        visible: !!v && (v.pending > 0 || v.planned > 0)
                        text: v ? [v.pending > 0 ? TT.fmtDays(v.pending) + " awaiting approval" : "", v.planned > 0 ? TT.fmtDays(v.planned) + " planned" : ""].filter(x => x).join(" · ") : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                    }

                    Item {
                        width: parent.width
                        height: Theme.spacingXS
                    }

                    StyledText {
                        text: "Upcoming"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: root.upcoming.length === 0
                        text: "Nothing planned in the next 4 months"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: root.upcoming

                        Item {
                            id: absRow
                            required property var modelData
                            readonly property bool pending: modelData.approvalState !== "" && modelData.approvalState !== "APPROVED"
                            width: vacCard.width - vacCard.padding * 2
                            height: absText.implicitHeight

                            Rectangle {
                                id: absBar
                                width: 4
                                height: parent.height
                                radius: 2
                                color: absRow.modelData.color || Theme.primary
                            }
                            Column {
                                id: absText
                                anchors.left: absBar.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: absDays.left
                                anchors.rightMargin: Theme.spacingS
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                    text: absRow.modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                }
                                StyledText {
                                    text: TT.fmtRange(absRow.modelData.begin, absRow.modelData.end) + " · " + TT.relativeDays(absRow.modelData.begin, root.now) + (absRow.pending ? " · pending" : "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: absRow.pending ? Theme.warning : Theme.surfaceVariantText
                                }
                            }
                            StyledText {
                                id: absDays
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: TT.fmtDays(absRow.modelData.days) + " d"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }
                        }
                    }
                }

                // --- Bookings the API allows right now: the primary one
                // full width, the rest sharing a row below ---
                Column {
                    id: actionCol
                    visible: root.actions.length > 0
                    width: body.width
                    spacing: Theme.spacingS
                    readonly property var primaryAction: root.actions.length > 0 ? root.actions[0] : null
                    readonly property var others: root.actions.slice(1)

                    function run(action) {
                        api.book(action);
                        if (popout.closePopout)
                            popout.closePopout();
                    }

                    // Two actions fit side by side, as in the design.
                    Row {
                        visible: root.actions.length === 2
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.actions.length === 2 ? [root.actions[1], root.actions[0]] : []

                            ActionButton {
                                required property var modelData
                                width: (actionCol.width - Theme.spacingS) / 2
                                label: modelData.label
                                icon: modelData.icon
                                primary: modelData.primary
                                onActivated: actionCol.run(modelData)
                            }
                        }
                    }

                    ActionButton {
                        visible: root.actions.length !== 2 && actionCol.primaryAction !== null
                        width: parent.width
                        label: actionCol.primaryAction ? actionCol.primaryAction.label : ""
                        icon: actionCol.primaryAction ? actionCol.primaryAction.icon : ""
                        primary: true
                        onActivated: actionCol.run(actionCol.primaryAction)
                    }

                    Row {
                        visible: root.actions.length > 2
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.actions.length > 2 ? actionCol.others : []

                            ActionButton {
                                required property var modelData
                                width: (actionCol.width - Theme.spacingS * (actionCol.others.length - 1)) / actionCol.others.length
                                label: modelData.label
                                icon: modelData.icon
                                primary: false
                                onActivated: actionCol.run(modelData)
                            }
                        }
                    }
                }

                Item {
                    width: body.width
                    height: Theme.spacingXS
                }
            }
        }
    }
}
