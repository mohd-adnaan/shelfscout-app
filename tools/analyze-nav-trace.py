#!/usr/bin/env python3
"""Read a shelfscout navigation trace and print what guidance did, next to the
capture that produced it.

    python3 tools/analyze-nav-trace.py shelfscout-navigation-trace-*.jsonl

The trace is JSONL written by ios/NavigationTrace.swift. Events:

  map.node          a point marked during the mapping walk
  map.pose          the mapping walk's own path, ~4 Hz
  map.saved         the finished graph
  ar.mappingStarted / ar.mapLoaded / ar.localized / ar.relocalizeVeto / ar.poseJump
  nav.start         resolved route, shaped legs, opening cue
  nav.start.resolve which edge the start snapped to and what the options cost
  nav.tick          guidance state, ~4 Hz plus every transition
  nav.advance       a leg completed and the turn spoken at the node
  nav.alignmentCue / nav.recovery / nav.beliefHold / nav.snap / nav.rebuild / nav.rejoin
  cue               every spoken sentence, with the function that emitted it
"""

import json
import sys
from collections import Counter, defaultdict


def load(path):
    events = []
    with open(path) as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"  ! unparseable line {number}", file=sys.stderr)
    return events


def clock(event):
    return f"{event.get('t', 0):8.2f}"


def section(title):
    print(f"\n\n{'=' * 78}\n{title}\n{'=' * 78}")


def report_capture(events):
    nodes = [e for e in events if e["e"] == "map.node"]
    saves = [e for e in events if e["e"] == "map.saved"]
    if not nodes and not saves:
        print("  (no mapping walk in this trace)")
        return

    section("MAPPING WALK — what was marked, where, and facing which way")
    for event in nodes:
        turn = event.get("signedTurnDeg")
        turn_text = f"{turn:+7.1f}°" if isinstance(turn, (int, float)) else "      —"
        print(
            f"  {clock(event)}  {event.get('name', '?'):<22.22s}"
            f" {event.get('kind', '?'):<12.12s} hint={event.get('turnHint', 'none'):<12.12s}"
            f" at ({event.get('x', 0):6.2f},{event.get('y', 0):6.2f})"
            f" facing {event.get('headingDeg', 0):5.0f}°"
            f"  in={event.get('incomingBearing', float('nan')):5.0f}°"
            f" {event.get('incomingDistM', float('nan')):5.2f}m"
            f"  turn={turn_text}"
        )

    for event in saves:
        graph = event.get("graph", {})
        print(
            f"\n  {clock(event)}  SAVED {graph.get('name')!r}"
            f"  space={graph.get('coordinateSpace')} axes=v{graph.get('axisConvention')}"
            f"  arWorldMap={graph.get('arWorldMapId')}"
            f"  keyframes={graph.get('keyframeCount')} fingerprints={graph.get('fingerprintCount')}"
        )
        for edge in graph.get("edges", []):
            print(
                f"      edge {edge['from'][:8]}→{edge['to'][:8]}"
                f"  {edge['distM']:6.2f}m  bearing {edge['bearing']:6.1f}°"
                f"  reverse {edge['reverseBearing']:6.1f}°"
            )


