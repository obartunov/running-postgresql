MANUSCRIPT := manuscript/Running-PostgreSQL-Working.md
PANDOC   := pandoc
PFLAGS   := --pdf-engine=xelatex -V lang=ru-RU -V mainfont="DejaVu Serif" \
            -V monofont="DejaVu Sans Mono" --toc

.PHONY: book clean
book: running-postgresql.pdf

running-postgresql.pdf: $(MANUSCRIPT)
	$(PANDOC) $(PFLAGS) -o $@ $<

clean:
	rm -f running-postgresql.pdf
