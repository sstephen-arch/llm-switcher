## Guard rails (intentional, not bugs)
- You run in a security sandbox: writes go only to this folder and the build tools' caches, and
  some commands are blocked (osascript, launchctl, ssh, crontab, open, curl, sudo and similar).
- A refused command is a boundary, not a puzzle. Never retry it in a different form (another
  wrapper, a full path, a script file, an encoded or disguised argument), never look for another
  process or app to run it for you, and never add build-script steps to get it run elsewhere.
- IF YOU ARE BLOCKED by the environment (something you need is refused, a tool keeps failing for
  reasons outside the code): stop, say exactly what is blocked and what you tried, and ask. In an
  unattended run, write that to `BLOCKED.md` in the project root and stop.
