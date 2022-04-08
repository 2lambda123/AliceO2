// Copyright 2019-2020 CERN and copyright holders of ALICE O2.
// See https://alice-o2.web.cern.ch/copyright for details of the copyright holders.
// All rights not expressly granted are reserved.
//
// This software is distributed under the terms of the GNU General Public
// License v3 (GPL Version 3), copied verbatim in the file "COPYING".
//
// In applying this license CERN does not waive the privileges and immunities
// granted to it by virtue of its status as an Intergovernmental Organization
// or submit itself to any jurisdiction.
///

#include "fairlogger/Logger.h"

#include "ITStracking/Constants.h"

#include "ITStrackingGPU/Utils.h"
#include "ITStrackingGPU/TimeFrameGPU.h"

namespace o2
{
namespace its
{
using constants::MB;
namespace gpu
{

GPUh() void gpuThrowOnError()
{
  cudaError_t error = cudaGetLastError();

  if (error != cudaSuccess) {
    std::ostringstream errorString{};
    errorString << GPU_ARCH << " API returned error  [" << cudaGetErrorString(error) << "] (code " << error << ")" << std::endl;
    throw std::runtime_error{errorString.str()};
  }
}

template <int NLayers>
TimeFrameGPU<NLayers>::TimeFrameGPU()
{
  for (int iLayer{0}; iLayer < NLayers; ++iLayer) { // Tracker and vertexer
    mClustersD[iLayer] = Vector<Cluster>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity};
    mTrackingFrameInfoD[iLayer] = Vector<TrackingFrameInfo>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity};
    mClusterExternalIndicesD[iLayer] = Vector<int>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity};
    mROframesClustersD[iLayer] = Vector<int>{mConfig.clustersPerROfCapacity, mConfig.clustersPerROfCapacity};
    if (iLayer < NLayers - 1) {
      mTrackletsD[iLayer] = Vector<Tracklet>{mConfig.trackletsCapacity,
                                             mConfig.trackletsCapacity};
    }
  }

  for (auto iComb{0}; iComb < 2; ++iComb) { // Vertexer only
    mNTrackletsPerClusterD[iComb] = Vector<int>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity};
  }
  mIndexTablesLayer0D = Vector<int>{mConfig.nMaxROFs * (ZBins * PhiBins + 1), mConfig.nMaxROFs * (ZBins * PhiBins + 1)};
  mIndexTablesLayer2D = Vector<int>{mConfig.nMaxROFs * (ZBins * PhiBins + 1), mConfig.nMaxROFs * (ZBins * PhiBins + 1)};
  mLines = Vector<Line>{mConfig.trackletsCapacity, mConfig.trackletsCapacity};
  // mNFoundLines = Vector<int>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity};          // 4e4 * sizeof(int) = 160KB
  // mNExclusiveFoundLines = Vector<int>{mConfig.clustersPerLayerCapacity, mConfig.clustersPerLayerCapacity}; // 4e4 * sizeof(int) = 160KB, tot = <10MB
  getDeviceMemory();
}

template <int NLayers>
float TimeFrameGPU<NLayers>::getDeviceMemory()
{
  float totalMemory{0};
  totalMemory += NLayers * mConfig.clustersPerLayerCapacity * sizeof(Cluster);
  totalMemory += NLayers * mConfig.clustersPerLayerCapacity * sizeof(TrackingFrameInfo);
  totalMemory += NLayers * mConfig.clustersPerLayerCapacity * sizeof(int);
  totalMemory += NLayers * mConfig.clustersPerROfCapacity * sizeof(int);
  totalMemory += (NLayers - 1) * mConfig.trackletsCapacity * sizeof(Tracklet);
  totalMemory += 2 * mConfig.clustersPerLayerCapacity * sizeof(int);
  totalMemory += 2 * mConfig.nMaxROFs * (ZBins * PhiBins + 1) * sizeof(int);

  LOGP(info, "Total requested memory for GPU: {:.2f} MB", totalMemory / MB);
  LOGP(info, "\t- clusters: {:.2f} MB", NLayers * mConfig.clustersPerLayerCapacity * sizeof(Cluster) / MB);
  LOGP(info, "\t- tracking frame info: {:.2f} MB", NLayers * mConfig.clustersPerLayerCapacity * sizeof(TrackingFrameInfo) / MB);
  LOGP(info, "\t- cluster external indices: {:.2f} MB", NLayers * mConfig.clustersPerLayerCapacity * sizeof(int) / MB);
  LOGP(info, "\t- clusters per ROf: {:.2f} MB", NLayers * mConfig.clustersPerROfCapacity * sizeof(int) / MB);
  LOGP(info, "\t- tracklets: {:.2f} MB", (NLayers - 1) * mConfig.trackletsCapacity * sizeof(Tracklet) / MB);
  LOGP(info, "\t- n tracklets per cluster: {:.2f} MB", 2 * mConfig.clustersPerLayerCapacity * sizeof(int) / MB);
  LOGP(info, "\t- index tables: {:.2f} MB", 2 * mConfig.nMaxROFs * (ZBins * PhiBins + 1) * sizeof(int) / MB);

  return totalMemory;
}

