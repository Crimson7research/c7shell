#include "testing/fakeservice.h"
#include "testing/privatebus.h"
#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtDBus/QDBusAbstractAdaptor>
#include <QtDBus/QDBusConnectionInterface>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusPendingCall>
#include <QtDBus/QDBusPendingReply>
#include <QtDBus/QDBusVariant>
#include <QtTest/QTest>

using c7::testing::FakeService;
using c7::testing::PrivateBus;
using c7::testing::waitUntil;

namespace {

const QString kName = QStringLiteral("org.c7.Test");
const QString kPath = QStringLiteral("/thing");
const QString kIface = QStringLiteral("org.c7.Test.Thing");
const QString kWireless = QStringLiteral("org.c7.Test.Thing.Wireless");
const QString kProps = QStringLiteral("org.freedesktop.DBus.Properties");

// What a test defines: its interface name is its D-Bus Interface class info,
// its methods are its slots, its signals its signals, and its properties its
// properties.
class Thing : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.c7.Test.Thing")
    Q_PROPERTY(QString state READ state WRITE setState)

public:
    using QObject::QObject;
    QString state() const { return m_state; }
    void setState(const QString &s) { m_state = s; }

public slots:
    QString Echo(const QString &text) { return text; }

signals:
    void Ping(const QString &what);

private:
    QString m_state = QStringLiteral("idle");
};

// A second interface on the same path, the way NetworkManager puts
// Device.Wireless beside Device: an adaptor child of the exported object.
class Wireless : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.c7.Test.Thing.Wireless")
    Q_PROPERTY(int strength READ strength WRITE setStrength)

public:
    explicit Wireless(QObject *parent) : QDBusAbstractAdaptor(parent) {}
    int strength() const { return m_strength; }
    void setStrength(int s) { m_strength = s; }

private:
    int m_strength = 40;
};

// The client side: records every signal it is connected to.
class Listener : public QObject {
    Q_OBJECT

public:
    QStringList pings;
    QString changedInterface;
    QVariantMap changed;
    QStringList invalidated{QStringLiteral("not-yet")};

public slots:
    void onPing(const QString &what) { pings << what; }
    void onPropertiesChanged(const QString &iface, const QVariantMap &props, const QStringList &inv)
    {
        changedInterface = iface;
        changed = props;
        invalidated = inv;
    }
};

QDBusPendingCall callOn(QDBusConnection c, const QString &path, const QString &iface,
                        const QString &method, const QVariantList &args)
{
    QDBusMessage m = QDBusMessage::createMethodCall(kName, path, iface, method);
    m.setArguments(args);
    return c.asyncCall(m);
}

} // namespace

class TestFakeService : public QObject {
    Q_OBJECT

private slots:
    void init()
    {
        bus = std::make_unique<PrivateBus>();
        QVERIFY2(bus->isRunning(), qPrintable(bus->error()));
        thing = std::make_unique<Thing>();
        new Wireless(thing.get());
        service = std::make_unique<FakeService>(bus->connect(), kName);
        QVERIFY(service->ownsName());
        QVERIFY(service->exportObject(kPath, thing.get()));
        client = bus->connect();
    }

    void cleanup()
    {
        service.reset();
        thing.reset();
        bus.reset();
    }

    void ownsItsName() { QVERIFY(client.interface()->isServiceRegistered(kName)); }

    void aSecondOwnerIsRefusedAndDoesNothing()
    {
        FakeService second(bus->connect(), kName);
        QVERIFY(!second.ownsName());
        Thing other;
        QVERIFY(!second.exportObject(QStringLiteral("/other"), &other));
        QVERIFY(!second.emitSignal(kPath, kIface, QStringLiteral("Ping"), {QStringLiteral("x")}));
        QVERIFY(!second.setProperty(kPath, kIface, QStringLiteral("state"), QStringLiteral("x")));
    }

    void answersMethods()
    {
        QDBusPendingReply<QString> reply =
            callOn(client, kPath, kIface, QStringLiteral("Echo"), {QStringLiteral("hi")});
        QVERIFY(waitUntil([&] { return reply.isFinished(); }));
        QVERIFY2(reply.isValid(), qPrintable(reply.error().message()));
        QCOMPARE(reply.value(), QStringLiteral("hi"));
    }

    void servesPropertiesOfEveryInterfaceOnThePath()
    {
        QDBusPendingReply<QDBusVariant> state =
            callOn(client, kPath, kProps, QStringLiteral("Get"), {kIface, QStringLiteral("state")});
        QDBusPendingReply<QDBusVariant> strength = callOn(
            client, kPath, kProps, QStringLiteral("Get"), {kWireless, QStringLiteral("strength")});
        QVERIFY(waitUntil([&] { return state.isFinished() && strength.isFinished(); }));
        QVERIFY2(state.isValid(), qPrintable(state.error().message()));
        QVERIFY2(strength.isValid(), qPrintable(strength.error().message()));
        QCOMPARE(state.value().variant().toString(), QStringLiteral("idle"));
        QCOMPARE(strength.value().variant().toInt(), 40);
    }

