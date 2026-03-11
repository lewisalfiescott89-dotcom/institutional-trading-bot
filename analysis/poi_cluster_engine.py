"""
POI Cluster Engine – merges overlapping POIs from multiple timeframes
into stronger composite zones.
"""

from __future__ import annotations

import uuid
from typing import List, Optional

from config.settings import POISettings, TIMEFRAME_WEIGHTS
from core.utils import zones_overlap, overlap_pct
from models.poi import POI, POIDirection, POIType


class POIClusterEngine:
    """Detects and merges overlapping POI zones into clusters."""

    def __init__(self, settings: Optional[POISettings] = None) -> None:
        self.cfg = settings or POISettings()

    def cluster(self, pois: List[POI]) -> List[POI]:
        """
        Merge overlapping POIs into cluster super-zones.

        Returns
        -------
        A list of POIs where overlapping groups have been replaced by a
        single cluster POI.  Non-overlapping POIs are returned as-is.
        """
        if not pois:
            return []

        # Separate by direction – only merge same-direction POIs
        bullish = [p for p in pois if p.direction == POIDirection.BULLISH and p.active]
        bearish = [p for p in pois if p.direction == POIDirection.BEARISH and p.active]
        inactive = [p for p in pois if not p.active]

        merged = (
            self._merge_group(bullish, POIDirection.BULLISH)
            + self._merge_group(bearish, POIDirection.BEARISH)
            + inactive
        )
        return merged

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _merge_group(self, pois: List[POI], direction: POIDirection) -> List[POI]:
        """Greedy overlap-based clustering within a single direction."""
        if not pois:
            return []

        # Sort by zone_low ascending
        sorted_pois = sorted(pois, key=lambda p: p.zone_low)
        clusters: List[List[POI]] = []
        current_cluster: List[POI] = [sorted_pois[0]]

        for poi in sorted_pois[1:]:
            # Check overlap with the cluster envelope
            cluster_low = min(p.zone_low for p in current_cluster)
            cluster_high = max(p.zone_high for p in current_cluster)

            ovlp = overlap_pct(cluster_low, cluster_high, poi.zone_low, poi.zone_high)
            if ovlp >= self.cfg.cluster_overlap_pct:
                current_cluster.append(poi)
            else:
                clusters.append(current_cluster)
                current_cluster = [poi]

        clusters.append(current_cluster)

        # Build cluster POIs
        result: List[POI] = []
        for group in clusters:
            if len(group) == 1:
                result.append(group[0])
            else:
                result.append(self._build_cluster_poi(group, direction))
        return result

    def _build_cluster_poi(self, group: List[POI], direction: POIDirection) -> POI:
        """Combine multiple overlapping POIs into one cluster POI."""
        cluster_id = uuid.uuid4().hex[:12]
        zone_low = min(p.zone_low for p in group)
        zone_high = max(p.zone_high for p in group)

        # Aggregate score: sum of individual scores weighted by TF
        total_score = 0.0
        confluences: list = []
        timeframes_seen: set = set()
        for p in group:
            total_score += p.score
            confluences.extend(p.confluences)
            timeframes_seen.add(p.timeframe)
            p.cluster_id = cluster_id  # back-link members

        # Bonus for multi-TF alignment
        tf_bonus = len(timeframes_seen) * 3.0
        total_score += tf_bonus

        cluster_poi = POI(
            id=cluster_id,
            symbol=group[0].symbol,
            timeframe="CLUSTER",
            direction=direction,
            poi_type=POIType.CLUSTER,
            zone_low=zone_low,
            zone_high=zone_high,
            score=round(total_score, 2),
            confluences=confluences + [f"cluster_{len(group)}tf"],
            cluster_id=cluster_id,
            origin_bar_index=min(p.origin_bar_index for p in group),
        )
        return cluster_poi
