CHAPTERS := $(sort $(wildcard chapters/*.md))
PANDOC   := pandoc
PFLAGS   := --pdf-engine=xelatex -V lang=ru-RU -V mainfont="DejaVu Serif" \
            -V monofont="DejaVu Sans Mono" --toc

.PHONY: book clean
book: running-postgresql.pdf

running-postgresql.pdf: $(CHAPTERS)
	$(PANDOC) $(PFLAGS) -o $@ $^

ch%: chapters/%*.md
	$(PANDOC) $(PFLAGS) -o $(basename $(notdir $<)).pdf $<

clean:
	rm -f running-postgresql.pdf chapters/*.pdf
