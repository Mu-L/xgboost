########################
XGBoost4J-Spark Tutorial
########################

**XGBoost4J-Spark** is a project aiming to seamlessly integrate XGBoost and Apache Spark by fitting XGBoost to
Apache Spark's MLLIB framework. With the integration, user can not only uses the high-performant algorithm
implementation of XGBoost, but also leverages the powerful data processing engine of Spark for:

* Feature Engineering: feature extraction, transformation, dimensionality reduction, and selection, etc.
* Pipelines: constructing, evaluating, and tuning ML Pipelines
* Persistence: persist and load machine learning models and even whole Pipelines

This tutorial is to cover the end-to-end process to build a machine learning pipeline with XGBoost4J-Spark. We will discuss

* Using Spark to preprocess data to fit to XGBoost4J-Spark's data interface
* Training a XGBoost model with XGBoost4J-Spark
* Serving XGBoost model (prediction) with Spark
* Building a Machine Learning Pipeline with XGBoost4J-Spark
* Running XGBoost4J-Spark in Production

.. contents::
  :backlinks: none
  :local:

********************************************
Build an ML Application with XGBoost4J-Spark
********************************************

Refer to XGBoost4J-Spark Dependency
===================================

Before we go into the tour of how to use XGBoost4J-Spark, you should first consult :ref:`Installation from Maven repository <install_jvm_packages>`
in order to add XGBoost4J-Spark as a dependency for your project. We provide both stable releases and snapshots.

.. note:: XGBoost4J-Spark requires Apache Spark 3.0+

  XGBoost4J-Spark now requires **Apache Spark 3.0+**. Latest versions of XGBoost4J-Spark uses facilities of `org.apache.spark.ml.param.shared`
  extensively to provide for a tight integration with Spark MLLIB framework, and these facilities are not fully available on earlier versions of Spark.

  Also, make sure to install Spark directly from `Apache website <https://spark.apache.org/>`_. **Upstream XGBoost is not guaranteed to
  work with third-party distributions of Spark, such as Cloudera Spark.** Consult appropriate third parties to obtain their distribution of XGBoost.

Data Preparation
================

As aforementioned, XGBoost4J-Spark seamlessly integrates Spark and XGBoost. The integration enables
users to apply various types of transformation over the training/test datasets with the convenient
and powerful data processing framework: Spark.

In this section, we use `Iris <https://archive.ics.uci.edu/ml/datasets/iris>`_ dataset as an example to
showcase how we use Spark to transform raw dataset and make it fit to the data interface of XGBoost.

Iris dataset is shipped in CSV format. Each instance contains 4 features, "sepal length", "sepal width",
"petal length" and "petal width". In addition, it contains the "class" column, which is essentially the
label with three possible values: "Iris Setosa", "Iris Versicolour" and "Iris Virginica".

Read Dataset with Spark's Built-In Reader
-----------------------------------------

The first thing in data transformation is to load the dataset as Spark's structured data abstraction, DataFrame.

.. code-block:: scala

  import org.apache.spark.sql.SparkSession
  import org.apache.spark.sql.types.{DoubleType, StringType, StructField, StructType}

  val spark = SparkSession.builder().getOrCreate()
  val schema = new StructType(Array(
    StructField("sepal length", DoubleType, true),
    StructField("sepal width", DoubleType, true),
    StructField("petal length", DoubleType, true),
    StructField("petal width", DoubleType, true),
    StructField("class", StringType, true)))
  val rawInput = spark.read.schema(schema).csv("input_path")

At the first line, we create a instance of `SparkSession <https://spark.apache.org/docs/latest/sql-getting-started.html#starting-point-sparksession>`_
which is the entry of any Spark program working with DataFrame. The ``schema`` variable defines the schema of DataFrame wrapping Iris data.
With this explicitly set schema, we can define the columns' name as well as their types; otherwise the column name would be the default ones
derived by Spark, such as ``_col0``, etc. Finally, we can use Spark's built-in csv reader to load Iris csv file as a DataFrame named ``rawInput``.

