# VPN workspace

Operate surface, native macOS SwiftUI. Preserve ClaudeBar's ice/graphite palette,
SF typography and semantic ink colors. This page uses stationary neutral surfaces
(`vpnSurface`), without tile hover lifts, inner decorative rings or corner lenses.

## Structure

A page-header row (VPN title, domain rules and core-log button) sits above a viewport-sized
workspace. At widths of 900pt and above, the leading column (340–380pt, 28% of
the workspace) holds the runtime overview and the subscriptions, and traffic
takes the remainder. Each column scrolls independently. Narrow windows
use a native segmented switch between traffic and subscriptions. The page never
forces a minimum content width or a horizontal page scroll.

The overview panel owns runtime controls, sampled rates, totals and one current
node entry. TUN, LAN access and editable port live in a network-settings popover.
Connectivity combines its glyph, all seven probes, exit IP and test action in one
row of the panel; narrow layouts wrap the probes into an adaptive grid without
hiding any service. The running-node entry includes its latest measured latency.
Rate and cumulative values keep intrinsic text width; the layout does not
truncate their numeric readings. Core logs have a separate popover;
runtime failures also expose it automatically.

Subscriptions share one neutral panel with compact separated rows. Browsing is
independent of activation. The activate action is explicit; maintenance actions
live in each subscription's menu. The thin progress track represents **used**
traffic, with its numerator and denominator available in the tooltip.

## Nodes

Collapsed by default, per visit. The current-node entry opens a trailing drawer
(maximum 720pt, contained by the window), with a dismissible scrim and Escape.
Opening it preserves traffic view state and scroll position. Subscription name
buttons open the selected subscription in this drawer without activating it. The drawer contains
fixed title, current-node summary, native group menu, count, search and group
latency test controls. Only the list scrolls. Rows are lazy, 48pt tall, with
single-line node names, state, and a fixed latency column. Duplicate node names
use original group positions for identity. Search keeps those positions stable.

Browsing an inactive subscription produces read-only configuration preview;
switching and testing are available only for the running subscription. Node
switches show progress, suppress overlapping switches, and surface failures.
Long names remain available in tooltips. Preview and live lists share geometry.

## Domain rules

The title-bar action opens a trailing panel, at most 760pt wide, with a dismissible
scrim and Escape. A fixed title, composer and footer frame a scrolling rule list.
The composer combines a domain field, shared route capsule and one add action;
subdomain matching is explicit. Search and route filtering sit above columns for
domain, match scope and route. Rows edit scope and route directly, with a separate
delete button. Blue identifies proxy routing; green identifies direct routing.
The footer reports save state and explicitly names restart-and-apply; automatic
persistence is distinct from applying rules to the running VPN.

## Traffic

Shared icon-bearing `SegmentedCapsule`: detail, retained-domain summary, live
connections. Its sliding selected pill matches the app's other filters. Search and
route filters, follow, copy and clear share one top toolbar (two rows when narrow); failure filtering is available for history. Detail
uses a fixed header and 30pt rows. Text is neutral; only route and failure signals
carry color. Record text supports system text selection. The row is not a button: only its
trailing detail control opens complete endpoint/rule/outbound information, so
mouse and system three-finger text selection are not intercepted by a row action.
The header copy button targets the filtered set, not only the current page. Clear is a confirmed action in a menu.

The route menu shows matching counts; the log glyph tooltip carries retained capacity. The footer pages through at most 200 rows at a time and states the total. Domain summary covers retained records, not evicted
history. Following is explicit and pauses on user scroll or older-page navigation; paused history freezes its reading snapshot, even at ring eviction, and shows
new matching record count and a return-to-latest action. Incoming logs do not
change subscriptions, drawer geometry or the page's layout.

Proxy and direct flow lanes stay visible in all three modes. Each reports its own
sampled upload, download and total, plus the observed route path. These totals
are session samples and do not follow filters; counts follow search and failure
filtering. Domain summary separates proxy and direct bytes into fixed columns,
with full upload/download values on separate lines. Historical records carry
routes and exits, not invented per-connection byte counts. System-proxy bypass
and traffic outside the kernel are explicitly outside this sampling scope.

## Performance

2,000 retained connection records in a fixed-capacity FIFO, with at most 200
rows handed to SwiftUI in each mode. Background parsing remains; history publishes
at most once per second. The section subscribes to revisions for its active mode,
so byte totals update the visible flow strip without rerunning history queries; hidden workspaces do not mirror updates. Ring wraparound
replaces slots instead of shifting the head of an Array. Each publish produces an
immutable bounded snapshot for readers. Historical and live-connection search/counting execute off-main;
query task identity cancels stale publication and work on disappearance or
when the narrow workspace hides traffic. Query loops cooperate with cancellation. Typing
uses 150ms debounce. Domain folding and sorting run only in summary mode, in the
background. Detail/node rows are lazy; historic updates never replace the entire
scroll-view identity. Both workspace view identities survive width changes and
compact-workspace switches, preserving search, mode and position.

## Verification

Build the complete native app with `CLAUDEBAR_SKIP_INSTALL=1` (do not restart the
user's VPN for visual verification). Parser/query/ring regression suite:
`python3 Tests/vpn-domain-log-regressions.py` drives the production parser and
ring (including 2,000-record wraparound and paused-snapshot cases) without
launching the app. The synthetic preview (`Tools/render-mainwindow-preview.py`)
seeds 12 node names and no domain-log records, so it exercises layout, not
volume; runtime node switching, real network startup, native text selection and
hover remain outside preview coverage.

`Tools/render-vpn-preview.py` additionally renders production rule, empty-list,
detail and summary views through offscreen NSHostingView in both themes, with
synthetic stores and private files under `.build/vpn-preview`. A 560pt traffic
capture checks the narrow toolbar. It does not test real routing or system settings.
