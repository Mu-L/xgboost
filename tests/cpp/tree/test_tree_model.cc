/**
 * Copyright 2018-2025, XGBoost Contributors
 */
#include <gtest/gtest.h>

#include "../../../src/common/bitfield.h"
#include "../../../src/common/categorical.h"
#include "../../../src/tree/io_utils.h"  // for DftBadValue
#include "../helpers.h"
#include "xgboost/tree_model.h"

namespace xgboost {
TEST(Tree, ModelShape) {
  bst_feature_t n_features = std::numeric_limits<uint32_t>::max();
  RegTree tree{1u, n_features};
  ASSERT_EQ(tree.NumFeatures(), n_features);

  {
    // json
    Json j_tree{Object{}};
    tree.SaveModel(&j_tree);
    std::vector<char> dumped;
    Json::Dump(j_tree, &dumped);
    RegTree new_tree;

    auto j_loaded = Json::Load(StringView{dumped.data(), dumped.size()});
    new_tree.LoadModel(j_loaded);
    ASSERT_EQ(new_tree.NumFeatures(), n_features);
  }
  {
    // ubjson
    Json j_tree{Object{}};
    tree.SaveModel(&j_tree);
    std::vector<char> dumped;
    Json::Dump(j_tree, &dumped, std::ios::binary);
    RegTree new_tree;

    auto j_loaded = Json::Load(StringView{dumped.data(), dumped.size()}, std::ios::binary);
    new_tree.LoadModel(j_loaded);
    ASSERT_EQ(new_tree.NumFeatures(), n_features);
  }
}

TEST(Tree, AllocateNode) {
  RegTree tree;
  tree.ExpandNode(0, 0, 0.0f, false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                  /*left_sum=*/0.0f, /*right_sum=*/0.0f);
  tree.CollapseToLeaf(0, 0);
  ASSERT_EQ(tree.NumExtraNodes(), 0);

  tree.ExpandNode(0, 0, 0.0f, false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                  /*left_sum=*/0.0f, /*right_sum=*/0.0f);
  ASSERT_EQ(tree.NumExtraNodes(), 2);

  auto& nodes = tree.GetNodes();
  ASSERT_FALSE(nodes.at(1).IsDeleted());
  ASSERT_TRUE(nodes.at(1).IsLeaf());
  ASSERT_TRUE(nodes.at(2).IsLeaf());
}

TEST(Tree, ExpandCategoricalFeature) {
  {
    RegTree tree;
    tree.ExpandCategorical(0, 0, {}, true, 1.0, 2.0, 3.0, 11.0, 2.0,
                           /*left_sum=*/3.0, /*right_sum=*/4.0);
    ASSERT_EQ(tree.GetNodes().size(), 3ul);
    ASSERT_EQ(tree.GetNumLeaves(), 2);
    ASSERT_EQ(tree.GetSplitTypes().size(), 3ul);
    ASSERT_EQ(tree.GetSplitTypes()[0], FeatureType::kCategorical);
    ASSERT_EQ(tree.GetSplitTypes()[1], FeatureType::kNumerical);
    ASSERT_EQ(tree.GetSplitTypes()[2], FeatureType::kNumerical);
    ASSERT_EQ(tree.GetSplitCategories().size(), 0ul);
    ASSERT_EQ(tree[0].SplitCond(), DftBadValue());
  }
  {
    RegTree tree;
    bst_cat_t cat = 33;
    std::vector<uint32_t> split_cats(LBitField32::ComputeStorageSize(cat+1));
    LBitField32 bitset {split_cats};
    bitset.Set(cat);
    tree.ExpandCategorical(0, 0, split_cats, true, 1.0, 2.0, 3.0, 11.0, 2.0,
                           /*left_sum=*/3.0, /*right_sum=*/4.0);
    auto categories = tree.GetSplitCategories();
    auto segments = tree.GetSplitCategoriesPtr();
    auto got = categories.subspan(segments[0].beg, segments[0].size);
    ASSERT_TRUE(std::equal(got.cbegin(), got.cend(), split_cats.cbegin()));

    Json out{Object()};
    tree.SaveModel(&out);

    RegTree loaded_tree;
    loaded_tree.LoadModel(out);

    auto const& cat_ptr = loaded_tree.GetSplitCategoriesPtr();
    ASSERT_EQ(cat_ptr.size(), 3ul);
    ASSERT_EQ(cat_ptr[0].beg, 0ul);
    ASSERT_EQ(cat_ptr[0].size, 2ul);

    auto loaded_categories = loaded_tree.GetSplitCategories();
    auto loaded_root = loaded_categories.subspan(cat_ptr[0].beg, cat_ptr[0].size);
    ASSERT_TRUE(std::equal(loaded_root.begin(), loaded_root.end(), split_cats.begin()));
  }
}

void GrowTree(RegTree* p_tree) {
  SimpleLCG lcg;
  size_t n_expands = 10;
  constexpr size_t kCols = 256;
  SimpleRealUniformDistribution<double> coin(0.0, 1.0);
  SimpleRealUniformDistribution<double> feat(0.0, kCols);
  SimpleRealUniformDistribution<double> split_cat(0.0, 128.0);
  SimpleRealUniformDistribution<double> split_value(0.0, kCols);

  std::stack<bst_node_t> stack;
  stack.push(RegTree::kRoot);
  auto& tree = *p_tree;

  for (size_t i = 0; i < n_expands; ++i) {
    auto is_cat = coin(&lcg) <= 0.5;
    bst_node_t node = stack.top();
    stack.pop();

    bst_feature_t f = feat(&lcg);
    if (is_cat) {
      bst_cat_t cat = common::AsCat(split_cat(&lcg));
      std::vector<uint32_t> split_cats(
          LBitField32::ComputeStorageSize(cat + 1));
      LBitField32 bitset{split_cats};
      bitset.Set(cat);
      tree.ExpandCategorical(node, f, split_cats, true, 1.0, 2.0, 3.0, 11.0, 2.0,
                             /*left_sum=*/3.0, /*right_sum=*/4.0);
    } else {
      auto split = split_value(&lcg);
      tree.ExpandNode(node, f, split, true, 1.0, 2.0, 3.0, 11.0, 2.0,
                      /*left_sum=*/3.0, /*right_sum=*/4.0);
    }

    stack.push(tree[node].LeftChild());
    stack.push(tree[node].RightChild());
  }
}

void CheckReload(RegTree const &tree) {
  Json out{Object()};
  tree.SaveModel(&out);

  RegTree loaded_tree;
  loaded_tree.LoadModel(out);
  Json saved{Object()};
  loaded_tree.SaveModel(&saved);

  ASSERT_EQ(out, saved);
}

TEST(Tree, CategoricalIO) {
  {
    RegTree tree;
    bst_cat_t cat = 32;
    std::vector<uint32_t> split_cats(LBitField32::ComputeStorageSize(cat + 1));
    LBitField32 bitset{split_cats};
    bitset.Set(cat);
    tree.ExpandCategorical(0, 0, split_cats, true, 1.0, 2.0, 3.0, 11.0, 2.0,
                           /*left_sum=*/3.0, /*right_sum=*/4.0);

    CheckReload(tree);
  }

  {
    RegTree tree;
    GrowTree(&tree);
    CheckReload(tree);
  }
}

namespace {
RegTree ConstructTree() {
  RegTree tree;
  tree.ExpandNode(
      /*nid=*/0, /*split_index=*/0, /*split_value=*/0.0f,
      /*default_left=*/true, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, /*left_sum=*/0.0f,
      /*right_sum=*/0.0f);
  auto left = tree[0].LeftChild();
  auto right = tree[0].RightChild();
  tree.ExpandNode(
      /*nid=*/left, /*split_index=*/1, /*split_value=*/1.0f,
      /*default_left=*/false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, /*left_sum=*/0.0f,
      /*right_sum=*/0.0f);
  tree.ExpandNode(
      /*nid=*/right, /*split_index=*/2, /*split_value=*/2.0f,
      /*default_left=*/false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, /*left_sum=*/0.0f,
      /*right_sum=*/0.0f);
  return tree;
}

RegTree ConstructTreeCat(std::vector<bst_cat_t>* cond) {
  RegTree tree;
  std::vector<uint32_t> cats_storage(common::CatBitField::ComputeStorageSize(33), 0);
  common::CatBitField split_cats(cats_storage);
  split_cats.Set(0);
  split_cats.Set(14);
  split_cats.Set(32);

  cond->push_back(0);
  cond->push_back(14);
  cond->push_back(32);

  tree.ExpandCategorical(0, /*split_index=*/0, cats_storage, true, 0.0f, 2.0,
                         3.00, 11.0, 2.0, 3.0, 4.0);
  auto left = tree[0].LeftChild();
  auto right = tree[0].RightChild();
  tree.ExpandNode(
      /*nid=*/left, /*split_index=*/1, /*split_value=*/1.0f,
      /*default_left=*/false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, /*left_sum=*/0.0f,
      /*right_sum=*/0.0f);
  tree.ExpandCategorical(right, /*split_index=*/0, cats_storage, true, 0.0f,
                         2.0, 3.00, 11.0, 2.0, 3.0, 4.0);
  return tree;
}

void TestCategoricalTreeDump(std::string format, std::string sep) {
  std::vector<bst_cat_t> cond;
  auto tree = ConstructTreeCat(&cond);

  FeatureMap fmap;
  auto str = tree.DumpModel(fmap, true, format);
  std::string cond_str;
  for (size_t c = 0; c < cond.size(); ++c) {
    cond_str += std::to_string(cond[c]);
    if (c != cond.size() - 1) {
      cond_str += sep;
    }
  }
  auto pos = str.find(cond_str);
  ASSERT_NE(pos, std::string::npos);
  pos = str.find(cond_str, pos + 1);
  ASSERT_NE(pos, std::string::npos);

  fmap.PushBack(0, "feat_0", "c");
  fmap.PushBack(1, "feat_1", "q");
  fmap.PushBack(2, "feat_2", "int");

  str = tree.DumpModel(fmap, true, format);
  pos = str.find(cond_str);
  ASSERT_NE(pos, std::string::npos);
  pos = str.find(cond_str, pos + 1);
  ASSERT_NE(pos, std::string::npos);
  ASSERT_NE(str.find("gain"), std::string::npos);

  if (format == "json") {
    // Make sure it's valid JSON
    Json::Load(StringView{str});
  }
}
}  // anonymous namespace

TEST(Tree, DumpJson) {
  auto tree = ConstructTree();
  FeatureMap fmap;
  auto str = tree.DumpModel(fmap, true, "json");
  size_t n_leaves = 0;
  size_t iter = 0;
  while ((iter = str.find("leaf", iter + 1)) != std::string::npos) {
    n_leaves++;
  }
  ASSERT_EQ(n_leaves, 4ul);

  size_t n_conditions = 0;
  iter = 0;
  while ((iter = str.find("split_condition", iter + 1)) != std::string::npos) {
    n_conditions++;
  }
  ASSERT_EQ(n_conditions, 3ul);

  fmap.PushBack(0, "feat_0", "i");
  fmap.PushBack(1, "feat_1", "q");
  fmap.PushBack(2, "feat_2", "int");

  str = tree.DumpModel(fmap, true, "json");
  ASSERT_NE(str.find(R"("split": "feat_0")"), std::string::npos);
  ASSERT_NE(str.find(R"("split": "feat_1")"), std::string::npos);
  ASSERT_NE(str.find(R"("split": "feat_2")"), std::string::npos);

  str = tree.DumpModel(fmap, false, "json");
  ASSERT_EQ(str.find("cover"), std::string::npos);


  auto j_tree = Json::Load({str.c_str(), str.size()});
  ASSERT_EQ(get<Array>(j_tree["children"]).size(), 2ul);
}

TEST(Tree, DumpJsonCategorical) {
  TestCategoricalTreeDump("json", ", ");
}

TEST(Tree, DumpText) {
  auto tree = ConstructTree();
  FeatureMap fmap;
  auto str = tree.DumpModel(fmap, true, "text");
  size_t n_leaves = 0;
  size_t iter = 0;
  while ((iter = str.find("leaf", iter + 1)) != std::string::npos) {
    n_leaves++;
  }
  ASSERT_EQ(n_leaves, 4ul);

  iter = 0;
  size_t n_conditions = 0;
  while ((iter = str.find("gain", iter + 1)) != std::string::npos) {
    n_conditions++;
  }
  ASSERT_EQ(n_conditions, 3ul);

  ASSERT_NE(str.find("[f0<0]"), std::string::npos) << str;
  ASSERT_NE(str.find("[f1<1]"), std::string::npos);
  ASSERT_NE(str.find("[f2<2]"), std::string::npos);

  fmap.PushBack(0, "feat_0", "i");
  fmap.PushBack(1, "feat_1", "q");
  fmap.PushBack(2, "feat_2", "int");

  str = tree.DumpModel(fmap, true, "text");
  ASSERT_NE(str.find("[feat_0]"), std::string::npos);
  ASSERT_NE(str.find("[feat_1<1]"), std::string::npos);
  ASSERT_NE(str.find("[feat_2<2]"), std::string::npos);

  str = tree.DumpModel(fmap, false, "text");
  ASSERT_EQ(str.find("cover"), std::string::npos);
}

TEST(Tree, DumpTextCategorical) {
  TestCategoricalTreeDump("text", ",");
}

TEST(Tree, DumpDot) {
  auto tree = ConstructTree();
  FeatureMap fmap;
  auto str = tree.DumpModel(fmap, true, "dot");

  size_t n_leaves = 0;
  size_t iter = 0;
  while ((iter = str.find("leaf", iter + 1)) != std::string::npos) {
    n_leaves++;
  }
  ASSERT_EQ(n_leaves, 4ul);

  size_t n_edges = 0;
  iter = 0;
  while ((iter = str.find("->", iter + 1)) != std::string::npos) {
    n_edges++;
  }
  ASSERT_EQ(n_edges, 6ul);

  fmap.PushBack(0, "feat_0", "i");
  fmap.PushBack(1, "feat_1", "q");
  fmap.PushBack(2, "feat_2", "int");

  str = tree.DumpModel(fmap, true, "dot");
  ASSERT_NE(str.find(R"("feat_0)"), std::string::npos);
  ASSERT_EQ(str.find(R"("feat_0")"), std::string::npos);  // newline
  ASSERT_NE(str.find(R"(feat_1<1)"), std::string::npos);
  ASSERT_NE(str.find(R"(feat_2<2)"), std::string::npos);

  str = tree.DumpModel(fmap, true, R"(dot:{"graph_attrs": {"bgcolor": "#FFFF00"}})");
  ASSERT_NE(str.find(R"(graph [ bgcolor="#FFFF00" ])"), std::string::npos);

  // Default left for root.
  ASSERT_NE(str.find(R"(0 -> 1 [label="yes, missing")"), std::string::npos);
  // Default right for node 1
  ASSERT_NE(str.find(R"(1 -> 4 [label="no, missing")"), std::string::npos);
}

TEST(Tree, DumpDotCategorical) {
  TestCategoricalTreeDump("dot", ",");
}

TEST(Tree, JsonIO) {
  RegTree tree;
  tree.ExpandNode(0, 0, 0.0f, false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                  /*left_sum=*/0.0f, /*right_sum=*/0.0f);
  Json j_tree{Object()};
  tree.SaveModel(&j_tree);

  auto tparam = j_tree["tree_param"];
  ASSERT_EQ(get<String>(tparam["num_feature"]), "0");
  ASSERT_EQ(get<String>(tparam["num_nodes"]), "3");
  ASSERT_EQ(get<String>(tparam["size_leaf_vector"]), "1");

  ASSERT_EQ(get<I32Array const>(j_tree["left_children"]).size(), 3ul);
  ASSERT_EQ(get<I32Array const>(j_tree["right_children"]).size(), 3ul);
  ASSERT_EQ(get<I32Array const>(j_tree["parents"]).size(), 3ul);
  ASSERT_EQ(get<I32Array const>(j_tree["split_indices"]).size(), 3ul);
  ASSERT_EQ(get<F32Array const>(j_tree["split_conditions"]).size(), 3ul);
  ASSERT_EQ(get<U8Array const>(j_tree["default_left"]).size(), 3ul);

  RegTree loaded_tree;
  loaded_tree.LoadModel(j_tree);
  ASSERT_EQ(loaded_tree.NumNodes(), 3);
  ASSERT_TRUE(loaded_tree == tree);

  auto left = tree[0].LeftChild();
  auto right = tree[0].RightChild();
  tree.ExpandNode(left, 0, 0.0f, false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                  /*left_sum=*/0.0f, /*right_sum=*/0.0f);
  tree.ExpandNode(right, 0, 0.0f, false, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                  /*left_sum=*/0.0f, /*right_sum=*/0.0f);
  tree.SaveModel(&j_tree);

  tree.ChangeToLeaf(1, 1.0f);
  ASSERT_EQ(tree[1].LeftChild(), -1);
  ASSERT_EQ(tree[1].RightChild(), -1);
  tree.SaveModel(&j_tree);
  loaded_tree.LoadModel(j_tree);
  ASSERT_EQ(loaded_tree[1].LeftChild(), -1);
  ASSERT_EQ(loaded_tree[1].RightChild(), -1);
  ASSERT_TRUE(tree.Equal(loaded_tree));
}
}  // namespace xgboost
