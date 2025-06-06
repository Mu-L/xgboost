/*
 Copyright (c) 2025 by Contributors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

package ml.dmlc.xgboost4j.scala

import java.io.File

import scala.collection.mutable.ArrayBuffer

import ai.rapids.cudf.Table
import org.scalatest.funsuite.AnyFunSuite

import ml.dmlc.xgboost4j.java.{ColumnBatch, CudfColumnBatch}
import ml.dmlc.xgboost4j.scala.rapids.spark.TmpFolderSuite
import ml.dmlc.xgboost4j.scala.spark.{ColumnIndices, ExternalMemoryIterator, GpuColumnBatch}
import ml.dmlc.xgboost4j.scala.spark.Utils.withResource

class ExtMemQuantileDMatrixSuite extends AnyFunSuite with TmpFolderSuite {

  private def runTest(buildIterator: (Iterator[Table], ColumnIndices) => Iterator[ColumnBatch]) = {
    val label1 = Array[java.lang.Float](25f, 21f, 22f, 20f, 24f)
    val weight1 = Array[java.lang.Float](1.3f, 2.31f, 0.32f, 3.3f, 1.34f)
    val baseMargin1 = Array[java.lang.Float](1.2f, 0.2f, 1.3f, 2.4f, 3.5f)
    val group1 = Array[java.lang.Integer](1, 1, 7, 7, 19, 26)

    val label2 = Array[java.lang.Float](9f, 5f, 4f, 10f, 12f)
    val weight2 = Array[java.lang.Float](3.0f, 1.3f, 3.2f, 0.3f, 1.34f)
    val baseMargin2 = Array[java.lang.Float](0.2f, 2.5f, 3.1f, 4.4f, 2.2f)
    val group2 = Array[java.lang.Integer](30, 30, 30, 40, 40)

    val expectedGroup = Array(0, 2, 4, 5, 6, 9, 11)

    withResource(new Table.TestBuilder()
      .column(1.2f, null.asInstanceOf[java.lang.Float], 5.2f, 7.2f, 9.2f)
      .column(0.2f, 0.4f, 0.6f, 2.6f, 0.10f.asInstanceOf[java.lang.Float])
      .build) { X_0 =>
      withResource(new Table.TestBuilder().column(label1: _*).build) { y_0 =>
        withResource(new Table.TestBuilder().column(weight1: _*).build) { w_0 =>
          withResource(new Table.TestBuilder().column(baseMargin1: _*).build) { m_0 =>
            withResource(new Table.TestBuilder().column(group1: _*).build) { q_0 =>
              withResource(new Table.TestBuilder()
                .column(11.2f, 11.2f, 15.2f, 17.2f, 19.2f.asInstanceOf[java.lang.Float])
                .column(1.2f, 1.4f, null.asInstanceOf[java.lang.Float], 12.6f, 10.10f).build) {
                X_1 =>
                  withResource(new Table.TestBuilder().column(label2: _*).build) { y_1 =>
                    withResource(new Table.TestBuilder().column(weight2: _*).build) { w_1 =>
                      withResource(new Table.TestBuilder().column(baseMargin2: _*).build) { m_1 =>
                        withResource(new Table.TestBuilder().column(group2: _*).build) { q_2 =>
                          val tables = new ArrayBuffer[Table]()
                          tables += new Table(X_0.getColumn(0), X_0.getColumn(1), y_0.getColumn(0),
                            w_0.getColumn(0), m_0.getColumn(0))
                          tables += new Table(X_1.getColumn(0), X_1.getColumn(1), y_1.getColumn(0),
                            w_1.getColumn(0), m_1.getColumn(0))

                          val indices = ColumnIndices(
                            labelId = 2,
                            featureId = None,
                            featureIds = Option(Seq(0, 1)),
                            weightId = Option(3),
                            marginId = Option(4),
                            groupId = Option(5)
                          )
                          val iter = buildIterator(tables.toIterator, indices);
                          val dmatrix = new ExtMemQuantileDMatrix(iter, 0.0f, 8)

                          def check(dm: ExtMemQuantileDMatrix) = {
                            assert(dm.getLabel.sameElements(label1 ++ label2))
                            assert(dm.getWeight.sameElements(weight1 ++ weight2))
                            assert(dm.getBaseMargin.sameElements(baseMargin1 ++ baseMargin2))
                          }
                          check(dmatrix)
                        }
                      }
                    }
                  }
              }
            }
          }
        }
      }
    }
  }

  test("ExtMemQuantileDMatrix test") {
    val buildIter = (input: Iterator[Table], indices: ColumnIndices) =>
    new ExternalMemoryIterator(
      input, indices, Option(new File(tempDir.toFile, "xgboost").getPath)
    )
    runTest(buildIter)
  }
}
