PARALLEL_JOBS := $(shell echo $$(nproc))

all: build/linenoise.o

build/linenoise.o:
	mkdir -p build
	gcc -c -O2 vendor/linenoise/linenoise.c -o build/linenoise.o

clean:
	rm -rf build/linenoise.o
