<div align="center">

# ISO Forge

### Create bootable USB media from ISO and IMG on macOS

A native SwiftUI utility for Windows UEFI installers and hybrid Linux images, with whole-drive and existing-partition workflows.

[Українська версія нижче](#українська)

</div>

---

## Features

- **Windows UEFI:** prepares a FAT32 installer drive and copies files with SHA-256 verification.
- **Large Windows images:** splits oversized `.wim` files into FAT32-compatible `.swm` parts; converts a large `sources/install.esd` before splitting.
- **Linux and other systems:** writes supported hybrid ISO/IMG images directly to a whole drive or, with a bootability caveat, to a selected partition.
- **Partition mode:** formats only the selected existing partition and checks that the partition map and neighboring partitions remain unchanged.
- **Safety checks:** identifies external physical drives, protects system/source volumes, checks capacity, requires a typed target confirmation, supports cancellation, and verifies written files.
- **Bilingual interface:** Ukrainian, English, or automatic selection from the macOS preferred language.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools or Xcode for building
- An ISO/IMG image and an external drive with enough space

## Install or build

Download the app from the repository’s **Releases** page, or build it locally:

```bash
git clone https://github.com/OWNER/ISOForge.git
cd ISOForge
bash scripts/build-app.sh
```

The app bundle is created at `dist/ISO Forge.app`. To install it into `/Applications`:

```bash
bash scripts/build-app.sh --install
```

The build fetches and bundles wimlib; Homebrew is not required. Review the included licenses and provenance files under `Vendor/wimlib` before redistributing a build.

## Use

1. Choose an ISO or IMG.
2. Select **Whole USB** to prepare an entire external drive, or **Existing partition** to preserve the rest of that drive.
3. Review the target and confirm its identifier before formatting.
4. Wait for the write and SHA-256 verification to finish.

The language menu in the top-right lets you choose **System language**, **Українська**, or **English**. System language follows the macOS preferred language: Ukrainian for Ukrainian, English for every other language.

> **Warning:** Formatting erases all data on the selected target. In whole-drive mode, all partitions on that drive are erased. In partition mode, only the selected partition is formatted.

> **Bootability:** Windows UEFI installers are prepared as FAT32. Firmware compatibility can vary. Directly writing a hybrid ISO to a partition does not guarantee that the computer firmware can boot it; whole-drive writing is usually the appropriate mode for hybrid images.

## Development

```bash
swift build --disable-sandbox --scratch-path "$HOME/Library/Caches/ua.isoforge/swift-build"
```

Core and disposable-image tests are in `Tests/`. They do not validate physical USB bootability. Never use valuable or system storage as a test target.

## License

See the repository’s `LICENSE` and `Vendor/*/PROVENANCE.txt` and license files for project and bundled-component terms.

---

<a id="українська"></a>

## Українська

ISO Forge — нативна програма для macOS, що створює завантажувальні USB-накопичувачі з ISO та IMG. Підтримує інсталяційні образи Windows UEFI, гібридні образи Linux, запис на весь зовнішній диск або на окремий наявний розділ.

### Можливості

- **Windows UEFI:** підготовка FAT32 та копіювання файлів із перевіркою SHA-256.
- **Великі образи Windows:** поділ великих `.wim` на частини `.swm`, сумісні з FAT32; великий `sources/install.esd` перед поділом перетворюється.
- **Linux та інші системи:** побайтовий запис підтримуваних гібридних ISO/IMG на цілий диск або окремий розділ. Для розділу завантаження не гарантується.
- **Режим окремого розділу:** форматується лише вибраний розділ; програма перевіряє, що таблиця розділів і сусідні розділи не змінилися.
- **Захисні перевірки:** визначення зовнішніх фізичних дисків, захист системних дисків і вихідного ISO, перевірка обсягу, підтвердження ідентифікатора цілі, зупинка операції та перевірка записаних файлів.
- **Дві мови:** українська, англійська або автоматичний вибір за мовою macOS.

### Вимоги

- macOS 14 або новіша
- Xcode Command Line Tools або Xcode для збирання
- ISO/IMG та зовнішній накопичувач достатнього обсягу

### Збирання та встановлення

```bash
git clone https://github.com/OWNER/ISOForge.git
cd ISOForge
bash scripts/build-app.sh
```

Застосунок буде створено в `dist/ISO Forge.app`. Для встановлення в `/Applications` виконайте:

```bash
bash scripts/build-app.sh --install
```

Під час збирання завантажується та додається wimlib; Homebrew не потрібен. Перед поширенням перегляньте ліцензії та відомості про походження компонентів у `Vendor/wimlib`.

### Використання

1. Виберіть ISO або IMG.
2. Оберіть **Увесь USB**, щоб підготувати весь зовнішній диск, або **Окремий розділ**, щоб зберегти решту розділів.
3. Перевірте ціль і підтвердьте її ідентифікатор перед форматуванням.
4. Дочекайтеся завершення запису та перевірки SHA-256.

Меню мови у правому верхньому куті пропонує **Мова системи**, **Українська** та **English**. Автоматичний режим використовує українську, якщо основна мова macOS — українська; для будь-якої іншої мови вмикається англійська.

> **Увага:** форматування стирає дані вибраної цілі. У режимі всього диска стираються всі його розділи. У режимі окремого розділу форматується лише він.

> **Завантаження:** Windows UEFI готується у FAT32. Сумісність залежить від прошивки. Побайтовий запис гібридного ISO у розділ не гарантує завантаження; для таких образів зазвичай слід обирати запис на весь диск.

### Розробка

```bash
swift build --disable-sandbox --scratch-path "$HOME/Library/Caches/ua.isoforge/swift-build"
```

Тести ядра та роботи з тимчасовими образами розміщено в `Tests/`. Вони не підтверджують завантаження з фізичного USB. Не використовуйте системні диски або накопичувачі з важливими даними для тестів.

### Ліцензія

Умови ліцензування програми та вбудованих компонентів наведено у файлах `LICENSE`, `Vendor/*/PROVENANCE.txt` і ліцензіях компонентів.
