# Maestro Mobile and Web Test Framework — MAUDAU

[🇺🇦 Українська](#українська) | [🇬🇧 English](#english)

---

## Українська

Mobile UI автотести для Android-додатку MAUDAU, побудовані на [Maestro](https://maestro.mobile.dev/).  
Репорти генеруються через Allure з відео-записами і скріншотами.

Маестро дозволяє суттєво прискорити написання тестів — YAML-флоу можна створювати вручну або автоматично через **MCP сервер**: підключи AI-агента (наприклад Cursor) до запущеного `maestro mcp` і агент зможе досліджувати живий додаток, читати UI-ієрархію і генерувати тести самостійно.

### Залежності

| Інструмент | Версія | Призначення |
|---|---|---|
| [Maestro CLI](https://maestro.mobile.dev/getting-started/installing-maestro) | latest | запуск тестів |
| Java JDK | 17+ | потрібна для Maestro |
| Android Emulator або фізичний пристрій | API 30+ | таргет для тестів |
| [Allure CLI](https://allurereport.org/docs/install/) | 2.x | генерація HTML-репортів |
| PowerShell | 5.1+ | скрипти генерації репортів |

### Встановлення Maestro

```bash
# macOS / Linux
curl -Ls "https://get.maestro.mobile.dev" | bash

# Windows — завантажити з https://github.com/mobile-dev-inc/maestro/releases
# Розпакувати і додати bin/ до PATH
```

### Встановлення Allure

```bash
# macOS
brew install allure

# Windows (scoop)
scoop install allure

# або завантажити з https://github.com/allure-framework/allure2/releases
```

### Структура проекту

```
flows/
  smoke/              # smoke-тести (запускаються як suite)
    01-launch.yaml    # запуск додатку, перевірка головного екрану
    02-cart.yaml      # додавання та видалення товару з кошика
    03-promotions.yaml# перехід до акцій з порожнього кошика
  subflows/           # перевикористовувані блоки
    skip-onboarding.yaml
    add-random-product.yaml
    remove-from-cart.yaml
    login.yaml
  regression/         # регресійні тести
  record-all-smoke.yaml  # запуск smoke з відео-записом
config/
  env.yaml            # змінні середовища
scripts/
  generate-allure-report.ps1  # генерація Allure репорту
```

### Запуск тестів

#### Через VS Code tasks (рекомендовано)

Відкрий `Terminal → Run Task` і обери:

| Task | Опис |
|---|---|
| `Run smoke tests and open Allure report` | запуск тестів + генерація репорту |
| `Run smoke tests with recording and Allure report` | те саме + відео-запис кожного тесту |
| `Run smoke tests for Allure` | лише запуск тестів, без репорту |
| `Generate Allure report` | лише генерація репорту з наявних результатів |

#### Через термінал

```bash
# Запуск smoke suite
maestro test flows/smoke

# Запуск з JUnit XML для Allure
maestro test --format JUNIT --output allure-results/smoke.xml flows/smoke

# Запуск з відео-записом
maestro test flows/record-all-smoke.yaml

# Генерація репорту
powershell -File scripts/generate-allure-report.ps1
```

### Перед запуском

1. Запусти Android емулятор або підключи пристрій
2. Перевір підключення: `adb devices` — має показати пристрій зі статусом `device`
3. Встанови APK на пристрій або використай скрипт `scripts/install-apk.ps1`

### Додавання нових тестів

1. Створи файл у `flows/smoke/` з іменем `NN-назва.yaml` де `NN` — порядковий номер
2. Додай запис відео у `flows/record-all-smoke.yaml`
3. Додай `takeScreenshot: screenshots/NN-назва` в кінці тесту

Приклад мінімального тесту:
```yaml
appId: com.maudau
name: 04 - Smoke - My test
tags:
  - smoke
---
- runFlow: ../subflows/skip-onboarding.yaml
- tapOn: "Каталог"
- assertVisible: "Продукти і напої"
- takeScreenshot: screenshots/04-my-test
```

---

## English

Mobile UI automation tests for the MAUDAU Android app, built on [Maestro](https://maestro.mobile.dev/).  
Reports are generated via Allure with video recordings and screenshots.

Maestro significantly speeds up test authoring — YAML flows can be written manually or generated automatically via the **MCP server**: connect an AI agent (e.g. Cursor) to a running `maestro mcp` instance and the agent can explore the live app, read UI hierarchy and write tests on its own.

### Requirements

| Tool | Version | Purpose |
|---|---|---|
| [Maestro CLI](https://github.com/mobile-dev-inc/maestro/releases) | latest | running tests |
| [Java JDK](https://adoptium.net/) | 17+ | required by Maestro |
| Android Emulator or physical device | API 30+ | test target |
| [Allure CLI](https://github.com/allure-framework/allure2/releases) | 2.x | HTML report generation |
| PowerShell | 5.1+ | report generation scripts |
| [ADB (Android SDK Platform Tools)](https://developer.android.com/tools/releases/platform-tools) | latest | device communication |

### Installation (Windows)

#### 1. Java JDK

Download and install JDK 17+ from [Adoptium](https://adoptium.net/).  
After installation, set the environment variable:

```
JAVA_HOME = C:\path\to\your\jdk
```

Add to PATH: `%JAVA_HOME%\bin`

Verify:
```cmd
java -version
```

#### 2. Maestro CLI

Download the latest release from [GitHub Releases](https://github.com/mobile-dev-inc/maestro/releases).  
Extract the archive and add the `bin\` folder to your PATH.

Verify:
```cmd
maestro --version
```

> If you use a custom JDK path, set `JAVA_HOME` before running Maestro or configure it in `.vscode\tasks.json`.

#### 3. Android SDK Platform Tools (ADB)

Download from [developer.android.com](https://developer.android.com/tools/releases/platform-tools).  
Extract and add the folder to PATH.

Verify:
```cmd
adb version
```

#### 4. Allure CLI

**Option A — via Scoop (recommended):**
```cmd
scoop install allure
```

**Option B — manual:**  
Download from [GitHub Releases](https://github.com/allure-framework/allure2/releases), extract and add `bin\` to PATH.

Verify:
```cmd
allure --version
```

### Project Structure

```
flows/
  smoke/                      # smoke tests (run as a suite)
    01-launch.yaml            # app launch, home screen check
    02-cart.yaml              # add and remove product from cart
    03-promotions.yaml        # navigate to promotions from empty cart
  subflows/                   # reusable flow blocks
    skip-onboarding.yaml
    add-random-product.yaml
    remove-from-cart.yaml
    login.yaml
  regression/                 # regression tests
  record-all-smoke.yaml       # runs smoke suite with video recording
config/
  env.yaml                    # environment variables
scripts/
  generate-allure-report.ps1  # Allure report generation script
  install-apk.ps1             # APK installation helper
```

### Before Running

1. Start an Android emulator or connect a physical device via USB
2. Verify the device is visible:
```cmd
adb devices
```
Expected output: a device listed with status `device`

3. Install the APK:
```cmd
powershell -File scripts\install-apk.ps1
```

### Running Tests

#### Via VS Code Tasks (recommended)

Open `Terminal → Run Task` and choose:

| Task | Description |
|---|---|
| `Run smoke tests and open Allure report` | run tests + generate and open report |
| `Run smoke tests with recording and Allure report` | same + video recording per test |
| `Run smoke tests for Allure` | run tests only, no report |
| `Generate Allure report` | generate report from existing results |

#### Via Terminal

```cmd
# Run smoke suite
maestro test flows\smoke

# Run with JUnit XML output for Allure
maestro test --format JUNIT --output allure-results\smoke.xml flows\smoke

# Run with video recording
maestro test flows\record-all-smoke.yaml

# Generate Allure report
powershell -File scripts\generate-allure-report.ps1
```

### Adding New Tests

1. Create a file in `flows\smoke\` named `NN-name.yaml` where `NN` is the order number
2. Add a recording block to `flows\record-all-smoke.yaml`
3. Add `takeScreenshot: screenshots/NN-name` at the end of the test

Minimal test example:
```yaml
appId: com.maudau
name: 04 - Smoke - My test
tags:
  - smoke
---
- runFlow: ../subflows/skip-onboarding.yaml
- tapOn: "Catalog"
- assertVisible: "Products"
- takeScreenshot: screenshots/04-my-test
```

### Allure Report

The report includes per test:
- step-by-step execution log with pass/fail/skipped status
- video recording (embedded, plays in browser)
- final screenshot

Reports are saved to `allure-report\<timestamp>\` and opened automatically after generation.
