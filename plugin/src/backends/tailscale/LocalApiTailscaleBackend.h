#pragma once

#include "contracts/TailscaleBackend.h"
#include "tailscale/LocalApiClient.h"
#include "tailscale/PeerModel.h"
#include "tailscale/Types.h"

#include <QtCore/QByteArray>
#include <QtCore/QStringList>
#include <QtCore/QTimer>

// The TailscaleBackend that reads tailscaled's local API socket: GET /status,
// /prefs and /suggest-exit-node on connect, then the /watch-ipn-bus stream
// that pushes every later change. Nothing here spawns the `tailscale` CLI,
// and nothing here polls: a notification on the bus is what makes it re-read
// /status, and with a quiet bus it issues no requests at all.
//
// A notification says that something changed, never what, so the reply to the
// status GET is the authority and no state is reconstructed from the bus.
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
    // The socket to read, and the first retry delay in milliseconds. Both are
    // parameters so a test can point the backend at a fake tailscaled and
    // step the reconnect curve without sleeping out the shipped one, which
    // docs/architecture.md:204 forbids it to do.
    explicit LocalApiTailscaleBackend(QString socketPath, int retryBaseMs = kRetryBaseMs,
                                      QObject *parent = nullptr);

    // Health messages this module never counts as an issue, matched as
    // substrings of what tailscaled reports.
    //
    // This is a policy list, not a workaround for a bug. The one entry is the
    // standing `--accept-routes` warning on c7-test-2: routes are deliberately
    // not accepted there, because the fleet advertises four /18s that would
    // otherwise blackhole the laptop's own LAN. Surfaced naively it is an
    // issue that never clears, on the only machine this module runs on, so
    // the panel would warn forever about a setting someone chose. Anything
    // tailscaled says that is not named here still reaches the panel.
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
    // Which of the opening reads has answered. The connection counts as
    // established only when all of them have and nothing has failed, which is
    // what makes the backoff advance -- see noteEstablished().
    enum OpeningRead { StatusRead = 1, PrefsRead = 2, SuggestRead = 4, EveryRead = 7 };

    // Drop whatever is in flight, start the watch, read the three endpoints.
    // Also the retry timer's slot.
    void open();
    void onReplied(const QString &path, const QByteArray &body);
    void onFailed(const QString &path, const QString &reason);
    void onEvent();
    // tailscaled is not answering: publish what that means and arrange to try
    // again.
    void lostTailscaled();
    void scheduleRetry();
    // Re-read what a notification can have changed: the status, and the
    // suggestion that is keyed on a row of it.
    void refresh();
    // Clear the backoff, but only once this connection has wholly proved
    // itself. A status reply alone is not proof: a local API that answers
    // /status and refuses anything else would otherwise reset the curve on
    // every pass and retry flat at the base delay forever.
    void noteEstablished();

    void applyStatus(const c7::tailscale::Status &status);
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
    int m_retryBaseMs;
    int m_attempts = 0;
    // One refresh at a time: tailscaled emits several notifications for one
    // change, and a pair of sockets per notification would be a storm. A
    // notification that arrives while a refresh is out is remembered, not
    // dropped -- the reply in flight was asked for before the change, so it
    // cannot be the answer to it.
    bool m_refreshInFlight = false;
    bool m_refreshStale = false;
    // Reset by open(), so each attempt is judged on its own.
    int m_openingReads = 0;
    bool m_attemptFailed = false;
    bool m_established = false;
};
