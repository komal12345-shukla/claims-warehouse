.PHONY: all data build test report clean

all: data build

data:
	python generator/generate.py --out data/raw

build:
	python run.py

test:
	python tests/run_tests.py

report:
	python run.py --report

clean:
	rm -rf out/*.duckdb data/raw/*.csv