    void emitsTheObjectsSignals()
    {
        Listener listener;
        QVERIFY(client.connect(kName, kPath, kIface, QStringLiteral("Ping"), &listener,
                               SLOT(onPing(QString))));
        emit thing->Ping(QStringLiteral("from-qt"));
        QVERIFY(waitUntil([&] { return !listener.pings.isEmpty(); }));
        QCOMPARE(listener.pings, QStringList{QStringLiteral("from-qt")});
    }

    void emitsAdHocSignals()
    {
        Listener listener;
        QVERIFY(client.connect(kName, kPath, kIface, QStringLiteral("Ping"), &listener,
                               SLOT(onPing(QString))));
        QVERIFY(service->emitSignal(kPath, kIface, QStringLiteral("Ping"), {QStringLiteral("ad-hoc")}));
        QVERIFY(waitUntil([&] { return !listener.pings.isEmpty(); }));
        QCOMPARE(listener.pings, QStringList{QStringLiteral("ad-hoc")});
    }

    void setPropertyChangesItAndNotifies_data()
    {
        QTest::addColumn<QString>("iface");
        QTest::addColumn<QString>("property");
        QTest::addColumn<QVariant>("value");
        QTest::newRow("the object's own") << kIface << QStringLiteral("state") << QVariant(QStringLiteral("busy"));
        QTest::newRow("an adaptor's") << kWireless << QStringLiteral("strength") << QVariant(77);
    }

    void setPropertyChangesItAndNotifies()
    {
        QFETCH(QString, iface);
        QFETCH(QString, property);
        QFETCH(QVariant, value);
        Listener listener;
        QVERIFY(client.connect(kName, kPath, kProps, QStringLiteral("PropertiesChanged"), &listener,
                               SLOT(onPropertiesChanged(QString, QVariantMap, QStringList))));
        QVERIFY(service->setProperty(kPath, iface, property, value));
        QVERIFY(waitUntil([&] { return listener.changed.contains(property); }));
        QCOMPARE(listener.changedInterface, iface);
        QCOMPARE(listener.changed, (QVariantMap{{property, value}}));
        QCOMPARE(listener.invalidated, QStringList{});

        // And a Get afterwards reads the new value, as a real service's would.
        QDBusPendingReply<QDBusVariant> now =
            callOn(client, kPath, kProps, QStringLiteral("Get"), {iface, property});
        QVERIFY(waitUntil([&] { return now.isFinished(); }));
        QCOMPARE(now.value().variant(), value);
    }

    void refusesWhatItDidNotExport()
    {
        QVERIFY(!service->setProperty(QStringLiteral("/nope"), kIface, QStringLiteral("state"), 1));
        QVERIFY(!service->emitSignal(QStringLiteral("/nope"), kIface, QStringLiteral("Ping"), {}));
        QVERIFY(!service->setProperty(kPath, QStringLiteral("org.c7.Nope"), QStringLiteral("state"), 1));
        QVERIFY(!service->emitSignal(kPath, QStringLiteral("org.c7.Nope"), QStringLiteral("Ping"), {}));
        QVERIFY(!service->setProperty(kPath, kIface, QStringLiteral("noSuchProperty"), 1));
    }

    void refusesAnObjectWithoutAnInterface()
    {
        QObject bare;
        QVERIFY(!service->exportObject(QStringLiteral("/bare"), &bare));
    }

    void refusesAPathTwice()
    {
        Thing other;
        QVERIFY(!service->exportObject(kPath, &other));
    }

    void refusesAnObjectThatIsGone()
    {
        auto gone = std::make_unique<Thing>();
        QVERIFY(service->exportObject(QStringLiteral("/gone"), gone.get()));
        gone.reset();
        QVERIFY(!service->emitSignal(QStringLiteral("/gone"), kIface, QStringLiteral("Ping"), {}));
        QVERIFY(!service->setProperty(QStringLiteral("/gone"), kIface, QStringLiteral("state"), 1));
    }

    void releasesItsNameAndObjectsWhenDestroyed()
    {
        // The service going away, as NetworkManager or BlueZ do on a restart.
        service.reset();
        QVERIFY(!client.interface()->isServiceRegistered(kName));

        FakeService again(bus->connect(), kName);
        QVERIFY(again.ownsName());
        QDBusPendingReply<QString> reply =
            callOn(client, kPath, kIface, QStringLiteral("Echo"), {QStringLiteral("hi")});
        QVERIFY(waitUntil([&] { return reply.isFinished(); }));
        QVERIFY(reply.isError());
    }

private:
    std::unique_ptr<PrivateBus> bus;
    std::unique_ptr<Thing> thing;
    std::unique_ptr<FakeService> service;
    QDBusConnection client{QString()};
};

C7_TEST_MAIN(TestFakeService)
#include "tst_fakeservice.moc"
