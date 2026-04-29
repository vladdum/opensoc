D2       := ~/.local/bin/d2 --layout elk --elk-nodeNodeBetweenLayers 40 \
             --elk-edgeNodeBetweenLayers 30 \
             --elk-padding "[top=15,left=15,bottom=15,right=15]" --pad 20
DOT      := dot -Tsvg
WAVEDROM := npx wavedrom-cli

D2_SRC   := $(wildcard src/*.d2)
DOT_SRC  := $(wildcard src/*.dot)
WF_SRC   := $(wildcard src/wf-*.json)
D2_SVG   := $(patsubst src/%.d2,svg/%.svg,$(D2_SRC))
DOT_SVG  := $(patsubst src/%.dot,svg/%.svg,$(DOT_SRC))
WF_SVG   := $(patsubst src/%.json,svg/%.svg,$(WF_SRC))

.PHONY: all clean regen

all: $(D2_SVG) $(DOT_SVG) $(WF_SVG)

svg/%.svg: src/%.dot
	@if grep -q 'pos="[0-9.,!]*!"' $<; then \
	  echo "neato -n2 -Tsvg $< -o $@"; \
	  neato -n2 -Tsvg $< -o $@; \
	else \
	  echo "$(DOT) $< -o $@"; \
	  $(DOT) $< -o $@; \
	fi

svg/%.svg: src/%.d2
	$(D2) $< $@

svg/%.svg: src/%.json
	$(WAVEDROM) -i $< -s $@

regen:
	@for f in $$(git diff --name-only -- src/); do \
	  svg=svg/$$(basename "$${f%.*}").svg; \
	  echo "Rebuilding $$svg from $$f"; \
	  $(MAKE) "$$svg"; \
	done

clean:
	rm -f svg/*.svg