Spark also contains many built-in readers for other format. The latest version of Spark supports CSV, JSON, Parquet, and LIBSVM.

Transform Raw Iris Dataset
--------------------------

To make Iris dataset be recognizable to XGBoost, we need to

1. Transform String-typed label, i.e. "class", to Double-typed label.
2. Assemble the feature columns as a vector to fit to the data interface of Spark ML framework.

To convert String-typed label to Double, we can use Spark's built-in feature transformer
`StringIndexer <https://spark.apache.org/docs/latest/api/scala/org/apache/spark/ml/feature/StringIndexer.html>`_.

.. code-block:: scala

  import org.apache.spark.ml.feature.StringIndexer
  val stringIndexer = new StringIndexer().
    setInputCol("class").
    setOutputCol("classIndex").
    fit(rawInput)
  val labelTransformed = stringIndexer.transform(rawInput).drop("class")

With a newly created StringIndexer instance:

1. we set input column, i.e. the column containing String-typed label.
2. we set output column, i.e. the column containing the Double-typed label.
3. Then we ``fit`` StringIndex with our input DataFrame ``rawInput``, so that Spark internals can get information like total number of distinct values, etc.

Now we have a StringIndexer which is ready to be applied to our input DataFrame. To execute the transformation logic of StringIndexer,
we ``transform`` the input DataFrame ``rawInput`` and to keep a concise DataFrame,
we drop the column "class" and only keeps the feature columns and the transformed Double-typed label column (in the last line of the above code snippet).

The ``fit`` and ``transform`` are two key operations in MLLIB. Basically, ``fit`` produces a "transformer", e.g. StringIndexer,
and each transformer applies ``transform`` method on DataFrame to add new column(s) containing transformed features/labels or
prediction results, etc. To understand more about ``fit`` and ``transform``, You can find more details in
`here <http://spark.apache.org/docs/latest/ml-pipeline.html#pipeline-components>`_.

Similarly, we can use another transformer, `VectorAssembler <https://spark.apache.org/docs/latest/api/scala/org/apache/spark/ml/feature/VectorAssembler.html>`_,
to assemble feature columns "sepal length", "sepal width", "petal length" and "petal width" as a vector.

.. code-block:: scala

  import org.apache.spark.ml.feature.VectorAssembler
  val vectorAssembler = new VectorAssembler().
    setInputCols(Array("sepal length", "sepal width", "petal length", "petal width")).
    setOutputCol("features")
  val xgbInput = vectorAssembler.transform(labelTransformed).select("features", "classIndex")

Now, we have a DataFrame containing only two columns, "features" which contains vector-represented
"sepal length", "sepal width", "petal length" and "petal width" and "classIndex" which has Double-typed
labels. A DataFrame like this (containing vector-represented features and numeric labels) can be fed to XGBoost4J-Spark's training engine directly.

Dealing with missing values
~~~~~~~~~~~~~~~~~~~~~~~~~~~

XGBoost supports missing values by default (`as desribed here <https://xgboost.readthedocs.io/en/latest/faq.html#how-to-deal-with-missing-values>`_).
If given a SparseVector, XGBoost will treat any values absent from the SparseVector as missing. You are also able to
specify to XGBoost to treat a specific value in your Dataset as if it was a missing value. By default XGBoost will treat NaN as the value representing missing.

Example of setting a missing value (e.g. -999) to the "missing" parameter in XGBoostClassifier:

.. code-block:: scala

  import ml.dmlc.xgboost4j.scala.spark.XGBoostClassifier
  val xgbParam = Map("eta" -> 0.1f,
        "missing" -> -999,
        "objective" -> "multi:softprob",
        "num_class" -> 3,
        "num_round" -> 100,
        "num_workers" -> 2)
  val xgbClassifier = new XGBoostClassifier(xgbParam).
        setFeaturesCol("features").
        setLabelCol("classIndex")

