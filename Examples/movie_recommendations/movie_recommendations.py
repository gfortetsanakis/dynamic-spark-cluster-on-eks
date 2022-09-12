import os
from pyspark import SparkConf
from pyspark.sql import Row, SparkSession
from pyspark.ml.evaluation import RegressionEvaluator
from pyspark.ml.recommendation import ALS
from pyspark.ml.tuning import CrossValidator, ParamGridBuilder

input_dataset_path = os.getenv('INPUT_DATASET_PATH')
output_dataset_path = os.getenv('OUTPUT_DATASET_PATH')
spark_event_logs_dir = os.getenv('SPARK_EVENT_LOGS_DIR')
checkpoint_dir = os.getenv('CHECKPOINT_DIR')

conf = SparkConf()
conf.set('spark.hadoop.fs.s3a.aws.credentials.provider', 'com.amazonaws.auth.WebIdentityTokenCredentialsProvider')
conf.set('spark.eventLog.enabled', 'true')
conf.set('spark.eventLog.dir', spark_event_logs_dir)

spark = SparkSession.builder.config(conf = conf).getOrCreate()
spark.sparkContext.setCheckpointDir(checkpoint_dir)

lines = spark.read.text(input_dataset_path).rdd
parts = lines.map(lambda row: row.value.split("::"))
ratingsRDD = parts.map(lambda p: Row(userId=int(p[0]), movieId=int(p[1]),
                                     rating=float(p[2]), timestamp=int(p[3])))

ratings = spark.createDataFrame(ratingsRDD)
ratings = ratings.repartition(100, "userId")

(training, validation) = ratings.randomSplit([0.8, 0.2])

als = ALS(maxIter=50, userCol="userId", itemCol="movieId", ratingCol="rating",
          coldStartStrategy="drop")

evaluator = RegressionEvaluator(metricName="rmse", labelCol="rating",
                                predictionCol="prediction")

paramGrid = ParamGridBuilder() \
    .addGrid(als.rank, range(5, 15)) \
    .build()

crossval = CrossValidator(estimator=als,
                          estimatorParamMaps=paramGrid,
                          evaluator=evaluator,
                          numFolds=2)

cvModel = crossval.fit(training)

userRecs = cvModel.bestModel.recommendForAllUsers(10)
userRecs.write.parquet(output_dataset_path,mode="overwrite")

predictions = cvModel.transform(validation)
rmse = evaluator.evaluate(predictions)
best_rank_param=cvModel.bestModel.rank
print(f"Best rank parameter: {best_rank_param}")
print(f"Root-mean-square error = {str(rmse)}")