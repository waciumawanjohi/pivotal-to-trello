run:
    docker build -t p2t -f Dockerfile2 . && docker run -i p2t import --trello-key $TRELLO_KEY --trello-token $TRELLO_TOKEN --pivotal-token $PIVOTAL_TOKEN
build-base:
    docker build -t pivotal-to-trello .
build-test-base:
    docker build -t p2t-testbase -f DockerfileTestBase .
test specfile=".":
    docker build -t p2t-test -f DockerfileTestFast . && docker run p2t-test "{{specfile}}"
