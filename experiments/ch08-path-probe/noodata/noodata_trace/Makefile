# noodata_trace: JSONL trace of planner path events for dataset generation.
# Out-of-tree test/demo callback; build with PGXS against the patched tree.
MODULE_big = noodata_trace
OBJS = noodata_trace.o
EXTENSION = noodata_trace
DATA = noodata_trace--0.1.sql
PGFILEDESC = "noodata_trace - planner trajectory events as JSON lines"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
