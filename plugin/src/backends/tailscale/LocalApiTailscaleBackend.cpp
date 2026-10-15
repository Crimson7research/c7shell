#include "backends/tailscale/LocalApiTailscaleBackend.h"

#include "tailscale/StatusParser.h"

#include <QtCore/QHash>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QVarLengthArray>

#include <algorithm>
#include <iterator>
#include <optional>
#include <utility>

using c7::tailscale::LocalApiClient;
using c7::tailscale::Peer;
using c7::tailscale::Status;
using c7::tailscale::StatusParser;

namespace {

const QString kStatusPath = QStringLiteral("/localapi/v0/status");
const QString kPrefsPath = QStringLiteral("/localapi/v0/prefs");
const QString kSuggestPath = QStringLiteral("/localapi/v0/suggest-exit-node");

// Where tailscaled puts its local API socket on Linux. TS_SOCKET overrides it,
// which is the same variable the `tailscale` CLI reads, so a machine running
// tailscaled somewhere else needs no change here.
QString defaultSocketPath()
{
    return qEnvironmentVariable("TS_SOCKET",
                                QStringLiteral("/var/run/tailscale/tailscaled.sock"));
}

// tailscaled's BackendState, which is a string on the wire. Anything it does
// not name -- including the empty string a status without the field leaves --
// is NoState: a value this build does not know is not a value to guess at.
TailscaleBackend::State stateOf(const QString &backendState)
{
    using State = TailscaleBackend::State;
    static const QHash<QString, State> byName = {
        {QStringLiteral("NeedsMachineAuth"), State::NeedsMachineAuth},
        {QStringLiteral("NeedsLogin"), State::NeedsLogin},
        {QStringLiteral("Stopped"), State::Stopped},
        {QStringLiteral("Starting"), State::Starting},
        {QStringLiteral("Running"), State::Running},
    };
    return byName.value(backendState, State::NoState);
}

} // namespace

LocalApiTailscaleBackend::LocalApiTailscaleBackend(QObject *parent)
    : LocalApiTailscaleBackend(defaultSocketPath(), kRetryBaseMs, parent)
{
}

LocalApiTailscaleBackend::LocalApiTailscaleBackend(QString socketPath, int retryBaseMs,
                                                   QObject *parent)
    : TailscaleBackend(parent), m_client(std::move(socketPath), this), m_retryBaseMs(retryBaseMs)
{
    connect(&m_client, &LocalApiClient::replied, this, &LocalApiTailscaleBackend::onReplied);
    connect(&m_client, &LocalApiClient::failed, this, &LocalApiTailscaleBackend::onFailed);
    // The notification's body is deliberately not read: it says that something
    // changed, not what, and /status is the authority on what it now is.
    connect(&m_client, &LocalApiClient::event, this,
            [this](const QByteArray &) { onEvent(); });
    // A failing watch reports failed and then watchEnded, in that order, so
    // both arrive for one lost connection; scheduleRetry() is what makes that
    // one reconnect rather than two.
    connect(&m_client, &LocalApiClient::watchEnded, this,
            &LocalApiTailscaleBackend::lostTailscaled);

    m_retry.setSingleShot(true);
    connect(&m_retry, &QTimer::timeout, this, &LocalApiTailscaleBackend::open);
    open();
}

const QStringList &LocalApiTailscaleBackend::suppressedHealth()
{
    static const QStringList suppressed = {
        // `tailscale status` phrases it as a sentence; matching the clause
        // rather than the whole line survives tailscaled rewording around it.
        QStringLiteral("advertising routes but --accept-routes is false"),
    };
    return suppressed;
}

QStringList LocalApiTailscaleBackend::reportableHealth(const QStringList &health)
{
    const QStringList &suppressed = suppressedHealth();
    QStringList reportable;
    for (const QString &message : health) {
        const bool silent = std::any_of(suppressed.cbegin(), suppressed.cend(),
                                        [&message](const QString &fragment) {
                                            return message.contains(fragment);
                                        });
        if (!silent)
            reportable.append(message);
    }
    return reportable;
}

