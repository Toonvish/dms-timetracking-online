import QtQuick
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "timeTrackingOnline"

    readonly property string keyringService: "dms-timetracking-online"

    StringSetting {
        id: apiUrlSetting
        settingKey: "apiUrl"
        label: "API URL"
        description: "Your company's TimeTracking Online API, usually https://<company>.timetracking-online.com/api"
        placeholder: "https://example.timetracking-online.com/api"
        defaultValue: ""
    }

    StringSetting {
        id: usernameSetting
        settingKey: "username"
        label: "Username"
        description: "The user name you sign in to the web app with."
        placeholder: "jane.doe"
        defaultValue: ""
    }

    // The password never goes into DMS's settings files: it is stored in the
    // system keyring with secret-tool (libsecret).
    Column {
        id: passwordBlock
        width: parent.width
        spacing: Theme.spacingS

        property string status: ""
        property bool statusError: false
        readonly property string user: usernameSetting.value.trim()

        StyledText {
            text: "Password"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightMedium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Stored in your system keyring (secret-tool), not in the DMS settings. Saving replaces the stored password."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        DTextField {
            id: passwordField
            width: parent.width
            placeholderText: passwordBlock.user === "" ? "Set the username first" : "Password for " + passwordBlock.user
            echoMode: TextInput.Password
            showPasswordToggle: true
            enabled: passwordBlock.user !== ""
            onAccepted: passwordBlock.save()
        }

        Row {
            spacing: Theme.spacingM

            DButton {
                text: "Save to keyring"
                iconName: "key"
                enabled: passwordBlock.user !== "" && passwordField.text !== "" && !storeProc.running
                onClicked: passwordBlock.save()
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: passwordBlock.status
                font.pixelSize: Theme.fontSizeSmall
                color: passwordBlock.statusError ? Theme.error : Theme.success
            }
        }

        function save() {
            if (user === "" || passwordField.text === "" || storeProc.running)
                return;
            status = "";
            storeProc.command = ["secret-tool", "store", "--label=TimeTracking Online (" + user + ")", "service", root.keyringService, "account", user];
            storeProc.running = true;
        }

        Process {
            id: storeProc
            stdinEnabled: true
            // secret-tool reads the password from stdin until EOF.
            onStarted: {
                write(passwordField.text);
                stdinEnabled = false;
            }
            onExited: (code, status) => {
                stdinEnabled = true;
                if (code === 0) {
                    passwordField.text = "";
                    passwordBlock.statusError = false;
                    passwordBlock.status = "Saved";
                    // Tell the widget to drop its cached login.
                    root.saveValue("passwordChangedAt", Date.now());
                } else {
                    passwordBlock.statusError = true;
                    passwordBlock.status = "Could not save (is libsecret installed and the keyring unlocked?)";
                }
            }
        }
    }

    SliderSetting {
        settingKey: "interval"
        label: "Refresh interval"
        description: "How often the bar updates today's time. The detail panel refreshes when opened."
        defaultValue: 60
        minimum: 30
        maximum: 600
        unit: "s"
    }

    ToggleSetting {
        settingKey: "showWeek"
        label: "Show week total in bar"
        defaultValue: false
    }
}