.. note:: Missing values

  If the feature is vector type, the single feature instance could be a SparseVector, where "0" will be treated as the missing value.
  In order to get the correct model, XGBoost4j-Spark will convert the SparseVector to array by restoring the "0". However, we can't
  assume 0 for missing values as it may be meaningful. So in this case, users need to specify the missing value explicitly
  even the missing value has been set to `Float.NaN` by default in the XGBoost4j-Spark.

Training
========

XGBoost supports regression, classification and ranking. While we use Iris dataset in this tutorial to show how we
use XGBoost4J-Spark to resolve a multi-classes classification problem, the usage in Regression and Ranking is very similar to classification.

To train a XGBoost model for classification, we need to create a XGBoostClassifier first:

.. code-block:: scala

  import ml.dmlc.xgboost4j.scala.spark.XGBoostClassifier
  val xgbParam = Map("eta" -> 0.1f,
        "max_depth" -> 2,
        "objective" -> "multi:softprob",
        "num_class" -> 3)
  val xgbClassifier = new XGBoostClassifier(xgbParam).
        setNumRound(100).
        setNumWorkers(2).
        setFeaturesCol("features").
        setLabelCol("classIndex")

The available parameters for training a XGBoost model can be found in :doc:`here </parameter>`. In XGBoost4J-Spark, we support
not only the default set of parameters but also the camel-case variant of these parameters to keep consistent with Spark's MLLIB parameters.

Specifically, each parameter in :doc:`this page </parameter>` has its
equivalent form in XGBoost4J-Spark with camel case. For example, to set ``max_depth`` for each tree, you can pass parameter just
like what we did in the above code snippet (as ``max_depth`` wrapped in a Map), or you can do it through setters in XGBoostClassifer:

.. code-block:: scala

  val xgbClassifier = new XGBoostClassifier().
    setFeaturesCol("features").
    setLabelCol("classIndex")
  xgbClassifier.setMaxDepth(2)

After we set XGBoostClassifier parameters and feature/label column, we can build a transformer, XGBoostClassificationModel by
fitting XGBoostClassifier with the input DataFrame. This ``fit`` operation is essentially the training process and the generated
model can then be used in prediction.

.. code-block:: scala

  val xgbClassificationModel = xgbClassifier.fit(xgbInput)

Early Stopping
----------------

Early stopping is a feature to prevent the unnecessary training iterations. By specifying ``num_early_stopping_rounds`` or
directly call ``setNumEarlyStoppingRounds`` over a XGBoostClassifier or XGBoostRegressor, we can define number of rounds if
the evaluation metric going away from the best iteration and early stop training iterations.

When it comes to custom eval metrics, in additional to ``num_early_stopping_rounds``, you also need to define ``maximize_evaluation_metrics``
or call ``setMaximizeEvaluationMetrics`` to specify whether you want to maximize or minimize the metrics in training. For built-in eval metrics,
XGBoost4J-Spark will automatically select the direction.

For example, we need to maximize the evaluation metrics (set ``maximize_evaluation_metrics`` with true), and set ``num_early_stopping_rounds``
with 5. The evaluation metric of 10th iteration is the maximum one until now. In the following iterations, if there is no evaluation metric
greater than the 10th iteration's (best one), the training would be early stopped at 15th iteration.

Training with Evaluation Dataset
--------------------------------

You can also monitor the performance of the model during training with evaluation dataset. By calling ``setEvalDataset`` over a
XGBoostClassifier, XGBoostRegressor or XGBoostRanker.

Prediction
==========

XGBoost4j-Spark supports two ways for model serving: batch prediction and single instance prediction.

Batch Prediction
----------------

When we get a model, either XGBoostClassificationModel, XGBoostRegressionModel or XGBoostRankerModel, it takes a DataFrame, read the column containing
feature vectors, predict for each feature vector, and output a new DataFrame with the following columns by default:

* XGBoostClassificationModel will output margins (``rawPredictionCol``), probabilities(``probabilityCol``) and the eventual prediction labels (``predictionCol``) for each possible label.
* XGBoostRegressionModel will output prediction label(``predictionCol``).
* XGBoostRankerModel will output prediction label(``predictionCol``).

