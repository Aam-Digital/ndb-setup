docker build -t ndb-server:$1
docker tag ndb-server aamdigital/ndb-server:$1
docker push aamdigital/ndb-server:$1
