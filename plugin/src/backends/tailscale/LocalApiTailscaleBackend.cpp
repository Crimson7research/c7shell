#include "backends/tailscale/LocalApiTailscaleBackend.h"

LocalApiTailscaleBackend::LocalApiTailscaleBackend(QObject *parent) : TailscaleBackend(parent) {}

// Defined here rather than in the contract: choosing the backend is the one
// thing that changes when a second one arrives, and it should change in a
// backend file, not in the contract every backend implements.
//
// No parent: the QML engine takes ownership of what create() returns.
TailscaleBackend *TailscaleBackend::create(QQmlEngine *, QJSEngine *)
{
    return new LocalApiTailscaleBackend;
}
