#pragma once

#include <QtCore/QHash>
#include <QtCore/QPointer>
#include <QtCore/QVariantList>
#include <QtDBus/QDBusConnection>

namespace c7::testing {

// A D-Bus service a test writes in C++: it owns `name` on `bus` (usually a
// PrivateBus connection) and exports test-defined QObjects.
//
// An exported object carries its interfaces as Q_CLASSINFO("D-Bus Interface",
// ...): its own, and one per QDBusAbstractAdaptor child, which is how a test
// puts several interfaces on one path (NetworkManager's Device and
// Device.Wireless). Slots answer method calls, signals go out as D-Bus
// signals, and properties answer org.freedesktop.DBus.Properties.
//
// Qt does not announce a property change on its own; setProperty() changes the
// property and emits PropertiesChanged, as a real service would.
//
// A FakeService that does not own its name does nothing and says so: a test
// talking to the name would otherwise reach whoever does own it.
class FakeService {
public:
    FakeService(QDBusConnection bus, const QString &name);
    ~FakeService();

    FakeService(const FakeService &) = delete;
    FakeService &operator=(const FakeService &) = delete;

    // The name was free on the bus and is now ours.
    bool ownsName() const { return m_ownsName; }

    // Export `object` at `path`. The test keeps ownership. Refuses an object
    // with no interface (Qt would export it under a made-up name no client
    // asks for) and a path already exported.
    bool exportObject(const QString &path, QObject *object);

    // Set `property` of `interface` on the object at `path` and emit
    // PropertiesChanged for it. Refuses a path, interface or property the
    // object does not have.
    bool setProperty(const QString &path, const QString &interface, const QString &property,
                     const QVariant &value);

    // Emit `signal` of `interface` from `path` with `args`, without the object
    // declaring it.
    bool emitSignal(const QString &path, const QString &interface, const QString &signal,
                    const QVariantList &args);

private:
    // The object at `path`, or its adaptor child, that implements `interface`.
    QObject *implementer(const QString &path, const QString &interface) const;

    QDBusConnection m_bus;
    QString m_name;
    bool m_ownsName = false;
    QHash<QString, QPointer<QObject>> m_objects;
};

} // namespace c7::testing
