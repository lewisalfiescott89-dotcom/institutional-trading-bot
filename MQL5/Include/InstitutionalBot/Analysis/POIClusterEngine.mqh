//+------------------------------------------------------------------+
//| POIClusterEngine.mqh - Merges overlapping POIs into clusters     |
//+------------------------------------------------------------------+
#ifndef POI_CLUSTER_ENGINE_MQH
#define POI_CLUSTER_ENGINE_MQH

#include "../Core/Utils.mqh"
#include "../Models/POI.mqh"
#include "../Config.mqh"

class CPOIClusterEngine
{
private:
   double m_overlap_pct;

public:
   CPOIClusterEngine(double overlap_pct = 0.3) : m_overlap_pct(overlap_pct) {}

   //--- Cluster overlapping POIs, returns new count
   int Cluster(POIData &pois[], int count)
   {
      if(count <= 1) return count;

      // Mark cluster assignments
      int cluster_ids[];
      ArrayResize(cluster_ids, count);
      for(int i = 0; i < count; i++) cluster_ids[i] = i;

      // Union-find style clustering
      for(int i = 0; i < count; i++)
      {
         if(!pois[i].active) continue;
         for(int j = i + 1; j < count; j++)
         {
            if(!pois[j].active) continue;
            // Same direction only
            if(pois[i].direction != pois[j].direction) continue;

            double overlap = OverlapPct(pois[i].zone_low, pois[i].zone_high,
                                        pois[j].zone_low, pois[j].zone_high);
            if(overlap >= m_overlap_pct)
            {
               // Merge j into i's cluster
               int root_i = FindRoot(cluster_ids, i);
               int root_j = FindRoot(cluster_ids, j);
               if(root_i != root_j)
                  cluster_ids[root_j] = root_i;
            }
         }
      }

      // Merge clusters: expand zone, combine scores
      for(int i = 0; i < count; i++)
      {
         int root = FindRoot(cluster_ids, i);
         if(root != i && pois[i].active)
         {
            // Merge into root
            pois[root].zone_low  = MathMin(pois[root].zone_low, pois[i].zone_low);
            pois[root].zone_high = MathMax(pois[root].zone_high, pois[i].zone_high);
            pois[root].score    += pois[i].score * 0.5;
            pois[root].AddConfluence("cluster_" + TimeframeToString(pois[i].timeframe));

            // Deactivate merged POI
            pois[i].active = false;
         }
      }

      // Compact active POIs
      int new_count = 0;
      for(int i = 0; i < count; i++)
      {
         if(pois[i].active)
         {
            if(new_count != i)
               pois[new_count] = pois[i];
            new_count++;
         }
      }
      return new_count;
   }

private:
   int FindRoot(int &ids[], int i)
   {
      while(ids[i] != i) i = ids[i];
      return i;
   }
};

#endif
