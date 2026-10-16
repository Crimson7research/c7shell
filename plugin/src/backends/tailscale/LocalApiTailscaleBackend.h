#pragma once

#include "contracts/TailscaleBackend.h"
#include "tailscale/LocalApiClient.h"
#include "tailscale/PeerModel.h"
#include "tailscale/Types.h"

#include <QtCore/QByteArray>
#include <QtCore/QStringList>
#include <QtCore/QTimer>

#include <optional>

// The TailscaleBackend that reads tailscaled's local API socket: GET /status,
// /prefs and /suggest-exit-node on connect, then the /watch-ipn-bus stream
// that pushes every later change. Nothing here spawns the `tailscale` CLI,
// and nothing here polls: a notification on the bus is what makes it re-read
// /status, and with a quiet bus it issues no requests at all.
//
// A notification says that something changed, never what, so the replies to
// the GETs are the authority and no state is reconstructed from the bus.
//
// A SNAPSHOT IS A /status AND THE /prefs READ BESIDE IT, applied together.
// Neither alone describes the exit node: /status's ExitNodeStatus says
// whether the selected node answers but is absent on some builds and null on
// others while a selection is still being resolved, and /prefs's ExitNodeID
// says whether one is selected at all but never whether it works. Publishing
// one without the other reads "selected, status unresolved" as "nothing
// selected" -- a plain healthy globe during exactly the window in which
// egress is most likely to be dropped -- or announces a stale block when a
// selection has just been cleared. So the two replies of a pass are held
// until both have landed, and a selection with no resolvable status is
// published as active and NOT online: fail closed.
//
// Everything this publishes is stored before any of it is announced. The
// contract chains exitNodeActiveChanged and exitNodeOnlineChanged onto
// exitNodeBlockedChanged synchronously, so a signal emitted while a sibling
// member still holds the previous status hands QML a fail-closed flag
// computed from half of one status and half of the next -- and nothing emits
// again to correct it.
//
// Every member starts at the value a machine that has not reported in has, so
// the singleton is loadable, and reads as unknown rather than as connected,
// before the socket answers.
class LocalApiTailscaleBackend : public TailscaleBackend {
    Q_OBJECT

public:
    // The first reconnect delay. The curve doubles from here, six times, then
    // holds at kRetryCapMs -- the shape of Services/AuthService.qml:202.
    static constexpr int kRetryBaseMs = 500;
    static constexpr int kRetryCapMs = 30000;

    explicit LocalApiTailscaleBackend(QObject *parent = nullptr);
    // The socket to read, the first retry delay, how long a connection must
    // hold before it counts as one that worked, and how long one exchange
    // with tailscaled may take. All four are parameters so a test can point
    // the backend at a fake tailscaled and step the reconnect curve, or wedge
    // one request, without sleeping out the shipped timings, which
    // docs/architecture.md:204 forbids it to do.
    explicit LocalApiTailscaleBackend(QString socketPath, int retryBaseMs = kRetryBaseMs,
                                      int settleMs = kRetryCapMs,
                                      int requestTimeoutMs = c7::tailscale::LocalApiClient::kTimeoutMs,
                                      QObject *parent = nullptr);

    // Health messages this module never counts as an issue, matched as
    // substrings of what tailscaled reports.
    //
    // This is a policy list, not a workaround for a bug. The one entry is the
    // standing `--accept-routes` warning tailscaled raises on a machine whose
    // tailnet advertises subnet routes it deliberately does not accept --
    // because accepting them would blackhole the machine's own LAN. Surfaced
    // naively it is an issue that never clears on such a machine, so the panel
    // would warn forever about a setting someone chose. Anything tailscaled
    // says that is not named here still reaches the panel.
    static const QStringList &suppressedHealth();
    // `health` with every suppressed message dropped: what issues() publishes.
    static QStringList reportableHealth(const QStringList &health);

    // The reconnect curve, as a pure function of the attempt number, so it can
    // be checked without waiting for it: Services/AuthService.qml:202's shape,
    // doubling from `baseMs` six times and then flat at kRetryCapMs.
    static int retryDelayMs(int attempt, int baseMs);

    State state() const override { return m_state; }

    QString selfName() const override { return m_selfName; }
    QString selfIp4() const override { return m_selfIp4; }
    QString selfIp6() const override { return m_selfIp6; }
    QString tailnet() const override { return m_tailnet; }
    QDateTime keyExpiry() const override { return m_keyExpiry; }

    bool exitNodeActive() const override { return m_exitNodeActive; }
    QString exitNodeId() const override { return m_exitNodeId; }
    QString exitNodeName() const override { return m_exitNodeName; }
    bool exitNodeOnline() const override { return m_exitNodeOnline; }

    QStringList issues() const override { return m_issues; }

    // Owned by this object and outliving every binding on it, so a view may
    // hold the pointer for as long as the singleton lives.
    QAbstractItemModel *peers() const override { return &m_peers; }
    QAbstractItemModel *exitNodes() const override { return &m_exitNodes; }

