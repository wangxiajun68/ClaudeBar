#!/usr/bin/env python3
"""The connection panel is an instrument board, not a form.

The panel was rebuilt from five stacked blocks into a hub with four rings. Three
things about that rebuild are *structural* rather than visual, and each of them
is the kind of decision that silently reverts: a numbers block creeping back in,
an empty cell reappearing in the ring grid, or the four rings collapsing into one
repeated drawing. This asserts them from the source, no app launch.

The one thing it cannot assert is taste. It asserts the shape.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
panel = (root / 'Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift').read_text()
card = (root / 'Sources/ClaudeBar/Views/Shared/ConnectionCard.swift').read_text()

start = panel.index('struct ConnectionDetailPanel: View {')
end = panel.index('struct CapacityHardwareMark: View {')
body = panel[start:end]

# --- 1. Every ring is present, and they are four *different* drawings ---
for kind in ['.uplink', '.proxy', '.airdrop', '.bluetooth']:
    assert kind in body, f"the {kind} ring is gone from the panel"

# The uplink ring is the only one that measures a position, and the bluetooth
# ring is the only one reporting a device count. If both lost their figure the
# four rings would be four buttons.
assert 'linkPosition' in body, "the uplink ring no longer carries a level"
assert '"\\(audio.accessories.count) 个设备"' in body, \
    "the bluetooth ring no longer counts attached devices"

# Three distinct cores, not one arc stroked four times: the old panel's four
# concentric trims in four tints read as one meter repeated.
for core in ['WifiRingCore', 'ProxyRingCore', 'AirDropCore', 'BluetoothRingCore']:
    assert f'struct {core}' in panel, f"{core} is missing — the rings collapsed into one drawing"

# --- 2. The grid has no conditional cell ---
# `LazyVGrid` with fixed columns is what keeps 0, 1, 2, 3 and 4 accessories from
# leaving a hole. A conditional `if` inside the grid is how it came back before.
rings_start = body.index('private func rings(')
rings = body[rings_start:body.index('private var clusterAngle')]
assert 'LazyVGrid' in rings, "the ring grid is no longer a grid"
assert 'if ' not in rings.split('GridItem')[0], \
    "a conditional climbed into the ring grid's column list"

# --- 3. No address deck came back ---
# MAC, IP and the resolvers belong in 复制诊断, not on the surface. Only *code*
# counts: the doc comment above the panel names them on purpose, to record where
# they went.
code = "\n".join(line for line in body.splitlines()
                 if not line.lstrip().startswith("//"))
for banned in ['MAC', 'DNS', '网关', '子网', 'en0', 'resolver']:
    assert banned not in code, f"an address line ({banned}) is back on the panel"
# A `Text` whose interpolation is a bare address is the shape the old block had.
for line in code.splitlines():
    stripped = line.strip()
    assert not (stripped.startswith('Text("') and ('192.168' in stripped or '255.255' in stripped)), \
        f"a raw address literal is being printed: {stripped}"

# --- 4. The tile's badge states its size, like every other meter's does ---
# Unstated, `InstrumentBadge` takes its 24pt default, which is how one strip
# ended up with two badge sizes on it.
assert 'InstrumentBadge(kind: .link, tint: Theme.chartBlue)\n                .frame(width: 26, height: 26)' in card, \
    "the connection tile's header badge lost its explicit 26pt frame"

# --- 5. The card's marks stay small ---
# 48pt was the biggest object on the dashboard strip. A regression would be
# silent, which is exactly why it is pinned.
assert 'dial: 38' in card and 'column: 72' in card, \
    "the page-density connection marks no longer resolve to 38pt / 72pt"
assert 'dial: 48' not in card, "the 48pt mark came back"

print("PASS: connection panel is a four-ring hub (no address deck, no empty cell, "
      "three distinct ring drawings); the tile keeps its small marks and one badge size")
