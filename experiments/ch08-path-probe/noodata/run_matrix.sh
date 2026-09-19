#!/bin/sh
# First NooData LoRA run: one base model, one seed, two held-out folds.
#
#   MODEL=Qwen/Qwen3-4B DSN="host=... dbname=..." SEED=0 ./run_matrix.sh OUT
#
# Per fold: LoRA on corpus A and on corpus B, then predictions for
#   Base@A Base@B  A@A A@B  B@A B@B      (model@prompt context)
# on test_interp and test_transfer, scored with score.py.  B@A (trained with
# trajectories, asked without them) is the cell the experiment is about.
#
# DSN must reach a server built from PostgreSQL master c62b330 (injection
# points not needed: the series does not change plans) with setup.sql
# loaded; it is used only to plan the SQL proposed in repair answers.
set -eu
# shellcheck disable=SC2086
OUT=${1:?output directory}
MODEL=${MODEL:-Qwen/Qwen3-4B}
SEED=${SEED:-0}
DSN=${DSN:?DSN of a server loaded with setup.sql}
TRAIN_ARGS=${TRAIN_ARGS:-}      # smoke tests only, e.g. "--max-steps 2"
PRED_ARGS=${PRED_ARGS:-}        # smoke tests only, e.g. "--limit 4"
HERE=$(cd "$(dirname "$0")" && pwd)

python3 "$HERE/build_corpus.py" "$HERE/data-v1" "$OUT/corpus" \
    --fold ordering --fold expression_index --human-fold ordering >/dev/null
python3 "$HERE/check_corpus.py" "$OUT/corpus" | tail -1

for fold in ordering expression_index; do
    F=$OUT/corpus/fold-$fold
    R=$OUT/runs/$fold
    P=$OUT/preds/$fold
    mkdir -p "$R" "$P" "$OUT/scores"
    for c in A B; do
        [ -f "$R/$c-seed$SEED/adapter_config.json" ] ||
            python3 "$HERE/train_lora.py" --model "$MODEL" \
                --train "$F/corpus_$c.train.jsonl" --out "$R/$c-seed$SEED" \
                --seed "$SEED" $TRAIN_ARGS
    done
    for split in test_interp test_transfer; do
        preds=""
        for m in Base A B; do
            for c in A B; do
                o=$P/$m@$c.$split.jsonl
                if [ ! -f "$o" ]; then
                    if [ $m = Base ]; then
                        python3 "$HERE/predict.py" --model "$MODEL" \
                            --test "$F/corpus_$c.$split.jsonl" --out "$o" \
                            $PRED_ARGS
                    else
                        python3 "$HERE/predict.py" --model "$MODEL" \
                            --adapter "$R/$m-seed$SEED" \
                            --test "$F/corpus_$c.$split.jsonl" --out "$o" \
                            $PRED_ARGS
                    fi
                fi
                preds="$preds --pred $m@$c=$o"
            done
        done
        # shellcheck disable=SC2086
        python3 "$HERE/score.py" "$F" --split $split --dsn "$DSN" $preds \
            --json "$OUT/scores/$fold.$split.seed$SEED.json" |
            tee "$OUT/scores/$fold.$split.seed$SEED.txt"
    done
done
