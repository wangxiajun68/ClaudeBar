#!/usr/bin/env python3
"""The connection inspector reports state; it does not claim reachability.

The panel has been through two rewrites, and both times the regression to guard
against was structural rather than visual: a numbers deck creeping back in, and
*claims* — a listener or an attached interface being reported as working
internet.

The previous version was a hub of four rings (出口 / 本机代理 / 隔空投送 / 蓝牙).
It is now three stacked sections (网络 / 本机代理 / 附近与设备) sharing one state
vocabulary and one signal scale with the tile that opens it. What is asserted
here is what those two versions agree on and what the *reason* for the rewrite
was:

  * every section is present, and the address material stays in 复制诊断;
  * no ring machinery comes back — the rings measured a position where what a
    person needs is a word;
  * the card and the panel speak one vocabulary (`ConnectionStatus`) and draw
    one ruler (`ConnectionSignalScale`), so a reading cannot differ between a
    tile and its own popover;
  * neither surface states or implies reachability: a listening local proxy is
    a process, an attached interface is a link, and neither is the internet.

See docs/technical/08-performance.md for why `.shadow`-free drawing matters here
and docs/design/05-main-window-and-theme.md for the design intent.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
panel = (root / 'Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift').read_text()
card = (root / 'Sources/ClaudeBar/Views/Shared/ConnectionCard.swift').read_text()

start = panel.index('struct ConnectionDetailPanel: View {')
end = panel.index('struct CapacityHardwareMark: View {')
body = panel[start:end]

# --- 1. The three sections are all present, in reading order ---
# 网络 first (what the machine is attached to), then the one connection the app
# itself owns, then what is attached over the air.
for section in ['private var network', 'private var proxy', 'private var devices']:
    assert section in body, f"the panel lost its {section} section"
assert body.index('private var network') < body.index('private var proxy') < body.index('private var devices'), \
    "the panel's sections are out of reading order"

# --- 2. No ring machinery came back ---
# The four-ring hub drew a position (`linkPosition`), rotated a cluster
# (`clusterAngle`) and drew four bespoke `*RingCore` shapes. All three were
# removed for the same reason: a ring states "how much", and the question here
# is "which way out, through what door, with what attached".
for banned in ['RingCore', 'linkPosition', 'clusterAngle']:
    assert banned not in body, f"the four-ring hub is back on the panel ({banned})"

# --- 3. No address deck came back ---
# MAC, IP and the resolvers belong in 复制诊断, not on the surface. Only *code*
# counts: a doc comment may name them on purpose, to record where they went.
code = "\n".join(line for line in body.splitlines()
                 if not line.lstrip().startswith("//"))
for banned in ['MAC', 'DNS', '网关', '子网', 'en0', 'resolver']:
    assert banned not in code, f"an address line ({banned}) is back on the panel"
# A `Text` whose interpolation is a bare address is the shape the old block had.
for line in code.splitlines():
    stripped = line.strip()
    assert not (stripped.startswith('Text("') and ('192.168' in stripped or '255.255' in stripped)), \
        f"a raw address literal is being printed: {stripped}"

# --- 4. The card and the panel share one vocabulary and one ruler ---
# Two places naming the same link differently is how a tile and its own popover
# end up disagreeing; two RSSI scales is how the same −46 dBm draws at two
# lengths. Both components are declared once, in the card's file, and read by
# the panel — asserted by declaration, not by substring: a `ConnectionStatus_X`
# or a second local copy in the panel must fail here, and a bare "does the name
# appear" check would pass on both.
def declares(source: str, name: str) -> bool:
    # `\b` after the name: `ConnectionStatus_X` is a different declaration and
    # must not satisfy this (nor a bare "does the name appear" check).
    return re.search(rf'^\s*(?:fileprivate |private )?struct {name}\b', source, re.M) is not None


# The two *shared* pieces are the vocabulary and the ruler. `ConnectionStatus`
# is declared once, in the card's file, and read by both. The ruler
# (`ConnectionSignalScale`) now lives only in the panel: the tile draws its
# reading as a mark in the mark slot every sibling reserves (`ConnectInterfaceMark`
# — a filled cell row over the interface's own glyph), so a tile that no longer
# has a full-width row must not still declare the wide view.
assert declares(card, 'ConnectionStatus'), \
    "ConnectionStatus is gone from the tile — it must not move"
assert not declares(panel, 'ConnectionStatus'), \
    "the panel declares its own ConnectionStatus; the tile and its popover must share one"
assert 'ConnectionStatus(host:' in body, "the panel no longer reads ConnectionStatus"
assert not declares(card, 'ConnectionSignalScale'), \
    "the tile should no longer declare the wide signal ruler; it moved to the panel"
assert 'ConnectionSignalScale(rssi:' in body, "the panel no longer draws the signal ruler"
# The tile's own mark must read the same ruler: one definition of "how full" for
# both surfaces, or a tile and its popover disagree about one dBm.
assert 'Double(rssi + 100) / 60' in card, \
    "the tile's mark stopped using the −100…−40 dBm ruler the panel's scale draws"

# --- 5. Neither surface claims reachability ---
# The rule the whole inspector exists to keep: the local proxy is a process this
# app owns, an attached interface is a link, and a *listener* is not evidence of
# working internet. The panel says so, both times it could be misread.
assert '网络接入状态不代表互联网可用性' in body, \
    "the panel stopped stating that an attached interface is not internet access"
assert '不代表上游模型可用' in body, \
    "the panel stopped stating that a responding local proxy is not a working upstream"
for claim in ['已连接互联网', '联网正常', '可以上网', '网络正常']:
    assert claim not in code, f"the panel claims reachability: {claim}"

# --- 6. The tile keeps the shape it opens the panel from ---
# One badge size on the strip (the other five meters state theirs), and the whole
# card is the target: only the title used to be clickable, which made this the
# one tile whose obvious target did nothing.
assert 'InstrumentBadge(kind: .link, tint: Theme.chartBlue)\n                .frame(width: 26, height: 26)' in card, \
    "the connection tile's header badge lost its explicit 26pt frame"
# The title is text, not a button: the whole card is the target, so a `Button`
# here (the old form) would nest a second hit region inside the card's own.
assert 'Text("连接")' in card, \
    "the connection tile's title must be a plain label, not its own button"
# And the card's mark is drawn in the shared mark slot, like the five meters it
# sits among — the layout that made it a sibling rather than a stranger.
assert 'ResourceStrip.markSlot' in card, \
    "the connection tile stopped drawing its mark in the shared mark slot"
assert '.onTapGesture { showConnections = true }' in card and \
    '.popover(isPresented: $showConnections) { ConnectionDetailPanel() }' in card, \
    "the connection tile no longer opens the inspector from the whole card"

print("PASS: connection inspector is three sections (no rings, no address deck), "
      "shares one state vocabulary and one RSSI ruler with its tile, and states "
      "that a link and a listener are not internet access")
