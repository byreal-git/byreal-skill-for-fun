# Just for fun

Community skills for [RealClaw](https://byreal.io) — drop them into your workspace and go.

## Skills

| Skill | Description |
|-------|-------------|
| [byreal-hermes-deploy-native](./byreal-hermes-deploy-native/) | Deploy a [Hermes](https://github.com/NousResearch/hermes-agent) Telegram bot on top of RealClaw's built-in LLM API. One command, no external API key needed. |

## Install

Copy any skill directory into your RealClaw workspace:

```bash
# Clone
git clone https://github.com/byreal-git/byreal-skill-for-fun.git

# Copy the skill you want
cp -r byreal-skill-for-fun/<skill-name> ~/.openclaw/workspace/skills/
```

Then tell your RealClaw agent to run it (e.g. "install hermes").

## Structure

Each top-level directory is a standalone skill:

```
<skill-name>/
├── SKILL.md          # Entry point — trigger phrases, instructions, flow
└── references/       # Supporting files (docs, scripts, templates)
```

## License

MIT