template <int NLayers>
void TimeFrameGPU<NLayers>::loadToDevice(const int maxLayers)
{
  for (int iLayer{0}; iLayer < maxLayers; ++iLayer) {
    mClustersD[iLayer].reset(mClusters[iLayer].data(), static_cast<int>(mClusters[iLayer].size()));
    mROframesClustersD[iLayer].reset(mROframesClusters[iLayer].data(), static_cast<int>(mROframesClusters[iLayer].size()));
  }
  if (maxLayers == NLayers) {
    // Tracker-only: we don't need to copy data in vertexer
    for (int iLayer{0}; iLayer < maxLayers; ++iLayer) {
      mTrackingFrameInfoD[iLayer].reset(mTrackingFrameInfo[iLayer].data(), static_cast<int>(mTrackingFrameInfo[iLayer].size()));
      mClusterExternalIndicesD[iLayer].reset(mClusterExternalIndices[iLayer].data(), static_cast<int>(mClusterExternalIndices[iLayer].size()));
    }
  } else {
    // flatten vector of vectors into single buffer
    std::vector<int> flatTables0, flatTables2;
    flatTables0.reserve(mConfig.nMaxROFs * (ZBins * PhiBins + 1));
    flatTables2.reserve(mConfig.nMaxROFs * (ZBins * PhiBins + 1));
    for (size_t rofId{0}; rofId < mNrof; ++rofId) {
      const auto& v0 = mIndexTablesL0[rofId];
      const auto& v2 = mIndexTables[rofId][1];
      flatTables0.insert(flatTables0.end(), v0.begin(), v0.end());
      flatTables2.insert(flatTables2.end(), v2.begin(), v2.end());
    }
    mIndexTablesLayer0D.reset(flatTables0.data(), static_cast<int>(flatTables0.size()));
    mIndexTablesLayer2D.reset(flatTables2.data(), static_cast<int>(flatTables2.size()));
  }
  gpuThrowOnError();
}

template <int NLayers>
void TimeFrameGPU<NLayers>::initialise(const int iteration,
                                       const MemoryParameters& memParam,
                                       const TrackingParameters& trkParam,
                                       const int maxLayers)
{
  o2::its::TimeFrame::initialise(iteration, memParam, trkParam, maxLayers);
  checkBufferSizes();
  loadToDevice(maxLayers);
}

template <int NLayers>
TimeFrameGPU<NLayers>::~TimeFrameGPU()
{
}

template <int NLayers>
void TimeFrameGPU<NLayers>::checkBufferSizes()
{
  for (int iLayer{0}; iLayer < NLayers; ++iLayer) {
    if (mClusters[iLayer].size() > mConfig.clustersPerLayerCapacity) {
      LOGP(error, "Number of clusters on layer {} is {} and exceeds the GPU configuration defined one: {}", iLayer, mClusters[iLayer].size(), mConfig.clustersPerLayerCapacity);
    }
    if (mTrackingFrameInfo[iLayer].size() > mConfig.clustersPerLayerCapacity) {
      LOGP(error, "Number of tracking frame info on layer {} is {} and exceeds the GPU configuration defined one: {}", iLayer, mTrackingFrameInfo[iLayer].size(), mConfig.clustersPerLayerCapacity);
    }
    if (mClusterExternalIndices[iLayer].size() > mConfig.clustersPerLayerCapacity) {
      LOGP(error, "Number of external indices on layer {} is {} and exceeds the GPU configuration defined one: {}", iLayer, mClusterExternalIndices[iLayer].size(), mConfig.clustersPerLayerCapacity);
    }
    if (mROframesClusters[iLayer].size() > mConfig.clustersPerROfCapacity) {
      LOGP(error, "Size of clusters per roframe on layer {} is {} and exceeds the GPU configuration defined one: {}", iLayer, mROframesClusters[iLayer].size(), mConfig.clustersPerROfCapacity);
    }
  }
  if (mNrof > mConfig.nMaxROFs) {
    LOGP(error, "Number of ROFs in timeframe is {} and exceeds the GPU configuration defined one: {}", mNrof, mConfig.nMaxROFs);
  }
}
template class TimeFrameGPU<7>;
} // namespace gpu
} // namespace its
} // namespace o2