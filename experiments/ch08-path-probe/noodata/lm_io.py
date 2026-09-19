"""Prompt and tokenizer handling shared by train_lora.py and predict.py.

Training and inference must build the prompt the same way, and a base model
evaluated zero-shot must see the same prompt as the LoRA models.
"""
import json
import os


def load_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f]


def prompt_text(tok, user_content):
    """Chat prompt ending where the assistant answer starts.

    Qwen3 templates take enable_thinking; with it off the template emits an
    empty think block, so the answer is the first thing generated.  Templates
    without the argument ignore it.
    """
    msgs = [{"role": "user", "content": user_content}]
    try:
        return tok.apply_chat_template(msgs, tokenize=False,
                                       add_generation_prompt=True,
                                       enable_thinking=False)
    except TypeError:
        return tok.apply_chat_template(msgs, tokenize=False,
                                       add_generation_prompt=True)


def end_of_answer(tok):
    """Token that closes an assistant turn in the chat template."""
    for t in ("<|im_end|>", "<|eot_id|>", "<|end|>"):
        if t in tok.get_vocab():
            return t
    return tok.eos_token


def tiny_model_and_tokenizer(corpus_paths, workdir):
    """A randomly initialised Qwen3-shaped model with a BPE tokenizer trained
    on the corpus, for smoke-testing the pipeline without downloading weights.
    It learns nothing useful; it only proves the scripts run end to end."""
    from tokenizers import Tokenizer, models, pre_tokenizers, trainers, decoders
    from transformers import PreTrainedTokenizerFast, Qwen3Config, \
        Qwen3ForCausalLM

    specials = ["<|endoftext|>", "<|im_start|>", "<|im_end|>"]
    bpe = Tokenizer(models.BPE(unk_token=None))
    bpe.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    bpe.decoder = decoders.ByteLevel()
    texts = []
    for p in corpus_paths:
        for r in load_jsonl(p):
            texts.extend(m["content"] for m in r["messages"])
    bpe.train_from_iterator(texts, trainers.BpeTrainer(
        vocab_size=2000, special_tokens=specials,
        initial_alphabet=pre_tokenizers.ByteLevel.alphabet()))
    tok = PreTrainedTokenizerFast(tokenizer_object=bpe,
                                  eos_token="<|im_end|>",
                                  pad_token="<|endoftext|>")
    tok.chat_template = (
        "{% for m in messages %}<|im_start|>{{ m['role'] }}\n"
        "{{ m['content'] }}<|im_end|>\n{% endfor %}"
        "{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}")
    cfg = Qwen3Config(vocab_size=len(tok), hidden_size=64,
                      intermediate_size=128, num_hidden_layers=2,
                      num_attention_heads=4, num_key_value_heads=2,
                      head_dim=16, max_position_embeddings=8192,
                      tie_word_embeddings=True)
    model = Qwen3ForCausalLM(cfg)
    path = os.path.join(workdir, "tiny-base")
    model.save_pretrained(path)
    tok.save_pretrained(path)
    return path
