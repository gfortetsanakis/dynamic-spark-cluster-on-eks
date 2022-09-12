FROM datamechanics/spark:3.2-latest

ENV PYSPARK_MAJOR_PYTHON_VERSION=3

WORKDIR /opt/application

RUN conda install -y --quiet numpy

COPY movie_recommendations.py .