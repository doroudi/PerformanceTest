# docker-k6-grafana-influxdb
Demonstrates how to run load tests with containerised instances of K6, Grafana and InfluxDB.

#### To Run Project
docker-compose up -d influxdb grafana

docker-compose run k6 run /scripts/stress-test.js


Grafana Url
http://localhost:3000/

Influx DB Url 
http://localhost:8888/



#### Dashboards
The dashboard in /dashboards is adapted from the excellent K6 / Grafana dashboard here:
https://grafana.com/grafana/dashboards/2587

There are only two small modifications:
* the data source is configured to use the docker created InfluxDB data source
* the time period is set to now-15m, which I feel is a better view for most tests