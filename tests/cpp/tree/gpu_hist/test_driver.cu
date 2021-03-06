#include <gtest/gtest.h>
#include "../../../../src/tree/driver.h"
#include "../../../../src/tree/gpu_hist/expand_entry.cuh"

namespace xgboost {
namespace tree {

TEST(GpuHist, DriverDepthWise) {
  Driver<GPUExpandEntry> driver(TrainParam::kDepthWise);
  EXPECT_TRUE(driver.Pop().empty());
  DeviceSplitCandidate split;
  split.loss_chg = 1.0f;
  GPUExpandEntry root(0, 0, split, .0f, .0f, .0f);
  driver.Push({root});
  EXPECT_EQ(driver.Pop().front().nid, 0);
  driver.Push({GPUExpandEntry{1, 1, split, .0f, .0f, .0f}});
  driver.Push({GPUExpandEntry{2, 1, split, .0f, .0f, .0f}});
  driver.Push({GPUExpandEntry{3, 2, split, .0f, .0f, .0f}});
  // Should return entries from level 1
  auto res = driver.Pop();
  EXPECT_EQ(res.size(), 2);
  for (auto &e : res) {
    EXPECT_EQ(e.depth, 1);
  }
  res = driver.Pop();
  EXPECT_EQ(res[0].depth, 2);
  EXPECT_TRUE(driver.Pop().empty());
}

TEST(GpuHist, DriverLossGuided) {
  DeviceSplitCandidate high_gain;
  high_gain.loss_chg = 5.0f;
  DeviceSplitCandidate low_gain;
  low_gain.loss_chg = 1.0f;

  Driver<GPUExpandEntry> driver(TrainParam::kLossGuide);
  EXPECT_TRUE(driver.Pop().empty());
  GPUExpandEntry root(0, 0, high_gain, .0f, .0f, .0f);
  driver.Push({root});
  EXPECT_EQ(driver.Pop().front().nid, 0);
  // Select high gain first
  driver.Push({GPUExpandEntry{1, 1, low_gain, .0f, .0f, .0f}});
  driver.Push({GPUExpandEntry{2, 2, high_gain, .0f, .0f, .0f}});
  auto res = driver.Pop();
  EXPECT_EQ(res.size(), 1);
  EXPECT_EQ(res[0].nid, 2);
  res = driver.Pop();
  EXPECT_EQ(res.size(), 1);
  EXPECT_EQ(res[0].nid, 1);

  // If equal gain, use nid
  driver.Push({GPUExpandEntry{2, 1, low_gain, .0f, .0f, .0f}});
  driver.Push({GPUExpandEntry{1, 1, low_gain, .0f, .0f, .0f}});
  res = driver.Pop();
  EXPECT_EQ(res[0].nid, 1);
  res = driver.Pop();
  EXPECT_EQ(res[0].nid, 2);
}
}  // namespace tree
}  // namespace xgboost
