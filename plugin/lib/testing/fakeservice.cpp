#include "testing/fakeservice.h"

#include <QtCore/QMetaProperty>
#include <QtDBus/QDBusAbstractAdaptor>
#include <QtDBus/QDBusConnectionInterface>
#include <QtDBus/QDBusMessage>

namespace c7::testing {

namespace {

// The interface `o` declares itself; empty when it declares none.
QString interfaceOf(const QObject *o)
{
    const QMetaObject *meta = o->metaObject();
    const int info = meta->indexOfClassInfo("D-Bus Interface");
    return info < 0 ? QString() : QString::fromLatin1(meta->classInfo(info).value());
}

QList<QDBusAbstractAdaptor *> adaptorsOf(QObject *o)
{
    return o->findChildren<QDBusAbstractAdaptor *>(Qt::FindDirectChildrenOnly);
}

} // namespace

FakeService::FakeService(QDBusConnection bus, const QString &name)
    : m_bus(std::move(bus)), m_name(name)
{
    // registerService() reports success when the name is already queued for us,
    // so ask the bus for the outcome directly: we are the primary owner or not.
    QDBusConnectionInterface *iface = m_bus.interface();
    if (!iface)
        return;
    const QDBusReply<QDBusConnectionInterface::RegisterServiceReply> reply =
        iface->registerService(name, QDBusConnectionInterface::DontQueueService,
                               QDBusConnectionInterface::DontAllowReplacement);
    m_ownsName = reply.isValid() && reply.value() == QDBusConnectionInterface::ServiceRegistered;
}

FakeService::~FakeService()
{
    for (auto it = m_objects.cbegin(); it != m_objects.cend(); ++it)
        m_bus.unregisterObject(it.key());
    if (m_ownsName)
        m_bus.unregisterService(m_name);
}

bool FakeService::exportObject(const QString &path, QObject *object)
{
    if (!m_ownsName || !object || m_objects.contains(path))
        return false;
    if (interfaceOf(object).isEmpty() && adaptorsOf(object).isEmpty())
        return false;
    if (!m_bus.registerObject(path, object,
                              QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals
                                  | QDBusConnection::ExportAllProperties
                                  | QDBusConnection::ExportAdaptors))
        return false;
    m_objects.insert(path, object);
    return true;
}

QObject *FakeService::implementer(const QString &path, const QString &interface) const
{
    QObject *object = m_objects.value(path);
    if (!m_ownsName || !object)
        return nullptr;
    if (interfaceOf(object) == interface)
        return object;
    for (QDBusAbstractAdaptor *a : adaptorsOf(object)) {
        if (interfaceOf(a) == interface)
            return a;
    }
    return nullptr;
}

bool FakeService::setProperty(const QString &path, const QString &interface,
                              const QString &property, const QVariant &value)
{
    QObject *target = implementer(path, interface);
    const QByteArray name = property.toUtf8();
    if (!target || target->metaObject()->indexOfProperty(name.constData()) < 0
        || !target->setProperty(name.constData(), value))
        return false;

    QDBusMessage changed = QDBusMessage::createSignal(
        path, QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("PropertiesChanged"));
    changed << interface << QVariantMap{{property, target->property(name.constData())}}
            << QStringList();
    return m_bus.send(changed);
}

bool FakeService::emitSignal(const QString &path, const QString &interface, const QString &signal,
                             const QVariantList &args)
{
    if (!implementer(path, interface))
        return false;
    QDBusMessage message = QDBusMessage::createSignal(path, interface, signal);
    message.setArguments(args);
    return m_bus.send(message);
}

} // namespace c7::testing
