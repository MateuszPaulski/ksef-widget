import KsefCore
import SwiftUI

struct SettingsMessage: Equatable {
    let text: String
    let isError: Bool
}

struct SettingsForm: Equatable {
    var nip: String
    var environment: KsefEnvironment
    var startDate: Date
    var dataDir: String
    var certificateName: String?
    var keyName: String?
    var password: String
    var hasStoredCredentials: Bool
    var startAtLogin: Bool
    var loginNeedsApproval: Bool
    var notificationsAllowed: Bool?
    var legacyAgent: Bool
    var message: SettingsMessage?
}

struct SettingsActions {
    let chooseCertificate: () -> Void
    let chooseKey: () -> Void
    let chooseFolder: () -> Void
    let save: () -> Void
    let check: () -> Void
    let testNotification: () -> Void
    let openLoginItems: () -> Void
    let setStartAtLogin: (Bool) -> Void
}

private let warsaw = TimeZone(identifier: "Europe/Warsaw")!
private let labelWidth: CGFloat = 170

struct SettingsView: View {
    @Binding var form: SettingsForm
    let busy: Bool
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if form.legacyAgent { legacyBanner }
            row("NIP") {
                TextField("", text: $form.nip)
                    .labelsHidden()
                    .frame(width: 150)
            }
            row("Certyfikat (.crt)") { fileRow(name: form.certificateName, choose: actions.chooseCertificate) }
            row("Klucz prywatny (.key)") { fileRow(name: form.keyName, choose: actions.chooseKey) }
            row("Hasło klucza") {
                SecureField(form.hasStoredCredentials ? "zapisane — wpisz, aby zmienić" : "", text: $form.password)
                    .labelsHidden()
            }
            row("Środowisko") {
                Picker("", selection: $form.environment) {
                    Text("Produkcja").tag(KsefEnvironment.prod)
                    Text("Test").tag(KsefEnvironment.test)
                    Text("Demo").tag(KsefEnvironment.demo)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            row("Pobieraj faktury od") {
                DatePicker("", selection: $form.startDate, in: ...latestStartDate, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, warsaw)
            }
            row("Folder faktur") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: form.dataDir)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Text(verbatim: form.dataDir))
                        Spacer(minLength: 0)
                        Button("Zmień…", action: actions.chooseFolder)
                            .disabled(busy)
                    }
                    Text("Zmiana folderu nie przenosi plików: w nowym folderze pobieranie zacznie się od daty początkowej.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row("Uruchamiaj przy logowaniu") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { form.startAtLogin },
                        set: { form.startAtLogin = $0; actions.setStartAtLogin($0) }
                    ))
                    .labelsHidden()
                    if form.loginNeedsApproval {
                        Text("Zatwierdź KSeF w Ustawieniach systemowych › Ogólne › Rzeczy otwierane podczas logowania.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Otwórz ustawienia logowania", action: actions.openLoginItems)
                    }
                }
            }
            if let allowed = form.notificationsAllowed {
                row("") {
                    Text(allowed
                        ? "Powiadomienia: włączone"
                        : "Powiadomienia: wyłączone — włącz je w Ustawieniach systemowych › Powiadomienia")
                        .foregroundStyle(allowed ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("Zapisz", action: actions.save)
                    .keyboardShortcut(.defaultAction)
                Button("Sprawdź połączenie", action: actions.check)
                    .disabled(!form.hasStoredCredentials)
                Button("Wyślij testowe powiadomienie", action: actions.testNotification)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            if let message = form.message {
                Text(verbatim: message.text)
                    .foregroundStyle(message.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
    }

    /// The latest start date `Settings.validate` accepts: the current UTC day.
    private var latestStartDate: Date { startDate(fromText: defaultStartDateText(now: Date())) ?? Date() }

    private var legacyBanner: some View {
        Text("Wykryto stare zadanie launchd „local.ksef-daily-fetch”. Dopóki jest zainstalowane, aplikacja nie pobiera faktur. Usuń je w Terminalu poleceniem scripts/launchagent.sh uninstall w katalogu repozytorium.")
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileRow(name: String?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: name ?? (form.hasStoredCredentials ? "zapisany" : "nie wybrano"))
                .foregroundStyle(name == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(name == nil && !form.hasStoredCredentials ? "Wybierz…" : "Zmień…", action: choose)
                .disabled(busy)
        }
    }
}