    QString recommendedExitNodeId() const override { return m_recommendedExitNodeId; }

signals:
    // The delay this backend armed, each time it armed one. Nothing in QML
    // binds to it: it is here so a test can read the curve the reconnect
    // actually used instead of sleeping through it, which
    // docs/architecture.md:204 forbids it to do.
    void retryScheduled(int delayMs);

protected:
    QString rawSelfDnsName() const override { return m_selfDnsName; }

private:
    // What a whole connection consists of: the two health probes answered
    // *and* the stream up. The watch is one of these and not an afterthought
    // -- a local API that serves the reads and refuses the stream is as
    // broken as one that refuses a read, and leaving the watch out left the
    // backoff resting on the order open() happens to issue its requests in.
    //
    // /suggest-exit-node is deliberately NOT one of them. It is an optional
    // feature endpoint: a tailnet with no exit nodes has nothing to suggest,
    // and a 404, a 500 and an empty 200 all mean the same thing there -- no
    // suggestion. Counting it as a probe made such a tailnet never complete a
    // connection at all: nothing ever established, the settle timer never
    // armed, and the backend flapped Running/NoState at the 30s cap forever,
    // with the slot and the panel both gated on state !== NoState and so
    // blank or absent most of the time. /status and /prefs are the health
    // probes, and an optional endpoint is never one.
    enum OpeningRead {
        StatusRead = 1,
        PrefsRead = 2,
        WatchStarted = 4,
        EveryRead = 7,
    };

    // Drop whatever is in flight, start the watch, read the three endpoints.
    // Also the retry timer's slot.
    void open();
    void onReplied(const QString &path, const QByteArray &body, quint64 token);
    void onFailed(const QString &path, const QString &reason, quint64 token);
    // Whether a pass is open at all. A pass is numbered from 1, so a reply
    // that carries no token cannot be mistaken for one belonging to it.
    bool passOpen() const { return m_openPass != 0; }
    void onEvent(const QByteArray &notification);
    // Whether this notification is worth a re-read. The body is read for that
    // one decision and nothing else: what changed still comes from /status.
    //
    // tailscaled broadcasts every notification to every watcher whatever mask
    // it asked for, so a stream this module keeps narrow still carries the
    // 2s engine drumbeat whenever anything else on the machine asks for it.
    // Re-reading a 28KB status for byte counters nothing displays is the
    // polling docs/architecture.md keeps backends away from.
    //
    // Fails safe: anything not known to be ignorable is a reason to re-read.
    static bool worthRefreshing(const QByteArray &notification);
    // tailscaled is not answering: publish what that means and arrange to try
    // again.
    void lostTailscaled();
    void scheduleRetry();
    // Re-read what a notification can have changed: the status, and the
    // suggestion that is keyed on a row of it.
    void refresh();
    // Note that the connection is whole, and start the clock on it holding.
    // Being whole is not yet proof that it works: a stream that is accepted
    // and dropped a moment later has established and achieved nothing, and
    // clearing the curve for it makes every pass attempt zero -- a reconnect
    // running flat at the base delay forever. Only m_settle firing clears it.
    void noteEstablished();

    // Publish the pass once both its replies are in; do nothing until then.
    void applySnapshotWhenWhole();
    void applyStatus(const c7::tailscale::Status &status, const QString &prefsExitNodeId);
    void applySuggestion(const QByteArray &body);

    State m_state = State::NoState;

    QString m_selfName;
    QString m_selfIp4;
    QString m_selfIp6;
    QString m_selfDnsName; // as tailscaled reports it, root dot and all
    QString m_tailnet;
    QDateTime m_keyExpiry;

    bool m_exitNodeActive = false;
    // False until an exit node is known to be reachable: the fail-closed flag
    // built on this must not start out saying traffic is fine.
    bool m_exitNodeOnline = false;
    QString m_exitNodeId;
    QString m_exitNodeName;

    QStringList m_issues;

    // Members, so they live exactly as long as the singleton a view binds
    // them to. mutable only because a property READ is const while the model
    // QML receives cannot be.
    mutable c7::tailscale::PeerModel m_peers;
    mutable c7::tailscale::PeerModel m_exitNodes;

    QString m_recommendedExitNodeId;

    c7::tailscale::LocalApiClient m_client;
    QTimer m_retry;
    // Armed when the connection is whole, and the only thing that clears the
    // backoff. A connection that does not outlive it did not work.
    QTimer m_settle;
    int m_retryBaseMs;
    int m_settleMs;
    int m_attempts = 0;
    // One refresh at a time: tailscaled emits several notifications for one
    // change, and a set of sockets per notification would be a storm. A
    // notification that arrives while a refresh is out is remembered, not
    // dropped -- the reply in flight was asked for before the change, so it
    // cannot be the answer to it.
    //
    // A NUMBER RATHER THAN A FLAG, and this is the whole of the fix for the
    // skew it replaced. A flag answers "is a pass open?", and the question
    // that has to be answered is "is this reply from the pass that is open?".
    // Those differ exactly when a reply from an abandoned pass arrives while
    // the next one is out -- which is ordinary, because the notification that
    // starts the next pass routinely beats a slow /prefs from the last one --
    // and the flag says yes to the straggler, which is then paired with the
    // new pass's other half.
    //
    // m_passes only ever counts up, so a number is never reused and a
    // straggler can always be recognised. m_openPass is the one this object
    // is still interested in, or 0 when none is.
    quint64 m_passes = 0;
    quint64 m_openPass = 0;
    bool m_refreshStale = false;
    // The two halves of the pass in flight. A pass publishes when both are
    // here and not before -- see the note on snapshots at the top of this
    // file -- and open() drops whichever arrived, because a reply from the
    // previous attempt is not half of this one's answer.
    std::optional<c7::tailscale::Status> m_pendingStatus;
    std::optional<QString> m_pendingExitNodeId;
    // Reset by open(), so each attempt is judged on its own.
    int m_openingReads = 0;
    bool m_attemptFailed = false;
    bool m_established = false;
};