void LocalApiTailscaleBackend::open()
{
    // Everything in flight goes first: a reconnect must not leave an earlier
    // attempt's sockets to report endings that are no longer about the
    // connection this object has. stop() is silent by contract, so dropping
    // the old watch here cannot trigger the very reconnect it is part of.
    m_client.stop();
    m_refreshInFlight = false;
    m_refreshStale = false;
    m_openingReads = 0;
    m_attemptFailed = false;
    m_established = false;
    // The watch goes out before the reads, for two reasons. A change between
    // reading the state and subscribing to changes would otherwise be missed
    // entirely. And a watch that cannot start reports failed and watchEnded
    // ahead of the reads it was queued before, so this attempt is already
    // marked failed when they land -- which is what stops a local API that
    // serves /status but refuses the stream from resetting the backoff on
    // every pass.
    m_client.watch();
    refresh();
    // Read for the same reason the status is: all three answer 200
    // unprivileged on a working tailscaled, so one of them refusing means this
    // socket is not a local API this backend can publish from. /prefs carries
    // no property of its own today -- every field in it is either already in
    // the status or belongs to the writes v1 does not do.
    m_client.get(kPrefsPath);
}

void LocalApiTailscaleBackend::refresh()
{
    m_refreshInFlight = true;
    m_refreshStale = false;
    m_client.get(kStatusPath);
    // Re-read alongside the status, not only on connect: the suggestion names
    // a row of exitNodes, so a published id outlives the row it points at
    // whenever the set of exit nodes changes under it.
    m_client.get(kSuggestPath);
}

void LocalApiTailscaleBackend::onEvent()
{
    if (m_refreshInFlight) {
        // The reply on its way was asked for before this change, so it cannot
        // be the answer to it.
        m_refreshStale = true;
        return;
    }
    refresh();
}

void LocalApiTailscaleBackend::noteEstablished()
{
    if (m_established || m_attemptFailed || m_openingReads != EveryRead)
        return;
    m_established = true;
    m_attempts = 0;
}

void LocalApiTailscaleBackend::onReplied(const QString &path, const QByteArray &body)
{
    if (path == kSuggestPath) {
        applySuggestion(body);
        m_openingReads |= SuggestRead;
        noteEstablished();
        return;
    }
    if (path == kPrefsPath) {
        // Nothing is published from the body. A 2xx is the whole point: it is
        // what says this socket is a local API that answers unprivileged, and
        // LocalApiClient has already turned anything else into failed(). A
        // further check on the shape of a 2xx body would only buy a NoState
        // flap for a reply no tailscaled sends.
        m_openingReads |= PrefsRead;
        noteEstablished();
        return;
    }
    if (path != kStatusPath)
        return;

    m_refreshInFlight = false;
    const std::optional<Status> status = StatusParser::parse(body);
    // `{}` parses, so a reply is only a status if it carries a BackendState:
    // without one there is nothing to publish but the parser's defaults, which
    // would read as a tailnet with no peers rather than as no answer.
    if (!status || status->backendState.isEmpty()) {
        lostTailscaled();
        return;
    }
    applyStatus(*status);
    // Deliberately after applyStatus and deliberately not a reset of its own:
    // a good status is one of three reads this attempt needs, never the whole
    // of it.
    m_openingReads |= StatusRead;
    noteEstablished();
    if (m_refreshStale)
        refresh();
}

void LocalApiTailscaleBackend::onFailed(const QString &path, const QString &)
{
    if (path == kStatusPath)
        m_refreshInFlight = false;
    lostTailscaled();
}

void LocalApiTailscaleBackend::lostTailscaled()
{
    // Whatever else this attempt managed, it did not wholly work, so it must
    // not clear the backoff.
    m_attemptFailed = true;
    // State alone, because state is the only thing that is certainly wrong
    // when tailscaled stops answering. The rest of the snapshot is the last
    // thing it said, and blanking it would set exitNodeActive to false -- the
    // fail-closed flag going quiet exactly when the daemon behind it died.
    if (m_state != State::NoState) {
        m_state = State::NoState;
        emit stateChanged();
    }
    scheduleRetry();
}

