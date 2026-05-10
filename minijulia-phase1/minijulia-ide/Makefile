IMAGE    = minimlc-env:v1
MYDOCKER = sudo /usr/local/bin/mydocker.real
SRC      = $(shell pwd)
RUN      = $(MYDOCKER) run -v $(SRC):/workspace -w /workspace $(IMAGE)

compile:
	$(RUN) sh -c "cd /workspace && dune build && echo 'Build OK'"

server:
	@echo "Starting MiniJulia IDE server on http://localhost:7777 ..."
	@echo "Open your browser at: http://localhost:7777"
	$(RUN) sh -c "cd /workspace && dune build && ./_build/default/server/server.exe"

run:
	$(RUN) sh -c "cd /workspace && ./_build/default/bin/main.exe $(FILE)"

examples:
	@for f in demo fibonacci prime bubble_sort file_io; do \
		echo "=== $$f.jl ==="; \
		$(RUN) sh -c "cd /workspace && ./_build/default/bin/main.exe examples/$$f.jl"; \
		echo ""; \
	done

shell:
	$(MYDOCKER) run -v $(SRC):/workspace -w /workspace $(IMAGE) sh

build-image:
	$(MYDOCKER) build -t $(IMAGE) .

clean:
	rm -rf _build

.PHONY: compile server run examples shell build-image clean
