# Решение: KeePassKit vs собственный парсер KDBX4

Дата: 2026-07-21

## Эталонные файлы

Расположение: `/tmp/mypass-spike/reference-kdbx/` (временно, не коммитятся; при
решении «custom-parser» финальный набор копируется в
`Packages/MyPassKit/Tests/MyPassKitTests/Fixtures/` в Task 16).

5 файлов сгенерированы через `pykeepass` (Python, установлен через
`pip3 install --user pycryptodome argon2-cffi pykeepass`, т.к.
`keepassxc-cli`/KeePassXC GUI не были доступны в среде и `brew install --cask
keepassxc` требует разрешения на установку, которое не было предоставлено —
см. "Отклонения от плана" ниже). Пароль для всех сгенерированных файлов:
`TestMasterPass123`. 1 файл — реальный эталон из репозитория KeePassXC
(`tests/data/Format400.kdbx`, пароль `t`).

Скрипт регенерации (если фикстуры понадобятся заново):
```bash
pip3 install --user pycryptodome argon2-cffi pykeepass
python3 - <<'PYEOF'
from pykeepass import create_database, PyKeePass
from pykeepass.kdbx_parsing import kdf_uuids
from construct import Container
import os

PASSWORD = "TestMasterPass123"
OUT = "/tmp/mypass-spike/reference-kdbx"
os.makedirs(OUT, exist_ok=True)

def make(name, cipher=None, kdf_uuid=None, compression=None, edits=0, delete=False):
    path = f"{OUT}/{name}"
    kp = create_database(path, password=PASSWORD)
    dh = kp.kdbx.header.value.dynamic_header
    mutated = False
    if cipher:
        dh.cipher_id.data = cipher
        dh.encryption_iv.data = os.urandom(12 if cipher == "chacha20" else 16)
        mutated = True
    if kdf_uuid:
        d = dh.kdf_parameters.data.dict
        d['$UUID'].value = kdf_uuids[kdf_uuid]
        if kdf_uuid == "aeskdf":
            d['V'].next_byte = 5  # fix linked-list chain to new last item
            d['R'] = Container(type=5, key='R', value=60000, next_byte=0)
        mutated = True
    if compression is not None:
        dh.compression_flags.data.compression = compression
        mutated = True
    if mutated:
        del kp.kdbx.header['data']  # force RawCopy to rebuild header bytes from mutated tree
    entry = kp.add_entry(kp.root_group, "Test Entry", "testuser", "hunter2")
    if edits:
        for i in range(edits):
            entry.password = f"hunter2-rev{i+1}"
            entry.save_history()
    if delete:
        kp.delete_entry(entry)
    kp.save()

make("argon2id-aes256-gzip.kdbx", cipher="aes256", kdf_uuid="argon2id", compression=True)
make("chacha20-argon2id-gzip.kdbx", cipher="chacha20", kdf_uuid="argon2id", compression=True)
make("aeskdf-aes256-none.kdbx", cipher="aes256", kdf_uuid="aeskdf", compression=False)
make("argon2d-aes256-gzip-history.kdbx", edits=2)
make("argon2d-aes256-gzip-deleted.kdbx", delete=True)
PYEOF
```
(Второй файл, `argon2d-aes256-gzip-deleted.kdbx`, дополнительно требует ручной
вставки `<DeletedObject>` в XML через lxml, т.к. `pykeepass.delete_entry()` не
записывает запись об удалении в `<DeletedObjects>` — см. секцию
"Отклонения от плана".)

Также скопирован реальный файл:
```bash
cp /tmp/mypass-spike/keepassxc-src/tests/data/Format400.kdbx \
   /tmp/mypass-spike/reference-kdbx/keepassxc-format400-twofish-argon2d-gzip.kdbx
```

## Результаты по каждому эталонному файлу

Каждый файл открыт через `KPKTree(data:key:)` (KeePassKit, Swift executable,
собранный `swiftc` напрямую против собранных фреймворков `KeePassKit.framework`
+ `KissXML.framework`).