def report_localization(events):
    interesting = [
        e for e in events
        if e["e"] in {"ar.mappingStarted", "ar.mapLoaded", "ar.localized",
                      "ar.relocalizeVeto", "ar.poseJump"}
    ]
    if not interesting:
        return
    section("AR FRAME / LOCALIZATION — is the pose in the saved map's frame?")
    for event in interesting:
        kind = event["e"]
        if kind == "ar.mappingStarted":
            print(f"  {clock(event)}  mapping started, worldAlignment={event.get('worldAlignment')}")
        elif kind == "ar.mapLoaded":
            print(
                f"  {clock(event)}  loaded {event.get('mapName')!r}"
                f"  pois={event.get('poiCount')} {event.get('poiNames')}"
                f"  features={event.get('featurePoints')}"
                f"  worldAlignment={event.get('worldAlignment')}"
            )
        elif kind == "ar.localized":
            proof = "ANCHOR-PROVEN" if event.get("hadAnchorProof") else "NO ANCHOR PROOF"
            print(
                f"  {clock(event)}  LOCALIZED after {event.get('heldSeconds', 0):.1f}s"
                f"  [{proof}]  status={event.get('mappingStatus')}"
                f"  at ({event.get('x', 0):.2f},{event.get('routeY', 0):.2f})"
                f" heading {event.get('headingDeg')}"
            )
            if not event.get("hadAnchorProof"):
                print("        ^^ pose may still be in ARKit's own session frame, not the map's")
        elif kind == "ar.relocalizeVeto":
            print(f"  {clock(event)}  veto: {event.get('reason')}  {event.get('message', '')}")
        elif kind == "ar.poseJump":
            print(
                f"  {clock(event)}  POSE JUMP {event.get('jumpM', 0):.2f}m"
                f" ({event.get('fromX', 0):.2f},{event.get('fromRouteY', 0):.2f})"
                f" → ({event.get('toX', 0):.2f},{event.get('toRouteY', 0):.2f})"
                f"  {event.get('sinceLocalizedS', 0):.1f}s after localizing"
            )


def report_route(events):
    starts = [e for e in events if e["e"] == "nav.start"]
    resolves = [e for e in events if e["e"] == "nav.start.resolve"]
    if not starts:
        print("\n  (no guidance run in this trace)")
        return

    section("GUIDANCE RUNS — resolved route and the turns it intends to speak")
    for start in starts:
        print(
            f"\n  {clock(start)}  START → {start.get('resolvedTarget')!r}"
            f" (asked for {start.get('requestedTarget')!r},"
            f" exact={start.get('exactMatch')})"
        )
        print(
            f"      standing at ({start.get('arPoseX')},{start.get('arPoseY')})"
            f" facing {start.get('startHeadingDeg')}°"
            f"  (ar={start.get('arHeadingDeg')} imu={start.get('imuBearingDeg')})"
        )
        print(f"      opening: {start.get('openingInstruction')!r}")
        if start.get("droppedLeadingStub"):
            print("      leading stub dropped")

        nearest = min(
            (r for r in resolves if r["t"] <= start["t"]),
            key=lambda r: start["t"] - r["t"],
            default=None,
        )
        if nearest:
            print(f"      start resolution: mode={nearest.get('mode')}")
            if nearest.get("snappedEdge"):
                print(
                    f"        snapped to {nearest['snappedEdge']}"
                    f"  along={nearest.get('alongTrackM', 0):.2f}m"
                    f" cross={nearest.get('crossTrackM', 0):.2f}m"
                    f"  bearing={nearest.get('snappedEdgeBearing', 0):.1f}°"
                    f" reverse={nearest.get('snappedEdgeReverseBearing', 0):.1f}°"
                )
            for option in nearest.get("options", []):
                print(
                    f"        option cost {option['cost']:7.2f}"
                    f"  progress {option['initialProgressM']:5.2f}m"
                    f"  path {' → '.join(p[:8] for p in option['path'])}"
                )

        for leg in start.get("legs", []):
            print(
                f"      leg {leg['i']}: {leg['from']:<18.18s} → {leg['to']:<18.18s}"
                f" {leg['distM']:6.2f}m  bearing {leg['bearing']:6.1f}°"
                f"  hint={leg['turnHintAtEnd']:<12.12s} speaks {leg['spokenTurnAtEnd']!r}"
            )