void LocalApiTailscaleBackend::scheduleRetry()
{
    // Idempotent on purpose. One lost connection arrives here several times: a
    // failing watch reports failed and then watchEnded, and the three opening
    // gets fail together when nothing is listening. Counting each as an
    // attempt would run the backoff to its cap on the first failure.
    if (m_retry.isActive())
        return;
    const int delay = retryDelayMs(m_attempts, m_retryBaseMs);
    ++m_attempts;
    m_retry.start(delay);
    emit retryScheduled(delay);
}

int LocalApiTailscaleBackend::retryDelayMs(int attempt, int baseMs)
{
    // The curve of Services/AuthService.qml:202 -- doubling from the base, six
    // doublings, then flat -- so a tailscaled that will not start is retried
    // forever without being spun on.
    return std::min(kRetryCapMs, baseMs * (1 << std::clamp(attempt, 0, 6)));
}

void LocalApiTailscaleBackend::applyStatus(const Status &status)
{
    // Every member moves before any signal does, and the signals go out
    // together at the end. The contract derives exitNodeBlocked from two of
    // these and announces it off either one, synchronously: emitting as each
    // member lands would hand QML a flag computed from a half-applied status.
    using Signal = void (TailscaleBackend::*)();
    QVarLengthArray<Signal, 12> moved;
    auto store = [&moved](auto &slot, const auto &value, Signal changed) {
        if (slot == value)
            return;
        slot = value;
        moved.append(changed);
    };

    store(m_state, stateOf(status.backendState), &TailscaleBackend::stateChanged);
    store(m_selfName, status.selfName, &TailscaleBackend::selfNameChanged);
    store(m_selfIp4, status.selfIp4, &TailscaleBackend::selfIp4Changed);
    store(m_selfIp6, status.selfIp6, &TailscaleBackend::selfIp6Changed);
    store(m_selfDnsName, status.selfDnsName, &TailscaleBackend::selfDnsNameChanged);
    store(m_tailnet, status.tailnet, &TailscaleBackend::tailnetChanged);
    store(m_keyExpiry, status.keyExpiry, &TailscaleBackend::keyExpiryChanged);

    const bool active = status.exitNode.has_value();
    store(m_exitNodeActive, active, &TailscaleBackend::exitNodeActiveChanged);
    // ExitNodeStatus.Online, never the peer's: the selected peer reads
    // Online: true while the exit node itself is unreachable. Without a
    // selection it is false, which is what the contract calls meaningless.
    store(m_exitNodeOnline, active && status.exitNode->online,
          &TailscaleBackend::exitNodeOnlineChanged);
    store(m_exitNodeName, active ? status.exitNode->name : QString(),
          &TailscaleBackend::exitNodeNameChanged);

    store(m_issues, reportableHealth(status.health), &TailscaleBackend::issuesChanged);

    // The models diff themselves and emit their own row signals, so they are
    // filled here with the members rather than after them: a view reacting to
    // stateChanged must not find yesterday's rows underneath it.
    m_peers.setPeers(status.peers);
    QList<Peer> exitNodes;
    std::copy_if(status.peers.cbegin(), status.peers.cend(), std::back_inserter(exitNodes),
                 [](const Peer &peer) { return peer.exitNodeOption; });
    m_exitNodes.setPeers(exitNodes);

    for (Signal changed : moved)
        emit(this->*changed)();
}

void LocalApiTailscaleBackend::applySuggestion(const QByteArray &body)
{
    // ID, not Name: it is the string id the status, exit-node and suggestion
    // endpoints all share, and the one a row in exitNodes can be found by.
    const QString id = QJsonDocument::fromJson(body)
                               .object()
                               .value(QLatin1String("ID"))
                               .toString();
    if (m_recommendedExitNodeId == id)
        return;
    m_recommendedExitNodeId = id;
    emit recommendedExitNodeIdChanged();
}

// Defined here rather than in the contract: choosing the backend is the one
// thing that changes when a second one arrives, and it should change in a
// backend file, not in the contract every backend implements.
//
// No parent: the QML engine takes ownership of what create() returns.
TailscaleBackend *TailscaleBackend::create(QQmlEngine *, QJSEngine *)
{
    return new LocalApiTailscaleBackend;
}
