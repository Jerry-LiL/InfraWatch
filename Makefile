.PHONY: lint test test-unit test-integration check up down

lint:
	shellcheck -x -P SCRIPTDIR bin/infrawatch bin/install.sh bin/lib/*.sh tests/*.sh

test-unit:
	bash tests/run.sh

test-integration:
	bash tests/integration.sh

test: lint test-unit

check: test test-integration

up:
	docker compose up -d --wait

down:
	docker compose down -v
