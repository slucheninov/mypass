# Запуск MyPass

## Вимоги

- **Xcode** (macOS 14+, цілі проєкту: `MyPass`, `ChromeHost`)
- **XcodeGen** — генерація `.xcodeproj` з `project.yml`:
  ```sh
  brew install xcodegen
  ```
- **Node.js** (опційно) — для JS-тестів розширення Chrome

## Швидкий старт

```sh
./scripts/build-all.sh
./scripts/run.sh
```

Перший запуск збере застосунок і native messaging host; `run.sh` відкриє `MyPass.app`.

## Скрипти

| Скрипт | Призначення |
|--------|------------|
| [`scripts/generate.sh`](scripts/generate.sh) | `xcodegen generate` — створити/оновити `MyPass.xcodeproj` |
| [`scripts/build.sh`](scripts/build.sh) | Згенерувати проєкт і зібрати схему **MyPass** |
| [`scripts/build-chrome-host.sh`](scripts/build-chrome-host.sh) | Згенерувати проєкт і зібрати **ChromeHost** |
| [`scripts/build-all.sh`](scripts/build-all.sh) | Зібрати MyPass і ChromeHost |
| [`scripts/run.sh`](scripts/run.sh) | Зібрати і запустити **MyPass.app** |
| [`scripts/test.sh`](scripts/test.sh) | Xcode-тести, Swift Package-тести, JS-тести (якщо є `node`) |

## Тести

```sh
./scripts/test.sh
```

За замовчуванням інтеграційні тести з зовнішніми залежностями **не** потрібні. Опційні змінні оточення:

| Змінна | Що вмикає |
|------------|--------------|
| `MYPASS_KEYCHAIN_TESTS=1` | Тести, що звертаються до Keychain |
| `MYPASS_SFTP_INTEGRATION_TESTS=1` | SFTP-інтеграція в SyncKit; перед запуском підняти Docker-фікстуру: `cd Packages/SyncKit/Tests/Fixtures/docker-sshd && ./run.sh` (зупинка: `./teardown.sh`) |
| `MYPASS_ICLOUD_INTEGRATION_TESTS=1` | iCloud-інтеграційні тести SyncKit |

## Chrome-розширення

### Як додати в Chrome (розпаковане)

1. **Передумова:** JS-розширення лежить у [`ChromeExtension/`](ChromeExtension/) — окремого кроку збірки для нього немає; завантажуйте цю папку як є. Native host (`ChromeHost`) — окремо; його збирають скриптами з розділу [Швидкий старт](#швидкий-старт) (див. нижче [Підключення до MyPass](#підключення-до-mypass-native-messaging)).
2. Відкрийте Chrome → перейдіть на `chrome://extensions` (або **Меню → Розширення → Керування розширеннями**).
3. Увімкніть **Режим розробника** (Developer mode) — перемикач у правому верхньому куті.
4. Натисніть **Завантажити розпаковане розширення** (Load unpacked).
5. Оберіть каталог репозиторію [`ChromeExtension/`](ChromeExtension/) (повний шлях: `<repo>/ChromeExtension/`).
6. Переконайтеся, що на картці відображається **MyPass** (версія 0.1.0).
7. Скопіюйте **ID** розширення (32-символьний рядок на картці) — він знадобиться в MyPass Settings.
8. Після змін у JS-файлах: на тій же сторінці натисніть іконку оновлення (reload) на картці MyPass.

### Підключення до MyPass (native messaging)

1. Запустіть MyPass (див. [Швидкий старт](#швидкий-старт)).
2. Відкрийте **MyPass → Settings**.
3. Вставте **ID розширення** з кроку вище.
4. Вкажіть папку **Native Messaging Hosts** (стандартний шлях Chrome на macOS).
5. Натисніть **Install host** — має встановитися зібраний `ChromeHost` (попередньо `./scripts/build-chrome-host.sh` або `./scripts/build-all.sh`).

### Chrome e2e (ручна перевірка)

1. Запустіть фікстурний HTTP-сервер:
   ```sh
   cd ChromeExtension/tests/fixtures && python3 -m http.server 8765
   ```
2. Короткий чеклист:
   - [ ] Popup показує збіги для домену фікстури
   - [ ] Autofill заповнює логін/пароль за явною дією користувача
   - [ ] Після входу пропонується зберегти новий запис
   - [ ] Збережений запис з'являється в MyPass

Повний чеклист і деталі налаштування: [план Фази 4](docs/superpowers/plans/2026-07-25-mypass-phase4-chrome-extension.md).

## Обмеження

- **`MyPass.xcodeproj` у `.gitignore`** — перед збіркою завжди потрібен `./scripts/generate.sh` (викликається автоматично з `build*.sh` і `test.sh`).
- **Keychain sharing** — у `MyPass` і `ChromeHost` має бути однаковий Team ID під час підпису, інакше host не зчитає токен/порт з Keychain.
- **Шлях ChromeHost** — installer може очікувати бінарник у фіксованому DerivedData-шляху; після зміни конфігурації Xcode шлях може не збігтися (перезберіть і перевстановіть host).
- **iCloud entitlements** — у репозиторії можуть бути неповними; інтеграційні iCloud-тести потребують налаштованого середовища розробника.
