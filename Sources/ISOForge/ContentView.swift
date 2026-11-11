import SwiftUI
import UniformTypeIdentifiers
import ForgeCore

private enum Theme {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.085)
    static let panel = Color(red: 0.09, green: 0.105, blue: 0.13)
    static let mint = Color(red: 0.34, green: 0.91, blue: 0.73)
    static let secondary = Color(red: 0.59, green: 0.64, blue: 0.71)
    static let border = Color.white.opacity(0.085)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    scopePicker
                    HStack(alignment: .top, spacing: 18) { imageCard; deviceCard }
                    if model.needsRawPartitionAcknowledgment { partitionBootWarning }
                    if let notice = model.notice { noticeView(notice) }
                    operationCard
                    footer
                }
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 26)
            }
        }
        .background(Theme.background)
        .tint(Theme.mint)
        .environment(\.locale, model.locale)
        .sheet(isPresented: $model.showConfirmation) { confirmationSheet }
        .sheet(isPresented: $model.showHelp) { helpSheet }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.mint.opacity(0.13))
                Image(systemName: "externaldrive.fill.badge.plus").font(.system(size: 25)).foregroundStyle(Theme.mint)
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("ISO Forge").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Завантажувальні USB для вашого наступного старту").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text("macOS").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.04), in: Capsule())
            Menu {
                Picker("Language", selection: $model.language) {
                    Text("System language").tag(AppLanguage.system)
                    Text("Українська").tag(AppLanguage.ukrainian)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.language.effectiveCode.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.mint)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.white.opacity(0.05), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("Language")
            Button { model.showHelp = true } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 19)).foregroundStyle(Theme.secondary)
            }.buttonStyle(.plain).help("Як користуватися ISO Forge")
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Новий USB. Нові можливості.").font(.system(size: 29, weight: .semibold, design: .rounded))
                Spacer()
                Label("Перевірка SHA-256", systemImage: "checkmark.shield")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.mint)
            }
            Text("Оберіть образ і накопичувач. ISO Forge підготує USB та перевірить записані дані.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                step("1", "Образ", complete: model.image != nil, active: model.image == nil)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary.opacity(0.5))
                step("2", model.scope == .partition ? "Розділ диска" : "Накопичувач", complete: model.targetAvailable, active: model.image != nil && !model.targetAvailable)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary.opacity(0.5))
                step("3", "Запис і перевірка", complete: model.status?.phase == .complete, active: model.busy)
                Spacer()
            }.padding(.top, 2)
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 18) {
            Picker("Ціль запису", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                ForEach(TargetScope.allCases, id: \.self) { Text($0.title.appLocalized).tag($0) }
            }.pickerStyle(.segmented).frame(width: 340).disabled(model.busy)
            Text(model.scope == .partition ? "Збереження інших розділів диска" : "Підготовка всього накопичувача")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Spacer()
        }
    }

    private var partitionBootWarning: some View {
        Label("Побайтовий запис ISO у розділ не гарантує завантаження. Образ має підтримувати такий спосіб запису; гібридні образи зазвичай призначені для цілого диска.", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ number: String, _ title: String, complete: Bool, active: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(complete || active ? Theme.mint.opacity(0.14) : Color.white.opacity(0.05))
                if complete { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                else { Text(number).font(.system(size: 10, weight: .bold)) }
            }.frame(width: 23, height: 23).foregroundStyle(complete || active ? Theme.mint : Theme.secondary)
            Text(title).font(.system(size: 12, weight: active ? .semibold : .medium)).foregroundStyle(complete || active ? .white : Theme.secondary)
        }
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Образ системи", icon: "opticaldisc", trailing: "ISO / IMG")
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.background.opacity(0.55))
                RoundedRectangle(cornerRadius: 12).strokeBorder(dropTarget ? Theme.mint : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                if model.imageLoading {
                    VStack(spacing: 12) { ProgressView(); Text("Перевіряю вміст образу…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                } else if let image = model.image {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: image.mode == .windows ? "square.grid.2x2.fill" : "opticaldisc.fill")
                                .font(.system(size: 33)).foregroundStyle(Theme.mint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(image.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).help(image.path)
                                Text(Formatters.bytes(image.size)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { model.clearImage() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                                .buttonStyle(.plain).disabled(model.busy).help("Прибрати образ")
                        }
                        Label(image.mode.title.appLocalized, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.mint)
                        if image.mode == .windows {
                            Text("UEFI · \(image.bootArchitectures.joined(separator: ", "))" + (image.largeWindowsFiles > 0 ? " · автоматичний поділ WIM/ESD" : " · FAT32"))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                        } else {
                            Text((image.isHybrid ? "Гібридний образ" : "Оптичний ISO") + " · побайтовий запис").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                    }.padding(18)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.mint)
                        Text("Перетягніть сюди образ").font(.system(size: 14, weight: .medium))
                        Text("Гібридний ISO Linux, Windows UEFI або IMG").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Button("Обрати файл…") { model.chooseImage() }
                            .buttonStyle(.bordered).controlSize(.small).disabled(model.busy)
                    }
                }
            }.frame(height: 157)
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
                    guard !model.busy, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.loadImage(url) } }
                    }
                    return true
                }
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.mint)
                Text("Режим запису визначається за вмістом образу.").foregroundStyle(Theme.secondary)
            }.font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(Theme.border, lineWidth: 1) }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(model.scope == .partition ? "Розділ зовнішнього диска" : "USB-накопичувач", systemImage: "externaldrive").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.refreshDisks() } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).disabled(model.busy || model.scanning).help("Оновити список дисків")
            }
            if model.scope == .partition {
                Picker("Диск", selection: Binding(get: { model.selectedID }, set: { model.selectDevice($0) })) {
                    Text("Оберіть диск…").tag(String?.none)
                    ForEach(model.devices) { device in
                        Text("\(device.name) · \(Formatters.bytes(device.size)) · \(device.id)")
                            .tag(Optional(device.id)).disabled(!device.isAvailable)
                    }
                }.disabled(model.busy).font(.system(size: 12))
            }
            ScrollView {
                VStack(spacing: 9) {
                    if model.scope == .partition && !model.devices.isEmpty {
                        if model.selectedDevice == nil {
                            Text("Оберіть диск у меню, щоб побачити його розділи.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity).frame(height: 155)
                        } else if model.visiblePartitions.isEmpty {
                            Text("На цьому диску немає доступної таблиці розділів.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity).frame(height: 155)
                        } else {
                            ForEach(model.visiblePartitions) { partition in partitionRow(partition) }
                        }
                    } else if model.devices.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "cable.connector").font(.system(size: 29, weight: .light)).foregroundStyle(Theme.secondary)
                            Text(model.scanning ? "Шукаю диски…" : "Під'єднайте зовнішній накопичувач").font(.system(size: 13, weight: .medium))
                            Text("Список оновлюється автоматично").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }.frame(maxWidth: .infinity).frame(height: 155)
                    } else {
                        ForEach(model.devices) { device in deviceRow(device) }
                    }
                }
            }.frame(height: model.scope == .partition ? 185 : 157)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.mint)
                Text(model.scope == .partition ? "Системні, службові розділи та розділ з ISO захищені." : "Системні диски й диск із вибраним ISO захищені.").foregroundStyle(Theme.secondary)
            }.font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(Theme.border, lineWidth: 1) }
    }

    private func deviceRow(_ device: USBDevice) -> some View {
        let selected = model.selectedID == device.id
        return Button {
            model.selectDevice(device.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.isAvailable ? "externaldrive.fill" : "externaldrive.fill.badge.minus")
                    .font(.system(size: 25)).foregroundStyle(selected ? Theme.mint : Theme.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(device.name).font(.system(size: 13, weight: .semibold)); Spacer(); Text(Formatters.bytes(device.size)).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    Text(device.volumes.isEmpty ? "/dev/\(device.id) · USB" : device.volumes.joined(separator: ", ") + " · " + device.id)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    if let reason = device.blockedReason {
                        Text(reason.appLocalized).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
            }.padding(13).background(selected ? Theme.mint.opacity(0.075) : Theme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).stroke(selected ? Theme.mint.opacity(0.65) : Theme.border, lineWidth: 1) }
        }.buttonStyle(.plain).disabled(!device.isAvailable || model.busy).help(device.blockedReason ?? device.devicePath)
    }

    private func partitionRow(_ partition: DiskPartition) -> some View {
        let selected = model.selectedPartitionID == partition.id
        return Button { model.selectPartition(partition.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: partition.isAvailable ? "square.stack.3d.up.fill" : "lock.fill")
                    .font(.system(size: 20)).foregroundStyle(selected ? Theme.mint : Theme.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(partition.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(Formatters.bytes(partition.size)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Text("\(partition.id) · \(partition.filesystem)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if let reason = partition.blockedReason {
                        Text(reason.appLocalized).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
            }.padding(12).background(selected ? Theme.mint.opacity(0.075) : Theme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).stroke(selected ? Theme.mint.opacity(0.65) : Theme.border, lineWidth: 1) }
        }.buttonStyle(.plain).disabled(!partition.isAvailable || model.busy).help(partition.blockedReason ?? partition.devicePath)
    }

    private var operationCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            if let status = model.status {
                HStack(spacing: 11) {
                    Image(systemName: status.phase == .complete ? "checkmark.seal.fill" : status.phase == .failed ? "exclamationmark.triangle.fill" : "arrow.down.to.line")
                        .font(.system(size: 22)).foregroundStyle(status.phase == .failed ? .orange : Theme.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.phase.title.appLocalized).font(.system(size: 16, weight: .semibold))
                        Text((model.cancellationRequested ? (model.scope == .partition ? "Зупиняю запис і відмонтовую вибраний розділ…" : "Зупиняю запис і безпечно вилучаю USB…") : status.message).appLocalized)
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if model.busy && status.phase != .waiting {
                        Text("\(Int(status.fraction * 100))%").font(.system(size: 25, weight: .medium, design: .monospaced)).foregroundStyle(Theme.mint)
                    }
                }
                if model.busy {
                    if status.phase == .waiting || status.phase == .splitting || status.phase == .formatting {
                        ProgressView().progressViewStyle(.linear)
                    } else { ProgressView(value: status.fraction).progressViewStyle(.linear) }
                    HStack {
                        if status.bytesTotal > 0 { Text("\(Formatters.bytes(status.bytesDone)) / \(Formatters.bytes(status.bytesTotal))") }
                        Spacer()
                        if status.bytesPerSecond > 0 { Text("\(Formatters.bytes(UInt64(status.bytesPerSecond)))/с") }
                    }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
                if let checksum = status.checksum {
                    Text("SHA-256  " + checksum).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
                HStack {
                    if model.session != nil { Button("Зберегти журнал…") { model.exportLog() }.buttonStyle(.plain).foregroundStyle(Theme.secondary).font(.system(size: 12)) }
                    Spacer()
                    if model.busy {
                        Button(model.cancellationRequested ? "Зупиняється…" : "Зупинити запис") { model.cancelWrite() }
                            .buttonStyle(.bordered).disabled(model.cancellationRequested)
                    } else { createButton }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.shield").font(.system(size: 23)).foregroundStyle(Theme.mint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Готові до запису?").font(.system(size: 16, weight: .semibold))
                        Text("Після запису програма зчитає дані з USB і перевірить їхню цілісність.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                }
                HStack {
                    if model.scope == .disk {
                        Toggle("Безпечно вилучити USB після завершення", isOn: $model.ejectAfterWrite)
                            .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.busy)
                    } else {
                        Label("Інші розділи залишаться підключеними", systemImage: "checkmark.shield")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    createButton
                }
                Text(model.buttonHint.appLocalized).font(.system(size: 11)).foregroundStyle(model.ready ? .orange.opacity(0.85) : Theme.secondary)
            }
        }.padding(22).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(Theme.border, lineWidth: 1) }
    }

    private var createButton: some View {
        Button { model.prepareConfirmation() } label: {
            HStack(spacing: 9) { Text(model.createTitle.appLocalized); Image(systemName: "arrow.right") }
                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 11)
                .foregroundStyle(model.ready ? Theme.background : Theme.secondary)
                .background(model.ready ? Theme.mint : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(!model.ready)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Linux: гібридні ISO та IMG. Windows: UEFI. Сумісність залежить від образу та комп'ютера.")
            Spacer()
            Text("1.2.2").font(.system(size: 10, design: .monospaced))
        }.font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.7))
    }

    private func cardTitle(_ title: String, icon: String, trailing: String) -> some View {
        HStack { Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)); Spacer(); Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary) }
    }
    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text.appLocalized).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark").foregroundStyle(Theme.secondary) }.buttonStyle(.plain)
        }.padding(14).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label((model.scope == .partition ? "Стерти вибраний розділ і записати образ?" : "Стерти накопичувач і записати образ?").appLocalized, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(.orange)
            if let device = model.selectedDevice, let image = model.image {
                Text(model.scope == .partition ? "Усі файли лише вибраного розділу буде втрачено. Таблиця розділів та інші розділи диска збережуться. Перед записом збережіть потрібні дані." : "Усі розділи та файли на цьому USB буде видалено. Перед записом збережіть потрібні дані.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Накопичувач", value: "\(device.name) · \(Formatters.bytes(device.size))")
                    if let partition = model.selectedPartition, model.scope == .partition {
                        LabeledContent("Розділ", value: "\(partition.name) · \(Formatters.bytes(partition.size))")
                        LabeledContent("Ціль запису", value: partition.devicePath)
                    } else { LabeledContent("Ціль запису", value: device.devicePath) }
                    LabeledContent("Образ", value: image.name)
                    LabeledContent("Режим", value: image.mode.title.appLocalized)
                }.font(.system(size: 12)).padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                Toggle(model.scope == .partition ? "Я зберіг потрібні дані та погоджуюся стерти цей розділ" : "Я зберіг потрібні дані та погоджуюся стерти весь USB", isOn: $model.acknowledged).font(.system(size: 12))
                if model.needsRawPartitionAcknowledgment {
                    Text("Прямий запис ISO у розділ може не створити завантажувальний носій. Багато образів потребують запису на цілий диск.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Toggle("Я розумію, що завантаження з цього розділу не гарантоване", isOn: $model.rawPartitionAcknowledged).font(.system(size: 12))
                } else if model.scope == .partition {
                    Text("Розділ буде відформатовано у FAT32 для Windows UEFI. Можливість завантаження залежить від прошивки цільового комп'ютера.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Для підтвердження введіть \(model.targetID ?? "")").font(.system(size: 12))
                    TextField(model.targetID ?? "", text: $model.confirmationText).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced))
                }
                Text("macOS попросить пароль адміністратора лише для цієї операції.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Скасувати") { model.showConfirmation = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(model.scope == .partition ? "Стерти розділ і записати" : "Стерти USB і записати") { model.startWrite() }.buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(!model.acknowledged || model.confirmationText != model.targetID || !model.ready || (model.needsRawPartitionAcknowledgment && !model.rawPartitionAcknowledged))
                }
            }
        }.padding(30).frame(width: 610).background(Theme.background)
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ваш USB — за три кроки").font(.system(size: 25, weight: .semibold, design: .rounded))
            helpRow("1", "Оберіть образ", "Відкрийте ISO або IMG через кнопку, перетягування чи ⌘O. Програма перевірить формат і визначить спосіб запису.")
            helpRow("2", "Оберіть ціль запису", "Режим «Увесь USB» стирає всі розділи накопичувача. У режимі «Окремий розділ» оберіть зовнішній фізичний диск, а потім його розділ. Системні диски, EFI, Recovery, APFS-контейнери й розділ з ISO захищені. ISO може бути на іншому розділі того самого диска.")
            helpRow("3", "Запишіть і перевірте", "Підтвердьте стирання та дозвіл macOS. Дочекайтеся завершення перевірки. Після зупинки операції повторіть запис перед використанням USB.")
            Divider()
            Text("Підтримувані образи").font(.system(size: 14, weight: .semibold))
            Text("Linux та інші системи: гібридні ISO/IMG з MBR або GPT. Windows: інсталяційні ISO з sources/boot.wim та EFI/BOOT; створюється FAT32 USB для UEFI. Будь-який .wim, більший за ліміт FAT32, поділяється на SWM поруч із вихідним файлом; великий sources/install.esd спочатку перетворюється на WIM. Для підготовки великих образів потрібне вільне місце на Mac.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("Окремий розділ: Windows записується у наявний розділ Microsoft Basic Data/FAT/ExFAT/NTFS з форматуванням у FAT32. Для інших ISO/IMG виконується побайтовий запис лише в межах розділу, без зміни MBR/GPT. Такий запис не гарантує завантаження; гібридні образи зазвичай потребують цілого диска. Інші розділи залишаються підключеними. Програма не створює нових розділів і не змінює їхній розмір.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("Для інсталятора macOS потрібен Apple createinstallmedia. Прямий запис ISO не створює інсталятор macOS. Завантаження Windows/Linux залежить від архітектури й можливостей цільового комп'ютера.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack { Spacer(); Button("Зрозуміло") { model.showHelp = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(30).frame(width: 650).background(Theme.background)
    }
    private func helpRow(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.mint).frame(width: 28, height: 28).background(Theme.mint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title.appLocalized).font(.system(size: 14, weight: .semibold)); Text(text.appLocalized).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
    }
}
