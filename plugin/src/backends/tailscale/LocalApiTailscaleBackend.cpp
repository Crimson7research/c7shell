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

// Fields of a notification this module never reads. Anything else -- State,
// Prefs, NetMap, ErrMessage, a login URL -- is grounds to re-read the status.
const QStringList &ignoredNotifyFields()
{
    static const QStringList ignored = {
        QStringLiteral("Version"),   // the daemon's version, on every message
        QStringLiteral("SessionID"), // this watcher's own id, echoed at subscribe
        // Byte counters and live-peer stats, refreshed every two seconds for
        // as long as anything on the machine watches with the engine bit.
        // Nothing here displays them.
        QStringLiteral("Engine"),
    };
    return ignored;
}

} // namespace

LocalApiTailscaleBackend::LocalApiTailscaleBackend(QObject *parent)
    : LocalApiTailscaleBackend(defaultSocketPath(), kRetryBaseMs, kRetryCapMs,
                               LocalApiClient::kTimeoutMs, parent)
{
}

LocalApiTailscaleBackend::LocalApiTailscaleBackend(QString socketPath, int retryBaseMs,
                                                   int settleMs, int requestTimeoutMs,
                                                   QObject *parent)
    : TailscaleBackend(parent), m_client(std::move(socketPath), requestTimeoutMs, this),
      m_retryBaseMs(retryBaseMs), m_settleMs(settleMs)
{
    connect(&m_client, &LocalApiClient::replied, this, &LocalApiTailscaleBackend::onReplied);
    connect(&m_client, &LocalApiClient::failed, this, &LocalApiTailscaleBackend::onFailed);
    connect(&m_client, &LocalApiClient::event, this, &LocalApiTailscaleBackend::onEvent);
    // The stream is up: the fourth and last thing a whole connection needs.
    connect(&m_client, &LocalApiClient::watchStarted, this, [this] {
        m_openingReads |= WatchStarted;
        noteEstablished();
    });
    // A failing watch reports failed and then watchEnded, in that order, so
    // both arrive for one lost connection; scheduleRetry() is what makes that
    // one reconnect rather than two.
    connect(&m_client, &LocalApiClient::watchEnded, this,
            &LocalApiTailscaleBackend::lostTailscaled);

    m_retry.setSingleShot(true);
    connect(&m_retry, &QTimer::timeout, this, &LocalApiTailscaleBackend::open);
    m_settle.setSingleShot(true);
    // The connection outlived the longest wait this would have accepted before
    // retrying it, so it is one that works, and the next loss starts the curve
    // over rather than resuming it.
    connect(&m_settle, &QTimer::timeout, this, [this] { m_attempts = 0; });
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
    m_settle.stop();
    m_openPass = 0;
    m_refreshStale = false;
    // A reply from the attempt just dropped is not half of this attempt's
    // snapshot: whichever half arrived goes with the attempt it belonged to.
    m_pendingStatus.reset();
    m_pendingExitNodeId.reset();
    m_openingReads = 0;
    m_attemptFailed = false;
    m_established = false;
    // The watch goes out before the reads so that a change between reading the
    // state and subscribing to changes is not missed entirely. Nothing about
    // the backoff rests on that ordering: the stream is one of the things a
    // whole connection is counted from, so a watch that never starts holds
    // WatchStarted back however the replies interleave.
    m_client.watch();
    refresh();
}

void LocalApiTailscaleBackend::refresh()
{
    // A pass of asking, numbered. Every get of this pass carries the number
    // back on its reply, which is how a straggler from a pass this object has
    // abandoned is told apart from an answer to the one it is waiting on.
    m_openPass = ++m_passes;
    m_refreshStale = false;
    m_client.get(kStatusPath, m_openPass);
    // The other half of the snapshot, and read on every pass rather than only
    // on connect: ExitNodeID is what says an exit node is SELECTED, and a
    // selection made or cleared since the last read would otherwise be
    // published from a prefs body read minutes ago -- either a block that
    // never clears or a selection that never shows. It is also the second
    // health probe: it answers 200 unprivileged on a working tailscaled, so a
    // refusal means this socket is not a local API this backend can publish
    // from.
    m_client.get(kPrefsPath, m_openPass);
    // Re-read alongside the status, not only on connect: the suggestion names
    // a row of exitNodes, so a published id outlives the row it points at
    // whenever the set of exit nodes changes under it.
    m_client.get(kSuggestPath, m_openPass);
}

bool LocalApiTailscaleBackend::worthRefreshing(const QByteArray &notification)
{
    const QJsonObject fields = QJsonDocument::fromJson(notification).object();
    // Not an object, or one with nothing in it: no grounds to skip it.
    if (fields.isEmpty())
        return true;
    for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) {
        if (!it.value().isNull() && !ignoredNotifyFields().contains(it.key()))
            return true;
    }
    return false;
}

