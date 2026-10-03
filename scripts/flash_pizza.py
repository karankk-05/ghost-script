#!/usr/bin/env python3
import os
import glob
import subprocess
import sys

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    main_dir = os.path.dirname(script_dir)
    ss_dir = os.path.join(main_dir, "ss")

    # Get all png files in the ss directory
    list_of_files = glob.glob(os.path.join(ss_dir, "*.png"))
    
        
    # Show yellow ghost dot indicator
    subprocess.run(["open", "-g", "ghostscreen://indicator/yellow"])
    
    # Sort files by time so the AI reads them in order
    list_of_files.sort(key=os.path.getmtime)
    
    images_str = " ".join([f"@{f}" for f in list_of_files])
    
    # Run agy to process the image using gemini 3.1 pro high


    # Read custom prompt if it exists
    custom_prompt_file = os.path.join(main_dir, "delivery", "custom_prompt.txt")
    if os.path.exists(custom_prompt_file):
        with open(custom_prompt_file, "r") as f:
            custom_text = f.read().strip()
    else:
        custom_text = ""

    FOLLOWUP_SYSTEM = """This is a follow-up question. Follow these rules strictly:
1. If the screenshots show code with failing test cases or a compilation error, analyse the code in detail and pinpoint the exact mistakes. Give the line number and the specific change needed. Do NOT rewrite the entire code. Keep it short.
2. If a general query is asked, answer it concisely.
3. DO NOT use markdown code blocks (do not use ```). Give the answer in plain text only.
4. Output nothing but the answer. Zero conversational filler."""

    if custom_text and custom_text.lower() != "cpp":
        prompt = FOLLOWUP_SYSTEM + "\n\nUser's follow-up: " + custom_text
    else:
        prompt = "solve this given mcq question, answer only yhe final letter, theere can be muitple answers possible. no explanation needed"


    
    cmd = [
        "/Users/karan/.local/bin/agy",
        "--model", "gemini-3.8-flash",
        "--effort", "low",
        "--dangerously-skip-permissions",
        "-p", f"{prompt}" + (f" {images_str}" if images_str else "")
    ]
    
    try:
        # Run agy and capture output
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        output = result.stdout.strip()
        
        # Move processed screenshots to an archive folder so the next question starts fresh
        archive_dir = os.path.join(ss_dir, "archive")
        os.makedirs(archive_dir, exist_ok=True)
        import shutil
        for f in list_of_files:
            shutil.move(f, os.path.join(archive_dir, os.path.basename(f)))
        
        # Copy output to clipboard
        process = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE)
        process.communicate(output.encode('utf-8'))
        
        # Save output to delivery folder
        delivery_dir = os.path.join(main_dir, "delivery")
        os.makedirs(delivery_dir, exist_ok=True)
        # Force it to use the exact same file as margherita_pizza
        md_file = os.path.join(delivery_dir, "margherita_pizza.md")
        
        with open(md_file, "w") as f:
            f.write(output)
            f.write("\n")
            
        # Turn off indicator
        subprocess.run(["open", "-g", "ghostscreen://indicator/off"])
        
        print(f"Output saved to {md_file} and copied to clipboard.")
        
    except subprocess.CalledProcessError as e:
        subprocess.run(["open", "-g", "ghostscreen://indicator/off"])
        print(f"Error running agy: {e.stderr}")
        sys.exit(1)

if __name__ == "__main__":
    main()
