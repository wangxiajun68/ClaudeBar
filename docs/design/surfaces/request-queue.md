# Request Queue

Mode: Operate. Native macOS SwiftUI / Core Animation, within the existing
light ice and dark graphite status-sheet language.

`GatewayQueueView` shows four real transport stages: queued, connecting,
waiting for the first valid output frame, and streaming. Each stage has a
count and a bounded eight-slot request bank. Overflow remains in the count
and the stage inspector; it never creates additional drawing work. Fixed
20pt slot spacing prevents overlap as the window grows or shrinks. Below
640pt, the flow wraps onto a second row. Labels stay outside the paths.

Amber denotes admission waiting, blue connection, purple first-frame waiting,
and green output. Text uses Theme.Ink, with the existing system rounded metric
face. A thin three-line bus connects the banks. Native layers render real
request transitions and actual output signals. No fabricated throughput,
idle traffic, or synthetic waveform is shown.

The footer exposes queue capacity, queued bytes, retrying requests and queue
timeout. Initial attempts do not count as retries. Both retry waiters and
active attempts after the first count once. Recent outcomes exclude requests
still active or queued. Stage buttons expose every request, and individual
markers retain request identity and inspection across admission.

Geometry paths and empty slots are rebuilt only when width changes. Rendering
does not run a SwiftUI frame clock; Core Animation owns transitions. Occlusion,
scroll visibility, Reduce Motion and removal stop movement. Only the opened
request inspector refreshes elapsed time once per second.

Admission remains actor-owned and oldest-runnable-first across independent
providers. Expired work is rejected before capacity or RPM is consumed,
including when its timeout task has not run yet. A full global permit pool
skips candidate preparation. Snapshot provider counts accumulate in linear
passes over reservations and waiters. Existing cooldown, compatible-provider
failover, bounded queue memory, cancellation and no-midstream-retry rules remain.

Verification: `make test TEST=free-model-gateway` exercises production scheduling
and loopback HTTP transport. `python3 Tools/render-model-gateway-preview.py`
renders production views with synthetic data in both palettes, compact and idle
states, checks slot separation at 320–1600pt and animation lifecycle. Neither
preview nor regression starts the app, VPN, or real provider integrations.