void LocalApiTailscaleBackend::onEvent(const QByteArray &notification)
{
    // The body is read for one decision only -- whether to ask at all. What
    // changed still comes from the status reply, which stays the authority:
    // nothing here is reconstructed from a notification.
    if (!worthRefreshing(notification))
        return;
    if (passOpen()) {
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
    // Not a reset: only holding for m_settleMs clears the curve. A connection
    // that is whole and then gone is not one that worked.
    m_settle.start(m_settleMs);
}

void LocalApiTailscaleBackend::onReplied(const QString &path, const QByteArray &body,
                                         quint64 token)
{
    if (path == kSuggestPath) {
        // Not one of the opening reads and not a health probe: see the note on
        // OpeningRead. The suggestion is published when it arrives and nothing
        // about the connection rests on it.
        //
        // DELIBERATELY NOT pass-checked, unlike the two below. A pass closes
        // the moment its two halves pair, and the suggestion is a third socket
        // that routinely answers after that, so turning away a reply whose
        // pass has closed would throw away most suggestions. It is not part of
        // the snapshot, so it has nothing to be out of step with.
        applySuggestion(body);
        return;
    }

    // THE TWO SNAPSHOT READS ARE PASS-SCOPED: a reply is half of a snapshot
    // only for the pass that asked for it. A pass opens in refresh() -- which
    // open() calls, so the opening reads are a pass like any other -- and
    // closes when both halves have been paired, or when lostTailscaled()
    // abandons it. A reply carrying any other number belongs to a pass that is
    // over: it describes a moment this object has already given up on, and
    // pairing it with the other half of a LATER pass publishes an exit node
    // selected at one moment against a status read at another, which is the
    // fail-closed path reading from two moments at once.
    //
    // The NUMBER is what makes that decidable, and a boolean is not enough.
    // "Is a pass open?" answers yes to a straggler too, because the
    // notification that starts the next pass routinely beats a slow /prefs
    // from the last one -- which is how this was got wrong twice before.
    //
    // This is the rule for anything added to the snapshot, and the question to
    // ask of a new endpoint is which side of it the endpoint falls on: a read
    // the exit-node reading is assembled from is pass-scoped and belongs
    // below; one that stands alone, as /suggest-exit-node does above, is not.
    //
    // Only the gets. The watch is not pass-scoped and never passes through
    // here: event() and watchEnded() have slots of their own, and a
    // notification arriving between passes is exactly what starts the next
    // one.
    if (token != m_openPass)
        return;

    if (path == kPrefsPath) {
        // ExitNodeID is the only field read: it is what says an exit node is
        // selected at all, which ExitNodeStatus cannot while it is still
        // being resolved. A body that is not an object yields an empty id,
        // which is the same reading as "nothing selected" -- and a /prefs
        // that is not a prefs object is not something tailscaled sends with a
        // 2xx, which LocalApiClient has already filtered anything else out of.
        m_pendingExitNodeId = QJsonDocument::fromJson(body)
                                      .object()
                                      .value(QLatin1String("ExitNodeID"))
                                      .toString();
        m_openingReads |= PrefsRead;
        noteEstablished();
        applySnapshotWhenWhole();
        return;
    }
    if (path != kStatusPath)
        return;

    const std::optional<Status> status = StatusParser::parse(body);
    // `{}` parses, so a reply is only a status if it carries a BackendState:
    // without one there is nothing to publish but the parser's defaults, which
    // would read as a tailnet with no peers rather than as no answer.
    if (!status || status->backendState.isEmpty()) {
        lostTailscaled();
        return;
    }
    m_pendingStatus = *status;
    applySnapshotWhenWhole();
}

void LocalApiTailscaleBackend::applySnapshotWhenWhole()
{
    // Half a pass publishes nothing: the exit-node reading is assembled from
    // both replies, and either alone is the fail-closed flag computed from
    // half of one pass and half of the next.
    if (!m_pendingStatus || !m_pendingExitNodeId)
        return;
    const Status status = *std::exchange(m_pendingStatus, std::nullopt);
    const QString exitNodeId = *std::exchange(m_pendingExitNodeId, std::nullopt);

    m_openPass = 0;
    applyStatus(status, exitNodeId);
    // Deliberately after applyStatus and deliberately not a reset of its own:
    // a good snapshot is one of the things this attempt needs, never the whole
    // of it.
    m_openingReads |= StatusRead;
    noteEstablished();
    // A notification that arrived while this pass was out asked a question
    // this pass's replies were issued before, so it gets a pass of its own.
    if (m_refreshStale)
        refresh();
}

void LocalApiTailscaleBackend::onFailed(const QString &path, const QString &, quint64 token)
{
    // A suggestion that does not arrive is not a tailscaled that is gone. The
    // endpoint is optional -- a tailnet with no exit nodes has nothing to
    // suggest -- and a 404, a 500, a timeout and an empty 200 all read the
    // same way here: no suggestion.
    //
    // A 500 in particular is routine rather than a sign of anything wrong.
    // Measured on a live daemon: before DERP is resolved it answers
    // `{"error":"no preferred DERP, try again later"}`, which is every cold
    // boot and every network change, and is also what a daemon that is up and
    // merely logged out answers indefinitely. Routing any of that to
    // lostTailscaled() published NoState over a perfectly usable NeedsLogin
    // and took the whole slot off the bar.
    if (path == kSuggestPath) {
        applySuggestion({});
        return;
    }
    // A straggler from a pass already given up on says nothing about the
    // connection this object has now: it is the same loss that closed that
    // pass, arriving a second time by another socket. Acting on it would
    // abandon the LIVE pass and publish NoState over a tailscaled that is
    // answering -- the skew this token exists for, in its other direction.
    //
    // The watch carries no token and reports zero, and its failure is always
    // this object's business: a watch that drops is a lost connection whenever
    // it happens.
    if (token != 0 && token != m_openPass)
        return;
    // No bookkeeping of the open pass here: lostTailscaled() closes it for
    // every path, which is what keeps /prefs and the watch from leaving one
    // open behind them.
    lostTailscaled();
}

void LocalApiTailscaleBackend::lostTailscaled()
{
    // Whatever else this attempt managed, it did not wholly work, so it must
    // not clear the backoff -- including through a settle timer armed before
    // the loss and still pending.
    m_attemptFailed = true;
    m_settle.stop();
    // The pass is over, whichever of its reads reported the loss: it is closed
    // here and not in the failing path, so /prefs and the watch end it as
    // surely as /status does. Closing it is half of what keeps a straggler
    // out -- the number it carries no longer matches any open pass -- and
    // dropping the halves already in hand is the other half, because a pass
    // this object has given up on must not leave one of its two readings to
    // be paired with the other half of the next.
    m_openPass = 0;
    m_pendingStatus.reset();
    m_pendingExitNodeId.reset();
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

// The name of the peer with this id, or the id itself when no peer has it --
// the same fallback StatusParser uses for a node that has left the tailnet,
// so the panel names a machine where it can and never goes blank. The DISPLAY
// name, as everywhere else: an alert that says which exit node to clear has
// to name it the way the admin console does.
static QString nameOfPeer(const QList<Peer> &peers, const QString &nodeId)
{
    for (const Peer &peer : peers) {
        if (peer.nodeId == nodeId)
            return peer.displayName;
    }
    return nodeId;
}

void LocalApiTailscaleBackend::applyStatus(const Status &status, const QString &prefsExitNodeId)
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

    // Selected if EITHER half of the snapshot says so. /prefs's ExitNodeID is
    // the selection; /status's ExitNodeStatus is the selection RESOLVED, and
    // it is absent on some builds and null on others for as long as tailscaled
    // has not resolved it. An id with no resolvable status is therefore an
    // exit node that is selected and not known to answer, which is the
    // fail-closed reading -- and it is the reading for exactly the window in
    // which egress is most likely to be dropped on the floor.
    const bool resolved = status.exitNode.has_value();
    const bool active = resolved || !prefsExitNodeId.isEmpty();
    store(m_exitNodeActive, active, &TailscaleBackend::exitNodeActiveChanged);
    // ExitNodeStatus.Online, never the peer's: the selected peer reads
    // Online: true while the exit node itself is unreachable. Unresolved or
    // unselected it is false, which is what the contract calls meaningless --
    // and, with active true, is what makes exitNodeBlocked fail closed.
    store(m_exitNodeOnline, resolved && status.exitNode->online,
          &TailscaleBackend::exitNodeOnlineChanged);
    const QString exitNodeId = resolved ? status.exitNode->id : prefsExitNodeId;
    store(m_exitNodeId, active ? exitNodeId : QString(),
          &TailscaleBackend::exitNodeIdChanged);
    const QString exitNodeName =
            resolved ? status.exitNode->name : nameOfPeer(status.peers, prefsExitNodeId);
    store(m_exitNodeName, active ? exitNodeName : QString(),
          &TailscaleBackend::exitNodeNameChanged);

    store(m_issues, reportableHealth(status.health), &TailscaleBackend::issuesChanged);

    // The models diff themselves and emit their own row signals, so they are
    // filled here with the members rather than after them: a view reacting to
    // stateChanged must not find yesterday's rows underneath it.
    //
    // Only from a reply that actually described the tailnet. A status with no
    // Peer section at all is not a tailnet with no devices, but setPeers()
    // cannot tell the two apart: both empty the model, and the panel then
    // reads "network devices 0" whichever it was. The rows stay as the last
    // status described them instead; an empty Peer OBJECT -- a tailnet that
    // really has no other devices -- is a description, and does clear them.
    if (status.hasPeerSection) {
        m_peers.setPeers(status.peers);
        QList<Peer> exitNodes;
        std::copy_if(status.peers.cbegin(), status.peers.cend(), std::back_inserter(exitNodes),
                     [](const Peer &peer) { return peer.exitNodeOption; });
        m_exitNodes.setPeers(exitNodes);
    }

    for (Signal changed : moved)
        emit(this->*changed)();
}

void LocalApiTailscaleBackend::applySuggestion(const QByteArray &body)
{
    // ID, not Name: it is the string id the status, exit-node and suggestion
    // endpoints all share, and the one a row in exitNodes can be found by.
    //
    // An empty body -- which is what a failed suggestion is handed -- yields
    // an empty id, which is what "no suggestion" is: the recommended heading
    // and its row go, rather than keeping a recommendation nothing stands
    // behind.
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
