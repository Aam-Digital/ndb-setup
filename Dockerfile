# A simple wrapper to have SQS running inside a Docker container
FROM ubuntu:22.04
COPY ./structured-query-server structured-query-server
COPY ./better_sqlite3.node better_sqlite3.node
ENV COUCHDB_URL=http://localhost
ENV DATA_DIR=./data
ENV PORT=4984
CMD ./structured-query-server --server "$COUCHDB_URL" --data-dir "$DATA_DIR" --port $PORT
