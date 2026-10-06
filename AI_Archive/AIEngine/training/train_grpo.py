import os
import re
import json
import torch
from datasets import Dataset
from trl import GRPOConfig, GRPOTrainer
from unsloth import FastLanguageModel, PatchFastRL
from unsloth import is_bfloat16_supported

# Apply Unsloth's fast RL patches for memory efficiency
PatchFastRL("GRPO", FastLanguageModel)

# Configuration
MODEL_NAME = "google/gemma-4-12b-it-qat-q4_0" # Base model to tune
MAX_SEQ_LENGTH = 1024
LORA_RANK = 16
BATCH_SIZE = 1
GRAD_ACCUM_STEPS = 4

def load_synthetic_dataset(path: str) -> Dataset:
    """Loads the JSONL dataset and formats it for GRPO."""
    data = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip(): continue
            data.append(json.loads(line))
    return Dataset.from_list(data)

# ---- Custom Reward Functions for Velora DJ ----

def format_reward_func(completions, **kwargs) -> list[float]:
    """Rewards models that wrap their thinking process in <reasoning> tags."""
    rewards = []
    for completion in completions:
        # Check if the completion contains the tags
        if re.search(r"<reasoning>.*?</reasoning>", completion, re.DOTALL):
            rewards.append(1.0)
        else:
            rewards.append(0.0)
    return rewards

def dj_explanation_reward_func(completions, **kwargs) -> list[float]:
    """Rewards models for using acoustic/DJ terminology."""
    keywords = ["bpm", "key", "tempo", "mood", "acoustic", "energy", "vibe"]
    rewards = []
    for completion in completions:
        score = 0.0
        text = completion.lower()
        for kw in keywords:
            if kw in text:
                score += 0.2
        # Max reward of 1.0 for this function
        rewards.append(min(1.0, score))
    return rewards

def relevance_reward_func(completions, expected_track_id, **kwargs) -> list[float]:
    """Rewards the model if it outputs the exact [PLAY: track_id] tag expected."""
    rewards = []
    for completion, expected_id in zip(completions, expected_track_id):
        target_tag = f"[PLAY: {expected_id}]"
        if target_tag in completion:
            rewards.append(2.0) # High reward for getting the right track
        else:
            rewards.append(0.0)
    return rewards

def train():
    print("Loading model in 4-bit...")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name = MODEL_NAME,
        max_seq_length = MAX_SEQ_LENGTH,
        load_in_4bit = True, 
        fast_inference = True,
        max_lora_rank = LORA_RANK,
        gpu_memory_utilization = 0.6, 
    )

    print("Adding LoRA adapters...")
    model = FastLanguageModel.get_peft_model(
        model,
        r = LORA_RANK,
        target_modules = [
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
        lora_alpha = LORA_RANK,
        use_gradient_checkpointing = "unsloth",
        random_state = 3407,
    )

    print("Loading dataset...")
    dataset = load_synthetic_dataset("synthetic_data.jsonl")

    training_args = GRPOConfig(
        output_dir = "outputs",
        learning_rate = 5e-6,
        optim = "adamw_8bit",
        per_device_train_batch_size = BATCH_SIZE,
        gradient_accumulation_steps = GRAD_ACCUM_STEPS,
        max_prompt_length = 256,
        max_completion_length = 256,
        num_generations = 4,
        max_steps = 50, # Very short run for testing
        save_steps = 25,
        fp16 = not is_bfloat16_supported(),
        bf16 = is_bfloat16_supported(),
        logging_steps = 1,
        report_to = "none"
    )

    print("Initializing GRPO Trainer...")
    trainer = GRPOTrainer(
        model = model,
        processing_class = tokenizer,
        reward_funcs = [
            format_reward_func,
            dj_explanation_reward_func,
            relevance_reward_func
        ],
        args = training_args,
        train_dataset = dataset
    )

    print("Starting training loop...")
    trainer.train()

    print("Saving the LoRA adapters...")
    model.save_lora("lora_model")
    tokenizer.save_pretrained("lora_model")
    print("Training complete! Model saved to 'lora_model' directory.")

if __name__ == "__main__":
    train()
