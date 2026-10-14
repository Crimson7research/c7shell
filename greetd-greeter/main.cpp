// The c7shell login screen, as a greetd greeter.
//
// greetd runs this inside its own compositor (cage), so the greeter is a
// wayland client: there is no X server, no DRM master to hand over and no VT to
// recycle between greeter and session. That is the whole class of failure that
// made LightDM unusable here.
//
// What the binary provides is the conversation and the three models greetd does
// not supply. Everything visible is the same QML the sddm theme uses.

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSysInfo>
#include <QUrl>

#include "config.h"
#include "greetd.h"
#include "models.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("c7shell-greeter"));

    auto *greetd = new GreetdClient(&app);
    if (!greetd->connectToDaemon())
        return 1;

    auto *users = new UsersModel(&app);
    auto *sessions = new SessionsModel(&app);
    auto *power = new PowerInterface(&app);
    // Same theme.conf the sddm theme reads, so one file configures both.
    auto *theme = new ThemeConfig(QStringLiteral(C7_GREETER_DIR "/theme.conf"), &app);
    auto *lastUser = new LastUserStore(QStringLiteral(C7_STATE_DIR "/last-user"), &app);
    auto *keyboard = new KeyboardState(&app);

    QQmlApplicationEngine engine;
    // Qt.quit() from QML has to reach the application, or the greeter lingers
    // after handing over and greetd waits on it before starting the session.
    QObject::connect(&engine, &QQmlApplicationEngine::quit, &app, &QGuiApplication::quit);
    QQmlContext *ctx = engine.rootContext();
    ctx->setContextProperty(QStringLiteral("greetd"), greetd);
    ctx->setContextProperty(QStringLiteral("userModel"), users);
    ctx->setContextProperty(QStringLiteral("sessionModel"), sessions);
    ctx->setContextProperty(QStringLiteral("power"), power);
    ctx->setContextProperty(QStringLiteral("machineHostName"), QSysInfo::machineHostName());
    ctx->setContextProperty(QStringLiteral("themeConfig"), theme);
    ctx->setContextProperty(QStringLiteral("lastUserStore"), lastUser);
    ctx->setContextProperty(QStringLiteral("keyboardState"), keyboard);

    engine.load(QUrl::fromLocalFile(QStringLiteral(C7_GREETER_DIR "/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical("c7shell-greeter: Main.qml failed to load");
        return 1;
    }
    return app.exec();
}
