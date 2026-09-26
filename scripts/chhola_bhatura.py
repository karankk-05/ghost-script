#!/usr/bin/env python3
import os
import time
from PIL import ImageGrab

# This script (chhola_bhatura) takes a silent screenshot and saves it to the 'ss' directory
def main():
    # Define paths: scripts directory -> main directory -> ss directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    main_dir = os.path.dirname(script_dir)
    ss_dir = os.path.join(main_dir, "ss")

    # Ensure the 'ss' directory exists
    os.makedirs(ss_dir, exist_ok=True)

    # Generate a timestamped filename
    filename = os.path.join(ss_dir, f"meet_note_{time.strftime('%Y%m%d_%H%M%S')}.png")

    import subprocess
    
    # Take the screenshot silently and save it
    screenshot = ImageGrab.grab()
    screenshot.save(filename)
    
    # Flash green indicator
    subprocess.run(["open", "-g", "ghostscreen://indicator/green"])
    time.sleep(0.5)
    subprocess.run(["open", "-g", "ghostscreen://indicator/off"])

if __name__ == "__main__":
    main()
