FROM jupyter/pyspark-notebook:hadoop-3

USER root

ENV PYSPARK_SUBMIT_ARGS '--packages com.amazonaws:aws-java-sdk-s3:1.12.285,org.apache.hadoop:hadoop-aws:3.3.4,net.java.dev.jets3t:jets3t:0.9.4 pyspark-shell'


# Download missing jars

# Get AWS SDK JAR
RUN (cd /usr/local/spark/jars && wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.285/aws-java-sdk-bundle-1.12.285.jar)

# Get Hadoop-AWS Jar
RUN (cd /usr/local/spark/jars && wget https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar)

# Get jets3t JAR
RUN (cd /usr/local/spark/jars && wget https://repo1.maven.org/maven2/net/java/dev/jets3t/jets3t/0.9.4/jets3t-0.9.4.jar)

USER $NB_UID