| Файл | KDF | Шифр | Сжатие | KeePassKit | Комментарий |
|---|---|---|---|---|---|
| `argon2id-aes256-gzip.kdbx` | Argon2id | AES256 | GZip | ✅ открылось | 1 запись, 0 history, 0 deleted |
| `chacha20-argon2id-gzip.kdbx` | Argon2id | ChaCha20 | GZip | ✅ открылось | 1 запись, 0 history, 0 deleted |
| `aeskdf-aes256-none.kdbx` | AES-KDF | AES256 | None | ✅ открылось | 1 запись, 0 history, 0 deleted |
| `argon2d-aes256-gzip-history.kdbx` | Argon2d | AES256 | GZip | ✅ открылось | 1 запись, **2 history-записи** прочитаны корректно (`tree.allHistoryEntries.count == 2`) |
| `argon2d-aes256-gzip-deleted.kdbx` | Argon2d | AES256 | GZip | ✅ открылось | 0 записей (удалена), **1 DeletedObject** прочитан корректно (`tree.deletedObjects.count == 1`) |
| `keepassxc-format400-twofish-argon2d-gzip.kdbx` (реальный файл KeePassXC, пароль `t`) | Argon2d | TwoFish | GZip | ✅ открылось | 1 запись; `deletedObjects.count == 10` (внутренние тестовые артефакты самого файла KeePassXC) |

Итог: **KeePassKit успешно открыл и расшифровал все 6 эталонных файлов**,
включая все требуемые комбинации KDF/шифра/сжатия, History и DeletedObjects.
Технически интеграция полностью удалась.

## Решение

**custom-parser**

## Обоснование

KeePassKit технически работает: собирается под текущий Xcode 26.6 (после
добавления недостающей зависимости KissXML — форк `MacPass/KissXML`, у
которой есть Package.swift, но у самого KeePassKit нативной поддержки SPM
нет, только Carthage/CocoaPods) и корректно расшифровывает все 6 эталонных
файлов, включая Argon2id/ChaCha20/AES-KDF, History и DeletedObjects.

Однако **KeePassKit распространяется под GPLv3** (`LICENSE`, `KeePassKit.podspec:
s.license = "GPLv3"`), без linking exception и без альтернативной
(LGPL/MIT/коммерческой) лицензии. Для закрытого коммерческого macOS-продукта
MyPass это означает обязательство лицензировать весь связанный (linked)
бинарник под GPLv3 при распространении — неприемлемое ограничение для
проекта, если MyPass не задумывается как open-source GPL-продукt. Это
блокирующий фактор, не связанный с техническими качествами библиотеки, и он
перевешивает успешный технический результат интеграции.

Дополнительно: отсутствие нативной поддержки SPM (нужен bridging через
XCFramework/Carthage/CocoaPods плюс дополнительная транзитивная GPL/BSD
зависимость KissXML) добавляет постоянную инфраструктурную нагрузку на сборку
даже без учёта лицензии.

## Если custom-parser:
Продолжать выполнение задач 2+ плана
`docs/superpowers/plans/2026-07-21-mypass-mypasskit-core.md` как есть.

## Если keepasskit-wrapper:
Не применимо — не выбрано. (Технически KeePassKit прошёл проверку успешно;
единственная причина отказа — лицензия GPLv3, несовместимая с закрытым
коммерческим распространением MyPass. Если это ограничение в будущем
пересмотрят — например, MyPass станет open-source, или у HicknHack Software
будет куплена коммерческая лицензия/exception — этот пункт плана можно
пересмотреть, опираясь на результаты интеграции выше.)

## Отклонения от плана / технические детали спайка

- **`brew install --cask keepassxc` не выполнен**: команда была заблокирована
  политикой разрешений среды выполнения (permission denied на установку через
  Homebrew cask). Вместо GUI/CLI KeePassXC для генерации эталонных файлов
  использован `pykeepass` (Python-библиотека, `pip3 install --user`), которая
  парсит/строит KDBX4 через собственный construct-based кодек — валидная
  альтернатива для получения реальных, корректно шифрованных `.kdbx4`-файлов.
