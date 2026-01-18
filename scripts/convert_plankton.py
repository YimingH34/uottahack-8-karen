# Plankton Images to FPGA Memory Converter
# Converts PNG images to Vivado-compatible .mem files with color and transparency
# Format: 25-bit per pixel (1-bit transparency + 24-bit RGB)

from PIL import Image
import os

# Configuration
SCRIPT_DIR = os.path.dirname(__file__)
TARGET_WIDTH = 400
TARGET_HEIGHT = 340
WHITE_THRESHOLD = 240  # Pixels with R,G,B all > this are treated as transparent

# Input/Output files
IMAGES = [
    {
        "input": os.path.join(SCRIPT_DIR, "..", "audio", "plankton2.png"),  # Green "YOU WIN!"
        "output": os.path.join(SCRIPT_DIR, "..", "rtl", "plankton_win.mem"),
        "name": "win"
    },
    {
        "input": os.path.join(SCRIPT_DIR, "..", "audio", "plankton.png"),   # Red "YOU LOSE!"
        "output": os.path.join(SCRIPT_DIR, "..", "rtl", "plankton_lose.mem"),
        "name": "lose"
    }
]

def convert_image(input_path, output_path, name):
    """Convert a single PNG to .mem format with transparency."""
    print(f"\nConverting {name} image: {input_path}")
    
    # Open image and convert to RGBA
    img = Image.open(input_path).convert('RGBA')
    
    print(f"  Original size: {img.width}x{img.height}")
    
    # Resize while maintaining aspect ratio
    aspect = img.width / img.height
    if aspect > TARGET_WIDTH / TARGET_HEIGHT:
        # Image is wider - fit to width
        new_width = TARGET_WIDTH
        new_height = int(TARGET_WIDTH / aspect)
    else:
        # Image is taller - fit to height
        new_height = TARGET_HEIGHT
        new_width = int(TARGET_HEIGHT * aspect)
    
    img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
    
    # Create a new blank (transparent) image at exact target size and paste centered
    final_img = Image.new('RGBA', (TARGET_WIDTH, TARGET_HEIGHT), (255, 255, 255, 0))
    paste_x = (TARGET_WIDTH - new_width) // 2
    paste_y = (TARGET_HEIGHT - new_height) // 2
    final_img.paste(img, (paste_x, paste_y))
    
    print(f"  Resized to: {new_width}x{new_height}, centered in {TARGET_WIDTH}x{TARGET_HEIGHT}")
    
    # Convert to memory file
    pixels = list(final_img.getdata())
    pixel_count = 0
    visible_count = 0
    
    with open(output_path, 'w') as f:
        f.write(f"// Plankton {name} ROM: {TARGET_WIDTH}x{TARGET_HEIGHT} pixels\n")
        f.write(f"// Format: 25-bit per pixel (bit24=visible, bits23:0=RGB)\n")
        f.write(f"// Total pixels: {TARGET_WIDTH * TARGET_HEIGHT}\n\n")
        
        for y in range(TARGET_HEIGHT):
            for x in range(TARGET_WIDTH):
                idx = y * TARGET_WIDTH + x
                r, g, b, a = pixels[idx]
                
                # Determine transparency:
                # - Alpha < 128 = transparent
                # - White pixels (all channels > threshold) = transparent
                is_white = (r > WHITE_THRESHOLD and g > WHITE_THRESHOLD and b > WHITE_THRESHOLD)
                is_transparent = (a < 128) or is_white
                
                if is_transparent:
                    # Transparent pixel: visibility bit = 0
                    value = 0x0000000
                else:
                    # Visible pixel: bit 24 = 1, bits 23:0 = RGB
                    value = (1 << 24) | (r << 16) | (g << 8) | b
                    visible_count += 1
                
                f.write(f"{value:07X}\n")
                pixel_count += 1
    
    print(f"  Generated: {output_path}")
    print(f"  Total pixels: {pixel_count}, Visible pixels: {visible_count}")
    
    return TARGET_WIDTH, TARGET_HEIGHT

def main():
    print("=" * 60)
    print("Plankton Image to FPGA Memory Converter")
    print("=" * 60)
    
    for img_config in IMAGES:
        if os.path.exists(img_config["input"]):
            convert_image(img_config["input"], img_config["output"], img_config["name"])
        else:
            print(f"\nERROR: Input file not found: {img_config['input']}")
    
    print("\n" + "=" * 60)
    print(f"Conversion complete!")
    print(f"Dimensions for RTL: WIDTH={TARGET_WIDTH}, HEIGHT={TARGET_HEIGHT}")
    print("=" * 60)

if __name__ == "__main__":
    main()
