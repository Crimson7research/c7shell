---
name: c7shell-cpp-style
description: Use in the c7shell repo whenever you write, edit or review C++ under plugin/ — a .hpp, .cpp, .h, a class, a method, a member, a Q_PROPERTY, a Q_INVOKABLE, a signal, a singleton manager, a cast or an include block — so it follows the house style. Also on casual asks — "format this", "run clang-format", "what do we name members", "m_ prefix or not", "tabs or spaces", "how do we write a manager class", "can this be a singleton", "make this match our style", "why is the brace on its own line", "fix the naming", "style review". Formats with the skill's clang-format file and applies the PascalCase / m_PascalCase naming, the camelCase exception for names QML sees, dependency injection instead of singletons, and the cast and string rules. NOT for choosing a file's folder or name (c7shell-plugin-layout), NOT for QML or JavaScript, and NOT for shell scripts under bin/ or tests/.
---

# c7shell C++ style

Announce first: **Using c7shell-cpp-style to write this C++.**

**Legacy C++ only.** `docs/architecture.md` makes the plugin Rust with no
hand-written C++. This skill applies only to C++ already on `main` until epic
#287 ports it. Never use it to create a new `.cpp`, `.h` or `.hpp` file.

## 1. Name things

| Thing | Style | Example |
| --- | --- | --- |
| Type, file | `PascalCase` | `NmClient`, `NmClient.hpp` |
| Method, free function | `PascalCase` | `GetDevices()`, `Init()` |
| Member | `m_PascalCase` | `m_RootFolder` |
| Parameter, local | `camelCase` | `rootFolder`, `devicePath` |
| Constant, enumerator | `PascalCase` | `MaxRetries`, `State::Connected` |
| Namespace | `C7`, `C7::<Area>` | `C7::Network` |

**The QML exception.** Every name QML sees is `camelCase`: `Q_PROPERTY` names,
their `NOTIFY` signals, `Q_INVOKABLE` methods and public slots. Enum values
registered with `Q_ENUM` stay `PascalCase`, because QML requires it. QML rejects a property name
that starts with an upper-case letter and builds `onXChanged` from the signal
name. Keep C++-only methods on the same class `PascalCase`.

```cpp
class NetworkBackend : public QObject
{
	Q_OBJECT
	Q_PROPERTY(bool wifiEnabled READ wifiEnabled NOTIFY wifiEnabledChanged)

public:
	bool wifiEnabled() const;
	Q_INVOKABLE virtual void setWifiEnabled(bool enabled) = 0;

signals:
	void wifiEnabledChanged();

protected:
	void ApplyDeviceState(const DeviceState& state); // C++ only, so PascalCase

private:
	bool m_WifiEnabled = false;
};
```

## 2. Write it

- Open every header with `#pragma once`. No include guards.
- Group includes: project headers rooted at `plugin/src` first, then Qt, then std, one blank line between groups.
- Indent namespace bodies. Do not write a `// namespace` closing comment.
- Use `static_cast` and `reinterpret_cast`. Never a C-style cast.
- Take an immutable string parameter as `QStringView` or `QAnyStringView`, or `std::string_view` in code without Qt strings.
- Build a `constexpr` array with `std::to_array`.
- Braces on every `if`, `for` and `while` body that spans more than one line. A one-statement body may drop them, on its own line.
- Mark a getter that returns a value someone must use `[[nodiscard]]`.

**Inject dependencies. Never write a singleton.** No `GetInstance()`, no
function-local `static` instance, no mutable global. A test must be able to
build the class around a fake from `plugin/lib/testing/`, and a singleton
makes that impossible. Construct each manager once at plugin start-up, own it
there, and pass it by reference to whatever uses it. A contract is the one
exception: it keeps `QML_SINGLETON` and `create()` from `docs/architecture.md`,
and `create()` builds the backend with its dependencies passed in.

```cpp
class Settings final
{
public:
	explicit Settings(FileStore& store);

	Settings(const Settings&) = delete;
	Settings& operator=(const Settings&) = delete;

	[[nodiscard]] QString Theme() const;

private:
	FileStore& m_Store;
};
```

A test passes a fake `FileStore`; the plugin passes the real one.

## 3. Format and prove it

Format every C++ file you touched with the skill's config, then check it:

```bash
clang-format -i --style=file:.claude/skills/c7shell-cpp-style/clang-format <files>
clang-format --dry-run --Werror --style=file:.claude/skills/c7shell-cpp-style/clang-format <files>
```

Paste the second command's output in your reply; it must be empty. If
`plugin/.clang-format` exists, use `--style=file` instead, which reads it.

Then list each name you added in one line, `<name> → <rule from the table>`, so
a reviewer can check the naming without reading the diff.