def report_cues(events):
    section("SPOKEN CUES — in order, with the code that produced each one")
    print(
        f"  {'time':>8}  {'emitter':<34.34s} {'phase':<11.11s}"
        f" {'leg':<4.4s} {'hdg':>5.5s} {'want':>5.5s} {'err':>5.5s}"
        f" {'prog':>6.6s} {'belief':<10.10s}  text"
    )
    for event in events:
        if event["e"] != "cue":
            continue
        leg = f"{event.get('stepIndex', '?')}/{event.get('stepCount', '?')}"
        print(
            f"  {clock(event)}  {event.get('from', '?'):<34.34s}"
            f" {event.get('phase', '?'):<11.11s} {leg:<4.4s}"
            f" {_num(event.get('heading')):>5.5s}"
            f" {_num(event.get('legBearing')):>5.5s}"
            f" {_num(event.get('headingErrDeg')):>5.5s}"
            f" {_num(event.get('progressM'), 1):>6.6s}"
            f" {event.get('beliefStatus', '?'):<10.10s}  {event.get('text', '')}"
        )


def _num(value, places=0):
    if isinstance(value, (int, float)):
        return f"{value:.{places}f}"
    return "—"


def report_turns(events):
    advances = [e for e in events if e["e"] == "nav.advance"]
    if not advances:
        return
    section("TURNS ACTUALLY REACHED — recorded hint vs geometry vs spoken word")
    for event in advances:
        print(
            f"  {clock(event)}  at {event.get('atNode', '?'):<20.20s}"
            f" hint={event.get('recordedTurnHint', 'none'):<12.12s}"
            f" in={event.get('incomingBearing', 0):6.1f}°"
            f" out={event.get('outgoingBearing', 0):6.1f}°"
            f" turn={event.get('signedTurnDeg', 0):+7.1f}°"
            f"  →  {event.get('spokenTurn')!r}"
        )
        recorded = event.get("recordedTurnHint", "none")
        signed = event.get("signedTurnDeg", 0)
        if recorded == "left" and signed > 25:
            print("        ^^ hint says left, geometry says right")
        if recorded == "right" and signed < -25:
            print("        ^^ hint says right, geometry says left")


def report_evidence(events):
    """Which sensors actually reached the belief. If this says AR and visual
    never contributed, guidance was dead-reckoning and every downstream
    symptom (drifting heading, 'route lost', wrong turns) follows from that —
    look no further down the stack."""
    ticks = [e for e in events if e["e"] == "nav.evidence"]
    if not ticks:
        return
    section("SENSOR EVIDENCE REACHING THE BELIEF")
    total = len(ticks)
    localized = sum(1 for t in ticks if t.get("arLocalized"))
    with_point = sum(1 for t in ticks if t.get("hasARPoint"))
    with_image = sum(1 for t in ticks if t.get("hasCapturedImage"))
    ar_heading = sum(1 for t in ticks if t.get("headingSource") == "ar")
    matched = sum(1 for t in ticks if isinstance(t.get("visualMatchConf"), (int, float)))
    print(f"  samples            {total}")
    print(f"  arLocalized        {localized:5d}  {localized / total * 100:5.1f}%")
    print(f"  AR pose present    {with_point:5d}  {with_point / total * 100:5.1f}%")
    print(f"  heading from ARKit {ar_heading:5d}  {ar_heading / total * 100:5.1f}%"
          + ("   <-- rest fall back to drifting IMU bearing" if ar_heading < total else ""))
    print(f"  camera frame given {with_image:5d}  {with_image / total * 100:5.1f}%")
    print(f"  visual match found {matched:5d}  {matched / total * 100:5.1f}%")
    sims = [t["visualBestSimilarity"] for t in ticks
            if isinstance(t.get("visualBestSimilarity"), (int, float))]
    if sims:
        need = next((t["visualRequiredSimilarity"] for t in ticks
                     if isinstance(t.get("visualRequiredSimilarity"), (int, float))), None)
        cands = [t.get("visualCandidates", 0) for t in ticks]
        print(f"  best similarity    min {min(sims):.3f}  mean {sum(sims) / len(sims):.3f}"
              f"  max {max(sims):.3f}"
              + (f"   (needs >= {need:.3f})" if need else ""))
        print(f"  keyframes eligible min {min(cands)}  max {max(cands)}  (after heading gate)")
        if need and max(sims) < need:
            gap = need - max(sims)
            print(f"  !! never reached the bar — short by {gap:.3f} even at best."
                  " The threshold, not the matcher, is what blocks visual evidence")
        if max(cands) == 0:
            print("  !! heading gate left ZERO keyframes eligible — nothing could match")
    first = ticks[0]
    print(f"  map offers         {first.get('mapKeyframes')} keyframes,"
          f" {first.get('mapFingerprints')} fingerprints,"
          f" space={first.get('coordinateSpace')}")
    if with_image == 0:
        print("  !! no camera frame ever reached the matcher — visual matching cannot run")
    if localized == 0:
        print("  !! arLocalized never true — no AR projection evidence, PDR only")


