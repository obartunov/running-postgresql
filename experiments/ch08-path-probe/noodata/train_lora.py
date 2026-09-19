#!/usr/bin/env python3
"""LoRA fine-tuning on one NooData corpus (A or B) of one fold.

  train_lora.py --model Qwen/Qwen3-4B --train fold-ordering/corpus_B.train.jsonl
                --out runs/ordering/B-seed0 --seed 0

A and B are trained with identical settings and the same number of examples
and epochs; only the prompts differ.  Loss is on the answer tokens only.
An example longer than --max-len is dropped, not truncated (truncation
would cut the context the answer depends on); the count is reported and
written to train_log.json, and must be equal to zero or reported with the
results.
"""
import argparse
import json
import math
import os
import random
import time

import torch
from peft import LoraConfig, get_peft_model
from transformers import AutoModelForCausalLM, AutoTokenizer

from lm_io import end_of_answer, load_jsonl, prompt_text


def encode(tok, rec, max_len):
    prompt = prompt_text(tok, rec["messages"][0]["content"])
    answer = rec["messages"][1]["content"] + end_of_answer(tok)
    p = tok(prompt, add_special_tokens=False)["input_ids"]
    a = tok(answer, add_special_tokens=False)["input_ids"]
    if len(p) + len(a) > max_len:
        return None
    return {"input_ids": p + a, "labels": [-100] * len(p) + a}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--train", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--epochs", type=float, default=3)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--r", type=int, default=16)
    ap.add_argument("--alpha", type=int, default=32)
    ap.add_argument("--dropout", type=float, default=0.05)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--grad-accum", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=4096)
    ap.add_argument("--max-steps", type=int, default=0,
                    help="stop after this many optimizer steps (smoke tests)")
    args = ap.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.bfloat16 if dev == "cuda" else torch.float32

    tok = AutoTokenizer.from_pretrained(args.model)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=dtype)
    model.to(dev)
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()
    model = get_peft_model(model, LoraConfig(
        r=args.r, lora_alpha=args.alpha, lora_dropout=args.dropout,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"],
        task_type="CAUSAL_LM"))

    recs = load_jsonl(args.train)
    data = [encode(tok, r, args.max_len) for r in recs]
    dropped = [r["id"] for r, d in zip(recs, data) if d is None]
    data = [d for d in data if d is not None]

    steps_per_epoch = math.ceil(len(data) / (args.batch * args.grad_accum))
    total = math.ceil(steps_per_epoch * args.epochs)
    if args.max_steps:
        total = min(total, args.max_steps)
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad],
                            lr=args.lr, weight_decay=0.0)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / max(1, total // 20))
        * max(0.0, 1 - s / total))

    log = {"args": vars(args), "examples": len(data), "dropped": dropped,
           "optimizer_steps": total, "loss": []}
    model.train()
    step, micro, t0 = 0, 0, time.time()
    running = 0.0
    while step < total:
        order = list(range(len(data)))
        random.shuffle(order)
        for i in range(0, len(order), args.batch):
            batch = [data[j] for j in order[i:i + args.batch]]
            n = max(len(b["input_ids"]) for b in batch)
            ids = torch.full((len(batch), n), tok.pad_token_id)
            lab = torch.full((len(batch), n), -100)
            att = torch.zeros((len(batch), n), dtype=torch.long)
            for k, b in enumerate(batch):
                m = len(b["input_ids"])
                ids[k, :m] = torch.tensor(b["input_ids"])
                lab[k, :m] = torch.tensor(b["labels"])
                att[k, :m] = 1
            out = model(input_ids=ids.to(dev), attention_mask=att.to(dev),
                        labels=lab.to(dev))
            (out.loss / args.grad_accum).backward()
            running += out.loss.item()
            micro += 1
            if micro % args.grad_accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step()
                sched.step()
                opt.zero_grad()
                step += 1
                log["loss"].append(round(running / args.grad_accum, 4))
                running = 0.0
                if step % 10 == 0 or step == total:
                    print(f"step {step}/{total} loss {log['loss'][-1]} "
                          f"{time.time() - t0:.0f}s", flush=True)
                if step >= total:
                    break

    os.makedirs(args.out, exist_ok=True)
    model.save_pretrained(args.out)
    tok.save_pretrained(args.out)
    log["seconds"] = round(time.time() - t0)
    with open(os.path.join(args.out, "train_log.json"), "w") as f:
        json.dump(log, f, indent=2)
    print(f"examples {len(data)}, dropped {len(dropped)}, steps {total}")


if __name__ == "__main__":
    main()
