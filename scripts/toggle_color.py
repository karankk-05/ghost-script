#!/usr/bin/env python3
import subprocess

# Read current theme from defaults
result = subprocess.run(["defaults", "read", "io.koerbaecher.ghostscreen", "Theme"], capture_output=True, text=True)
current_theme = result.stdout.strip()

if current_theme == "black":
    next_theme = "white"
elif current_theme == "white":
    next_theme = "green"
else:
    next_theme = "black"

# Instantly tell GhostScreen to change
subprocess.run(["open", "-g", f"ghostscreen://theme/{next_theme}"])
print(f"Switched theme to {next_theme} instantly!")