Batch prediction expects the user to pass the testset in the form of a DataFrame. XGBoost4J-Spark starts a XGBoost worker
for each partition of DataFrame for parallel prediction and generates prediction results for the whole DataFrame in a batch.

.. code-block:: scala

  val xgbClassificationModel = xgbClassifier.fit(xgbInput)
  val results = xgbClassificationModel.transform(testSet)

With the above code snippet, we get a result DataFrame, result containing margin, probability for each class and the prediction for each instance

.. code-block:: none

  +-----------------+----------+--------------------+--------------------+----------+
  |         features|classIndex|       rawPrediction|         probability|prediction|
  +-----------------+----------+--------------------+--------------------+----------+
  |[5.1,3.5,1.4,0.2]|       0.0|[3.45569849014282...|[0.99579632282257...|       0.0|
  |[4.9,3.0,1.4,0.2]|       0.0|[3.45569849014282...|[0.99618089199066...|       0.0|
  |[4.7,3.2,1.3,0.2]|       0.0|[3.45569849014282...|[0.99643349647521...|       0.0|
  |[4.6,3.1,1.5,0.2]|       0.0|[3.45569849014282...|[0.99636095762252...|       0.0|
  |[5.0,3.6,1.4,0.2]|       0.0|[3.45569849014282...|[0.99579632282257...|       0.0|
  |[5.4,3.9,1.7,0.4]|       0.0|[3.45569849014282...|[0.99428516626358...|       0.0|
  |[4.6,3.4,1.4,0.3]|       0.0|[3.45569849014282...|[0.99643349647521...|       0.0|
  |[5.0,3.4,1.5,0.2]|       0.0|[3.45569849014282...|[0.99579632282257...|       0.0|
  |[4.4,2.9,1.4,0.2]|       0.0|[3.45569849014282...|[0.99618089199066...|       0.0|
  |[4.9,3.1,1.5,0.1]|       0.0|[3.45569849014282...|[0.99636095762252...|       0.0|
  |[5.4,3.7,1.5,0.2]|       0.0|[3.45569849014282...|[0.99428516626358...|       0.0|
  |[4.8,3.4,1.6,0.2]|       0.0|[3.45569849014282...|[0.99643349647521...|       0.0|
  |[4.8,3.0,1.4,0.1]|       0.0|[3.45569849014282...|[0.99618089199066...|       0.0|
  |[4.3,3.0,1.1,0.1]|       0.0|[3.45569849014282...|[0.99618089199066...|       0.0|
  |[5.8,4.0,1.2,0.2]|       0.0|[3.45569849014282...|[0.97809928655624...|       0.0|
  |[5.7,4.4,1.5,0.4]|       0.0|[3.45569849014282...|[0.97809928655624...|       0.0|
  |[5.4,3.9,1.3,0.4]|       0.0|[3.45569849014282...|[0.99428516626358...|       0.0|
  |[5.1,3.5,1.4,0.3]|       0.0|[3.45569849014282...|[0.99579632282257...|       0.0|
  |[5.7,3.8,1.7,0.3]|       0.0|[3.45569849014282...|[0.97809928655624...|       0.0|
  |[5.1,3.8,1.5,0.3]|       0.0|[3.45569849014282...|[0.99579632282257...|       0.0|
  +-----------------+----------+--------------------+--------------------+----------+

Single instance prediction
--------------------------

XGBoostClassificationModel, XGBoostRegressionModel or XGBoostRankerModel supports making prediction on single instance as well.
It accepts a single Vector as feature, and output the prediction label.

However, the overhead of single-instance prediction is high due to the internal overhead of XGBoost, use it carefully!

.. code-block:: scala

  val features = xgbInput.head().getAs[Vector]("features")
  val result = xgbClassificationModel.predict(features)

Model Persistence
=================

Model and pipeline persistence
------------------------------

A data scientist produces an ML model and hands it over to an engineering team for deployment in a production environment.
Reversely, a trained model may be used by data scientists, for example as a baseline, across the process of data exploration.
So it's important to support model persistence to make the models available across usage scenarios and programming languages.

XGBoost4j-Spark supports saving and loading XGBoostClassifier/XGBoostClassificationModel and XGBoostRegressor/XGBoostRegressionModel
and XGBoostRanker/XGBoostRankerModel to/from file system. It also supports saving and loading a ML pipeline which includes these
estimators and models.

We can save the XGBoostClassificationModel to file system:

.. code-block:: scala

  val xgbClassificationModelPath = "/tmp/xgbClassificationModel"
  xgbClassificationModel.write.overwrite().save(xgbClassificationModelPath)

and then loading the model in another session:

.. code-block:: scala

  import ml.dmlc.xgboost4j.scala.spark.XGBoostClassificationModel

  val xgbClassificationModel2 = XGBoostClassificationModel.load(xgbClassificationModelPath)
  xgbClassificationModel2.transform(xgbInput)

.. note::

  Besides dumping the model to raw format, users are able to dump the model to be json or ubj format.

  .. code-block:: scala

    val xgbClassificationModelPath = "/tmp/xgbClassificationModel"
    xgbClassificationModel.write.overwrite().option("format", "json").save(xgbClassificationModelPath)


With regards to ML pipeline save and load, please refer the next section.

Interact with Other Bindings of XGBoost
---------------------------------------
After we train a model with XGBoost4j-Spark on massive dataset, sometimes we want to do model serving
in single machine or integrate it with other single node libraries for further processing.

After saving the model, we can load this model with single node Python XGBoost directly.

.. code-block:: scala

  val xgbClassificationModelPath = "/tmp/xgbClassificationModel"
  xgbClassificationModel.write.overwrite().save(xgbClassificationModelPath)

.. code-block:: python

  import xgboost as xgb
  bst = xgb.Booster({'nthread': 4})
  bst.load_model("/tmp/xgbClassificationModel/data/model")

.. note:: Consistency issue between XGBoost4J-Spark and other bindings

  There is a consistency issue between XGBoost4J-Spark and other language bindings of XGBoost.

  When users use Spark to load training/test data in LIBSVM format with the following code snippet:

  .. code-block:: scala

    spark.read.format("libsvm").load("trainingset_libsvm")

  Spark assumes that the dataset is using 1-based indexing (feature indices staring with 1). However,
  when you do prediction with other bindings of XGBoost (e.g. Python API of XGBoost), XGBoost assumes
  that the dataset is using 0-based indexing (feature indices starting with 0) by default. It creates a
  pitfall for the users who train model with Spark but predict with the dataset in the same format in
  other bindings of XGBoost. The solution is to transform the dataset to 0-based indexing before you
  predict with, for example, Python API, or you append ``?indexing_mode=1`` to your file path when
  loading with DMatirx. For example in Python:

  .. code-block:: python

    xgb.DMatrix('test.libsvm?indexing_mode=1')

*******************************************
Building a ML Pipeline with XGBoost4J-Spark
*******************************************

Basic ML Pipeline
=================

Spark ML pipeline can combine multiple algorithms or functions into a single pipeline.
It covers from feature extraction, transformation, selection to model training and prediction.
XGBoost4j-Spark makes it feasible to embed XGBoost into such a pipeline seamlessly.
The following example shows how to build such a pipeline consisting of Spark MLlib feature transformer
and XGBoostClassifier estimator.

We still use `Iris <https://archive.ics.uci.edu/ml/datasets/iris>`_ dataset and the ``rawInput`` DataFrame.
First we need to split the dataset into training and test dataset.

.. code-block:: scala

  val Array(training, test) = rawInput.randomSplit(Array(0.8, 0.2), 123)

The we build the ML pipeline which includes 4 stages:

* Assemble all features into a single vector column.
* From string label to indexed double label.
* Use XGBoostClassifier to train classification model.
* Convert indexed double label back to original string label.

We have shown the first three steps in the earlier sections, and the last step is finished with a new
transformer `IndexToString <https://spark.apache.org/docs/latest/api/scala/org/apache/spark/ml/feature/IndexToString.html>`_:

.. code-block:: scala

	val labelConverter = new IndexToString()
        .setInputCol("prediction")
        .setOutputCol("realLabel")
        .setLabels(stringIndexer.labels)

We need to organize these steps as a Pipeline in Spark ML framework and evaluate the whole pipeline to get a PipelineModel:

.. code-block:: scala

  import org.apache.spark.ml.feature._
  import org.apache.spark.ml.Pipeline

  val pipeline = new Pipeline()
      .setStages(Array(assembler, stringIndexer, booster, labelConverter))
  val model = pipeline.fit(training)

After we get the PipelineModel, we can make prediction on the test dataset and evaluate the model accuracy.

.. code-block:: scala

  import org.apache.spark.ml.evaluation.MulticlassClassificationEvaluator

  val prediction = model.transform(test)
  val evaluator = new MulticlassClassificationEvaluator()
  val accuracy = evaluator.evaluate(prediction)

Pipeline with Hyper-parameter Tunning
=====================================
The most critical operation to maximize the power of XGBoost is to select the optimal parameters for the model.
Tuning parameters manually is a tedious and labor-consuming process. With the latest version of XGBoost4J-Spark,
we can utilize the Spark model selecting tool to automate this process.

The following example shows the code snippet utilizing CrossValidation and MulticlassClassificationEvaluator
to search the optimal combination of two XGBoost parameters, ``max_depth`` and ``eta``. (See :doc:`/parameter`.)
The model producing the maximum accuracy defined by MulticlassClassificationEvaluator is selected and used to
generate the prediction for the test set.

.. code-block:: scala

  import org.apache.spark.ml.tuning._
  import org.apache.spark.ml.PipelineModel
  import ml.dmlc.xgboost4j.scala.spark.XGBoostClassificationModel

  val paramGrid = new ParamGridBuilder()
      .addGrid(booster.maxDepth, Array(3, 8))
      .addGrid(booster.eta, Array(0.2, 0.6))
      .build()
  val cv = new CrossValidator()
      .setEstimator(pipeline)
      .setEvaluator(evaluator)
      .setEstimatorParamMaps(paramGrid)
      .setNumFolds(3)

  val cvModel = cv.fit(training)

  val bestModel = cvModel.bestModel.asInstanceOf[PipelineModel].stages(2)
      .asInstanceOf[XGBoostClassificationModel]
  bestModel.extractParamMap()

*********************************
Run XGBoost4J-Spark in Production
*********************************

XGBoost4J-Spark is one of the most important steps to bring XGBoost to production environment easier. In this section,
we introduce three key features to run XGBoost4J-Spark in production.

Parallel/Distributed Training
=============================
The massive size of training dataset is one of the most significant characteristics in production environment. To ensure
that training in XGBoost scales with the data size, XGBoost4J-Spark bridges the distributed/parallel processing framework
of Spark and the parallel/distributed training mechanism of XGBoost.

In XGBoost4J-Spark, each XGBoost worker is wrapped by a Spark task and the training dataset in Spark's memory space is
fed to XGBoost workers in a transparent approach to the user.

In the code snippet where we build XGBoostClassifier, we set parameter ``num_workers`` (or ``numWorkers``).
This parameter controls how many parallel workers we want to have when training a XGBoostClassificationModel.

.. note:: Regarding OpenMP optimization

  By default, we allocate a core per each XGBoost worker. Therefore, the OpenMP optimization within each XGBoost worker does
  not take effect and the parallelization of training is achieved by running multiple workers (i.e. Spark tasks) at the same time.

  If you do want OpenMP optimization, you have to

  1. set ``nthread`` to a value larger than 1 when creating XGBoostClassifier/XGBoostRegressor
  2. set ``spark.task.cpus`` in Spark to the same value as ``nthread``

Gang Scheduling
===============
XGBoost uses `AllReduce <http://mpitutorial.com/tutorials/mpi-reduce-and-allreduce/>`_.
algorithm to synchronize the stats, e.g. histogram values, of each worker during training. Therefore XGBoost4J-Spark requires
that all of ``nthread * numWorkers`` cores should be available before the training runs.

In the production environment where many users share the same cluster, it's hard to guarantee that your XGBoost4J-Spark application
can get all requested resources for every run. By default, the communication layer in XGBoost will block the whole application when
it requires more resources to be available. This process usually brings unnecessary resource waste as it keeps the ready resources
and try to claim more. Additionally, this usually happens silently and does not bring the attention of users.

XGBoost4J-Spark allows the user to setup a timeout threshold for claiming resources from the cluster. If the application cannot get
enough resources within this time period, the application would fail instead of wasting resources for hanging long. To enable this
feature, you can set with XGBoostClassifier/XGBoostRegressor/XGBoostRanker:

.. code-block:: scala

  xgbClassifier.setRabitTrackerTimeout(60000L)

or pass in ``rabit_tracker_timeout`` in ``xgbParamMap`` when building XGBoostClassifier:

.. code-block:: scala

  val xgbParam = Map("eta" -> 0.1f,
     "max_depth" -> 2,
     "objective" -> "multi:softprob",
     "num_class" -> 3,
     "num_round" -> 100,
     "num_workers" -> 2,
     "rabit_tracker_timeout" -> 60000L)
  val xgbClassifier = new XGBoostClassifier(xgbParam).
      setFeaturesCol("features").
      setLabelCol("classIndex")

If XGBoost4J-Spark cannot get enough resources for running two XGBoost workers, the application would fail.
Users can have external mechanism to monitor the status of application and get notified for such case.

Checkpoint During Training
==========================

Transient failures are also commonly seen in production environment. To simplify the design of XGBoost,
we stop training if any of the distributed workers fail. However, if the training fails after having been
through a long time, it would be a great waste of resources.

We support creating checkpoint during training to facilitate more efficient recovery from failure. To enable this feature,
you can set how many iterations we build each checkpoint with ``setCheckpointInterval`` and the location of checkpoints
with ``setCheckpointPath``:

.. code-block:: scala

  xgbClassifier.setCheckpointInterval(2)
  xgbClassifier.setCheckpointPath("/checkpoint_path")

An equivalent way is to pass in parameters in XGBoostClassifier's constructor:

.. code-block:: scala

  val xgbParam = Map("eta" -> 0.1f,
     "max_depth" -> 2,
     "objective" -> "multi:softprob",
     "num_class" -> 3,
     "num_round" -> 100,
     "num_workers" -> 2,
     "checkpoint_path" -> "/checkpoints_path",
     "checkpoint_interval" -> 2)
  val xgbClassifier = new XGBoostClassifier(xgbParam).
      setFeaturesCol("features").
      setLabelCol("classIndex")

If the training failed during these 100 rounds, the next run of training would start by reading the latest checkpoint
file in ``/checkpoints_path`` and start from the iteration when the checkpoint was built until to next failure or the specified 100 rounds.


***************
External Memory
***************

.. versionadded:: 3.0

.. warning::

   The feature is experimental.

Here we refer to the iterator-based external memory instead of the one that uses special
URL parameters. XGBoost-Spark has experimental support for GPU-based external memory
training (:doc:`/jvm/xgboost4j_spark_gpu_tutorial`) since 3.0. When it's used in
combination with GPU-based training, data is first cached on disk and then staged on CPU
memory.  See :doc:`/tutorials/external_memory` for general concept and best practices for
the external memory training. In addition, see the doc string of the estimator parameter
`useExternalMemory`. With Spark estimators:

.. code-block:: scala

  val xgbClassifier = new XGBoostClassifier(xgbParam)
      .setFeaturesCol(featuresNames)
      .setLabelCol(labelName)
      .setUseExternalMemory(true)
      .setDevice("cuda")  // CPU is not yet supported