def report_overrides(events):
    overrides = [
        e for e in events
        if e["e"] in {"nav.beliefHold", "nav.snap", "nav.rebuild", "nav.rejoin", "nav.recovery"}
    ]
    if not overrides:
        return
    # Older traces logged beliefHold every tick (~50 Hz). Collapse runs of the
    # same status so one episode reads as one line instead of nine hundred.
    collapsed = []
    for event in overrides:
        previous = collapsed[-1] if collapsed else None
        if (previous
                and previous["e"] == "nav.beliefHold" == event["e"]
                and previous.get("beliefStatus") == event.get("beliefStatus")
                and event.get("t", 0) - previous.get("t", 0) < 2.0):
            previous["_repeats"] = previous.get("_repeats", 1) + 1
            previous["_lastT"] = event.get("t")
            continue
        collapsed.append(dict(event))
    overrides = collapsed

    section("OVERRIDES — where something outranked the mapped route")
    for event in overrides:
        kind = event["e"]
        head = f"  {clock(event)}  {kind:<16.16s} leg {event.get('stepIndex')}"
        if kind == "nav.beliefHold":
            print(
                f"{head}  held {event.get('holdSeconds', 0):.1f}s"
                f"  status={event.get('beliefStatus')}"
                f"  conf={_num(event.get('beliefConf'), 2)}"
                f" margin={_num(event.get('beliefMargin'), 2)}"
            )
            for candidate in event.get("candidates", []):
                print(
                    f"        candidate step {candidate['step']}"
                    f" @{candidate['progressM']:.2f}m conf {candidate['conf']:.2f}"
                    f" unc {candidate['uncM']:.2f} n={candidate['support']}"
                    f" {candidate['sources']}"
                )
        elif kind == "nav.recovery":
            flags = [
                name for name in
                ("crossTrackBad", "backwardBad", "headingBad", "lowConfidenceBad", "localizationBad")
                if event.get(name)
            ]
            print(f"{head}  {','.join(flags) or 'none'}  → {event.get('instruction')!r}")
        elif kind == "nav.snap":
            print(
                f"{head}  → step {event.get('toStep')} @{_num(event.get('toProgressM'), 2)}m"
                f"  cross={_num(event.get('snapCrossM'), 2)}m"
                f" headingErr={_num(event.get('snapHeadingErrDeg'), 0)}°"
            )
        else:
            print(f"{head}  {event.get('instruction', '')}")
            for leg in event.get("legs", []):
                print(
                    f"        leg {leg['i']}: {leg['from']} → {leg['to']}"
                    f" {leg['distM']:.2f}m bearing {leg['bearing']:.1f}°"
                    f" speaks {leg['spokenTurnAtEnd']!r}"
                )

        if event.get("_repeats"):
            print(f"        … same state {event['_repeats']}x"
                  f" through t={event.get('_lastT', 0):.2f}")


