# Logo to FPGA Memory Converter
# Converts rosslogo.webp to a Vivado-compatible .mem file (1-bit bitmap)

from PIL import Image
import os

# Configuration
INPUT_IMAGE = os.path.join(os.path.dirname(__file__), "..", "audio", "rosslogo.webp")
OUTPUT_MEM = os.path.join(os.path.dirname(__file__), "..", "rtl", "logo_rom.mem")
TARGET_HEIGHT = 400  # pixels
THRESHOLD = 128  # Brightness threshold for white detection

def convert_logo():
    # Open and process the image
    img = Image.open(INPUT_IMAGE).convert('L')  # Convert to grayscale
    
    # Calculate target width maintaining aspect ratio
    aspect_ratio = img.width / img.height
    target_width = int(TARGET_HEIGHT * aspect_ratio)
    
    # Make width a multiple of 8 for byte alignment
    target_width = (target_width + 7) // 8 * 8
    
    print(f"Original size: {img.width}x{img.height}")
    print(f"Target size: {target_width}x{TARGET_HEIGHT}")
    
    # Resize the image
    img = img.resize((target_width, TARGET_HEIGHT), Image.Resampling.LANCZOS)
    
    # Convert to 1-bit and pack into bytes
    pixels = list(img.getdata())
    
    with open(OUTPUT_MEM, 'w') as f:
        f.write(f"// Logo ROM: {target_width}x{TARGET_HEIGHT} pixels, 1-bit packed\n")
        f.write(f"// Width: {target_width}, Height: {TARGET_HEIGHT}\n")
        f.write(f"// Bytes per row: {target_width // 8}\n\n")
        
        byte_count = 0
        for y in range(TARGET_HEIGHT):
            row_bytes = []
            for x_byte in range(target_width // 8):
                byte_val = 0
                for bit in range(8):
                    x = x_byte * 8 + bit
                    pixel_idx = y * target_width + x
                    if pixels[pixel_idx] >= THRESHOLD:
                        byte_val |= (1 << (7 - bit))  # MSB first
                row_bytes.append(f"{byte_val:02X}")
                byte_count += 1
            f.write(" ".join(row_bytes) + "\n")
    
    print(f"Generated {OUTPUT_MEM}")
    print(f"Total bytes: {byte_count}")
    print(f"Logo dimensions for RTL: WIDTH={target_width}, HEIGHT={TARGET_HEIGHT}")
    
    return target_width, TARGET_HEIGHT

if __name__ == "__main__":
    width, height = convert_logo()
