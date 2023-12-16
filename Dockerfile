FROM alpine:3.18.4
COPY ./structured-query-server structured-query-server
ENV COUCHDB_URL="http://localhost"
ENV DATA_DIR="./data"
ENV PORT=4984
CMD ./structured-query-server --server $COUCHDB_URL --data-dir $DATA_DIR --port $PORT
