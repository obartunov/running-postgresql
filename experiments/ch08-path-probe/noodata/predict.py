#!/usr/bin/env python3
"""Greedy answers for one test file, with or without a LoRA adapter.

  predict.py --model Qwen/Qwen3-4B [--adapter runs/ordering/B-seed0]
             --test fold-ordering/corpus_A.test_transfer.jsonl
             --out preds/ordering/B@A.test_transfer.jsonl

The test file decides the context (corpus_A = SQL + EXPLAIN, corpus_B = with
trajectory), the adapter decides the training; together they give the cells
Base@A, Base@B, A@A, A@B, B@A, B@B.  Only the prompt is taken from the file;
the reference answer is never shown to the model.
"""
import argparse
import json

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from lm_io import end_of_answer, load_jsonl, prompt_text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter")
    ap.add_argument("--test", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--max-new-tokens", type=int, default=256)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.bfloat16 if dev == "cuda" else torch.float32
    tok = AutoTokenizer.from_pretrained(args.adapter or args.model)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=dtype)
    if args.adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, args.adapter)
    model.to(dev).eval()
    stop = tok.convert_tokens_to_ids(end_of_answer(tok))

    recs = load_jsonl(args.test)
    if args.limit:
        recs = recs[:args.limit]
    with open(args.out, "w") as f:
        for i in range(0, len(recs), args.batch):
            chunk = recs[i:i + args.batch]
            prompts = [prompt_text(tok, r["messages"][0]["content"])
                       for r in chunk]
            enc = tok(prompts, return_tensors="pt", padding=True,
                      add_special_tokens=False).to(dev)
            with torch.no_grad():
                gen = model.generate(**enc, do_sample=False,
                                     max_new_tokens=args.max_new_tokens,
                                     eos_token_id=stop,
                                     pad_token_id=tok.pad_token_id)
            for r, g in zip(chunk, gen[:, enc["input_ids"].shape[1]:]):
                text = tok.decode(g, skip_special_tokens=True)
                f.write(json.dumps({"id": r["id"], "output": text}) + "\n")
            print(f"{min(i + args.batch, len(recs))}/{len(recs)}", flush=True)


if __name__ == "__main__":
    main()