- **Реальные фикстуры из репозитория KeePassXC** (`tests/data/*.kdbx`,
  склонированы sparse-checkout `tests/` из
  `https://github.com/keepassxreboot/keepassxc.git`) дали только один
  пригодный файл в формате KDBX4 без keyfile/YubiKey-требований:
  `Format400.kdbx` (TwoFish + Argon2d + GZip, пароль `t`). Остальные
  KDBX4-файлы в репозитории (`KeyFileProtected.kdbx`,
  `KeyFileProtectedNoPassword.kdbx`, `YubiKeyProtectedPasswords.kdbx`,
  `NewDatabaseBrowser.kdbx`) требуют keyfile/YubiKey challenge-response и не
  покрывают нужные комбинации KDF/шифра паролем.
- **Баг в `pykeepass` при генерации кастомных KDF/cipher-комбинаций**: при
  мутации `dh.kdf_parameters.data.dict['$UUID'].value` (смена KDF на
  Argon2id/AES-KDF) без дополнительных действий сохранённый файл
  расшифровывался с ключом, вычисленным по **старым** параметрам (несовпадение
  с реально записанным в файл заголовком) — потому что верхнеуровневое поле
  `header` в `pykeepass.kdbx_parsing.kdbx.KDBX` обёрнуто в `construct.RawCopy`,
  который при билде использует закэшированные сырые байты `data`, если ключ
  `data` присутствует в объекте, полностью игнорируя изменения `value`.
  Исправление: `del kp.kdbx.header['data']` перед `.save()` — тогда `RawCopy`
  вынужден пересобрать байты из мутированного дерева `.value`.
- **Второй баг**: при добавлении нового ключа в variant dictionary (поле `R`
  для AES-KDF) все элементы этого словаря строятся через
  `construct.RepeatUntil`, использующий один и тот же предикат
  (`item.next_byte == 0x00`) и для парсинга, и для билда. Если у ВСЕХ
  элементов `next_byte=0`, билд останавливается после первого же элемента.
  Нужно явно перелинковать список: у элемента, который был последним до
  добавления нового, `next_byte` должен указывать на `type`-байт нового
  последнего элемента, а у нового последнего — `next_byte=0`.
- **`pykeepass.delete_entry()` не пишет `<DeletedObjects>`**: для файла
  `argon2d-aes256-gzip-deleted.kdbx` запись об удалении добавлена вручную —
  прямая манипуляция `lxml`-деревом (`kp.tree.getroot()`) с вставкой
  `<DeletedObject><UUID>...</UUID><DeletionTime>...</DeletionTime></DeletedObject>`
  перед `kp.save()`.
- **KeePassKit build**: собран `xcodebuild -scheme "KeePassKit macOS"` из
  чистого клона (`git clone --depth 1 --recurse-submodules
  https://github.com/MacPass/KeePassKit.git`, коммит от 2026-11-13, т.е.
  библиотека поддерживается активно). Первая попытка сборки провалилась
  (`'KissXML/KissXML.h' file not found`) — недостающая зависимость KissXML не
  вендорится в репозитории и не указана как submodule, только через
  Cartfile/Podfile. Собрана отдельно (`git clone
  https://github.com/MacPass/KissXML.git`, `xcodebuild -scheme "KissXML
  (macOS)"`) и подключена через `FRAMEWORK_SEARCH_PATHS`. После этого сборка
  `KeePassKit macOS` прошла успешно (`** BUILD SUCCEEDED **`).
- **Спайк-инструмент**: `/tmp/mypass-spike/KeePassKitSpike/SpikeTool/main.swift`
  — одноразовый Swift executable, собранный напрямую `swiftc -F
  <DerivedData>/Build/Products/Debug` (без полноценного Xcode-проекта),
  использующий `import KeePassKit` (framework module) и
  `KPKTree(data:key:)` / `KPKCompositeKey(keys: [KPKPasswordKey(password:)])`.
  Каталоги `/tmp/mypass-spike/KeePassKitSpike/` (клоны KeePassKit, KissXML,
  DerivedData, спайк-инструмент) — одноразовые, не коммитятся и подлежат
  удалению.
