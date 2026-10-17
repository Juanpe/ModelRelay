.PHONY: format check-format lint lint-all check-style

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
