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
        
    if custom_text and custom_text.lower() != "cpp":
        prompt = custom_text
    else:
        prompt = """These images together form a single question (they may show different scrolled parts of the same problem). Solve the question in C++. Follow these instructions strictly:
1. If it is a multiple-choice question (MCQ), output ONLY the correct option(s) (e.g., A, C). Note that there may be multiple correct answers. Provide absolutely no explanation.
2. If it is a coding question, output ONLY the raw C++ code. DO NOT use markdown code blocks (do not use ```). DO NOT write any comments or explanations. You MUST use and complete the exact class/function template shown on the right side of the code editor in the images.
3. Write the code exactly like a typical human competitive programmer or student. Use short, common variable names (e.g., n, arr, i, j, ans) instead of verbose, highly descriptive AI-style names.
4. Output nothing but the final answer. Zero conversational filler."""


    
    cmd = [
        "/Users/karan/.local/bin/agy",
        "--model", "gemini-3.1-pro",
        "--effort", "high",
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
        # Use the name of the script without extension for the markdown file
        script_name = os.path.splitext(os.path.basename(__file__))[0]
        md_file = os.path.join(delivery_dir, f"{script_name}.md")
        
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