def report_belief_timeline(events):
    ticks = [e for e in events if e["e"] == "nav.tick"]
    if not ticks:
        return
    section("BELIEF STATUS OVER TIME (guidance ticks)")
    counts = Counter(t.get("beliefStatus", "?") for t in ticks)
    total = sum(counts.values())
    for status, count in counts.most_common():
        print(f"  {status:<14.14s} {count:5d}  {count / total * 100:5.1f}%")

    print("\n  moving vs status:")
    split = defaultdict(Counter)
    for tick in ticks:
        split["moving" if tick.get("moving") else "still"][tick.get("beliefStatus", "?")] += 1
    for state, statuses in split.items():
        inner = sum(statuses.values())
        detail = ", ".join(f"{k} {v / inner * 100:.0f}%" for k, v in statuses.most_common())
        print(f"    {state:<7.7s} n={inner:<5d} {detail}")

    print("\n  phase/leg transitions:")
    for tick in ticks:
        if tick.get("transition"):
            print(
                f"    {clock(tick)}  leg {tick.get('stepIndex')}/{tick.get('stepCount')}"
                f"  phase={tick.get('phase')}  belief={tick.get('beliefStatus')}"
                f"  progress={_num(tick.get('progressM'), 2)}m"
                f" remaining={_num(tick.get('remainingM'), 2)}m"
                f"  heading={_num(tick.get('heading'))}° want={_num(tick.get('legBearing'))}°"
            )


def split_sessions(events):
    """The export concatenates whole app runs, each with its own t=0 clock.
    Sorting the union by t interleaves capture and guidance runs into one
    scrambled timeline, so every analysis must stay inside one session."""
    sessions = []
    current = []
    for event in events:
        is_boundary = event["e"] == "session.open" or (
            current and event.get("t", 0) + 5.0 < current[-1].get("t", 0)
        )
        if is_boundary and current:
            sessions.append(current)
            current = []
        current.append(event)
    if current:
        sessions.append(current)
    return sessions


def session_title(number, events):
    opener = next((e for e in events if e["e"] == "session.open"), None)
    started = opener.get("startedAt", "?") if opener else "?"
    device = opener.get("device", "?") if opener else "?"
    kinds = []
    if any(e["e"] == "map.node" for e in events):
        kinds.append("capture")
    if any(e["e"] == "nav.start" for e in events):
        kinds.append("guidance")
    if any(e["e"] == "ar.mapLoaded" for e in events) and "guidance" not in kinds:
        kinds.append("relocalize-only")
    label = "+".join(kinds) or "no activity"
    return f"SESSION {number}  [{label}]  {device}  {started}  ({len(events)} events)"


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1

    # --raw EVENT[,EVENT] dumps just those events' JSON lines, for pasting a
    # targeted slice. map.pose and ar.frame are ~95% of the file's volume, so
    # anything you want to share by hand needs them filtered out.
    raw_filter = None
    if "--raw" in args:
        index = args.index("--raw")
        raw_filter = set(args[index + 1].split(","))
        del args[index:index + 2]

    # --session N (1-based, negatives count from the end: -1 = latest run).
    session_pick = None
    if "--session" in args:
        index = args.index("--session")
        session_pick = int(args[index + 1])
        del args[index:index + 2]

    events = []
    for path in args:
        events.extend(load(path))

    sessions = split_sessions(events)
    if session_pick is not None:
        picked = session_pick - 1 if session_pick > 0 else session_pick
        try:
            sessions = [sessions[picked]]
        except IndexError:
            print(f"no session {session_pick}; the file has {len(sessions)}")
            return 1

    if raw_filter is not None:
        for number, session in enumerate(sessions, 1):
            print(f"### {session_title(number, session)}")
            for event in session:
                if event["e"] in raw_filter:
                    print(json.dumps(event, sort_keys=True))
        return 0

    print(f"{len(events)} events in {len(sessions)} session(s)")
    for number, session in enumerate(sessions, 1):
        print(f"\n\n{'#' * 78}\n# {session_title(number, session)}\n{'#' * 78}")
        print(f"  ({Counter(e['e'] for e in session).most_common()})")
        report_capture(session)
        report_localization(session)
        report_route(session)
        report_turns(session)
        report_evidence(session)
        report_overrides(session)
        report_cues(session)
        report_belief_timeline(session)
    return 0


if __name__ == "__main__":
    sys.exit(main())
