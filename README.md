# Claude Code YOLO Harness

Guardrails for running `claude --dangerously-skip-permissions`

```bash
git clone https://github.com/danilopatrial/harness.git [DIR]
cd [DIR]
rm README.md LICENSE
chmod +x .claude/hooks/yolo-guard.sh
```

Requires `jq`. Check with `/permissions` and `/status` inside a session.

>[!Warning]
>This reduces risk; it does not make YOLO mode safe. Run it in a container or VM.
