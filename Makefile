.PHONY: format check-format lint lint-all check-style check-release test-release check-skill test-skill

format:
	bash Scripts/swift-style.sh format

check-format:
	bash Scripts/swift-style.sh check-format

lint:
	bash Scripts/swift-style.sh lint

lint-all:
	bash Scripts/swift-style.sh lint-all

check-style:
	bash Scripts/swift-style.sh check

check-release:
	bash Scripts/check-release.sh "$(VERSION)"

test-release:
	bash Scripts/Tests/check-release-tests.sh

check-skill:
	bash Scripts/check-skill.sh

test-skill:
	bash Scripts/Tests/check-skill-tests.sh
