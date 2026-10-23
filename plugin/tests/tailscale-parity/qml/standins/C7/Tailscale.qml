// The QML stand-in for the Tailscale contract (R-QML-25): the view tests
// set its properties as the backend would, and its actions only record
// that they were called. Written from the requirement, not copied.
pragma Singleton
import QtQuick

QtObject {
    id: root

    enum State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running }

    property int state: Tailscale.State.NoState
    property bool exitNodeActive: false
    property bool exitNodeOnline: false
    property string exitNodeId: ""
    property string exitNodeName: ""
    // Derived as the contract derives it; no test writes it.
    readonly property bool exitNodeBlocked: root.exitNodeActive && !root.exitNodeOnline
    property var issues: []
    readonly property int issueCount: root.issues.length
    property string selfName: ""
    property string selfIp4: ""
    property string selfIp6: ""
    property string selfDnsName: ""
    property string tailnet: ""
    property var keyExpiry: null
    property string recommendedExitNodeId: ""
    // ListModels with static roles: driven through the same adaptor a C++
    // QAbstractItemModel is, so an edit is that row's signal, never a reset.
    readonly property ListModel peers: ListModel { dynamicRoles: false }
    readonly property ListModel exitNodes: ListModel { dynamicRoles: false }
    property bool writable: true
    property string writeError: ""
    property string readError: ""
    property bool wantRunning: false
    property bool exitNodeAllowLANAccess: false
    property bool acceptRoutes: false
    property bool acceptDns: false

    // Each action records its call and moves no property.
    signal called(string call)
    function setWantRunning(on) { root.called("setWantRunning(" + on + ")") }
    function setExitNode(nodeId) { root.called("setExitNode(" + nodeId + ")") }
    function setExitNodeAllowLANAccess(on) { root.called("setExitNodeAllowLANAccess(" + on + ")") }
    function setAcceptRoutes(on) { root.called("setAcceptRoutes(" + on + ")") }
    function setAcceptDns(on) { root.called("setAcceptDns(" + on + ")") }
}
