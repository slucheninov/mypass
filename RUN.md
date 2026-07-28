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

### Автоматичне налаштування (рекомендовано)

Розширення має закріплений (pinned) ID `hjijbabodfldconmhdcdphlbgaajkejn` завдяки полю `key` у `ChromeExtension/manifest.json`, тому з'єднання можна налаштувати одним скриптом:

```sh
./scripts/setup-chrome-extension.sh
```

Скрипт `./scripts/setup-chrome-extension.sh` встановлює native messaging manifest для **усіх встановлених Chromium-браузерів** (Chrome, Edge, Brave, Vivaldi, Opera, Arc тощо). Кожен браузер підключається окремо — у **Settings → Paired browsers** з'являється свій рядок з назвою цього браузера.

1. У Chrome завантажте розпаковане розширення з `ChromeExtension/` (див. нижче) — його ID має бути `hjijbabodfldconmhdcdphlbgaajkejn`.
2. Якщо розширення вже було додано раніше, перезавантажте його (reload) на `chrome://extensions`.

### Підключення браузера (pairing)

Перед першим автозаповненням або збереженням пароля розширення має бути **підключене** до розблокованого MyPass:

1. Відкрийте popup розширення на будь-якій сторінці — з'явиться кнопка **Connect to MyPass**.
2. Натисніть її; у головному вікні MyPass з'явиться **6-значний код** (дійсний 120 секунд).
3. Введіть цей код у popup розширення та підтвердіть.

Після успішного підключення popup показує збережені записи як раніше. Скасувати довіру можна в **MyPass → Settings → Browser → Paired browsers → Revoke**. Деталі протоколу: [spec pairing](docs/superpowers/specs/2026-07-26-mypass-extension-pairing-design.md).

### Як додати в Chrome (розпаковане)

1. **Передумова:** JS-розширення лежить у [`ChromeExtension/`](ChromeExtension/) — окремого кроку збірки для нього немає; завантажуйте цю папку як є. Native host (`ChromeHost`) збирається автоматично скриптом [`setup-chrome-extension.sh`](scripts/setup-chrome-extension.sh) (див. [Автоматичне налаштування](#автоматичне-налаштування-рекомендовано)).
2. Відкрийте Chrome → перейдіть на `chrome://extensions` (або **Меню → Розширення → Керування розширеннями**).
3. Увімкніть **Режим розробника** (Developer mode) — перемикач у правому верхньому куті.
4. Натисніть **Завантажити розпаковане розширення** (Load unpacked).
5. Оберіть каталог репозиторію [`ChromeExtension/`](ChromeExtension/) (повний шлях: `<repo>/ChromeExtension/`).
6. Переконайтеся, що на картці відображається **MyPass** (версія 0.1.0) з ID `hjijbabodfldconmhdcdphlbgaajkejn`.
7. Після змін у JS-файлах: на тій же сторінці натисніть іконку оновлення (reload) на картці MyPass.

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

## Синхронізація через iCloud Drive

1. Розблокуйте сховище (потрібен пароль сховища, щоб прочитати сховище, яке вже може лежати в теці).
2. Відкрийте **Settings → Sync**, виберіть бекенд **iCloud Drive** і натисніть **Set Up iCloud Sync…**.
3. Виберіть теку в iCloud Drive (панель відкривається на `~/Library/Mobile Documents/com~apple~CloudDocs`). Можна створити нову теку, наприклад `MyPass`.
4. Якщо тека порожня — MyPass завантажить туди сховище з цього Mac. Якщо в теці вже є `vault.kdbx`, виберіть один з варіантів:
   - **Merge** (за замовчуванням) — залишає записи з обох боків;
   - **Use the vault from the folder** — замінює локальне сховище тим, що в теці (попереднє локальне потрапляє в `backups/`);
   - **Replace the vault in the folder** — замінює сховище в теці локальним.
5. **Перезапустіть MyPass** — бекенд синхронізації створюється під час запуску застосунку.
6. Після перезапуску в вибраній теці має з'явитися `vault.kdbx`, а кнопка **Sync Now** у Settings → Sync запускає синхронізацію вручну.

Якщо тека стала недоступною (перейменована, видалена, знята з iCloud Drive), MyPass очистить збережену закладку і попросить вибрати теку знову.

## Обмеження

- **`MyPass.xcodeproj` у `.gitignore`** — перед збіркою завжди потрібен `./scripts/generate.sh` (викликається автоматично з `build*.sh` і `test.sh`).
- **Keychain sharing** — у `MyPass` і `ChromeHost` має бути однаковий Team ID під час підпису, інакше host не зчитає токен/порт з Keychain.
- **Шлях ChromeHost** — скрипт `scripts/setup-chrome-extension.sh` копіює зібраний бінарник у `~/Library/Application Support/MyPass/ChromeHost`; після перезбірки ChromeHost перезапустіть скрипт, щоб оновити копію.
- **iCloud** — синхронізація працює через **теку в iCloud Drive** і не потребує платного акаунта Apple Developer. Шлях через приватний iCloud-контейнер (ubiquity container) вимагає платного акаунта Apple Developer і в цій збірці не задіяний. Інтеграційні iCloud-тести (`MYPASS_ICLOUD_INTEGRATION_TESTS=1`) потребують Mac з увімкненим iCloud Drive.
